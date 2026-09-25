import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore
#if os(macOS)
import SweetCookieKit
#endif

struct LangdockUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func response(_ plan: String) -> Data {
        Data("""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":\(plan)}}}}]
        """.utf8)
    }

    @Test
    func `session and weekly percentages retain raw values and reset dates`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":12.5,
         "sessionResetsAt":"2026-09-25T12:00:00.123Z","weeklyUsagePercent":104.2,
         "weeklyResetsAt":"2026-09-28T12:00:00Z"}
        """)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200, now: Self.now)

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.secondary?.usedPercent == 104.2)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt != nil)
        #expect(usage.updatedAt == Self.now)
        #expect(usage.dataConfidence == .percentOnly)
    }

    @Test
    func `disabled session leaves a genuine zero weekly value`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}
        """)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200)

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.resetsAt == nil)
    }

    @Test
    func `weekly only usage renders one full quota CLI metric`() throws {
        let data = Self.response("""
        {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}
        """)
        let snapshot = try LangdockUsageParser.parse(data, statusCode: 200, now: Self.now)
        let card = CLICardsRenderer.makeCard(.init(
            provider: .langdock,
            snapshot: snapshot,
            credits: nil,
            source: "synthetic",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .countdown,
            weeklyWorkDays: nil,
            now: Self.now))

        #expect(card.metrics.map(\.label) == ["Weekly"])
        #expect(card.metrics.first?.remainingPercent == 100)
        #expect(card.metrics.first?.resetText == nil)
    }

    @Test
    func `missing plan is a valid absence of included limits`() throws {
        let data = Data("""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":false}}}}]
        """.utf8)
        let usage = try LangdockUsageParser.parse(data, statusCode: 200)

        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.details.first?.rows.first?.value == "No included usage limits available")
    }

    @Test(arguments: [
        #"{"sessionUsageLimitsEnabled":true,"weeklyUsagePercent":4}"#,
        #"{"sessionUsageLimitsEnabled":true,"sessionUsagePercent":"5","weeklyUsagePercent":4}"#,
        #"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":"4"}"#,
        #"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":4,"weeklyResetsAt":"tomorrow"}"#,
    ])
    func `missing or malformed expected fields fail instead of becoming zero`(plan: String) {
        #expect(throws: LangdockUsageError.self) {
            try LangdockUsageParser.parse(Self.response(plan), statusCode: 200)
        }
    }

    @Test
    func `trpc and HTTP denials are distinct from missing limits`() {
        let forbidden = Data("""
        [{"error":{"json":{"data":{"code":"FORBIDDEN"}}}}]
        """.utf8)
        #expect(throws: LangdockUsageError.forbidden) {
            try LangdockUsageParser.parse(forbidden, statusCode: 200)
        }
        #expect(throws: LangdockUsageError.unauthorized) {
            try LangdockUsageParser.parse(Data(), statusCode: 401)
        }
        #expect(throws: LangdockUsageError.httpStatus(429)) {
            try LangdockUsageParser.parse(Data(), statusCode: 429)
        }
    }

    @Test
    func `profile ID persists in Langdock provider config`() throws {
        var config = ProviderConfig(id: .langdock)
        config.langdockEdgeProfileID = "/synthetic/Edge/Profile 2"
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.langdockEdgeProfileID == "/synthetic/Edge/Profile 2")
        #expect(LangdockProviderDescriptor.descriptor.metadata.defaultEnabled == false)
        #expect(LangdockProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .web])
    }

    @MainActor
    @Test
    func `cached Langdock usage is visible only for its selected profile`() {
        let settings = testSettingsStore(suiteName: "Langdock-profile-scope", userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let firstProfile = "/synthetic/Edge/Profile 1"
        store.snapshots[.langdock] = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Self.now).withIdentity(ProviderIdentitySnapshot(
            providerID: .langdock,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Edge profile",
            accountID: firstProfile))

        #expect(store.snapshot(for: .langdock) == nil)
        settings.updateProviderConfig(provider: .langdock) { $0.langdockEdgeProfileID = firstProfile }
        #expect(store.snapshot(for: .langdock)?.secondary?.usedPercent == 25)
        settings.updateProviderConfig(provider: .langdock) {
            $0.langdockEdgeProfileID = "/synthetic/Edge/Profile 2"
        }
        #expect(store.snapshot(for: .langdock) == nil)
    }

    @Test
    func `transient failures preserve prior usage while credential failures clear it`() {
        #expect(UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.httpStatus(503), hadPriorData: true))
        #expect(UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.httpStatus(429), hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.unauthorized, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.profileUnavailable, hadPriorData: true))
        #expect(UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.profileUnreadable, hadPriorData: true))
        #expect(UsageStore.shouldPreservePriorSnapshot(
            after: LangdockUsageError.browserAccessPaused, hadPriorData: true))
    }

    #if os(macOS)
    @Test
    func `profile discovery separates permission errors from absent stores`() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        let profile = home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default").path

        #expect(LangdockEdgeCookieImporter.profileAccessError(
            profileID: profile,
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.EPERM) }) == .profileUnreadable)
        #expect(LangdockEdgeCookieImporter.profileAccessError(
            profileID: profile,
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.ENOENT) }) == nil)
        #expect(LangdockEdgeCookieImporter.profileAccessError(
            profileID: "/other/path/Default",
            homeDirectories: [home],
            listDirectory: { _ in throw POSIXError(.EPERM) }) == nil)
    }

    private static func store(_ profileID: String, kind: BrowserCookieStoreKind) -> BrowserCookieStore {
        BrowserCookieStore(
            browser: .edge,
            profile: BrowserProfile(id: profileID, name: URL(fileURLWithPath: profileID).lastPathComponent),
            kind: kind,
            label: "Synthetic Edge",
            databaseURL: URL(fileURLWithPath: profileID).appendingPathComponent("Cookies"))
    }

    private static func cookie(
        domain: String,
        scope: BrowserCookieScope,
        name: String,
        value: String,
        path: String = "/") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: Date(timeIntervalSinceNow: 3600),
            isSecure: true,
            isHTTPOnly: true,
            scope: scope)
    }

    @Test
    func `only the selected profile store is chosen even if another comes first`() throws {
        let other = Self.store("/synthetic/Edge/Profile 1", kind: .network)
        let selectedPrimary = Self.store("/synthetic/Edge/Profile 2", kind: .primary)
        let selectedNetwork = Self.store("/synthetic/Edge/Profile 2", kind: .network)
        let stores = [other, selectedPrimary, selectedNetwork]

        #expect(try LangdockEdgeCookieImporter.selectedStore(
            profileID: selectedNetwork.profile.id,
            from: stores) == selectedNetwork)
        #expect(throws: LangdockUsageError.profileUnavailable) {
            try LangdockEdgeCookieImporter.selectedStore(profileID: "/synthetic/Edge/Profile 3", from: stores)
        }
    }

    @Test
    func `cookies honor host and path without borrowing another domain`() throws {
        let records = [
            Self.cookie(domain: "langdock.com", scope: .domain, name: "auth_token", value: "synthetic-auth"),
            Self.cookie(domain: "app.langdock.com", scope: .hostOnly, name: "pref", value: "A"),
            Self.cookie(domain: "langdock.com", scope: .hostOnly, name: "root-only", value: "B"),
            Self.cookie(domain: "other.langdock.com", scope: .domain, name: "other", value: "C"),
            Self.cookie(
                domain: "app.langdock.com",
                scope: .hostOnly,
                name: "wrong-path",
                value: "D",
                path: "/settings"),
        ]
        let header = try LangdockEdgeCookieImporter.cookieHeader(from: records)

        #expect(header.contains("auth_token=synthetic-auth"))
        #expect(header.contains("pref=A"))
        #expect(!header.contains("root-only"))
        #expect(!header.contains("other="))
        #expect(!header.contains("wrong-path"))
    }

    @Test
    func `conflicting auth cookies in one profile fail closed`() {
        let records = [
            Self.cookie(domain: "langdock.com", scope: .domain, name: "auth_token", value: "synthetic-one"),
            Self.cookie(domain: "app.langdock.com", scope: .hostOnly, name: "auth_token", value: "synthetic-two"),
        ]
        #expect(throws: LangdockUsageError.sessionUnavailable) {
            try LangdockEdgeCookieImporter.cookieHeader(from: records)
        }
    }

    @Test
    func `fetch uses only the selected profile and known Langdock endpoint`() async throws {
        let selected = "/synthetic/Edge/Profile 2"
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.host == "app.langdock.com")
            #expect(request.url?.path == "/api/trpc/usageSettings.getPersonalUsage")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "batch" })?.value == "1")
            #expect(query?.first(where: { $0.name == "input" })?.value?.contains("\"undefined\"") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-selected")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.response("""
            {"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":42}
            """), response)
        }
        let usage = try await LangdockUsageFetcher.fetch(
            edgeProfileID: selected,
            timeout: 5,
            transport: transport,
            cookieHeaderProvider: { profileID in
                guard profileID == selected else { throw LangdockUsageError.profileUnavailable }
                return "auth_token=synthetic-selected"
            })

        #expect(usage.secondary?.usedPercent == 42)
        #expect(usage.identity?.accountID == selected)
    }
    #endif
}
