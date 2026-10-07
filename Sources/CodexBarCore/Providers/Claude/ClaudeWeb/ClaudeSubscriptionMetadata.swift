import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Billing fields verified against the authenticated Claude billing page on 2026-10-05.
/// GET subscription_details is independent of quota refresh and never changes subscription state.
public struct ClaudeSubscriptionMetadata: Equatable, Sendable {
    public struct BillingDate: Equatable, Sendable {
        public let date: Date
        public let isDateOnly: Bool
    }

    public let renews: BillingDate?
    public let expires: BillingDate?

    public static func parse(_ data: Data) throws -> Self {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any], let status = fields["status"] as? String,
              ["active", "trialing", "canceled"].contains(status),
              fields.keys.contains("next_charge_at"), fields.keys.contains("next_charge_date"),
              fields.keys.contains("plan_ending_at"), fields.keys.contains("plan_ending_before")
        else { throw ParseError.unrecognized }
        func date(_ key: String) throws -> BillingDate? {
            guard let value = fields[key], !(value is NSNull) else { return nil }
            guard let string = value as? String else { throw ParseError.unrecognized }
            if string.count == 10 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                guard let parsed = formatter.date(from: string), formatter.string(from: parsed) == string else {
                    throw ParseError.unrecognized
                }
                return BillingDate(date: parsed, isDateOnly: true)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let parsed = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) else {
                throw ParseError.unrecognized
            }
            return BillingDate(date: parsed, isDateOnly: false)
        }
        let end = try date("plan_ending_at") ?? date("plan_ending_before")
        // Claude's current UI writes plan_ending_before after scheduled cancellation, and clears
        // both ending fields on resume. Never show a renewal alongside that scheduled ending.
        let renewal = end == nil && ["active", "trialing"].contains(status)
            ? try date("next_charge_at") ?? date("next_charge_date") : nil
        return Self(renews: renewal, expires: end)
    }

    public enum ParseError: Error { case unrecognized }
}

public enum ClaudeSubscriptionFetchResult: Equatable, Sendable {
    case unavailable
    /// A recognized response with two nil dates is authoritative empty metadata.
    case available(ClaudeSubscriptionMetadata)
}

public enum ClaudeSubscriptionMetadataFetcher {
    /// Uses ONLY an existing, verified web-owner binding. No cookie discovery or credential mutation.
    public static func fetch(cookieHeader: String, expectedOwnerID: String) async -> ClaudeSubscriptionFetchResult {
        do {
            let session = try ClaudeWebAPIFetcher.sessionKeyInfo(cookieHeader: cookieHeader)
            func get(_ path: String) async throws -> Data {
                var request = URLRequest(url: URL(string: "https://claude.ai/api" + path)!)
                request.setValue("sessionKey=\(session.key)", forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpMethod = "GET"
                request.timeoutInterval = 5
                let (data, response) = try await ClaudeWebHTTPTransport.current.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ClaudeSubscriptionMetadata.ParseError.unrecognized
                }
                try Task.checkCancellation()
                return data
            }
            func organization(_ data: Data) throws -> String? {
                guard let account = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let email = account["email_address"] as? String,
                      let memberships = account["memberships"] as? [[String: Any]] else { return nil }
                let matches = memberships.compactMap { membership -> String? in
                    guard let org = membership["organization"] as? [String: Any],
                          let id = org["uuid"] as? String,
                          UUID(uuidString: id) != nil,
                          [nil, account["uuid"] as? String].contains(where: { accountUUID in
                              ClaudeVerifiedAccountOwner.ownerID(
                                  accountUUID: accountUUID, email: email, organizationUUID: id) == expectedOwnerID
                          }) else { return nil }
                    return id
                }
                return matches.count == 1 ? matches.first : nil
            }
            guard let org = try await organization(get("/account")) else { return .unavailable }
            let metadata = try await ClaudeSubscriptionMetadata.parse(get("/organizations/\(org)/subscription_details"))
            // Recheck the authenticated principal + organization after the optional request.
            guard try await organization(get("/account")) == org else { return .unavailable }
            return .available(metadata)
        } catch { return .unavailable }
    }
}
