import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Exercises the production scheduler and all publication sinks. Only HTTP and the
/// already accepted in-memory credential are synthetic; no real account is modified.
@MainActor
struct ClaudeSubscriptionPublicationProofTests {
    enum Scenario: String, CaseIterable {
        case accepted, mismatchedAccount, reassignedOrganization, replacedOAuthCredential
        case replacedManualCookie, changedSelectedAccount, changedActiveSnapshot
    }

    final class CredentialVault: @unchecked Sendable {
        private let lock = NSLock()
        private var token = "sk-ant-oat01-proof-original"
        func replace() { self.lock.withLock { self.token = "sk-ant-oat01-proof-replaced" } }
        func credentials() -> ClaudeOAuthCredentials {
            self.lock.withLock {
                ClaudeOAuthCredentials(
                    accessToken: self.token,
                    refreshToken: "proof-refresh",
                    expiresAt: Date().addingTimeInterval(3600),
                    scopes: ["user:profile"],
                    rateLimitTier: nil)
            }
        }
    }

    actor AuthorityServer {
        let scenario: Scenario
        var profiles = 0
        var accounts = 0
        var entered = false
        var arrival: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        init(_ scenario: Scenario) { self.scenario = scenario }
        func waitForBilling() async {
            if self.entered { return }
            await withCheckedContinuation { self.arrival = $0 }
        }

        func resumeBilling() { self.release?.resume(); self.release = nil }
        func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let body: String
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                self.profiles += 1
                let org = self.scenario == .reassignedOrganization && self.profiles > 1
                    ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111"
                body = """
                {"account":{"uuid":"proof-account","email_address":"proof@example.com"},
                 "organization":{"uuid":"\(org)"}}
                """
            } else if url.path.hasSuffix("/account") {
                self.accounts += 1
                let account = self.scenario == .mismatchedAccount && self.accounts > 1
                    ? "different-account" : "proof-account"
                // Both memberships stay present: membership checks alone cannot detect reassignment.
                body = """
                {"uuid":"\(account)","email_address":"proof@example.com","memberships":[
                  {"organization":{"uuid":"11111111-1111-4111-8111-111111111111"}},
                  {"organization":{"uuid":"22222222-2222-4222-8222-222222222222"}}]}
                """
            } else {
                self.entered = true
                self.arrival?.resume(); self.arrival = nil
                await withCheckedContinuation { self.release = $0 }
                body = """
                {"status":"active","next_charge_at":"2026-11-05T14:15:04Z",
                 "next_charge_date":"2026-11-05","plan_ending_at":null,"plan_ending_before":null}
                """
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: Scenario.allCases)
    func `production scheduler rejects authority changes before all publication sinks`(
        _ scenario: Scenario) async throws
    {
        let settings = testSettingsStore(suiteName: "ClaudeAuthorityProof", userDefaults: InMemoryUserDefaults())
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            enabled: true)
        settings.accountWidgetsEnabled = false
        settings.addTokenAccount(provider: .claude, label: "Proof", token: "sk-ant-oat01-proof-original")
        settings.claudeCookieSource = .manual
        settings.claudeCookieHeader = "sessionKey=sk-ant-sid01-proof-original"
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        var publications = 0
        store._test_widgetSnapshotSaveOverride = { _ in publications += 1 }
        let initial = UsageSnapshot(
            primary: RateWindow(usedPercent: 35, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: ProviderIdentitySnapshot(
                providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: "Claude Pro"))
        store.snapshots[.claude] = initial
        store.lastSourceLabels[.claude] = "oauth"
        store.cacheTokenAccountSnapshot(provider: .claude, account: account, snapshot: initial, sourceLabel: "oauth")
        let server = AuthorityServer(scenario)
        let vault = CredentialVault()
        let transport = ProviderHTTPTransportHandler { request in try await server.respond(request) }
        let credentialLoader: @Sendable (String, [String: String]) -> ClaudeOAuthCredentials? = { history, _ in
            history == "accepted-history" ? vault.credentials() : nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try await UsageStore.$claudeSubscriptionProofTransport.withValue(transport) {
            try await UsageStore.$claudeSubscriptionProofCredentials.withValue(credentialLoader) {
                store.scheduleClaudeSubscriptionMetadataIfSupported(
                    snapshot: initial,
                    provider: .claude,
                    strategy: .oauth,
                    generation: nil,
                    oauthHistoryOwner: "accepted-history")
                let task = try #require(store.claudeSubscriptionMetadataTask)
                await server.waitForBilling()
                // The lookup is paused at the HTTP boundary, after production ownership checks.
                #expect(store.snapshots[.claude]?.subscriptionRenewsAt == nil)
                #expect(publications == 0)
                switch scenario {
                case .accepted:
                    store.snapshots[.claude] = initial.with(primary: RateWindow(
                        usedPercent: 67, windowMinutes: 300, resetsAt: nil, resetDescription: nil), secondary: nil)
                case .replacedOAuthCredential: vault.replace()
                case .replacedManualCookie: settings.claudeCookieHeader = "sessionKey=sk-ant-sid01-proof-replaced"
                case .changedSelectedAccount:
                    settings.addTokenAccount(provider: .claude, label: "Other", token: "sk-ant-oat01-proof-other")
                case .changedActiveSnapshot:
                    store.snapshots[.claude] = initial.withIdentity(ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: "other@example.com",
                        accountOrganization: nil,
                        loginMethod: "Claude Pro"))
                case .mismatchedAccount, .reassignedOrganization: break
                }
                let expectedSnapshot = try encoder.encode(store.snapshots[.claude])
                let expectedCache = try encoder.encode(store.accountSnapshots[.claude]?.map(\.snapshot))
                await server.resumeBilling()
                await task.value
                await store.widgetSnapshotPersistTask?.value
                if scenario == .accepted {
                    #expect(store.snapshots[.claude]?.subscriptionRenewsAt != nil)
                    #expect(store.snapshots[.claude]?.primary?.usedPercent == 67)
                    #expect(store.accountSnapshots[.claude]?.first?.snapshot?.subscriptionRenewsAt != nil)
                    #expect(publications == 1)
                } else {
                    #expect(try encoder.encode(store.snapshots[.claude]) == expectedSnapshot)
                    #expect(try encoder.encode(store.accountSnapshots[.claude]?.map(\.snapshot)) == expectedCache)
                    #expect(publications == 0)
                }
                let outcome = scenario == .accepted ? "published; newer quota preserved" : "unchanged; no publication"
                print("AUTHORITY PROOF \(scenario.rawValue): snapshot/cache/widget \(outcome)")
            }
        }
    }

    @Test func `OAuth refresh never carries a prior organization binding`() {
        let settings = testSettingsStore(suiteName: "ClaudeNoHistoryBinding", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let previous = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()).withIdentity(
            ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Claude Pro",
                widgetAccountOwnerID: "claude-owner-v1:prior"))
            .withSubscriptionMetadata(expiresAt: nil, renewsAt: Date())
        store.snapshots[.claude] = previous
        let next = previous.withIdentity(ProviderIdentitySnapshot(
            providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: "Claude Pro"))
            .withSubscriptionMetadata(expiresAt: nil, renewsAt: nil)
        let carried = store.carryingClaudeSubscriptionMetadata(
            next, provider: .claude, strategy: .oauth, oauthHistoryOwner: "same-history")
        #expect(carried.subscriptionRenewsAt == nil)
        #expect(carried.identity?.widgetAccountOwnerID == nil)
        print("AUTHORITY PROOF prior binding: not carried into next OAuth capture")
    }
}
