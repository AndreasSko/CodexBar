import Foundation

/// Reads the latest quota state the IDE writes to `idea.log`.
///
/// The IDE refreshes quota in memory and logs every change, but it only persists
/// `AIAssistantQuotaManager2.xml` occasionally, so the XML can be weeks out of date
/// while the log already has the value the IDE shows.
public enum JetBrainsQuotaLogReader {
    public struct Entry: Sendable, Equatable {
        public let timestamp: Date
        public let quotaInfo: JetBrainsQuotaInfo
        public let refillInfo: JetBrainsRefillInfo?

        public init(timestamp: Date, quotaInfo: JetBrainsQuotaInfo, refillInfo: JetBrainsRefillInfo?) {
            self.timestamp = timestamp
            self.quotaInfo = quotaInfo
            self.refillInfo = refillInfo
        }
    }

    private static let quotaMarker = "QuotaManager2Impl - New quota state is: "
    private static let refillMarker = "QuotaManager2Impl - New quota refill state is: "
    /// idea.log can grow to tens of MB; quota lines are logged on every refresh, so the tail is enough.
    private static let tailByteCount: UInt64 = 4 * 1024 * 1024

    /// `~/Library/Application Support/JetBrains/DataGrip2026.2` → `~/Library/Logs/JetBrains/DataGrip2026.2/idea.log`
    public static func logFilePath(forIDEBasePath basePath: String) -> String {
        let standardized = (basePath as NSString).standardizingPath
        let dirname = (standardized as NSString).lastPathComponent
        let vendor = ((standardized as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return "\(homeDir)/Library/Logs/\(vendor)/\(dirname)/idea.log"
        #else
        return "\(homeDir)/.cache/\(vendor)/\(dirname)/log/idea.log"
        #endif
    }

    public static func latestEntry(atPath path: String) -> Entry? {
        guard let content = self.readTail(atPath: path) else { return nil }
        return self.latestEntry(inLogContent: content)
    }

    public static func latestEntry(inLogContent content: String) -> Entry? {
        var latestQuota: (timestamp: Date, info: JetBrainsQuotaInfo)?
        var latestRefill: JetBrainsRefillInfo?

        for line in content.split(whereSeparator: \.isNewline).reversed() {
            if latestQuota == nil, let parsed = self.parseQuotaLine(String(line)) {
                latestQuota = parsed
            } else if latestRefill == nil, let parsed = self.parseRefillLine(String(line)) {
                latestRefill = parsed
            }
            if latestQuota != nil, latestRefill != nil { break }
        }

        guard let latestQuota else { return nil }
        return Entry(timestamp: latestQuota.timestamp, quotaInfo: latestQuota.info, refillInfo: latestRefill)
    }

    // MARK: - Line parsing

    /// `2026-10-05 15:27:49,811 [8326] INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is:
    /// Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z,
    /// tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), topUpQuota=...)`
    static func parseQuotaLine(_ line: String) -> (timestamp: Date, info: JetBrainsQuotaInfo)? {
        guard let markerRange = line.range(of: self.quotaMarker),
              let timestamp = self.parseTimestamp(line)
        else { return nil }

        let state = String(line[markerRange.upperBound...])
        let type = state.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        guard !type.isEmpty else { return nil }

        let tariff = self.captures(
            #"tariffQuota=QuotaDetails\(current=([0-9.]+), maximum=([0-9.]+), available=([0-9.]+)\)"#,
            in: state)
        let overall = self.captures(#"^\w+\(current=([0-9.]+), maximum=([0-9.]+)"#, in: state)
        // States without numbers (e.g. `Unknown` while the IDE is still loading) must not mask real quota.
        guard tariff != nil || overall != nil else { return nil }
        let until = self.captures(#"until=([^,)\s]+)"#, in: state)?.first.flatMap { ISO8601DateParser.parse($0) }

        let used = (tariff?[0] ?? overall?[0]).flatMap { Double($0) } ?? 0
        let maximum = (tariff?[1] ?? overall?[1]).flatMap { Double($0) } ?? 0
        let available = tariff.flatMap { Double($0[2]) }

        return (timestamp, JetBrainsQuotaInfo(
            type: type,
            used: used,
            maximum: maximum,
            available: available,
            until: until))
    }

    /// `... New quota refill state is: Known(next=2026-10-11T17:00:30.231Z,
    /// tariff=QuotaRefillInfoTariff(amount=1000000, duration=30d))`
    static func parseRefillLine(_ line: String) -> JetBrainsRefillInfo? {
        guard let markerRange = line.range(of: self.refillMarker) else { return nil }
        let state = String(line[markerRange.upperBound...])
        let type = state.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        let next = self.captures(#"next=([^,)\s]+)"#, in: state)?.first.flatMap { ISO8601DateParser.parse($0) }
        let amount = self.captures(#"amount=([0-9.]+)"#, in: state)?.first.flatMap { Double($0) }
        let duration = self.captures(#"duration=([^,)\s]+)"#, in: state)?.first
        return JetBrainsRefillInfo(type: type.isEmpty ? nil : type, next: next, amount: amount, duration: duration)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter
    }()

    private static func parseTimestamp(_ line: String) -> Date? {
        let prefix = String(line.prefix(23))
        return self.timestampFormatter.date(from: prefix)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func readTail(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > self.tailByteCount ? size - self.tailByteCount : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        // A mid-file offset can split a multi-byte character; start at the first complete line.
        let lines = offset > 0
            ? data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data()
            : data[...]
        return String(bytes: lines, encoding: .utf8)
    }
}
