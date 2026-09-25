import Foundation
import SweetCookieKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LangdockUsageFetcher {
    private static let usageURL =
        URL(
            string: "https://app.langdock.com/api/trpc/usageSettings.getPersonalUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D")!

    private static let isolatedTransport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    public static func fetch(
        edgeProfileID: String?,
        timeout: TimeInterval,
        transport: (any ProviderHTTPTransport)? = nil,
        cookieHeaderProvider: (@Sendable (String) throws -> String)? = nil) async throws -> UsageSnapshot
    {
        #if os(macOS)
        guard let edgeProfileID = edgeProfileID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !edgeProfileID.isEmpty
        else { throw LangdockUsageError.profileRequired }
        try Task.checkCancellation()
        let cookieHeader = try cookieHeaderProvider?(edgeProfileID)
            ?? LangdockEdgeCookieImporter.cookieHeader(profileID: edgeProfileID)
        try Task.checkCancellation()
        var request = URLRequest(url: self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(1, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://app.langdock.com/settings/account/usage", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let response = try await (transport ?? self.isolatedTransport).response(for: request)
        try Task.checkCancellation()
        return try LangdockUsageParser.parse(response.data, statusCode: response.statusCode).withIdentity(
            ProviderIdentitySnapshot(
                providerID: .langdock,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Edge profile",
                accountID: edgeProfileID))
        #else
        throw LangdockUsageError.unsupportedPlatform
        #endif
    }
}

#if os(macOS)
public enum LangdockEdgeCookieImporter {
    private static let query = BrowserCookieQuery(
        domains: ["langdock.com", "app.langdock.com"],
        domainMatch: .exact,
        origin: .fixed(URL(string: "https://app.langdock.com")!))

    public static func selectedStore(
        profileID: String,
        from stores: [BrowserCookieStore]) throws -> BrowserCookieStore
    {
        let matching = stores.filter { $0.browser == .edge && $0.profile.id == profileID }
        guard let store = matching.first(where: { $0.kind == .network })
            ?? matching.first(where: { $0.kind == .primary })
        else { throw LangdockUsageError.profileUnavailable }
        return store
    }

    public static func cookieHeader(
        profileID: String,
        client: BrowserCookieClient = BrowserCookieClient()) throws -> String
    {
        let store = try self.selectedStore(profileID: profileID, from: client.codexBarStores(for: .edge))
        let records = try client.codexBarRecords(matching: self.query, in: store)
        return try self.cookieHeader(from: records)
    }

    public static func cookieHeader(from records: [BrowserCookieRecord]) throws -> String {
        let host = "app.langdock.com"
        let path = "/api/trpc/usageSettings.getPersonalUsage"
        let now = Date()
        let applicable = records.filter { record in
            let domain = record.domain.lowercased()
            let matchesHost = domain == host || (record.scope == .domain && host.hasSuffix("." + domain))
            let cookiePath = record.path.isEmpty ? "/" : record.path
            let matchesPath = path == cookiePath ||
                (path
                    .hasPrefix(cookiePath) &&
                    (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).first == "/"))
            return matchesHost && matchesPath && (record.expires == nil || record.expires! > now)
                && !record.name.isEmpty && !record.name.contains(";") && !record.name.contains("\n")
                && !record.value.contains(";") && !record.value.contains("\r") && !record.value.contains("\n")
        }
        let authValues = Set(applicable.filter { $0.name == "auth_token" }.map(\.value))
        guard authValues.count == 1, authValues.first?.isEmpty == false else {
            throw LangdockUsageError.sessionUnavailable
        }
        return applicable.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.name < $1.name
        }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
#endif
