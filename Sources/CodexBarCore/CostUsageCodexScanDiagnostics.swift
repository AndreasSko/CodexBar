import Foundation

/// Scheduling evidence from one bounded pass; contains no account IDs, paths, or session content.
package struct CodexScanPassDiagnostics: Sendable, Equatable {
    package let durationBudget: TimeInterval?
    package let fileAttempts: Int
    package let bytesConsumed: Int64
    package let deferredByTime: Bool
    /// Reader admission deferrals can include time yields as well as byte limits.
    package let deferredByBytes: Bool
    package let priorityValidationPending: Bool

    package init(
        durationBudget: TimeInterval?,
        fileAttempts: Int,
        bytesConsumed: Int64,
        deferredByTime: Bool,
        deferredByBytes: Bool = false,
        priorityValidationPending: Bool = false)
    {
        self.durationBudget = durationBudget
        self.fileAttempts = max(0, fileAttempts)
        self.bytesConsumed = max(0, bytesConsumed)
        self.deferredByTime = deferredByTime
        self.deferredByBytes = deferredByBytes
        self.priorityValidationPending = priorityValidationPending
    }

    package var yieldedBeforeFileAttempt: Bool {
        self.deferredByTime && self.fileAttempts == 0 && self.bytesConsumed == 0
            && !self.priorityValidationPending
    }

    package var logSummary: String {
        "budget=\(self.durationBudget.map(String.init(describing:)) ?? "none")"
            + " fileAttempts=\(self.fileAttempts) bytesRead=\(self.bytesConsumed)"
            + " timeDeferred=\(self.deferredByTime) admissionDeferred=\(self.deferredByBytes)"
            + " priorityValidationPending=\(self.priorityValidationPending)"
    }
}

extension CostUsageScanner {
    /// Owned by a single synchronous scan. Only the finished value crosses the scan executor.
    final class CodexScanPassRecorder: @unchecked Sendable {
        private var fileAttempts = 0
        private var budget: CodexScanBudget?
        private var priorityValidationPending = false

        func recordFileAttempt() {
            self.fileAttempts += 1
        }

        func recordBudget(_ budget: CodexScanBudget) {
            self.budget = budget
        }

        func recordPriorityValidationPending() {
            self.priorityValidationPending = true
        }

        func snapshot(durationBudget: TimeInterval?) -> CodexScanPassDiagnostics {
            CodexScanPassDiagnostics(
                durationBudget: durationBudget,
                fileAttempts: self.fileAttempts,
                bytesConsumed: self.budget?.bytesConsumed ?? 0,
                deferredByTime: (self.budget?.deferredByTimeBudgetFileCount ?? 0) > 0,
                deferredByBytes: (self.budget?.deferredByBudgetFileCount ?? 0) > 0,
                priorityValidationPending: self.priorityValidationPending)
        }
    }
}
