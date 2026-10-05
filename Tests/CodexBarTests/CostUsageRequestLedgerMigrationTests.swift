import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageRequestLedgerMigrationTests {
    @Test(arguments: [5, 6, 7], [false, true])
    func `bounded ledger upgrades retain prior pricing across reopen and append`(
        revision: Int,
        priority: Bool) async throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = ISO8601DateFormatter().string(from: day)
        func tokens(_ input: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]
        }
        func pair(_ id: String, input: Int, total: Int) -> [[String: Any]] {
            [
                ["type": "token_usage_record", "timestamp": timestamp, "payload": [
                    "thread_id": "migration-thread", "session_id": "execution-session", "response_id": id,
                    "turn_id": "migration-turn", "usage": tokens(input), "thread_token_usage": tokens(total),
                ]],
                ["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "token_count", "turn_id": "migration-turn", "info": [
                        "last_token_usage": tokens(input), "total_token_usage": tokens(total),
                    ],
                ]],
            ]
        }
        let header: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "migration-thread", "session_id": "execution-session"],
            ],
            [
                "type": "turn_context",
                "timestamp": timestamp,
                "payload": ["model": "gpt-5.4", "turn_id": "migration-turn"],
            ],
        ]
        let prefix = try env.jsonl(header + pair("first", input: 200_000, total: 200_000))
        let file = try env.writeCodexSessionFile(day: day, filename: "migration.jsonl", contents: prefix)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        func report(_ selected: CostUsageScanner.Options) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: selected)
        }
        _ = report(options)
        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = revision
        // Older revisions may have only legacy rows; revision 7 retains its typed identities.
        if revision < 7 { usage.codexRequestLedgerState = nil }
        if revision == 7, let state = usage.codexRequestLedgerState {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            object["mirroredSnapshots"] = Array((state.mirroredResponses ?? [:]).keys)
            object.removeValue(forKey: "mirroredResponses")
            object.removeValue(forKey: "pendingLedgerResponseID")
            usage.codexRequestLedgerState = try JSONDecoder().decode(
                CostUsageScanner.CodexRequestLedgerState.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(usage.codexRequestLedgerState?.sessionID == "execution-session")
            #expect(usage.codexRequestLedgerState?.responseIDs == ["first"])
            #expect(usage.codexRequestLedgerState?.mirroredResponses == nil)
        }
        usage.codexRows = try usage.codexRows?.map { row in
            var row = row
            row.pricingMode = priority ? "priority" : "standard"
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            if revision < 7 {
                object.removeValue(forKey: "responseID")
                object.removeValue(forKey: "requestMirrorKeys")
            }
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        let predecessorHash = switch revision {
        case 5: "4a4c4ef34ce6f037"
        case 6: "c61aebb9cf043a72"
        default: "029fe80aa98f27e8"
        }
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion, parserHash: predecessorHash)
        let adoptedStore = CostUsageStore(cacheRoot: env.cacheRoot)
        let connection = try BaselineSQLiteConnection(url: adoptedStore.databaseURL)
        try connection.execute("UPDATE meta SET value = '\(predecessorHash)' WHERE key = 'parser_hash'")
        try connection.execute("PRAGMA user_version = \(predecessorVersion)")
        let adopted = adoptedStore.syncLoadCodexCache(calendar: .current)
        #expect(adopted.files[file.path]?.codexRows == usage.codexRows)
        #expect(await adoptedStore.rebuildCount == 0)
        #expect(await adoptedStore.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        func append(_ lines: [[String: Any]]) throws {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl(lines).utf8))
            try handle.close()
        }
        try append(pair("second", input: 50000, total: 250_000))
        options.maxCodexScanBytesPerRefresh = 256
        options.maxCodexSessionFileBytes = 256
        var observedPartial = false
        for _ in 0..<40 {
            _ = report(options)
            let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
            let current = try #require(reopened.files[file.path])
            observedPartial = observedPartial || current.codexScanComplete == false
            if current.codexScanComplete == true, current.hasCurrentCodexParser,
               try current.parsedBytes == Int64(Data(contentsOf: file).count) { break }
        }
        #expect(observedPartial)
        let migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let migratedFile = try #require(migrated.files[file.path])
        #expect(migratedFile.codexRows?.compactMap(\.responseID) == ["first", "second"])
        #expect(migratedFile.codexRows?.first?.pricingMode == (priority ? "priority" : "standard"))
        #expect(migratedFile.codexRows?.last?.pricingMode == "standard")
        #expect(migratedFile.codexScanComplete == true)
        try append(pair("third", input: 25000, total: 275_000))
        options.maxCodexScanBytesPerRefresh = 512 * 1024 * 1024
        options.maxCodexSessionFileBytes = 512 * 1024 * 1024
        let appended = report(options)
        #expect(appended.summary?.totalTokens == 275_000)
        let completed = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        #expect(completed.files[file.path]?.codexRows?.compactMap(\.responseID) == ["first", "second", "third"])
        #expect(completed.files[file.path]?.codexRows?.first?.pricingMode == (priority ? "priority" : "standard"))
        #expect(completed.files[file.path]?.codexRows?.dropFirst().allSatisfy { $0.pricingMode == "standard" } == true)
        var coldOptions = options
        coldOptions.cacheRoot = env.root.appendingPathComponent("cold-cache")
        _ = report(coldOptions)
        var cold = try CostUsageStoreAccess.read(cacheRoot: #require(coldOptions.cacheRoot))
        let prices = try #require(completed.files[file.path]?.codexRows)
        var coldFile = try #require(cold.files[file.path])
        coldFile.codexRows = coldFile.codexRows?.enumerated().map { index, row in
            var row = row
            row.pricingMode = prices[index].pricingMode
            return row
        }
        cold.files[file.path] = coldFile
        #expect(try !CostUsageStoreAccess.replace(cacheRoot: #require(coldOptions.cacheRoot), cache: cold)
            .catchUpRequired)
        let expected = report(coldOptions)
        #expect(expected.data == appended.data)
        #expect(expected.summary == appended.summary)
        #expect(report(options).data == appended.data)
    }

    @Test(arguments: [
        (ledgerFirst: true, offsetMs: 400, bounded: false),
        (ledgerFirst: false, offsetMs: 400, bounded: false),
        (ledgerFirst: true, offsetMs: -350, bounded: false),
        (ledgerFirst: false, offsetMs: -350, bounded: false),
        (ledgerFirst: true, offsetMs: 400, bounded: true),
        (ledgerFirst: false, offsetMs: -350, bounded: true),
    ])
    func `legacy upgrade keeps saved pricing when ledger and token count timestamps differ`(
        _ scenario: (ledgerFirst: Bool, offsetMs: Int, bounded: Bool)) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "offset-migration.jsonl",
            contents: Self.offsetLedgerLines(
                day: day, env: env, scenario: (scenario.ledgerFirst, scenario.offsetMs)))
        var options = Self.options(env: env)
        let canonical = Self.report(day: day, options: options)
        let standardCost = try #require(canonical.summary?.totalCostUSD)

        // Revision 5 saved token_count rows with their own timestamps and no response identity.
        var old = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(old.files[file.path])
        usage.codexParserRevision = 5
        usage.codexRequestLedgerState = nil
        usage.codexRows = try usage.codexRows?.enumerated().map { index, row in
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            object.removeValue(forKey: "responseID")
            object.removeValue(forKey: "requestMirrorKeys")
            object["timestampUnixMs"] = Int64((day.timeIntervalSince1970 + Double(index + 1) * 10) * 1000)
            // Saved priority evidence cannot be rederived without traces, so it proves the old row's pricing survived.
            object["pricingMode"] = "priority"
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        old.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: old).catchUpRequired)
        try Self.markPredecessor(cacheRoot: env.cacheRoot, parserHash: "4a4c4ef34ce6f037")
        if scenario.bounded {
            // Each pass reads about one line, so some slices end between a ledger row and its mirror.
            options.maxCodexScanBytesPerRefresh = 256
            options.maxCodexSessionFileBytes = 256
        }

        var migrated: CostUsageFileUsage?
        var observedPartial = false
        let fileSize = try Int64(Data(contentsOf: file).count)
        for _ in 0..<60 {
            _ = Self.report(day: day, options: options)
            migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
                .files[file.path]
            observedPartial = observedPartial || migrated?.codexScanComplete == false
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true,
               migrated?.parsedBytes == fileSize { break }
        }
        #expect(observedPartial == scenario.bounded)
        let rows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.compactMap(\.responseID) == ["offset-0", "offset-1", "offset-2"])
        #expect(rows.map(\.unpricedTokens) == [nil, nil, nil])
        #expect(rows.map(\.pricingMode) == ["priority", "priority", "priority"])
        let upgraded = Self.report(day: day, options: options)
        #expect(upgraded.summary?.totalTokens == canonical.summary?.totalTokens)
        #expect(try #require(upgraded.summary?.totalCostUSD) > standardCost)
    }

    @Test(arguments: [
        (storedHash: "ed735dc27ffa70d9", invalidated: false),
        (storedHash: "ed735dc27ffa70d9", invalidated: true),
        (storedHash: "029fe80aa98f27e8", invalidated: false),
    ])
    func `adopting a 0_72_0 store repairs only ledger timestamp pricing markers`(
        _ scenario: (storedHash: String, invalidated: Bool)) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "marked-ledger.jsonl",
            contents: Self.offsetLedgerLines(
                day: day,
                env: env,
                scenario: (ledgerFirst: true, offsetMs: 400),
                inputs: [200_000, 50000, 25000, 10000]))
        var options = Self.options(env: env)
        options.refreshMinIntervalSeconds = 3600
        #expect(Self.report(day: day, options: options).summary?.totalCostUSD != nil)

        // Rows 0 and 1 carry the 0.72.0 signature. An authoritative amount is never cleared. A fully marked
        // legacy row means the file's saved evidence was invalidated, so every marker in that file is kept.
        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        var usage = try #require(stored.files[file.path])
        let rows = try #require(usage.codexRows)
        #expect(rows.count == 4)
        usage.codexRows = try rows.enumerated().map { index, row in
            var row = row
            row.unpricedTokens = row.input + row.output
            if index == 2 { row.knownCostNanos = 123_000_000 }
            guard index == 3, scenario.invalidated else { return row }
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
            object.removeValue(forKey: "responseID")
            object.removeValue(forKey: "requestMirrorKeys")
            return try JSONDecoder().decode(
                CostUsageScanner.CodexUsageRow.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        stored.files[file.path] = usage
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored).catchUpRequired)
        #expect(Self.report(day: day, options: options).summary?.totalCostUSD == nil)
        try Self.markPredecessor(cacheRoot: env.cacheRoot, parserHash: scenario.storedHash)

        let adopted = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: .current)
        let adoptedRows = try #require(adopted.files[file.path]?.codexRows)
        let repairs = scenario.storedHash == "ed735dc27ffa70d9" && !scenario.invalidated
        let marked: [Int] = rows.map { $0.input + $0.output }
        let expectedMarkers: [Int?] = repairs ? [nil, nil, marked[2], nil] : marked
        let expectedCosts: [Int64?] = [nil, nil, 123_000_000, nil]
        #expect(adoptedRows.map(\.unpricedTokens) == expectedMarkers)
        #expect(adoptedRows.map(\.knownCostNanos) == expectedCosts)
        #expect(adoptedRows.map(\.pricingMode) == rows.map(\.pricingMode))
        #expect(adopted.files[file.path]?.days == usage.days)
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func report(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
    }

    private static func markPredecessor(cacheRoot: URL, parserHash: String) throws {
        let version = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: parserHash)
        let connection = try BaselineSQLiteConnection(url: CostUsageStore(cacheRoot: cacheRoot).databaseURL)
        try connection.execute("UPDATE meta SET value = '\(parserHash)' WHERE key = 'parser_hash'")
        try connection.execute("PRAGMA user_version = \(version)")
    }

    /// Real Codex logs stamp the owned token_usage_record and its token_count mirror a few hundred ms apart.
    private static func offsetLedgerLines(
        day: Date,
        env: CostUsageTestEnvironment,
        scenario: (ledgerFirst: Bool, offsetMs: Int),
        inputs: [Int] = [200_000, 50000, 25000]) throws -> String
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func tokens(_ input: Int, output: Int) -> [String: Int] {
            ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output]
        }
        var lines: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": formatter.string(from: day),
                "payload": ["id": "offset-thread", "session_id": "offset-execution"],
            ],
            [
                "type": "turn_context",
                "timestamp": formatter.string(from: day),
                "payload": ["model": "gpt-5.4", "turn_id": "offset-turn"],
            ],
        ]
        var total = 0
        for (index, input) in inputs.enumerated() {
            total += input
            let countedAt = day.addingTimeInterval(Double(index + 1) * 10)
            let ledgerAt = countedAt.addingTimeInterval(Double(scenario.offsetMs) / 1000)
            let ledger: [String: Any] = [
                "type": "token_usage_record", "timestamp": formatter.string(from: ledgerAt), "payload": [
                    "thread_id": "offset-thread", "session_id": "offset-execution", "response_id": "offset-\(index)",
                    "turn_id": "offset-turn", "usage": tokens(input, output: 1000),
                    "thread_token_usage": tokens(total, output: 1000 * (index + 1)),
                ],
            ]
            let count: [String: Any] = [
                "type": "event_msg", "timestamp": formatter.string(from: countedAt), "payload": [
                    "type": "token_count", "turn_id": "offset-turn", "info": [
                        "last_token_usage": tokens(input, output: 1000),
                        "total_token_usage": tokens(total, output: 1000 * (index + 1)),
                    ],
                ],
            ]
            lines += scenario.ledgerFirst ? [ledger, count] : [count, ledger]
        }
        return try env.jsonl(lines)
    }
}
