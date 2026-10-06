import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendModelHistoryWarningTests {
    @Test(arguments: [UsageProvider.codex, .claude, .pi, .antigravity])
    func `complete token coverage with unknown prices has a pricing warning`(provider: UsageProvider) throws {
        let breakdown = try Self.breakdown(provider: provider, entries: [Self.entry()])
        #expect(breakdown.modelHistoryWarning == .unpriced)
        #expect(breakdown.models.first?.totalTokens == 100)
        #expect(breakdown.models.first?.totalCost == nil)
        #expect(!breakdown.hasPartialTokens)
    }

    @Test(arguments: [UsageProvider.codex, .claude, .pi, .antigravity])
    func `missing usage has an incomplete warning beside known subtotals`(provider: UsageProvider) throws {
        let breakdown = try Self.breakdown(provider: provider, entries: [
            Self.entry(cost: 1), Self.entry(day: "2026-09-15", tokens: nil, incomplete: 1),
        ])
        #expect(breakdown.modelHistoryWarning == .incompleteUsage)
        #expect(breakdown.totalTokens == 100)
        #expect(breakdown.totalCost == 1)
        #expect(breakdown.incompleteRequestCount == 1)
    }

    @Test(arguments: [UsageProvider.codex, .claude, .pi, .antigravity])
    func `a partial scan cannot be presented as only missing prices`(provider: UsageProvider) throws {
        let breakdown = try Self.breakdown(provider: provider, entries: [Self.entry()], historyScanIsPartial: true)
        #expect(breakdown.modelHistoryWarning == .partial)
        #expect(breakdown.tokensAreLowerBound)
    }

    @Test
    func `unattributed tokens keep the partial history warning`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-09-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 120,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "fixture-model", costUSD: nil, totalTokens: 100)])
        let breakdown = try Self.breakdown(entries: [entry])
        #expect(breakdown.modelHistoryWarning == .partial)
    }

    @Test
    func `selected day pricing warning does not inherit exclusions from other days`() throws {
        let breakdown = try Self.breakdown(entries: [
            Self.entry(), Self.entry(day: "2026-09-15", tokens: nil, incomplete: 1),
        ], selectedDay: Self.now)
        #expect(breakdown.incompleteRequestCount == 1)
        #expect(breakdown.modelHistoryWarning == .unpriced)
        #expect(breakdown.models.first?.incompleteRequestCount == 0)
    }

    @Test
    func `complete zero cost does not create a model warning`() throws {
        let breakdown = try Self.breakdown(entries: [Self.entry(cost: 0)])
        #expect(breakdown.modelHistoryWarning == nil)
        #expect(!breakdown.hasPartialModelHistory)
    }

    @Test
    func `warning reasons reuse localized titles`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(SpendModelHistoryWarning.unpriced.title == "未定价")
            #expect(SpendModelHistoryWarning.incompleteUsage.title == "不完整")
            #expect(SpendModelHistoryWarning.partial.title == "部分模型明细")
        }
    }

    static let now = Date(timeIntervalSince1970: 1_789_560_000)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func entry(
        day: String = "2026-09-16",
        cost: Double? = nil,
        tokens: Int? = 100,
        incomplete: Int? = nil) -> CostUsageDailyReport.Entry
    {
        .init(
            date: day,
            inputTokens: tokens,
            outputTokens: tokens.map { _ in 0 },
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: [.init(
                modelName: "fixture-model", costUSD: cost, totalTokens: tokens, incompleteRequestCount: incomplete)],
            unpricedRequestCount: cost == nil && tokens != nil ? 1 : nil)
    }

    static func breakdown(
        provider: UsageProvider = .antigravity,
        entries: [CostUsageDailyReport.Entry],
        historyScanIsPartial: Bool = false,
        selectedDay: Date? = nil) throws -> SpendProviderBreakdown
    {
        let tokens = entries.compactMap(\.totalTokens)
        let costs = entries.compactMap(\.costUSD)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            historyDays: 7,
            historyScanIsPartial: historyScanIsPartial,
            costProvenance: .listPriceEstimate,
            daily: entries,
            updatedAt: Self.now)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: provider, displayName: "Fixture source", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar,
            selectedDay: selectedDay)
        let group = try #require(model.groups.first)
        return try #require(spendDashboardProviderBreakdowns(group).first)
    }
}
