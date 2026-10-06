import AppKit
import CodexBarCore
import Foundation

/// Presentation only: original accounting and missing-cost semantics stay in the dashboard model.
struct SpendTrendChartModel {
    struct Segment: Identifiable, Equatable {
        let sourceID: String
        let provider: UsageProvider
        let name: String
        let date: Date
        let cost: Double
        var start: Double
        var end: Double

        var id: String {
            "\(self.sourceID):\(self.date.timeIntervalSince1970)"
        }
    }

    struct Bucket: Identifiable, Equatable {
        let date: Date
        let segments: [Segment]
        var total: Double {
            self.segments.reduce(0) { $0 + $1.cost }
        }

        var id: Date {
            self.date
        }
    }

    let segments: [Segment]
    let buckets: [Bucket]
    let domain: ClosedRange<Date>
    let scope: ClosedRange<Date>
    let section: SpendDashboardTrendSection
    let calendar: Calendar
    let unit: Calendar.Component

    init(
        group: SpendDashboardModel.CurrencyGroup,
        section: SpendDashboardTrendSection,
        day: Date?,
        sourceID: String? = nil,
        overviewInterval: DateInterval? = nil)
    {
        self.section = section
        self.calendar = group.calendar
        let points: [Segment]
        if section == .hourly {
            let day = day ?? Self.focusedDay(nil, group: group) ?? group.chartDomain.lowerBound
            let interval = group.calendar.dateInterval(of: .day, for: day)
                ?? DateInterval(start: day, duration: 86400)
            self.domain = interval.start...interval.end
            self.scope = self.domain
            self.unit = .hour
            points = group.hourlyPoints.filter {
                $0.hour >= interval.start && $0.hour < interval.end
            }.map {
                Segment(
                    sourceID: $0.sourceID,
                    provider: $0.provider,
                    name: $0.providerName,
                    date: $0.hour,
                    cost: $0.cost,
                    start: 0,
                    end: 0)
            }
        } else {
            self.scope = overviewInterval.map { $0.start...$0.end } ?? group.chartDomain
            let days = self.scope.upperBound.timeIntervalSince(self.scope.lowerBound) / 86400
            self.unit = days > 180 ? .month : days > 45 ? .weekOfYear : .day
            let start = group.calendar.dateInterval(of: self.unit, for: self.scope.lowerBound)?.start
                ?? self.scope.lowerBound
            let end = group.calendar.dateInterval(
                of: self.unit, for: self.scope.upperBound.addingTimeInterval(-1))?.end ?? self.scope.upperBound
            self.domain = start...end
            let scope = self.scope
            points = group.dailyPoints.filter {
                $0.day >= scope.lowerBound && $0.day < scope.upperBound
            }.map {
                Segment(
                    sourceID: $0.sourceID,
                    provider: $0.provider,
                    name: $0.providerName,
                    date: $0.day,
                    cost: $0.cost,
                    start: 0,
                    end: 0)
            }
        }
        let filtered = points.filter { sourceID == nil || $0.sourceID == sourceID }
        let unit = self.unit
        let grouped = Dictionary(grouping: filtered) {
            group.calendar.dateInterval(of: unit, for: $0.date)?.start ?? $0.date
        }
        self.buckets = grouped.keys.sorted().map { date in
            var end = 0.0
            let sources = Dictionary(grouping: grouped[date] ?? [], by: \.sourceID)
            let segments = sources.keys.sorted().compactMap { sourceID -> Segment? in
                guard let point = sources[sourceID]?.first else { return nil }
                let cost = (sources[sourceID] ?? []).reduce(0) { $0 + $1.cost }
                var segment = Segment(
                    sourceID: point.sourceID,
                    provider: point.provider,
                    name: point.name,
                    date: date,
                    cost: cost,
                    start: 0,
                    end: 0)
                segment.start = end
                end += cost
                segment.end = end
                return segment
            }
            return Bucket(date: date, segments: segments)
        }
        self.segments = self.buckets.flatMap(\.segments)
    }

    var peak: Bucket? {
        self.buckets.max { $0.total < $1.total }
    }

    var total: Double {
        self.buckets.reduce(0) { $0 + $1.total }
    }

    /// Drawable points omit unpriced records; their sum is never an authoritative period total.
    var recordedSpendLabel: String {
        self.section == .hourly ? "Recorded hourly spend" : "Recorded spend"
    }

    var visibleDuration: TimeInterval {
        let duration = self.domain.upperBound.timeIntervalSince(self.domain.lowerBound)
        return self.unit == .day ? min(duration, 31 * 86400) : duration
    }

    var needsScrolling: Bool {
        self.unit == .day && self.domain.upperBound.timeIntervalSince(self.domain.lowerBound) > 32 * 86400
    }

    /// No nearest-point fallback: hovering a gap must not silently show a different hour's spend.
    func bucket(at date: Date) -> Bucket? {
        let start = self.calendar.dateInterval(of: self.unit, for: date)?.start
        return self.buckets.first { $0.date == start }
    }

    func interval(at date: Date) -> DateInterval? {
        guard let interval = self.calendar.dateInterval(of: self.unit, for: date) else { return nil }
        let start = max(interval.start, self.scope.lowerBound)
        let end = min(interval.end, self.scope.upperBound)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    static func hourlyDays(_ group: SpendDashboardModel.CurrencyGroup) -> [Date] {
        Set(group.hourlyPoints.map { group.calendar.startOfDay(for: $0.hour) }).sorted()
    }

    static func focusedDay(_ day: Date?, group: SpendDashboardModel.CurrencyGroup) -> Date? {
        let days = self.hourlyDays(group)
        if let selectedDay = group.selectedDay { return selectedDay }
        if let day, days.contains(day) { return day }
        return days.last
    }
}

enum SpendChartPalette {
    /// Source IDs, rather than display labels, keep same-name accounts distinct and colors stable
    /// when a day has no entries for one account or the legend isolates a source.
    static func color(
        sourceID: String,
        provider: UsageProvider,
        providers: [SpendDashboardModel.ProviderRow]) -> NSColor
    {
        let base = ProviderAccentPalette.color(for: provider)
        let color = NSColor(srgbRed: base.red, green: base.green, blue: base.blue, alpha: 1)
        let ids = providers.filter { $0.provider == provider }.map(\.id).sorted()
        guard let index = ids.firstIndex(of: sourceID), index > 0 else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return NSColor(
            calibratedHue: (hue + CGFloat(index) * 0.17).truncatingRemainder(dividingBy: 1),
            saturation: max(saturation, 0.55),
            brightness: max(0.60, brightness * 0.82),
            alpha: 1)
    }

    static func label(_ row: SpendDashboardModel.ProviderRow, providers: [SpendDashboardModel.ProviderRow]) -> String {
        let duplicates = providers.filter { $0.displayName == row.displayName }.sorted { $0.id < $1.id }
        guard duplicates.count > 1, let index = duplicates.firstIndex(where: { $0.id == row.id }) else {
            return row.displayName
        }
        return "\(row.displayName) · \(codexBarLocalizedInteger(index + 1))"
    }
}
