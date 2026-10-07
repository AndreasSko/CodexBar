import CodexBarCore
import Foundation

extension UsageStore {
    #if DEBUG
    // Test only the external I/O boundary; scheduling, guards and publication remain production code.
    @TaskLocal static var claudeSubscriptionProofTransport: (any ProviderHTTPTransport)?
    @TaskLocal static var claudeSubscriptionProofCredentials:
        (@Sendable (String, [String: String]) -> ClaudeOAuthCredentials?)?
    #endif

    func carryingClaudeSubscriptionMetadata(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        strategy: ProviderFetchKind,
        oauthHistoryOwner: String? = nil) -> UsageSnapshot
    {
        guard provider == .claude, [.web, .oauth].contains(strategy),
              let prior = self.snapshots[.claude] else { return snapshot }
        // OAuth ownership must be verified anew by the optional path. A history identifier
        // cannot attest that the credential's current organization is unchanged.
        guard strategy == .web, Self.matchesClaudeSubscriptionOwner(snapshot, expected: prior)
        else { return snapshot }
        return snapshot.withSubscriptionMetadata(
            expiresAt: prior.subscriptionExpiresAt,
            renewsAt: prior.subscriptionRenewsAt,
            expiresAtIsDateOnly: prior.subscriptionExpiresAtIsDateOnly,
            renewsAtIsDateOnly: prior.subscriptionRenewsAtIsDateOnly)
    }

    func scheduleClaudeSubscriptionMetadataIfSupported(
        snapshot: UsageSnapshot,
        provider: UsageProvider,
        strategy: ProviderFetchKind,
        generation: UInt64?,
        oauthHistoryOwner: String? = nil)
    {
        guard provider == .claude, [.web, .oauth].contains(strategy) else { return }
        self.scheduleClaudeSubscriptionMetadata(
            snapshot: snapshot, generation: generation, oauthHistoryOwner: oauthHistoryOwner)
    }

    nonisolated static func matchesClaudeSubscriptionOwner(_ current: UsageSnapshot, expected: UsageSnapshot) -> Bool {
        guard let owner = expected.identity?.widgetAccountOwnerID,
              owner.hasPrefix("claude-owner-v1:") else { return false }
        return current.identity?.widgetAccountOwnerID == owner
            && current.identity?.accountEmail == expected.identity?.accountEmail
            && current.identity?.accountOrganization == expected.identity?.accountOrganization
            && current.identity?.loginMethod == expected.identity?.loginMethod
    }

    nonisolated static func enrichingClaudeSubscriptionSnapshot(
        _ current: UsageSnapshot,
        expected: UsageSnapshot,
        result: ClaudeSubscriptionFetchResult) -> UsageSnapshot?
    {
        guard self.matchesClaudeSubscriptionOwner(current, expected: expected),
              case let .available(metadata) = result else { return nil }
        return current.withSubscriptionMetadata(
            expiresAt: metadata.expires?.date,
            renewsAt: metadata.renews?.date,
            expiresAtIsDateOnly: metadata.expires?.isDateOnly ?? false,
            renewsAtIsDateOnly: metadata.renews?.isDateOnly ?? false)
    }

    nonisolated static func subscriptionManualCookie(
        source: ProviderCookieSource, accountToken: String?, configuredHeader: String) -> String?
    {
        if let header = ClaudeCredentialRouting.resolve(
            tokenAccountToken: accountToken, manualCookieHeader: nil).manualCookieHeader { return header }
        guard source == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(configuredHeader)
    }

    nonisolated static func subscriptionCaptureMatches(_ current: UsageSnapshot, _ expected: UsageSnapshot) -> Bool {
        if expected.identity?.widgetAccountOwnerID != nil {
            return self.matchesClaudeSubscriptionOwner(current, expected: expected)
        }
        return current.updatedAt == expected.updatedAt
            && current.identity?.widgetAccountOwnerID == nil
            && current.identity?.accountEmail == expected.identity?.accountEmail
            && current.identity?.accountOrganization == expected.identity?.accountOrganization
            && current.identity?.loginMethod == expected.identity?.loginMethod
    }

