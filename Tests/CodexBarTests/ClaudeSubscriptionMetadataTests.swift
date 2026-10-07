import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeSubscriptionMetadataTests {
    private func response(_ renewal: String = "2026-11-05T14:15:04Z", end: String? = nil) throws -> Data {
        let fields: [String: Any] = [
            "status": "active", "next_charge_at": renewal,
            "next_charge_date": "2026-11-05", "plan_ending_at": NSNull(),
            "plan_ending_before": end.map { $0 as Any } ?? NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: fields)
    }

    @Test func `authenticated renewal retains exact timestamp`() throws {
        let value = try ClaudeSubscriptionMetadata.parse(self.response())
        #expect(value.renews?.date == ISO8601DateFormatter().date(from: "2026-11-05T14:15:04Z"))
        #expect(value.renews?.isDateOnly == false)
        #expect(value.expires == nil)
    }

    @Test func `scheduled cancellation suppresses renewal and preserves calendar date precision`() throws {
        let value = try ClaudeSubscriptionMetadata.parse(self.response(end: "2026-11-05"))
        #expect(value.renews == nil)
        #expect(value.expires?.isDateOnly == true)
    }

    @Test func `explicit empty differs from malformed unavailable metadata`() throws {
        let empty = Data("""
        {"status":"canceled","next_charge_at":null,"next_charge_date":null,
         "plan_ending_at":null,"plan_ending_before":null}
        """.utf8)
        let parsed = try ClaudeSubscriptionMetadata.parse(empty)
        #expect(parsed.renews == nil && parsed.expires == nil)
        #expect(ClaudeSubscriptionFetchResult.available(parsed) != .unavailable)
        #expect(throws: ClaudeSubscriptionMetadata.ParseError.self) {
            try ClaudeSubscriptionMetadata.parse(Data("{}".utf8))
        }
        #expect(throws: ClaudeSubscriptionMetadata.ParseError.self) {
            try ClaudeSubscriptionMetadata.parse(self.response(end: "2026-02-30"))
        }
    }

    @Test func `date precision survives snapshot replacement and serialization`() throws {
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            .withSubscriptionMetadata(
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                renewsAt: nil,
                expiresAtIsDateOnly: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundtrip = try decoder.decode(UsageSnapshot.self, from: encoder.encode(snapshot))
        #expect(roundtrip.subscriptionExpiresAtIsDateOnly)
        #expect(roundtrip.with(primary: nil, secondary: nil).subscriptionExpiresAtIsDateOnly)
        #expect(!roundtrip.withSubscriptionMetadata(expiresAt: nil, renewsAt: nil).subscriptionExpiresAtIsDateOnly)
    }

    @Test func `authenticated billing rejects an account or organization switch during enrichment`() async throws {
        let owner = try #require(ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: nil,
            email: "one@example.com",
            organizationUUID: "11111111-1111-4111-8111-111111111111"))
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body = url.path == "/api/account"
                ? """
                {"email_address":"other@example.com",
                 "memberships":[{"organization":{"uuid":"11111111-1111-4111-8111-111111111111"}}]}
                """
                : "{}"
            return try (
                Data(body.utf8),
                #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)))
        }
        let result = await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            await ClaudeSubscriptionMetadataFetcher.fetch(
                cookieHeader: "sessionKey=sk-ant-sid01-fixture",
                expectedOwnerID: owner)
        }
        #expect(result == .unavailable)
    }

    @Test func `OAuth UUID owner is verified against authenticated account and organization`() async throws {
        let owner = try #require(ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: "account-one",
            email: "one@example.com",
            organizationUUID: "22222222-2222-4222-8222-222222222222"))
        let billing = try self.response()
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let body = url.path == "/api/account"
                ?
                Data(
                    """
                    {"uuid":"account-one","email_address":"one@example.com",
                     "memberships":[{"organization":{"uuid":"22222222-2222-4222-8222-222222222222"}}]}
                    """
                        .utf8)
                : billing
            return try (body, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let result = await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            await ClaudeSubscriptionMetadataFetcher.fetch(
                cookieHeader: "sessionKey=sk-ant-sid01-fixture", expectedOwnerID: owner)
        }
        guard case let .available(metadata) = result
        else { Issue.record("Verified OAuth binding was rejected"); return }
        #expect(metadata.renews != nil)
    }

    @Test func `real provider projection exposes live ownership without changing serialized sync identity`() {
        let usage = ClaudeUsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            updatedAt: Date(),
            accountEmail: "one@example.com",
            accountOrganization: "Organization",
            loginMethod: "Claude Pro",
            rawText: nil,
            accountID: "claude-owner-v1:one")
        let projected = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(projected.identity?.accountID == nil)
        #expect(projected.identity?.widgetAccountOwnerID == "claude-owner-v1:one")
        #expect(UsageStore.matchesClaudeSubscriptionOwner(projected, expected: projected))
    }

    @Test func `binding requires the same verified principal organization and plan`() {
        func snapshot(_ owner: String, _ plan: String = "Claude Pro") -> UsageSnapshot {
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: "one@example.com",
                    accountOrganization: "Organization",
                    loginMethod: plan,
                    widgetAccountOwnerID: owner))
        }
        let original = snapshot("claude-owner-v1:one")
        #expect(UsageStore.matchesClaudeSubscriptionOwner(original, expected: original))
        #expect(!UsageStore.matchesClaudeSubscriptionOwner(snapshot("claude-owner-v1:two"), expected: original))
        #expect(!UsageStore.matchesClaudeSubscriptionOwner(
            snapshot("claude-owner-v1:one", "Claude Max"),
            expected: original))
    }

    @Test func `late metadata preserves newer quota and explicit empty clears dates only`() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "one@example.com",
            accountOrganization: "Organization",
            loginMethod: "Claude Pro",
            widgetAccountOwnerID: "claude-owner-v1:one")
        let expected = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: identity)
        let newer = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 67,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 200),
            identity: identity)
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response())
        let enriched = try #require(UsageStore.enrichingClaudeSubscriptionSnapshot(
            newer,
            expected: expected,
            result: .available(metadata)))
        #expect(enriched.primary?.usedPercent == 67)
        #expect(enriched.updatedAt == newer.updatedAt)
        #expect(enriched.subscriptionRenewsAt == metadata.renews?.date)
        #expect(UsageStore.enrichingClaudeSubscriptionSnapshot(enriched, expected: expected, result: .unavailable)?
            .subscriptionRenewsAt == nil)
        let empty = try ClaudeSubscriptionMetadata.parse(Data("""
        {"status":"canceled","next_charge_at":null,"next_charge_date":null,
         "plan_ending_at":null,"plan_ending_before":null}
        """.utf8))
        let cleared = try #require(UsageStore.enrichingClaudeSubscriptionSnapshot(
            enriched,
            expected: expected,
            result: .available(empty)))
        #expect(cleared.subscriptionRenewsAt == nil && cleared.primary?.usedPercent == 67)
    }
}
