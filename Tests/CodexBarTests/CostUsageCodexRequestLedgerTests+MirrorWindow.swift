import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageCodexRequestLedgerTests {
    /// After a resume, Codex's token_count counter can run behind the thread counter while both events still describe
    /// the same response a few milliseconds apart. Adjacent same-turn observations with identical usage inside the
    /// mirror window are one request; beyond it they stay distinct.
    @Test(arguments: [false, true], [2, 4900, 5000, 5001, 5100])
    func `adjacent offset counters pair only inside the mirror window`(ledgerFirst: Bool, gapMs: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: gapMs)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44],
            turnTotal: [500, 100, 50, 20])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [860, 172, 86, 34])
        let result = try Self.parse(Self.header() + (ledgerFirst ? [ledger, legacy] : [legacy, ledger]), env: env)
        let paired = gapMs <= 5000
        #expect(result.rows.count == (paired ? 1 : 2))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (paired ? 110 : 220))
        #expect(result.rows.compactMap(\.responseID) == ["one"])
    }

    @Test(arguments: [false, true])
    func `adjacent equal usage from another turn remains distinct inside the mirror window`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44])
        let legacy: [String: Any] = [
            "type": "event_msg", "timestamp": ledgerFirst ? later : Self.timestampA, "payload": [
                "type": "token_count", "turn_id": "other-turn", "info": [
                    "last_token_usage": Self.tokens(usage), "total_token_usage": Self.tokens([860, 172, 86, 34]),
                ],
            ],
        ]
        let result = try Self.parse(Self.header() + (ledgerFirst ? [ledger, legacy] : [legacy, ledger]), env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// The pending observation is persisted, so a mirror appended after a refresh still pairs with it.
    @Test(arguments: [false, true])
    func `offset counter mirrors pair across an incremental refresh`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 3)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [3000, 600, 300, 120],
            turnTotal: [2000, 400, 200, 80])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [1500, 300, 150, 60])
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "offset-mirror.jsonl",
            contents: env.jsonl(Self.header() + [ledgerFirst ? ledger : legacy]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: end, options: options)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([ledgerFirst ? legacy : ledger]).utf8))
        try handle.close()
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: start,
            until: end,
            now: end.addingTimeInterval(1),
            options: options)
        let rows = try #require(CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar)
            .files[file.path]?.codexRows)
        #expect(rows.count == 1)
        #expect(rows.compactMap(\.responseID) == ["one"])
        #expect(report.summary?.totalTokens == 1100)
    }

    /// Revision 8 stored the offset-counter mirror as a second row. The revision 9 reparse drops it and keeps the
    /// ledger row's saved pricing, without rebuilding the store.
    @Test
    func `revision 8 duplicate mirror rows are removed by the reparse`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let mirrorAt = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "duplicate-mirror.jsonl",
            contents: env.jsonl(Self.header() + [
                Self.record(id: "one", usage: usage, total: [3000, 600, 300, 120], turnTotal: [2000, 400, 200, 80]),
                Self.legacy(timestamp: mirrorAt, usage: usage, total: [1500, 300, 150, 60]),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func report(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: now, options: options)
        }
        func load() -> CostUsageFileUsage? {
            CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar).files[file.path]
        }
        #expect(report(end).summary?.totalTokens == 1100)

        // Recreate what revision 8 saved: the ledger row with Priority evidence plus the unpaired mirror row.
        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        var usageFile = try #require(stored.files[file.path])
        var ledger = try #require(usageFile.codexRows?.first)
        ledger.pricingMode = "priority"
        let duplicate = CostUsageScanner.CodexUsageRow(
            day: ledger.day,
            model: ledger.model,
            rawModel: ledger.rawModel,
            turnID: ledger.turnID,
            eventIndex: (ledger.eventIndex ?? 0) + 1,
            timestampUnixMs: Int64((start.timeIntervalSince1970 * 1000).rounded()) + 2,
            input: ledger.input,
            cached: ledger.cached,
            output: ledger.output,
            reasoning: ledger.reasoning,
            pricingModel: ledger.pricingModel,
            pricingMode: "standard")
        usageFile.codexRows = [ledger, duplicate]
        usageFile.codexParserRevision = 8
        stored.files[file.path] = usageFile
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored, calendar: calendar)
            .catchUpRequired)
        #expect(load()?.codexRows?.count == 2)

        var migrated: CostUsageFileUsage?
        for pass in 1...20 {
            _ = report(end.addingTimeInterval(Double(pass)))
            migrated = load()
            if migrated?.hasCurrentCodexParser == true { break }
        }
        let rows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.count == 1)
        #expect(rows.first?.responseID == "one")
        #expect(rows.first?.pricingMode == "priority")
        #expect(report(end.addingTimeInterval(30)).summary?.totalTokens == 1100)
    }

    /// Real token_count payloads carry no turn_id; the active task supplies it, and a new task ends adjacency.
    @Test(arguments: [false, true])
    func `real token count shape pairs within its task only`(taskBetween: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        var lines = Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: usage, total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
        ]
        if taskBetween { lines.append(Self.taskStarted("synthetic-turn")) }
        lines.append(Self.realLegacy(timestamp: later, usage: usage, total: [860, 172, 86, 34]))
        let result = try Self.parse(lines, env: env)
        #expect(result.rows.count == (taskBetween ? 2 : 1))
        #expect(result.rows.compactMap(\.responseID) == ["one"])
    }

    /// After a tool runs, Codex writes the token_count long after its ledger record. Once a pair established the
    /// counter offset, a later ledger-first pair with the same offset is one request; a different offset is not.
    @Test(arguments: [true, false])
    func `far ledger first mirrors pair when their counter offset matches`(sameOffset: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let farLater = try Self.timestamp(Self.timestampA, plusMilliseconds: 30000)
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10),
                usage: [60, 20, 6, 3],
                total: [1160, 240, 116, 47],
                turnTotal: [560, 120, 56, 23]),
            Self.realLegacy(
                timestamp: farLater,
                usage: [60, 20, 6, 3],
                total: sameOffset ? [920, 192, 92, 37] : [925, 192, 92, 37]),
        ], env: env)
        #expect(result.rows.count == (sameOffset ? 2 : 3))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (sameOffset ? 176 : 242))
        #expect(result.rows.compactMap(\.responseID) == ["one", "two"])
    }

    /// Offset pairing applies only when the ledger record comes first; a token_count followed much later by a ledger
    /// record of equal size stays two requests even when their offset matches the learned one.
    @Test
    func `far legacy first observations stay distinct even with the learned offset`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10),
                usage: [60, 20, 6, 3],
                total: [920, 192, 92, 37]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 30000),
                usage: [60, 20, 6, 3],
                total: [1160, 240, 116, 47],
                turnTotal: [560, 120, 56, 23]),
        ], env: env)
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 242)
    }

    /// A legacy-only request is part of the thread counter, so an owned record of equal size that follows it is a
    /// different request even when the offset from an earlier pair is known.
    @Test
    func `legacy only request before an equal owned request stays distinct`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 20000),
                usage: [50, 10, 5, 2],
                total: [910, 182, 91, 36]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 50000),
                usage: [50, 10, 5, 2],
                total: [1200, 240, 120, 48],
                turnTotal: [600, 120, 60, 24]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 50002),
                usage: [50, 10, 5, 2],
                total: [960, 192, 96, 38]),
        ], env: env)
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// A resumed session and a counted bare usage line both separate observations, so they cannot be one request.
    @Test(arguments: [false, true], ["resume", "bare usage"])
    func `session resume or bare usage between observations keeps them distinct`(
        ledgerFirst: Bool,
        separator: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let between = try Self.timestamp(Self.timestampA, plusMilliseconds: 1000)
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2000)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44],
            turnTotal: [500, 100, 50, 20])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [860, 172, 86, 34])
        let separatorLine: [String: Any] = separator == "resume"
            ? ["type": "session_meta", "timestamp": between, "payload": ["id": "synthetic-thread"]]
            : ["timestamp": between, "usage": ["prompt_tokens": 10, "completion_tokens": 1]]
        let result = try Self.parse(
            Self.header() + (ledgerFirst ? [ledger, separatorLine, legacy] : [legacy, separatorLine, ledger]),
            env: env)
        let bareTokens = separator == "bare usage" ? 11 : 0
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220 + bareTokens)
    }

    static func taskStarted(_ turnID: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": self.timestampA, "payload": ["type": "task_started", "turn_id": turnID]]
    }

    /// The token_count shape Codex writes: no turn_id in the payload.
    static func realLegacy(timestamp: String, usage: [Int], total: [Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": [
            "type": "token_count", "info": [
                "last_token_usage": self.tokens(usage), "total_token_usage": self.tokens(total),
            ],
        ]]
    }
}
