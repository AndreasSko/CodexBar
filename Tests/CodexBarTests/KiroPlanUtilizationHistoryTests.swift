import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct KiroPlanUtilizationHistoryTests {
    @Test
    func `record plan history stores kiro monthly credits series`() async {
        let store = UsageStorePlanUtilizationTests.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO POWER",
            creditsUsed: 1666.37,
            creditsTotal: 10000,
            creditsPercent: 16.6637,
            bonusCreditsUsed: 5,
            bonusCreditsTotal: 20,
            bonusExpiryDays: 14,
            resetsAt: now.addingTimeInterval(20 * 24 * 60 * 60),
            updatedAt: now).toUsageSnapshot()

        await store.recordPlanUtilizationHistorySample(provider: .kiro, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .kiro)
        #expect(histories.count == 1)
        #expect(findSeries(histories, name: .monthly, windowMinutes: 43200)?.entries.last?.usedPercent == 16.6637)
    }
}
