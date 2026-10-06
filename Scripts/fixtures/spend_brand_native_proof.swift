#if DEBUG
import AppKit
import CodexBarCore

/// Local proof overlay: runs the production settings window in a packaged app with synthetic inputs.
@MainActor
enum SpendBrandNativeProof {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--spend-brand-proof") else { return false }
        let environment = ProcessInfo.processInfo.environment
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment["CODEXBAR_TEST_CODEX_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              let output = environment["CODEXBAR_SPEND_BRAND_NATIVE_DIR"]
        else { fatalError("Use the isolated proof launcher") }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = Delegate(output: URL(fileURLWithPath: output, isDirectory: true))
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
        return true
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        let output: URL
        var windowController: SettingsWindowController?
        var settings: SettingsStore?
        var store: UsageStore?
        var controller: SpendDashboardController?
        var timer: Timer?

        init(output: URL) { self.output = output }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do { try await self.open() }
                catch { fatalError("Synthetic proof setup failed: \(error)") }
            }
        }

        private func open() async throws {
            let defaults = UserDefaults(suiteName: "com.steipete.codexbar.brand-proof.\(UUID())")!
            defaults.set(true, forKey: "debugDisableKeychainAccess")
            defaults.set(["en"], forKey: "AppleLanguages")
            let configStore = CodexBarConfigStore(fileURL: self.output.appendingPathComponent("config.json"))
            var config = CodexBarConfig.makeDefault(metadata: ProviderRegistry.shared.metadata)
            let providers: Set<UsageProvider> = [.claude, .codex, .cursor]
            for index in config.providers.indices {
                config.providers[index].enabled = config.providers[index].id.firstPartyProvider
                    .map { providers.contains($0) } ?? false
            }
            try configStore.save(config)
            let settings = SettingsStore(
                userDefaults: defaults, configStore: configStore, performInitialProviderDetection: false)
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.costUsageEnabled = true
            settings.openCodexUsageLogsEnabled = true
            settings.preferredCurrencyCode = "USD"
            settings.costUsageBucketTimeZoneIdentifier = "UTC"
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings, startupBehavior: .testing, environmentBase: [:])
            store._test_providerRefreshOverride = { _ in fatalError("Proof must not start a provider transport") }
            store._test_widgetSnapshotSaveOverride = { _ in }
            let now = Date()
            let inputs = Self.inputs(now: now)
            let controller = SpendDashboardController(
                userDefaults: defaults,
                requestBuilder: { mode in
                    SpendDashboardLoadRequest(
                        configuration: SpendDashboardSource.configuration(settings: settings, store: store),
                        capturedInputs: inputs, unavailableSourceIDs: [], codexRequests: [],
                        now: now, force: mode.forcesLoader)
                },
                loader: { request in
                    SpendDashboardLoadResult(inputs: request.capturedInputs, failedSourceIDs: [])
                },
                nowProvider: { now },
                publicationHandler: { store.spendDashboardPublication = $0 })
            store.sharedSpendDashboardControllerStorage = controller
            controller.update(configuration: SpendDashboardSource.configuration(settings: settings, store: store))
            while controller.isRefreshing {
                try await Task.sleep(for: .milliseconds(50))
            }
            self.settings = settings
            self.store = store
            self.controller = controller
            let selection = PreferencesSelection(userDefaults: defaults)
            selection.pane = .general
            let managed = ManagedCodexAccountCoordinator()
            let promotion = CodexAccountPromotionCoordinator(
                settingsStore: settings, usageStore: store, managedAccountCoordinator: managed)
            let windowController = SettingsWindowController(
                settings: settings, store: store, cloudSyncState: CloudSyncState(),
                updater: DisabledUpdaterController(), selection: selection,
                managedCodexAccountCoordinator: managed, codexAccountPromotionCoordinator: promotion,
                runProviderLoginFlow: { _ in fatalError("Proof must not start a login flow") })
            self.windowController = windowController
            guard windowController.open(pane: .general) != .failed, let window = windowController.window
            else { fatalError("Production settings window failed to open") }
            window.setContentSize(NSSize(width: 1040, height: 840))
            window.center()
            window.title = "CodexBar — Synthetic brand proof"
            let menu = NSMenu()
            let applicationMenu = NSMenu()
            let appearance = NSMenuItem(
                title: "Toggle proof appearance", action: #selector(self.toggleAppearance), keyEquivalent: "d")
            appearance.target = self
            applicationMenu.addItem(appearance)
            applicationMenu.addItem(
                withTitle: "Quit proof",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
            let applicationItem = NSMenuItem()
            applicationItem.submenu = applicationMenu
            menu.addItem(applicationItem)
            NSApplication.shared.mainMenu = menu
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in
                    let icons: [[String: Any]] = providers.sorted { $0.rawValue < $1.rawValue }.map {
                        [
                            "provider": $0.rawValue,
                            "brandTemplate": ProviderBrandIcon.image(for: $0, style: .brand)?.isTemplate ?? true,
                            "childTemplate": ProviderBrandIcon.image(for: $0, style: .monochrome)?.isTemplate ?? false,
                        ]
                    }
                    let receipt: [String: Any] = [
                        "syntheticOnly": true, "entrypoint": "SettingsWindowController.open",
                        "selectedPane": selection.pane.persistenceToken,
                        "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
                        "applicationBundle": Bundle.main.bundleURL.lastPathComponent,
                        "bundledResourceLookup": Bundle.main.bundleURL.pathExtension == "app",
                        "groups": controller.model.groups.count, "icons": icons,
                        "appearance": window.effectiveAppearance.name.rawValue,
                    ]
                    try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                        .write(to: self.output.appendingPathComponent("runtime-receipt.json"), options: .atomic)
                }
            }
        }

        @objc private func toggleAppearance() {
            guard let window = self.windowController?.window else { return }
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApplication.shared.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            window.appearance = nil
        }

        private static func inputs(now: Date) -> [SpendDashboardModel.ProviderInput] {
            let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: now)
            func snapshot(_ model: String, cost: Double, tokens: Int) -> CostUsageTokenSnapshot {
                let entry = CostUsageDailyReport.Entry(
                    date: day, inputTokens: tokens, outputTokens: 0, totalTokens: tokens, costUSD: cost,
                    modelsUsed: [model],
                    modelBreakdowns: [.init(modelName: model, costUSD: cost, totalTokens: tokens)])
                return CostUsageTokenSnapshot(
                    sessionTokens: tokens, sessionCostUSD: cost, last30DaysTokens: tokens,
                    last30DaysCostUSD: cost, historyDays: 30, historyCoverageIsEstablished: true,
                    daily: [entry], updatedAt: now)
            }
            return [
                .init(
                    provider: .claude,
                    displayName: "Claude",
                    snapshot: snapshot("claude-sonnet-4", cost: 2.5, tokens: 42000)),
                .init(
                    id: "personal",
                    provider: .codex,
                    displayName: "Personal",
                    snapshot: snapshot("gpt-4.1", cost: 4.25, tokens: 200_000)),
                .init(
                    id: SpendDashboardModel.openCodexSourceID,
                    provider: .codex,
                    displayName: "OpenCodex",
                    snapshot: snapshot("example-test-model", cost: 1.75, tokens: 90000),
                    sourceKind: .openCodex),
                .init(
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: snapshot("claude-sonnet-4", cost: 3.5, tokens: 90000)),
            ]
        }
    }
}
#endif