    nonisolated static func subscriptionSnapshot(_ snapshot: UsageSnapshot, owner: String) -> UsageSnapshot {
        let identity = snapshot.identity
        return snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: identity?.providerID,
            accountEmail: identity?.accountEmail,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod,
            accountID: identity?.accountID,
            widgetAccountOwnerID: owner))
    }

    func scheduleClaudeSubscriptionMetadata(
        snapshot: UsageSnapshot, generation: UInt64?, oauthHistoryOwner: String? = nil)
    {
        let account = self.settings.selectedTokenAccount(for: .claude)
        let manual = Self.subscriptionManualCookie(
            source: self.settings.claudeCookieSource,
            accountToken: account?.token,
            configuredHeader: self.settings.claudeCookieHeader)
        #if DEBUG
        let transportOverride = Self.claudeSubscriptionProofTransport
        let credentialOverride = Self.claudeSubscriptionProofCredentials
        #else
        let transportOverride: (any ProviderHTTPTransport)? = nil
        let credentialOverride: (@Sendable (String, [String: String]) -> ClaudeOAuthCredentials?)? = nil
        #endif
        let transport = transportOverride ?? ProviderHTTPClient.shared
        let credentialsForHistory: @Sendable (String, [String: String]) -> ClaudeOAuthCredentials? =
            credentialOverride ?? { history, environment in
                ClaudeOAuthCredentialsStore.cachedCredentialsForSubscription(
                    historyOwner: history, environment: environment)
            }
        guard self.startupBehavior.automaticallyStartsBackgroundWork || transportOverride != nil,
              manual != nil || self.settings.claudeCookieSource == .auto,
              snapshot.identity?.widgetAccountOwnerID != nil || oauthHistoryOwner != nil else { return }
        self.claudeSubscriptionMetadataTask?.cancel()
        let token = UUID()
        self.claudeSubscriptionMetadataToken = token
        let selectedAccount = account?.id
        let revision = self.settings.providerConfigRevision(for: .claude)
        let environment = ProviderRegistry.makeEnvironment(
            base: self.environmentBase, provider: .claude, settings: self.settings, tokenOverride: nil)
        self.claudeSubscriptionMetadataTask = Task(priority: .utility) { @MainActor [weak self] in
            // Cache I/O and the optional requests never hold up usage publication or refresh completion.
            let worker = Task.detached(priority: .utility) {
                let credentials = oauthHistoryOwner.flatMap {
                    credentialsForHistory($0, environment)
                }
                let owner: String?
                if oauthHistoryOwner != nil {
                    guard let credentials,
                          let verified = await ClaudeSubscriptionMetadataFetcher.oauthOwner(
                              accessToken: credentials.accessToken, transport: transport),
                          snapshot.identity?.widgetAccountOwnerID == nil
                          || snapshot.identity?.widgetAccountOwnerID == verified
                    else {
                        return (
                            ClaudeSubscriptionFetchResult.unavailable,
                            CookieHeaderCache.Entry?.none,
                            String?.none,
                            credentials?.accessToken)
                    }
                    owner = verified
                } else {
                    owner = snapshot.identity?.widgetAccountOwnerID
                }
                let cache = manual == nil ? CookieHeaderCache.load(provider: .claude) : nil
                guard let owner, let header = manual ?? cache?.cookieHeader else {
                    return (ClaudeSubscriptionFetchResult.unavailable, cache, owner, credentials?.accessToken)
                }
                let result = await ClaudeSubscriptionMetadataFetcher.fetch(
                    cookieHeader: header, expectedOwnerID: owner, transport: transport)
                if let credentials,
                   await ClaudeSubscriptionMetadataFetcher.oauthOwner(
                       accessToken: credentials.accessToken, transport: transport) != owner
                {
                    return (ClaudeSubscriptionFetchResult.unavailable, cache, Optional(owner), credentials.accessToken)
                }
                return (result, cache, Optional(owner), credentials?.accessToken)
            }
            let fetched = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            defer {
                if self.claudeSubscriptionMetadataToken == token {
                    self.claudeSubscriptionMetadataTask = nil
                    self.claudeSubscriptionMetadataToken = nil
                }
            }
            guard !Task.isCancelled, self.claudeSubscriptionMetadataToken == token,
                  self.isEnabled(.claude), self.settings.providerConfigRevision(for: .claude) == revision,
                  self.isCurrentProviderRefreshGeneration(.claude, generation: generation),
                  self.settings.selectedTokenAccount(for: .claude)?.id == selectedAccount,
                  let current = self.snapshots[.claude], Self.subscriptionCaptureMatches(current, snapshot),
                  case let .available(metadata) = fetched.0, let owner = fetched.2 else { return }
            let cacheUnchanged = await Task.detached(priority: .utility) {
                let cookieMatches = manual != nil || CookieHeaderCache.load(provider: .claude) == fetched.1
                let oauthMatches = fetched.3 == nil || oauthHistoryOwner.flatMap {
                    credentialsForHistory($0, environment)
                }?.accessToken == fetched.3
                return cookieMatches && oauthMatches
            }.value
            let currentManual = Self.subscriptionManualCookie(
                source: self.settings.claudeCookieSource,
                accountToken: self.settings.selectedTokenAccount(for: .claude)?.token,
                configuredHeader: self.settings.claudeCookieHeader)
            guard cacheUnchanged, currentManual == manual, !Task.isCancelled,
                  self.settings.providerConfigRevision(for: .claude) == revision,
                  self.claudeSubscriptionMetadataToken == token,
                  self.isCurrentProviderRefreshGeneration(.claude, generation: generation),
                  self.settings.selectedTokenAccount(for: .claude)?.id == selectedAccount,
                  let latest = self.snapshots[.claude],
                  Self.subscriptionCaptureMatches(latest, snapshot) else { return }
            // Apply to the latest value, not the snapshot captured before the request.
            guard let enriched = Self.enrichingClaudeSubscriptionSnapshot(
                Self.subscriptionSnapshot(latest, owner: owner),
                expected: Self.subscriptionSnapshot(
                    snapshot,
                    owner: owner),
                result: .available(metadata))
            else { return }
            self.snapshots[.claude] = enriched
            if let resetSnapshot = self.lastKnownResetSnapshots[.claude],
               let updatedReset = Self.enrichingClaudeSubscriptionSnapshot(
                   resetSnapshot, expected: snapshot, result: .available(metadata))
            {
                self.lastKnownResetSnapshots[.claude] = updatedReset
            }
            if let account = self.settings.selectedTokenAccount(for: .claude),
               let sourceLabel = self.lastSourceLabels[.claude]
            {
                self.cacheTokenAccountSnapshot(
                    provider: .claude, account: account, snapshot: enriched, sourceLabel: sourceLabel)
            }
            self.persistWidgetSnapshot(reason: "claude-subscription-metadata")
        }
    }
}
