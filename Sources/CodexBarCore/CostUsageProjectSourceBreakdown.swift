import Foundation

public struct CostUsageProjectSourceBreakdown: Sendable, Equatable {
    public let name: String
    public let path: String?
    public let totalTokens: Int?
    public let totalCostUSD: Double?
    public let daily: [CostUsageDailyReport.Entry]
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?
    /// Complete file membership, including older files hidden by the session list's latest-file deduplication.
    public let sessionIDs: Set<String>?

    /// Membership is a read-only display annotation, not part of the accounting value.
    /// Preserve equality between a raw scanner report and its annotated store read view.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.path == rhs.path
            && lhs.totalTokens == rhs.totalTokens && lhs.totalCostUSD == rhs.totalCostUSD
            && lhs.daily == rhs.daily && lhs.modelBreakdowns == rhs.modelBreakdowns
    }

    public init(
        name: String,
        path: String?,
        totalTokens: Int?,
        totalCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry],
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?,
        sessionIDs: Set<String>? = nil)
    {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CostUsageProjectBreakdown.unknownProjectName
            : name
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = cleanPath?.isEmpty == true ? nil : cleanPath
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.daily = daily
        self.modelBreakdowns = modelBreakdowns
        self.sessionIDs = sessionIDs
    }
}
