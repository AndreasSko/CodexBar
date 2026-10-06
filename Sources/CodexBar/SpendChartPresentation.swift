import CodexBarCore
import Foundation

enum SpendChartContent: Equatable {
    case chart
    case unavailable
}

struct SpendChartSeries: Equatable {
    let name: String
    let provider: UsageProvider
}

struct SpendDailyChartPresentation: Equatable {
    let content: SpendChartContent
    let series: [SpendChartSeries]
    let dayCount: Int

    init(dailyPoints: [SpendDashboardModel.DailyPoint], aggregateTotal: Double?) {
        self.content = dailyPoints.isEmpty && aggregateTotal == nil ? .unavailable : .chart
        self.dayCount = Set(dailyPoints.map(\.day)).count

        var seenNames: Set<String> = []
        self.series = dailyPoints.compactMap { point in
            guard seenNames.insert(point.providerName).inserted else { return nil }
            return SpendChartSeries(name: point.providerName, provider: point.provider)
        }
    }

    var accessibilityValue: String {
        L("%d days of usage data across %d services", self.dayCount, self.series.count)
    }
}

/// Finds the id of the highest-`stackEnd` point per grouping key (day/hour), regardless of how
/// many providers are stacked in that group. Only that point's bar should render a rounded top.
func spendTopOfStackIDs<Point, Key: Hashable>(
    for points: [Point],
    key: (Point) -> Key,
    id: (Point) -> String,
    stackEnd: (Point) -> Double) -> Set<String>
{
    var bestByKey: [Key: (id: String, stackEnd: Double)] = [:]
    for point in points {
        let pointKey = key(point)
        let pointStackEnd = stackEnd(point)
        if let existing = bestByKey[pointKey], existing.stackEnd >= pointStackEnd {
            continue
        }
        bestByKey[pointKey] = (id(point), pointStackEnd)
    }
    return Set(bestByKey.values.map(\.id))
}

struct SpendHourlyChartPresentation: Equatable {
    let content: SpendChartContent
    let series: [SpendChartSeries]
    let hourCount: Int
    let includeDateInPointLabels: Bool

    init(hourlyPoints: [SpendDashboardModel.HourlyPoint], calendar: Calendar) {
        self.content = hourlyPoints.isEmpty ? .unavailable : .chart
        self.hourCount = Set(hourlyPoints.map(\.hour)).count
        self.includeDateInPointLabels = Set(hourlyPoints.map { calendar.startOfDay(for: $0.hour) }).count > 1
        var seenNames: Set<String> = []
        self.series = hourlyPoints.compactMap { point in
            guard seenNames.insert(point.providerName).inserted else { return nil }
            return SpendChartSeries(name: point.providerName, provider: point.provider)
        }
    }

    var accessibilityValue: String {
        spendDashboardHourlyChartAccessibilityValue(
            hourCount: self.hourCount,
            serviceCount: self.series.count)
    }
}
