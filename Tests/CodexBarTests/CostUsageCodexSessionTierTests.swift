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
