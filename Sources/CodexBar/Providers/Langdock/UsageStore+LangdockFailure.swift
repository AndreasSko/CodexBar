import CodexBarCore
import Foundation

extension UsageStore {
    func profileScopedSnapshot(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        let snapshot = self.snapshots[instanceID]
        guard instanceID == .langdock else { return snapshot }
        guard let snapshot,
              let profileID = self.settings.providerConfig(for: .langdock)?.langdockEdgeProfileID,
              snapshot.identity?.accountID == profileID
        else { return nil }
        return snapshot
    }

    func shouldSurfaceProviderRefreshFailure(
        provider: UsageProvider,
        state: (hadPriorData: Bool, preservesPriorData: Bool, restoredClaudeHistory: Bool)) -> Bool
    {
        if provider == .langdock {
            if !state.preservesPriorData {
                self.lastKnownResetSnapshots.removeValue(forKey: provider.instanceID)
                self.lastSourceLabels.removeValue(forKey: provider.instanceID)
            }
            if state.hadPriorData { return true }
        }
        if state.restoredClaudeHistory { return true }
        return self.failureGates[provider.instanceID]?
            .shouldSurfaceError(onFailureWithPriorData: state.hadPriorData) ?? true
    }
}

extension UsageSnapshot {
    func backfillingResetTimesForProvider(_ provider: UsageProvider, from cached: UsageSnapshot?) -> UsageSnapshot {
        // Langdock explicitly reports an unknown reset by omitting it. Do not revive an older date.
        provider == .langdock ? self : self.backfillingResetTimes(from: cached)
    }
}

enum LangdockFailurePolicy {
    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? LangdockUsageError else { return false }
        return switch error {
        case let .httpStatus(status): status == 429 || (500...599).contains(status)
        case let .rejected(code): ["TOO_MANY_REQUESTS", "INTERNAL_SERVER_ERROR", "TIMEOUT"].contains(code)
        default: false
        }
    }
}
