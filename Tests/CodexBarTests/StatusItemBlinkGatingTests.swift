import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemBlinkGatingTests {
    @Test
    func `brand icon mode stops the blink task because brand icons never draw blink frames`() {
        let settings = testSettingsStore(suiteName: "StatusItemBlinkGatingTests-brand-icon")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.randomBlinkEnabled = true
        settings.menuBarShowsBrandIconWithPercent = false
        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        // Without a snapshot the icon shows the loading animation, which suppresses blinking on its own.
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        controller.updateBlinkingState()
        #expect(controller.blinkTask != nil)

        settings.menuBarShowsBrandIconWithPercent = true
        controller.updateBlinkingState()
        #expect(controller.blinkTask == nil)
    }
}
