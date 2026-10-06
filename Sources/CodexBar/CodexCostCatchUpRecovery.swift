import CodexBarCore

/// A worker may recover one empty, time-limited pass per cache, never a repeated semantic cycle.
struct CodexCostCatchUpRecovery {
    private var recoveredScopes: Set<String> = []

    mutating func shouldRecover(
        scope: String,
        previousProgressKey: String?,
        status: CostUsageFetcher.CodexScanCatchUpStatus) -> Bool
    {
        guard status.pending,
              status.progressKey == previousProgressKey,
              status.passDiagnostics?.yieldedBeforeFileAttempt == true
        else { return false }
        return self.recoveredScopes.insert(scope).inserted
    }

    static func logRepeatedPass(
        worker: String,
        accountSlot: Int,
        previousProgressKey: String?,
        status: CostUsageFetcher.CodexScanCatchUpStatus,
        recovering: Bool)
    {
        // Progress keys are digests; scope IDs and session paths deliberately stay out of this log.
        CodexBarLog.logger(LogCategories.tokenCost).warning(
            "\(worker) Codex cost catch-up repeated pass: accountSlot=\(accountSlot)"
                + " recovering=\(recovering) previousKey=\(previousProgressKey ?? "none")"
                + " nextKey=\(status.progressKey) files=\(status.completedFiles)/\(status.totalFiles)"
                + " \(status.passDiagnostics?.logSummary ?? "diagnostics=unavailable")")
    }
}
