import CodexBarCore
import Foundation

struct SpendDashboardCodexCostCatchUpContext: Sendable {
    let token: UUID
    let accounts: [CodexSpendScanRequest]
    let historyDays: Int
    let scopeSignature: String
    let providerConfigRevision: UInt64
    let costUsageSettingsRevision: UInt64
}

struct SpendDashboardCodexCostCatchUpPause: Sendable {
    let context: SpendDashboardCodexCostCatchUpContext
    let pausedAt: Date
    let pendingCacheIdentities: Set<String>
}

struct SpendDashboardCodexCostCatchUpCompletionState: Sendable {
    var pause: SpendDashboardCodexCostCatchUpPause?
    var task: Task<Void, Never>?
    var token: UUID?
}

extension UsageStore {
    func refreshSpendDashboard(accounts: [CodexSpendScanRequest]) {
        self.sharedSpendDashboardController().refresh()
        guard self.spendDashboardCodexCostCatchUpRequiresExplicitResume else { return }
        self.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: .automatic)
    }

    func synchronizeSpendDashboardCodexCostCatchUp(
        accounts: [CodexSpendScanRequest],
        preferredMode: CodexCostCatchUpMode? = nil)
    {
        let accounts = Self.uniqueSpendDashboardCodexAccounts(accounts)
        guard !accounts.isEmpty,
              self.settings.isCostUsageEffectivelyEnabled(for: .codex),
              self.isEnabled(.codex)
        else {
            self.cancelSpendDashboardCodexCostCatchUp()
            return
        }
        // Observation-driven reloads must not undo a stop or repeatedly retry a stalled/failed pass.
        // Explicit Refresh uses startSpendDashboardCodexCostCatchUpIfNeeded directly.
        guard !self.spendDashboardCodexCostCatchUpStopRequested else { return }
        if self.spendDashboardCodexCostCatchUpRequiresExplicitResume {
            self.checkSpendDashboardCodexCostCatchUpCompletion(accounts: accounts)
            return
        }
        var mode = preferredMode
            ?? (self.spendDashboardCodexCostCatchUpTask == nil ? .automatic : self.spendDashboardCodexCostCatchUpMode)
        if preferredMode == .accelerated,
           self.spendDashboardCodexCostCatchUpTask == nil
           || self.spendDashboardCodexCostCatchUpMode != .accelerated,
           case .pause = self.codexCostCatchUpDecision(
               mode: .automatic,
               previousActiveDuration: nil,
               resourceState: self._test_spendDashboardCodexCostCatchUpResourceStateOverride?()).action
        {
            mode = .automatic
        }
        self.startSpendDashboardCodexCostCatchUpIfNeeded(accounts: accounts, mode: mode)
    }

    func startSpendDashboardCodexCostCatchUpIfNeeded(
        accounts: [CodexSpendScanRequest],
        mode: CodexCostCatchUpMode = .automatic)
    {
        let accounts = Self.uniqueSpendDashboardCodexAccounts(accounts)
        guard !accounts.isEmpty,
              self.settings.isCostUsageEffectivelyEnabled(for: .codex),
              self.isEnabled(.codex)
        else {
            self.cancelSpendDashboardCodexCostCatchUp()
            return
        }

        let historyDays = max(SpendDashboardSource.scanDays, self.settings.costUsageHistoryDays)
        let accountScopeSignature = accounts
            .map { "\($0.id)|\($0.cacheIdentity)" }
            .joined(separator: "\u{0}")
        let scopeSignature = "\(historyDays)\u{0}\(accountScopeSignature)"
        if self.spendDashboardCodexCostCatchUpTask != nil,
           self.spendDashboardCodexCostCatchUpScopeSignature == scopeSignature
        {
            if self.spendDashboardCodexCostCatchUpMode == mode {
                // A dashboard reload can discover fresh tail work while the previous task is
                // completing. Queue one restart so that the new pending status retains a worker.
                self.spendDashboardCodexCostCatchUpRestartRequested = true
                return
            }
            self.spendDashboardCodexCostCatchUpMode = mode
            // A bounded parser pass may be committing a resume checkpoint. Let it finish and
            // apply the new mode before scheduling the next account instead of cancelling it.
            if self.spendDashboardCodexCostCatchUpPassIsRunning {
                return
            }
        }

        self.cancelSpendDashboardCodexCostCatchUp()
        let token = UUID()
        let context = SpendDashboardCodexCostCatchUpContext(
            token: token,
            accounts: accounts,
            historyDays: historyDays,
            scopeSignature: scopeSignature,
            providerConfigRevision: self.settings.providerConfigRevision(for: .codex),
            costUsageSettingsRevision: self.settings.costUsageSettingsRevision)
        self.spendDashboardCodexCostCatchUpToken = token
        self.spendDashboardCodexCostCatchUpScopeSignature = scopeSignature
        self.spendDashboardCodexCostCatchUpMode = mode
        self.spendDashboardCodexCostCatchUpStopRequested = false
        self.spendDashboardCodexCostCatchUpPassIsRunning = false
        let priority: TaskPriority = mode == .accelerated ? .utility : .background
        self.spendDashboardCodexCostCatchUpTask = Task(priority: priority) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.spendDashboardCodexCostCatchUpToken == token {
                    // Scope invalidation can exit without publishing a terminal activity.
                    if self.spendDashboardCodexCostCatchUpActivity?.phase == .indexing {
                        self.spendDashboardCodexCostCatchUpActivity = nil
                    }
                    self.spendDashboardCodexCostCatchUpTask = nil
                    self.spendDashboardCodexCostCatchUpToken = nil
                    self.spendDashboardCodexCostCatchUpScopeSignature = nil
                    let restartRequested = self.spendDashboardCodexCostCatchUpRestartRequested
                    self.spendDashboardCodexCostCatchUpRestartRequested = false
                    if restartRequested, !self.spendDashboardCodexCostCatchUpRequiresExplicitResume {
                        self.startSpendDashboardCodexCostCatchUpIfNeeded(
                            accounts: context.accounts,
                            mode: self.spendDashboardCodexCostCatchUpMode)
                    }
                }
            }
            await self.runSpendDashboardCodexCostCatchUp(context: context)
        }
    }

    func stopSpendDashboardCodexCostCatchUp() {
        guard self.spendDashboardCodexCostCatchUpTask != nil else { return }
        self.spendDashboardCodexCostCatchUpStopRequested = true
        self.spendDashboardCodexCostCatchUpRestartRequested = false
        guard !self.spendDashboardCodexCostCatchUpPassIsRunning else { return }
        if let activity = self.spendDashboardCodexCostCatchUpActivity {
            self.spendDashboardCodexCostCatchUpActivity = CodexCostCatchUpActivity(
                phase: .paused,
                mode: activity.mode,
                processedBytes: activity.processedBytes,
                totalBytes: activity.totalBytes,
                completedFiles: activity.completedFiles,
                totalFiles: activity.totalFiles,
                pauseReason: .user,
                staleSnapshotUpdatedAt: activity.staleSnapshotUpdatedAt)
        }
        self.spendDashboardCodexCostCatchUpTask?.cancel()
        self.spendDashboardCodexCostCatchUpTask = nil
        self.spendDashboardCodexCostCatchUpToken = nil
        self.spendDashboardCodexCostCatchUpScopeSignature = nil
    }

    func cancelSpendDashboardCodexCostCatchUp() {
        self.spendDashboardCodexCostCatchUpCompletion.task?.cancel()
        self.spendDashboardCodexCostCatchUpCompletion.task = nil
        self.spendDashboardCodexCostCatchUpCompletion.token = nil
        self.spendDashboardCodexCostCatchUpCompletion.pause = nil
        self.spendDashboardCodexCostCatchUpTask?.cancel()
        self.spendDashboardCodexCostCatchUpTask = nil
        self.spendDashboardCodexCostCatchUpToken = nil
        self.spendDashboardCodexCostCatchUpScopeSignature = nil
        self.spendDashboardCodexCostCatchUpStopRequested = false
        self.spendDashboardCodexCostCatchUpPassIsRunning = false
        self.spendDashboardCodexCostCatchUpRestartRequested = false
        self.spendDashboardCodexCostCatchUpActivity = nil
    }

    private var spendDashboardCodexCostCatchUpRequiresExplicitResume: Bool {
        guard let activity = self.spendDashboardCodexCostCatchUpActivity,
              activity.phase == .paused else { return false }
        switch activity.pauseReason {
        case .user, .noProgress, .error:
            return true
        case .lowPower, .thermal, .none:
            return false
        }
    }

    private func runSpendDashboardCodexCostCatchUp(
        context: SpendDashboardCodexCostCatchUpContext) async
    {
        var statuses = await self.loadSpendDashboardCodexCostCatchUpStatuses(context.accounts)
        guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
        self.publishSpendDashboardCodexCostCatchUpActivity(
            statuses: statuses,
            context: context,
            phase: Self.spendDashboardCodexCatchUpIsPending(statuses) ? .indexing : .complete)

        var didChangeCache = false
        var previousActiveDuration: TimeInterval?
        var completedPasses = 0
        var recovery = CodexCostCatchUpRecovery()
        var requiresFreshBudget = false
        var (stalledCacheIdentities, seenKeysByCache) =
            (Set<String>(), statuses.mapValues { Set([$0.progressKey]) })
        while Self.spendDashboardCodexCatchUpIsPending(statuses) {
            do {
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }

                guard let account = context.accounts.first(where: {
                    statuses[$0.cacheIdentity]?.pending == true
                        && !stalledCacheIdentities.contains($0.cacheIdentity)
                }) else {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .noProgress)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    CodexBarLog.logger(LogCategories.tokenCost).warning(
                        "Spend Dashboard Codex cost catch-up stopped because all pending account caches stalled")
                    return
                }

                let decision = self.codexCostCatchUpDecision(
                    mode: self.spendDashboardCodexCostCatchUpMode,
                    previousActiveDuration: previousActiveDuration,
                    completedPasses: completedPasses,
                    requiresFreshBudget: requiresFreshBudget,
                    resourceState: self._test_spendDashboardCodexCostCatchUpResourceStateOverride?())
                switch decision.action {
                case let .pause(delay, reason):
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: reason)
                    try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay, dashboard: true)
                    continue
                case let .runAfter(delay):
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .indexing)
                    if delay > 0 || self.spendDashboardCodexCostCatchUpMode == .accelerated {
                        previousActiveDuration = nil
                        completedPasses = 0
                        requiresFreshBudget = false
                    }
                    try await self.sleepBetweenCodexCostCatchUpPasses(seconds: delay, dashboard: true)
                }

                try Task.checkCancellation()
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }

                let previousStatus = statuses[account.cacheIdentity]
                let result = try await self.advanceSpendDashboardCodexCostCatchUp(
                    account: account,
                    now: Date(),
                    historyDays: context.historyDays,
                    previousActiveDuration: previousActiveDuration)
                let nextStatus = result.value
                previousActiveDuration = (previousActiveDuration ?? 0) + result.activeDuration
                completedPasses += 1
                didChangeCache = didChangeCache || nextStatus.progressKey != previousStatus?.progressKey
                statuses[account.cacheIdentity] = nextStatus
                if nextStatus.pending,
                   !seenKeysByCache[account.cacheIdentity, default: []].insert(nextStatus.progressKey).inserted
                {
                    let recovering = recovery.shouldRecover(
                        scope: account.cacheIdentity,
                        previousProgressKey: previousStatus?.progressKey,
                        status: nextStatus)
                    CodexCostCatchUpRecovery.logRepeatedPass(
                        worker: "Spend Dashboard",
                        accountSlot: context.accounts.firstIndex(of: account) ?? 0,
                        previousProgressKey: previousStatus?.progressKey,
                        status: nextStatus,
                        recovering: recovering)
                    if recovering {
                        requiresFreshBudget = true
                    } else {
                        stalledCacheIdentities.insert(account.cacheIdentity)
                    }
                } else {
                    stalledCacheIdentities.remove(account.cacheIdentity)
                }

                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                let isPending = Self.spendDashboardCodexCatchUpIsPending(statuses)
                self.publishSpendDashboardCodexCostCatchUpActivity(
                    statuses: statuses,
                    context: context,
                    phase: isPending ? .indexing : .complete)
                if self.spendDashboardCodexCostCatchUpStopRequested {
                    self.publishSpendDashboardCodexCostCatchUpActivity(
                        statuses: statuses,
                        context: context,
                        phase: .paused,
                        pauseReason: .user)
                    self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.spendDashboardCodexCostCatchUpContextIsCurrent(context) else { return }
                self.publishSpendDashboardCodexCostCatchUpActivity(
                    statuses: statuses,
                    context: context,
                    phase: .paused,
                    pauseReason: .error(error.localizedDescription))
                self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
                CodexBarLog.logger(LogCategories.tokenCost).warning(
                    "Spend Dashboard Codex cost catch-up stopped after error: \(error.localizedDescription)")
                return
            }
        }

        self.publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(didChangeCache)
    }

    private func spendDashboardCodexCostCatchUpContextIsCurrent(
        _ context: SpendDashboardCodexCostCatchUpContext) -> Bool
    {
        !Task.isCancelled
            && self.spendDashboardCodexCostCatchUpToken == context.token
            && self.spendDashboardCodexCostCatchUpScopeSignature == context.scopeSignature
            && self.spendDashboardCodexCostCatchUpConfigurationIsCurrent(context)
    }

    private func spendDashboardCodexCostCatchUpConfigurationIsCurrent(
        _ context: SpendDashboardCodexCostCatchUpContext) -> Bool
    {
        self.settings.providerConfigRevision(for: .codex) == context.providerConfigRevision
            && self.settings.costUsageSettingsRevision == context.costUsageSettingsRevision
            && max(SpendDashboardSource.scanDays, self.settings.costUsageHistoryDays) == context.historyDays
            && self.settings.isCostUsageEffectivelyEnabled(for: .codex)
            && self.isEnabled(.codex)
            && context.accounts.allSatisfy(SpendDashboardSource.codexAuthFingerprintMatches)
    }

    private func checkSpendDashboardCodexCostCatchUpCompletion(accounts: [CodexSpendScanRequest]) {
        if let pause = self.spendDashboardCodexCostCatchUpCompletion.pause, pause.context.accounts != accounts {
            self.spendDashboardCodexCostCatchUpCompletion.task?.cancel()
            self.spendDashboardCodexCostCatchUpCompletion.task = nil
            self.spendDashboardCodexCostCatchUpCompletion.token = nil
            return
        }
        guard self.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress,
              self.spendDashboardCodexCostCatchUpTask == nil,
              self.spendDashboardCodexCostCatchUpCompletion.task == nil,
              let pause = self.spendDashboardCodexCostCatchUpCompletion.pause,
              pause.context.accounts == accounts,
              self.spendDashboardCodexCostCatchUpConfigurationIsCurrent(pause.context)
        else { return }
        let completionToken = UUID()
        self.spendDashboardCodexCostCatchUpCompletion.token = completionToken
        self.spendDashboardCodexCostCatchUpCompletion.task = Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.spendDashboardCodexCostCatchUpCompletion.token == completionToken {
                    self.spendDashboardCodexCostCatchUpCompletion.task = nil
                    self.spendDashboardCodexCostCatchUpCompletion.token = nil
                }
            }
            // This is a read-only check. It cannot resume a parser or replace a user stop.
            let statuses = await self.loadSpendDashboardCodexCostCatchUpStatuses(
                accounts, historyDays: pause.context.historyDays)
            guard !Task.isCancelled,
                  self.spendDashboardCodexCostCatchUpCompletion.token == completionToken,
                  !self.spendDashboardCodexCostCatchUpStopRequested,
                  self.spendDashboardCodexCostCatchUpTask == nil,
                  self.spendDashboardCodexCostCatchUpActivity?.pauseReason == .noProgress,
                  self.spendDashboardCodexCostCatchUpCompletion.pause?.context.token == pause.context.token,
                  self.spendDashboardCodexCostCatchUpConfigurationIsCurrent(pause.context),
                  accounts.allSatisfy({ account in
                      guard let status = statuses[account.cacheIdentity], let lastScanAt = status.lastScanAt else {
                          return false
                      }
                      return !status.pending && status.completionIsConfirmed
                          &&
                          (!pause.pendingCacheIdentities.contains(account.cacheIdentity) || lastScanAt > pause
                              .pausedAt)
                  })
            else { return }
            self.publishSpendDashboardCodexCostCatchUpActivity(
                statuses: statuses, context: pause.context, phase: .complete, confirmedCompletion: true)
            self.spendDashboardCodexCostCatchUpCompletion.task = nil
            self.spendDashboardCodexCostCatchUpCompletion.token = nil
            self.spendDashboardCodexCostCatchUpCompletion.pause = nil
            self.spendDashboardCodexCostCatchUpRevision &+= 1
        }
    }

    private func loadSpendDashboardCodexCostCatchUpStatuses(
        _ accounts: [CodexSpendScanRequest],
        historyDays: Int? = nil) async -> [String: CostUsageFetcher.CodexScanCatchUpStatus]
    {
        var statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus] = [:]
        for account in accounts {
            if let override = self._test_spendDashboardCodexCostCatchUpStatusOverride {
                statuses[account.cacheIdentity] = await override(account)
            } else {
                statuses[account.cacheIdentity] = await CostUsageFetcher(
                    cacheRoot: SpendDashboardSource.codexCacheRoot(for: account),
                    calendar: self.settings.costUsageBucketCalendar)
                    .codexScanCatchUpStatus(
                        codexHomePath: account.homePath,
                        calendar: self.settings.costUsageBucketCalendar,
                        historyDays: historyDays)
            }
        }
        return statuses
    }

    private func advanceSpendDashboardCodexCostCatchUp(
        account: CodexSpendScanRequest,
        now: Date,
        historyDays: Int,
        previousActiveDuration: TimeInterval?) async throws
        -> CostUsageScanExecutor.TimedResult<CostUsageFetcher.CodexScanCatchUpStatus>
    {
        let durationBudget = self.spendDashboardCodexCostCatchUpMode
            .scanDurationPerRefresh(after: previousActiveDuration)
        self._test_codexCostCatchUpBudgetObserver?(durationBudget)
        let token = self.spendDashboardCodexCostCatchUpToken
        self.spendDashboardCodexCostCatchUpPassIsRunning = true
        defer {
            if self.spendDashboardCodexCostCatchUpToken == token {
                self.spendDashboardCodexCostCatchUpPassIsRunning = false
            }
        }
        if let override = self._test_spendDashboardCodexCostCatchUpAdvanceOverride {
            return try await .init(
                value: override(account, now, historyDays),
                activeDuration: self._test_spendDashboardCodexCostCatchUpActiveDuration)
        }
        return try await CostUsageFetcher(
            cacheRoot: SpendDashboardSource.codexCacheRoot(for: account),
            calendar: self.settings.costUsageBucketCalendar)
            .advanceCodexScanCatchUp(
                now: now,
                codexHomePath: account.homePath,
                historyDays: historyDays,
                scanDurationPerRefresh: durationBudget,
                calendar: self.settings.costUsageBucketCalendar)
    }

    private func publishSpendDashboardCodexCostCatchUpActivity(
        statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus],
        context: SpendDashboardCodexCostCatchUpContext,
        phase: CodexCostCatchUpActivity.Phase,
        pauseReason: CodexCostCatchUpPauseReason? = nil,
        confirmedCompletion: Bool = false)
    {
        guard self.spendDashboardCodexCostCatchUpToken == context.token
            || (confirmedCompletion && phase == .complete
                && self.spendDashboardCodexCostCatchUpTask == nil
                && self.spendDashboardCodexCostCatchUpCompletion.pause?.context.token == context.token)
        else { return }
        if phase == .paused, pauseReason == .noProgress {
            self.spendDashboardCodexCostCatchUpCompletion.pause = .init(
                context: context,
                pausedAt: Date(),
                pendingCacheIdentities: Set(statuses.compactMap { $0.value.pending ? $0.key : nil }))
        }
        let values = context.accounts.compactMap { statuses[$0.cacheIdentity] }
        let hasIndeterminatePendingStatus = values.contains {
            $0.pending && $0.totalBytes == 0 && $0.totalFiles == 0
        }
        self.spendDashboardCodexCostCatchUpActivity = CodexCostCatchUpActivity(
            phase: phase,
            mode: self.spendDashboardCodexCostCatchUpMode,
            processedBytes: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.processedBytes },
            totalBytes: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.totalBytes },
            completedFiles: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.completedFiles },
            totalFiles: hasIndeterminatePendingStatus ? 0 : values.reduce(0) { $0 + $1.totalFiles },
            pauseReason: pauseReason,
            staleSnapshotUpdatedAt: values.compactMap(\.staleSnapshotUpdatedAt).min())
    }

    private func publishSpendDashboardCodexCostCatchUpRevisionIfNeeded(_ didChangeCache: Bool) {
        guard didChangeCache else { return }
        self.spendDashboardCodexCostCatchUpRevision &+= 1
    }

    private static func uniqueSpendDashboardCodexAccounts(
        _ accounts: [CodexSpendScanRequest]) -> [CodexSpendScanRequest]
    {
        var seen: Set<String> = []
        return accounts.filter { seen.insert($0.cacheIdentity).inserted }
    }

    private static func spendDashboardCodexCatchUpIsPending(
        _ statuses: [String: CostUsageFetcher.CodexScanCatchUpStatus]) -> Bool
    {
        statuses.values.contains(where: \.pending)
    }
}
