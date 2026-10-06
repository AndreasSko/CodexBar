// Copy this file into Tests/CodexBarTests temporarily and run its suite with test_environment.sh sourced.
// The dashboard allocates one unique fixture account cache; it never reads an existing account cache.
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct CodexCostCatchUpProductionProofTests {
    @Test
    func `real menu worker recovers a time yield through the scanner and SQLite`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let grants = CodexCredentialFileAccess.FixtureScope(roots: [env.root])
        try await CodexCredentialFileAccess.withFixtureScope(grants) {
            let day = Date()
            try Self.writeSessions(env: env, day: day)
            var options = CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot,
                cacheRoot: env.cacheRoot,
                codexTraceDatabaseURL: env.root.appendingPathComponent("absent-trace.sqlite"))
            options.refreshMinIntervalSeconds = 0
            options.maxCodexScanDurationPerRefresh = nil
            let since = CostReportingPeriod.rolling(days: 30).bounds(now: day, calendar: options.calendar).lowerBound
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex, since: since, until: day, now: day, options: options)
            var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let pendingPath = try #require(cache.files.keys.max())
            cache.files[pendingPath]?.codexScanComplete = false
            cache.codexScanCatchUpPending = true
            cache.codexScanInventoryPaths = nil
            let roots = CostUsageScanner.codexSessionsRoots(options: options)
                .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
            cache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
                scanSinceKey: #require(cache.scanSinceKey),
                rootPaths: roots,
                completedRootPaths: roots,
                pendingFilePaths: [pendingPath],
                completedCurrentWindowRootPaths: roots,
                completedCurrentWindowFlatRootPaths: roots)
            CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)

            let clock = ProofBudgetClock()
            let recorder = CostUsageScanner.CodexScanWorkRecorder()
            options.codexScanWorkRecorderForTesting = recorder
            let fetcher = CostUsageFetcher(scannerOptions: options)
            let store = try Self.makeStore(home: env.codexHomeRoot, fetcher: fetcher)
            defer { store.cancelCodexCostCatchUp() }
            let original = await fetcher.codexScanCatchUpStatus()
            try #require(original.pending)
            var budgets: [TimeInterval] = []
            var cooldowns: [TimeInterval] = []
            var previousKey = original.progressKey
            var recoveryBudgetIndex: Int?
            var lastDiagnostics: CodexScanPassDiagnostics?
            store._test_codexCostCatchUpBudgetObserver = { budgets.append($0) }
            store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            // Forward every request to the real fetcher, scanner, executor, and SQLite cache.
            // Each empty pass gets a fresh clock-controlled budget; recovery uses the normal wall clock.
            store._test_codexCostCatchUpAdvanceOverride = { now, homePath, historyDays in
                var passOptions = options
                let duration = try #require(budgets.last)
                if cooldowns.isEmpty {
                    clock.resume()
                    passOptions.codexScanBudgetForTesting = CostUsageScanner.CodexScanBudget(
                        maxFileBytes: 0, maxBytesPerRefresh: 0, maxDuration: duration, now: { clock.now })
                    clock.expire()
                }
                let result = try await CostUsageFetcher(scannerOptions: passOptions).advanceCodexScanCatchUp(
                    now: now,
                    codexHomePath: homePath,
                    historyDays: historyDays,
                    scanDurationPerRefresh: duration,
                    calendar: store.settings.costUsageBucketCalendar)
                store._test_codexCostCatchUpActiveDuration = result.activeDuration
                lastDiagnostics = result.value.passDiagnostics
                return result.value
            }
            store._test_codexCostCatchUpSleepOverride = { delay in
                guard delay > 0 else {
                    previousKey = await fetcher.codexScanCatchUpStatus().progressKey
                    return
                }
                cooldowns.append(delay)
                let repeated = await fetcher.codexScanCatchUpStatus()
                try #require(repeated.pending)
                try #require(repeated.progressKey == previousKey)
                try #require(recorder.snapshot().codexFileScanAttempts == 0)
                try #require(lastDiagnostics?.yieldedBeforeFileAttempt == true)
                print("PROOF recovery emptyPass=true sameKey=true fileAttempts=0 bytesRead=0 timeDeferred=true")
                print("PROOF recovery cooldownScheduled=true fullBudgetRequested=2")
                recoveryBudgetIndex = budgets.count
                clock.resume()
            }
            try #require(store._test_codexCostCatchUpStatusOverride == nil)
            try #require(store._test_cachedCodexTokenSnapshotLoaderOverride == nil)
            store.startCodexCostCatchUpIfNeeded()
            await store.codexCostCatchUpTask?.value
            let completed = await fetcher.codexScanCatchUpStatus(historyDays: store.settings.costUsageHistoryDays)
            try #require(!completed.pending)
            try #require(completed.completionIsConfirmed)
            try #require(store.codexCostCatchUpActivity?.phase == .complete)
            try #require(budgets.first == 2)
            let freshIndex = try #require(recoveryBudgetIndex)
            try #require(budgets[freshIndex] == 2)
            try #require(cooldowns.count == 1)
            try #require(recorder.snapshot().codexFileScanAttempts > 0)
            print("PROOF recovery realWorkerPhase=complete pending=false coverageConfirmed=true scannerAttempted=true")
        }
    }

    @Test
    func `a real dashboard stall clears after another scanner completes the same SQLite cache`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let account = CodexSpendScanRequest(
            id: "fixture",
            displayName: "Fixture",
            source: .profileHome(path: env.codexHomeRoot.path),
            homePath: env.codexHomeRoot.path,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: "catch-up-proof-" + UUID().uuidString)
        let cacheRoot = SpendDashboardSource.codexCacheRoot(for: account)
        try #require(!FileManager.default.fileExists(atPath: cacheRoot.path))
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let grants = CodexCredentialFileAccess.FixtureScope(roots: [env.root])
        try await CodexCredentialFileAccess.withFixtureScope(grants) {
            let files = try Self.writeSessions(env: env, day: Date())
            let blocked = try #require(files.last)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
            let store = try Self.makeStore(home: env.codexHomeRoot, fetcher: CostUsageFetcher())
            defer { store.cancelSpendDashboardCodexCostCatchUp() }
            let fetcher = CostUsageFetcher(cacheRoot: cacheRoot, calendar: store.settings.costUsageBucketCalendar)
            let historyDays = max(SpendDashboardSource.scanDays, store.settings.costUsageHistoryDays)
            let initial = try await fetcher.advanceCodexScanCatchUp(
                codexHomePath: account.homePath, historyDays: historyDays, scanDurationPerRefresh: 10)
            try #require(initial.value.pending)
            var workerPasses = 0
            store._test_codexCostCatchUpBudgetObserver = { _ in workerPasses += 1 }
            store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
            try #require(store._test_spendDashboardCodexCostCatchUpStatusOverride == nil)
            try #require(store._test_spendDashboardCodexCostCatchUpAdvanceOverride == nil)
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: [account], mode: .accelerated)
            await store.spendDashboardCodexCostCatchUpTask?.value
            try #require(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
            try #require(store.spendDashboardCodexCostCatchUpTask == nil)
            try #require(workerPasses > 0)
            print("PROOF completion realWorkerPhase=paused reason=noProgress workerRunning=false")

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path)
            try await Task.sleep(for: .milliseconds(20))
            var completed = try await fetcher.advanceCodexScanCatchUp(
                codexHomePath: account.homePath, historyDays: historyDays, scanDurationPerRefresh: 10)
            for _ in 0..<16 where completed.value.pending {
                completed = try await fetcher.advanceCodexScanCatchUp(
                    codexHomePath: account.homePath, historyDays: historyDays, scanDurationPerRefresh: 10)
            }
            try #require(!completed.value.pending)
            try #require(completed.value.completionIsConfirmed)
            let pause = try #require(store.spendDashboardCodexCostCatchUpCompletion.pause)
            try #require(try #require(completed.value.lastScanAt) > pause.pausedAt)
            let passesBeforeRead = workerPasses
            store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [account])
            await store.spendDashboardCodexCostCatchUpCompletion.task?.value
            try #require(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
            try #require(store.spendDashboardCodexCostCatchUpTask == nil)
            try #require(workerPasses == passesBeforeRead)
            print("PROOF completion otherScannerPending=false coverageConfirmed=true scanNewerThanPause=true")
            print("PROOF completion realWorkerPhase=complete extraWorkerPasses=0 readOnlyClear=true")
        }
    }

    private static func makeStore(home: URL, fetcher: CostUsageFetcher) throws -> UsageStore {
        let settings = testSettingsStore(suiteName: "production-proof", userDefaults: InMemoryUserDefaults())
        settings.costUsageEnabled = true
        settings.backgroundWorkLowPowerModePreference = .off
        for provider in [UsageProvider.codex, .pi] {
            let metadata = try #require(ProviderRegistry.shared.metadata[provider])
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: true)
        }
        let environment = ["CODEX_HOME": home.path]
        settings._test_codexReconciliationEnvironment = environment
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: fetcher,
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment,
            widgetSnapshotURL: home.appendingPathComponent("fixture-widget.json"),
            widgetTimelineReloader: {})
    }

    @discardableResult
    private static func writeSessions(env: CostUsageTestEnvironment, day: Date) throws -> [URL] {
        try (0..<2).map { index in
            try env.writeCodexSessionFile(
                day: day,
                filename: "fixture-\(index).jsonl",
                contents: "{\"type\":\"session_meta\",\"timestamp\":\"\(env.isoString(for: day))\","
                    + "\"payload\":{\"session_id\":\"fixture-\(index)\"}}\n"
                    + "{\"type\":\"turn_context\",\"timestamp\":\"\(env.isoString(for: day))\","
                    + "\"payload\":{\"model\":\"openai/gpt-5.2-codex\"}}\n"
                    + "{\"type\":\"event_msg\",\"timestamp\":\"\(env.isoString(for: day))\","
                    + "\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{"
                    + "\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10},"
                    + "\"model\":\"openai/gpt-5.2-codex\"}}}\n")
        }
    }
}

private final class ProofBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var expired = false

    var now: ContinuousClock.Instant {
        self.lock.withLock { self.origin.advanced(by: .seconds(self.expired ? 3 : 0)) }
    }

    func expire() { self.lock.withLock { self.expired = true } }
    func resume() { self.lock.withLock { self.expired = false } }
}
