import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusItemBalanceDisplayTests {
    @Test(arguments: [MenuBarDisplayMode.pace, .both])
    func `kiro menu bar follows the global pace display mode`(mode: MenuBarDisplayMode) {
        let settings = self.makeSettings(
            suiteName: "StatusItemBalanceDisplayTests-kiro-pace-\(mode.rawValue)",
            provider: .kiro)
        settings.menuBarDisplayMode = mode
        settings.kiroMenuBarDisplayMode = .automatic
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        // A third of the month has passed, but 60% of the credits are spent.
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO POWER",
            creditsUsed: 6000,
            creditsTotal: 10000,
            creditsPercent: 60,
            bonusCreditsUsed: nil,
            bonusCreditsTotal: nil,
            bonusExpiryDays: nil,
            resetsAt: Date().addingTimeInterval(20 * 24 * 60 * 60),
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kiro)
        store._setErrorForTesting(nil, provider: .kiro)

        let displayText = controller.menuBarDisplayText(for: .kiro, snapshot: snapshot)

        let expectedPrefix = mode == .pace ? "+" : "4000 · +"
        #expect(displayText?.hasPrefix(expectedPrefix) == true)
        #expect(displayText?.hasSuffix("%") == true)
    }
}
