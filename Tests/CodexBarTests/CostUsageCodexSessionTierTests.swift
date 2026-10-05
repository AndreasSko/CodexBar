import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexSessionTierTests {
    @Test
    func `session log priority tier prices the turn at the fast rate`() throws {
        let standard = try Self.cost(serviceTier: "default")
        let priority = try Self.cost(serviceTier: "priority")
        #expect(abs(priority - standard * 2) < 1e-9)
    }

    @Test
    func `priority tier does not leak to an older explicit turn`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-leak"]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "turn-a"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-a",
                "info": ["last_token_usage": ["input_tokens": 100, "output_tokens": 10]],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": "priority"],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "turn-b"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-a",
                "info": ["last_token_usage": ["input_tokens": 200, "output_tokens": 20]],
            ]],
        ]
        let file = try env.writeCodexSessionFile(day: day, filename: "tier-leak.jsonl", contents: env.jsonl(records))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let result = CostUsageScanner.parseCodexFile(fileURL: file, range: range)
        #expect(result.rows.count == 2)
        #expect(result.rows.last?.pricingMode == nil)
    }

    @Test
    func `priority tier survives an incremental scan checkpoint`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        let prefix = try env.jsonl([
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-checkpoint"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["service_tier": "priority"],
            ]],
        ])
        let suffix = try env.jsonl([
            [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": ["type": "task_started", "turn_id": "turn-checkpoint"],
            ],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "turn-checkpoint",
                "info": ["last_token_usage": ["input_tokens": 200_000, "output_tokens": 10000]],
            ]],
        ])
        let file = env.root.appendingPathComponent("tier-checkpoint.jsonl")
        try prefix.write(to: file, atomically: true, encoding: .utf8)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = CostUsageScanner.parseCodexFile(fileURL: file, range: range)
        #expect(first.serviceTierState?.pending == "priority")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        let second = CostUsageScanner.parseCodexFile(
            fileURL: file,
            range: range,
            startOffset: first.parsedBytes,
            initialServiceTierState: first.serviceTierState)
        #expect(second.rows.last?.pricingMode == "priority")
    }

    private static func cost(serviceTier: String) throws -> Double {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let timestamp = env.isoString(for: day)
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "tier-\(serviceTier)"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied",
                "thread_id": "tier-\(serviceTier)",
                "thread_settings": ["model": "gpt-5.4", "service_tier": serviceTier],
            ]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "tier-turn"]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.4", "turn_id": "tier-turn"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "turn_id": "tier-turn",
                "info": ["last_token_usage": [
                    "input_tokens": 200_000,
                    "cached_input_tokens": 0,
                    "output_tokens": 10000,
                ]],
            ]],
        ]
        _ = try env.writeCodexSessionFile(day: day, filename: "tier.jsonl", contents: env.jsonl(records))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        return try #require(report.summary?.totalCostUSD)
    }
}
