import Foundation
import Testing
@testable import CodexBarCore

struct JetBrainsQuotaLogReaderTests {
    private static let olderQuotaLine =
        "2026-10-05 15:06:48,538 [1828154]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
            + "Available(current=300000, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
            + "tariffQuota=QuotaDetails(current=300000, maximum=1000000, available=700000), "
            + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"
    private static let latestQuotaLine =
        "2026-10-05 15:27:49,811 [   8326]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
            + "Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
            + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), "
            + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"
    private static let refillLine =
        "2026-10-05 15:21:27,386 [2707002]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota refill state is: "
            + "Known(next=2026-10-11T17:00:30.231Z, tariff=QuotaRefillInfoTariff(amount=1000000, duration=30d))"

    private static func localDate(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        return formatter.date(from: text)!
    }

    @Test
    func `parses latest quota and refill state from idea log`() throws {
        let log = [
            "2026-10-05 15:00:00,000 [1]   INFO - #c.i.p.i.b.AppStarter - IDE STARTED",
            Self.olderQuotaLine,
            Self.refillLine,
            Self.latestQuotaLine,
            "2026-10-05 15:30:00,000 [2]   INFO - #c.i.o.SomethingElse - unrelated",
        ].joined(separator: "\n")

        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))

        #expect(entry.timestamp == Self.localDate("2026-10-05 15:27:49,811"))
        #expect(entry.quotaInfo.type == "Available")
        #expect(entry.quotaInfo.used == 346_495.294)
        #expect(entry.quotaInfo.maximum == 1_000_000)
        #expect(entry.quotaInfo.available == 653_504.706)
        #expect(abs(entry.quotaInfo.remainingPercent - 65.3504706) < 0.0001)
        #expect(entry.quotaInfo.until == ISO8601DateParser.parse("2028-09-22T21:00:00Z"))
        #expect(entry.refillInfo?.type == "Known")
        #expect(entry.refillInfo?.next == ISO8601DateParser.parse("2026-10-11T17:00:30.231Z"))
        #expect(entry.refillInfo?.amount == 1_000_000)
        #expect(entry.refillInfo?.duration == "30d")
    }

    @Test
    func `skips quota states without numbers`() throws {
        let unknownLine =
            "2026-10-05 15:40:00,000 [9000]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: Unknown"
        let log = [Self.latestQuotaLine, unknownLine].joined(separator: "\n")

        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))

        #expect(entry.timestamp == Self.localDate("2026-10-05 15:27:49,811"))
        #expect(entry.quotaInfo.available == 653_504.706)
    }

    @Test
    func `returns nil when the log has no quota state`() {
        let log = "2026-10-05 15:00:00,000 [1]   INFO - #c.i.p.i.b.AppStarter - IDE STARTED"
        #expect(JetBrainsQuotaLogReader.latestEntry(inLogContent: log) == nil)
    }

    @Test
    func `maps IDE config directory to its log file`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = JetBrainsQuotaLogReader.logFilePath(
            forIDEBasePath: "\(home)/Library/Application Support/JetBrains/DataGrip2026.2")
        #if os(macOS)
        #expect(path == "\(home)/Library/Logs/JetBrains/DataGrip2026.2/idea.log")
        #else
        #expect(path == "\(home)/.cache/JetBrains/DataGrip2026.2/log/idea.log")
        #endif
    }

    @Test
    func `prefers log entry newer than the persisted quota file`() throws {
        let staleSnapshot = JetBrainsStatusSnapshot(
            quotaInfo: JetBrainsQuotaInfo(
                type: "Available",
                used: 68433.145,
                maximum: 1_000_000,
                available: 931_566.855,
                until: nil),
            refillInfo: nil,
            detectedIDE: nil)
        let entry = try #require(JetBrainsQuotaLogReader.latestEntry(
            inLogContent: [Self.refillLine, Self.latestQuotaLine].joined(separator: "\n")))

        let fresh = JetBrainsStatusProbe.applyingLogEntry(
            entry,
            to: staleSnapshot,
            quotaFileModifiedAt: Self.localDate("2026-09-22 15:11:35,000"))
        #expect(fresh.quotaInfo.available == 653_504.706)
        #expect(fresh.refillInfo?.next == ISO8601DateParser.parse("2026-10-11T17:00:30.231Z"))

        let kept = JetBrainsStatusProbe.applyingLogEntry(
            entry,
            to: staleSnapshot,
            quotaFileModifiedAt: Self.localDate("2026-10-05 16:00:00,000"))
        #expect(kept.quotaInfo.available == 931_566.855)
    }
}
