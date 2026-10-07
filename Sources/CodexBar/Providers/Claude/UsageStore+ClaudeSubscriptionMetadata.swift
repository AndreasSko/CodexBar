import CodexBarCore
import Foundation

extension UsageStore {
    func carryingClaudeSubscriptionMetadata(
        _ snapshot: UsageSnapshot, provider: UsageProvider, strategy: ProviderFetchKind) -> UsageSnapshot
    {
        guard provider == .claude, [.web, .oauth].contains(strategy),
              let prior = self.snapshots[.claude],
              Self.matchesClaudeSubscriptionOwner(snapshot, expected: prior) else { return snapshot }
        return snapshot.withSubscriptionMetadata(
            expiresAt: prior.subscriptionExpiresAt,
            renewsAt: prior.subscriptionRenewsAt,
            expiresAtIsDateOnly: prior.subscriptionExpiresAtIsDateOnly,
            renewsAtIsDateOnly: prior.subscriptionRenewsAtIsDateOnly)
    }

    func scheduleClaudeSubscriptionMetadataIfSupported(
        snapshot: UsageSnapshot, provider: UsageProvider, strategy: ProviderFetchKind, generation: UInt64?)
    {
        guard provider == .claude, [.web, .oauth].contains(strategy) else { return }
        self.scheduleClaudeSubscriptionMetadata(snapshot: snapshot, generation: generation)
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

    func scheduleClaudeSubscriptionMetadata(snapshot: UsageSnapshot, generation: UInt64?) {
        guard self.startupBehavior.automaticallyStartsBackgroundWork,
              self.settings.claudeCookieSource.isEnabled,
              let owner = snapshot.identity?.widgetAccountOwnerID, owner.hasPrefix("claude-owner-v1:") else { return }
        self.claudeSubscriptionMetadataTask?.cancel()
        let token = UUID()
        self.claudeSubscriptionMetadataToken = token
        let selectedAccount = self.settings.selectedTokenAccount(for: .claude)?.id
        self.claudeSubscriptionMetadataTask = Task(priority: .utility) { @MainActor [weak self] in
            // Cache I/O and the optional requests never hold up usage publication or refresh completion.
            let worker = Task.detached(priority: .utility) {
                guard let cache = CookieHeaderCache.load(provider: .claude) else {
                    return (ClaudeSubscriptionFetchResult.unavailable, CookieHeaderCache.Entry?.none)
                }
                let result = await ClaudeSubscriptionMetadataFetcher.fetch(
                    cookieHeader: cache.cookieHeader, expectedOwnerID: owner)
                return (result, Optional(cache))
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
                  self.isEnabled(.claude), self.settings.claudeCookieSource.isEnabled,
                  self.isCurrentProviderRefreshGeneration(.claude, generation: generation),
                  self.settings.selectedTokenAccount(for: .claude)?.id == selectedAccount,
                  let current = self.snapshots[.claude], Self.matchesClaudeSubscriptionOwner(
                      current,
                      expected: snapshot),
                  case let .available(metadata) = fetched.0,
                  let expectedCache = fetched.1 else { return }
            let cacheUnchanged = await Task.detached(priority: .utility) {
                CookieHeaderCache.load(provider: .claude) == expectedCache
            }.value
            guard cacheUnchanged, !Task.isCancelled,
                  self.claudeSubscriptionMetadataToken == token,
                  self.isCurrentProviderRefreshGeneration(.claude, generation: generation),
                  self.settings.selectedTokenAccount(for: .claude)?.id == selectedAccount,
                  let latest = self.snapshots[.claude],
                  Self.matchesClaudeSubscriptionOwner(latest, expected: snapshot) else { return }
            // Apply to the latest value, not the snapshot captured before the request.
            guard let enriched = Self.enrichingClaudeSubscriptionSnapshot(
                latest, expected: snapshot, result: .available(metadata)) else { return }
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
