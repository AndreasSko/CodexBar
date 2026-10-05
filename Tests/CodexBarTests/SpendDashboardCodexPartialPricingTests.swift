import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardCodexPartialPricingTests {
    /// A Codex model subtotal that leaves requests unpriced is a partial breakdown, even though the model costs
    /// add up to the day's known cost.
    @Test(arguments: [false, true])
    func `codex days with unpriced requests mark the model breakdown partial`(partial: Bool) throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-09-16",
            inputTokens: 600_000,
            outputTokens: 0,
            totalTokens: 600_000,
            costUSD: 2,
            modelsUsed: ["gpt-5.4"],
            modelBreakdowns: [.init(modelName: "gpt-5.4", costUSD: 2, totalTokens: 600_000)],
            unpricedRequestCount: partial ? 1 : nil,
            pricedRequestCount: partial ? 2 : nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 600_000,
            sessionCostUSD: 2,
            last30DaysTokens: 600_000,
            last30DaysCostUSD: 2,
            costProvenance: .listPriceEstimate,
            daily: [entry],
            updatedAt: Self.now)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)
        let expectedCompleteness: SpendDashboardModel.ModelHistoryCompleteness = partial ? .incomplete : .complete

        #expect(group.modelHistoryCompleteness == expectedCompleteness)
        #expect(group.hasPartialCost == partial)
        #expect(group.models.first?.totalCost == 2)
    }

    static let now = Date(timeIntervalSince1970: 1_789_560_000) // 2026-09-16 12:00 UTC.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
