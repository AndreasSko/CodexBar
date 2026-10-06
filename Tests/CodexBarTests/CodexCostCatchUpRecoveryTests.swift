import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct CodexCostCatchUpRecoveryTests {
    @Test
    func `progress does not replenish the recovery allowance and accounts are independent`() {
        var recovery = CodexCostCatchUpRecovery()
        let deferred = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "same",
            passDiagnostics: .init(
                durationBudget: 0.001,
                fileAttempts: 0,
                bytesConsumed: 0,
                deferredByTime: true))
        let first = recovery.shouldRecover(scope: "one", previousProgressKey: "same", status: deferred)
        let changed = recovery.shouldRecover(scope: "one", previousProgressKey: "other", status: deferred)
        let repeated = recovery.shouldRecover(scope: "one", previousProgressKey: "same", status: deferred)
        let otherAccount = recovery.shouldRecover(scope: "two", previousProgressKey: "same", status: deferred)
        #expect(first)
        #expect(!changed)
        #expect(!repeated)
        #expect(otherAccount)
    }

    @Test(arguments: ["attempted", "read", "bytes", "validation", "missing", "cycle"])
    func `recovery requires an empty time deferral in the immediately previous state`(kind: String) {
        var recovery = CodexCostCatchUpRecovery()
        let diagnostics = CodexScanPassDiagnostics(
            durationBudget: 0.001,
            fileAttempts: kind == "attempted" ? 1 : 0,
            bytesConsumed: kind == "read" ? 1 : 0,
            deferredByTime: kind != "bytes",
            deferredByBytes: kind == "bytes",
            priorityValidationPending: kind == "validation")
        let shouldRecover = recovery.shouldRecover(
            scope: "fixture",
            previousProgressKey: kind == "cycle" ? "other" : "same",
            status: .init(
                pending: true,
                progressKey: "same",
                passDiagnostics: kind == "missing" ? nil : diagnostics))
        #expect(!shouldRecover)
    }

    @Test(arguments: [false, true], [false, true])
    func `workers restore a full budget once and keep the terminal stall guard`(
        dashboard: Bool,
        stillStalled: Bool) async throws
    {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "recovery-workers")
        defer {
            store.cancelCodexCostCatchUp()
            store.cancelSpendDashboardCodexCostCatchUp()
        }
        store.settings.backgroundWorkLowPowerModePreference = .off
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        var advances = 0
        var budgets: [TimeInterval] = []
        var sleeps: [TimeInterval] = []
        let initial = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "initial")
        let advance: @MainActor () -> CostUsageFetcher.CodexScanCatchUpStatus = {
            advances += 1
            return .init(
                pending: advances < 3 || stillStalled,
                progressKey: advances < 3 || stillStalled ? "advanced" : "complete",
                passDiagnostics: .init(
                    durationBudget: budgets.last,
                    fileAttempts: advances == 1 ? 1 : 0,
                    bytesConsumed: advances == 1 ? 1 : 0,
                    deferredByTime: advances != 1))
        }
        store._test_codexCostCatchUpBudgetObserver = { budgets.append($0) }
        if dashboard {
            store._test_spendDashboardCodexCostCatchUpActiveDuration = 1.999
            store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in initial }
            store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in advance() }
            store._test_spendDashboardCodexCostCatchUpSleepOverride = { sleeps.append($0) }
            store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
            await store.spendDashboardCodexCostCatchUpTask?.value
        } else {
            store._test_codexCostCatchUpActiveDuration = 1.999
            store._test_codexCostCatchUpStatusOverride = { _ in
                advances >= 3 && !stillStalled ? .init(
                    pending: false,
                    progressKey: "complete") : initial
            }
            store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in advance() }
            store._test_codexCostCatchUpSleepOverride = { sleeps.append($0) }
            store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_cachedCodexTokenSnapshotLoaderOverride = { now, _, _ in
                guard advances >= 3, !stillStalled else { return nil }
                return (CostUsageTokenSnapshot(
                    sessionTokens: 0,
                    sessionCostUSD: nil,
                    last30DaysTokens: 0,
                    last30DaysCostUSD: nil,
                    historyCoverageIsEstablished: true,
                    daily: [],
                    updatedAt: now), now, nil)
            }
            store.startCodexCostCatchUpIfNeeded()
            await store.codexCostCatchUpTask?.value
        }
        #expect(advances == 3)
        #expect(budgets.count == 3)
        #expect(budgets.first == 2)
        #expect(abs((budgets.dropFirst().first ?? 0) - 0.001) < 0.000001)
        #expect(budgets.last == 2)
        #expect(abs((sleeps.last ?? 0) - 3.998 * 999) < 0.000001)
        let activity = dashboard ? store.spendDashboardCodexCostCatchUpActivity : store.codexCostCatchUpActivity
        #expect(activity?.phase == (stillStalled ? .paused : .complete))
        #expect(activity?.pauseReason == (stillStalled ? .noProgress : nil))
    }

    @Test(arguments: [CodexCostCatchUpPowerSource.ac, .battery, .unknown])
    func `a requested fresh budget pays the automatic duty cycle even after cheap work`(
        source: CodexCostCatchUpPowerSource) throws
    {
        let policy = CodexCostCatchUpPolicy()
        let input = CodexCostCatchUpPolicy.Input(
            mode: .automatic,
            previousActiveDuration: 0.001,
            powerSource: source,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            requiresFreshBudget: true)
        let decision = policy.decision(for: input)
        let duty = try #require(decision.targetDutyCycle)
        #expect(decision.action == .runAfter(2 * (1 - duty) / duty))
        var constrained = input
        // Resource constraints are read again before a recovery starts.
        constrained = .init(
            mode: .automatic,
            previousActiveDuration: 0.001,
            powerSource: source,
            lowPowerModeEnabled: true,
            thermalState: .nominal,
            requiresFreshBudget: true)
        #expect(policy.decision(for: constrained).action == .pause(60, .lowPower))
        constrained = .init(
            mode: .automatic,
            previousActiveDuration: 0.001,
            powerSource: source,
            lowPowerModeEnabled: false,
            thermalState: .serious,
            requiresFreshBudget: true)
        #expect(policy.decision(for: constrained).action == .pause(60, .thermal))
    }

    @Test(arguments: [false, true])
    func `a user stop during recovery cooldown prevents the extra pass`(dashboard: Bool) async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "recovery-stop")
        defer {
            store.cancelCodexCostCatchUp()
            store.cancelSpendDashboardCodexCostCatchUp()
        }
        store.settings.backgroundWorkLowPowerModePreference = .off
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        var advances = 0
        let status = CostUsageFetcher.CodexScanCatchUpStatus(
            pending: true,
            progressKey: "same",
            passDiagnostics: .init(
                durationBudget: 0.001,
                fileAttempts: 0,
                bytesConsumed: 0,
                deferredByTime: true))
        if dashboard {
            store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in status }
            store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in advances += 1; return status }
            store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_spendDashboardCodexCostCatchUpSleepOverride = { delay in
                if delay > 0 { store.stopSpendDashboardCodexCostCatchUp() }
            }
            store.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts)
            await store.spendDashboardCodexCostCatchUpTask?.value
        } else {
            store._test_codexCostCatchUpStatusOverride = { _ in status }
            store._test_codexCostCatchUpAdvanceOverride = { _, _, _ in advances += 1; return status }
            store._test_cachedCodexTokenSnapshotLoaderOverride = { _, _, _ in nil }
            store._test_codexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
            store._test_codexCostCatchUpSleepOverride = { delay in
                if delay > 0 { store.stopCodexCostCatchUp() }
            }
            store.startCodexCostCatchUpIfNeeded()
            await store.codexCostCatchUpTask?.value
        }
        #expect(advances == 1)
        #expect((dashboard ? store.spendDashboardCodexCostCatchUpActivity : store.codexCostCatchUpActivity)?
            .pauseReason == .user)
    }

    @Test(arguments: ["unconfirmed", "old", "pending", "scope-mismatch", "unavailable", "new-account", "settings"])
    func `unproven or changed-scope results preserve the paused dashboard`(kind: String) async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-guards")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        var advances = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            return .init(
                pending: true,
                progressKey: "same")
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        let activity = store.spendDashboardCodexCostCatchUpActivity
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            .init(
                pending: kind == "pending",
                progressKey: kind,
                lastScanAt: kind == "old" ? .distantPast : .distantFuture,
                completionIsConfirmed: !["unconfirmed", "scope-mismatch", "unavailable"].contains(kind))
        }
        if kind == "settings" { store.settings.costUsageHistoryDays = 365 }
        let current = kind == "new-account"
            ? [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: "other",
                cacheIdentity: "other")] : accounts
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: current)
        await store.spendDashboardCodexCostCatchUpCompletion.task?.value
        #expect(store.spendDashboardCodexCostCatchUpActivity == activity)
        #expect(advances == 1)
        #expect(store.spendDashboardCodexCostCatchUpTask == nil)
    }

    @Test
    func `previously complete accounts do not need a new scan to clear another account stall`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-multiple")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = ["one", "two"].map {
            UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: $0,
                cacheIdentity: $0)
        }
        var advances = 0
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            .init(
                pending: account.id == "two",
                progressKey: account.id,
                lastScanAt: .distantPast,
                completionIsConfirmed: account.id == "one")
        }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in
            advances += 1
            return .init(
                pending: true,
                progressKey: "two")
        }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { account in
            .init(
                pending: false,
                progressKey: account.id,
                lastScanAt: account.id == "two" ? .distantFuture : .distantPast,
                completionIsConfirmed: true)
        }
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        await store.spendDashboardCodexCostCatchUpCompletion.task?.value
        #expect(store.spendDashboardCodexCostCatchUpActivity?.phase == .complete)
        #expect(advances == 1)
    }

    @Test
    func `an account change cancels a completion check already awaiting a read`() async throws {
        let store = try UsageStoreSpendDashboardCodexCostCatchUpTests.makeStore(suite: "completion-race")
        defer { store.cancelSpendDashboardCodexCostCatchUp() }
        let accounts = [UsageStoreSpendDashboardCodexCostCatchUpTests.account(
            id: "fixture",
            cacheIdentity: "fixture")]
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpAdvanceOverride = { _, _, _ in .init(
            pending: true,
            progressKey: "same") }
        store._test_spendDashboardCodexCostCatchUpSleepOverride = { _ in }
        store._test_spendDashboardCodexCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        store.startSpendDashboardCodexCostCatchUpIfNeeded(
            accounts: accounts,
            mode: .accelerated)
        await store.spendDashboardCodexCostCatchUpTask?.value
        var continuation: CheckedContinuation<Void, Never>?
        store._test_spendDashboardCodexCostCatchUpStatusOverride = { _ in
            await withCheckedContinuation { continuation = $0 }
            return .init(
                pending: false,
                progressKey: "complete",
                lastScanAt: .distantFuture,
                completionIsConfirmed: true)
        }
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: accounts)
        let task = try #require(store.spendDashboardCodexCostCatchUpCompletion.task)
        for _ in 0..<1000 {
            if continuation != nil { break }
            await Task.yield()
        }
        let read = try #require(continuation)
        store.synchronizeSpendDashboardCodexCostCatchUp(accounts: [
            UsageStoreSpendDashboardCodexCostCatchUpTests.account(
                id: "other",
                cacheIdentity: "other"),
        ])
        read.resume()
        await task.value
        #expect(store.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress)
        #expect(store.spendDashboardCodexCostCatchUpCompletion.task == nil)
    }
}
