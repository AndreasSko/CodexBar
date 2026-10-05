import Foundation

extension CostUsageScanner {
    /// Shares report construction for the projections produced by one refresh.
    ///
    /// The cache key includes the projection scope because unknown pricing evidence and
    /// fork reconciliation are scope-dependent. The detailed report history remains
    /// refresh-local and is never persisted by this helper.
    final class CodexReportPreparation: @unchecked Sendable {
        enum Key: Hashable {
            case full
            case file(String)
            case project(String)
        }

        private let range: CostUsageDayRange
        private let modelsDevCatalog: ModelsDevCatalog
        private let modelsDevCacheRoot: URL?
        private let priorityTurns: [String: CodexPriorityTurnMetadata]
        private let pricingResolver: CostUsagePricing.CodexResolver
        private var reports: [Key: CostUsageDailyReport] = [:]

        #if DEBUG
        private(set) var reportBuildCount = 0
        #endif

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            modelsDevCatalog: ModelsDevCatalog? = nil,
            modelsDevCacheRoot: URL? = nil,
            priorityTurns: [String: CodexPriorityTurnMetadata]? = nil,
            modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
                CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
            })
        {
            self.range = range
            self.modelsDevCacheRoot = modelsDevCacheRoot
            self.priorityTurns = priorityTurns ?? cache.codexResolvedPriorityTurns ?? [:]
            self.modelsDevCatalog = modelsDevCatalog
                ?? modelsDevCatalogLoader(modelsDevCacheRoot)
                ?? ModelsDevCatalog(providers: [:])
            self.pricingResolver = CostUsagePricing.CodexResolver(catalog: self.modelsDevCatalog)
        }

        func report(key: Key, cache: CostUsageCache) -> CostUsageDailyReport {
            if let report = self.reports[key] {
                return report
            }
            let report = CostUsageScanner.buildCodexReportFromCache(
                cache: cache,
                range: self.range,
                modelsDevCatalog: self.modelsDevCatalog,
                modelsDevCacheRoot: self.modelsDevCacheRoot,
                priorityTurns: self.priorityTurns,
                pricingResolver: self.pricingResolver)
            self.reports[key] = report
            #if DEBUG
            self.reportBuildCount += 1
            #endif
            return report
        }
    }

    static func codexCache(_ cache: CostUsageCache, scopedTo roots: [URL]) -> CostUsageCache {
        var scoped = cache
        scoped.files = cache.files.filter { filePath, _ in
            Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: roots)
        }
        scoped.days = [:]
        for usage in scoped.files.values {
            Self.applyFileDays(cache: &scoped, fileDays: usage.days, sign: 1)
        }
        return scoped
    }

    static func buildCodexSessionBreakdownsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        sessionRoots: [URL]? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata]? = nil,
        reportPreparation: CodexReportPreparation? = nil,
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> [CostUsageSessionBreakdown]
    {
        let preparation = reportPreparation ?? CodexReportPreparation(
            cache: cache,
            range: range,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            priorityTurns: priorityTurns,
            modelsDevCatalogLoader: modelsDevCatalogLoader)
        let projectPathResolver = CodexCanonicalProjectPathResolver()
        var latestFileBySessionID: [String: (path: String, usage: CostUsageFileUsage)] = [:]

        for (filePath, usage) in cache.files {
            if let sessionRoots,
               !Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: sessionRoots)
            {
                continue
            }
            guard usage.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey,
                calendar: range.calendar)
            else {
                continue
            }
            let sessionID = usage.sessionId ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            guard !sessionID.isEmpty else { continue }
            if let existing = latestFileBySessionID[sessionID], existing.usage.mtimeUnixMs >= usage.mtimeUnixMs {
                continue
            }
            latestFileBySessionID[sessionID] = (filePath, usage)
        }

        return latestFileBySessionID.compactMap { sessionID, file in
            var fileCache = CostUsageCache()
            fileCache.files[file.path] = file.usage
            fileCache.days = file.usage.days
            let report = preparation.report(key: .file(file.path), cache: fileCache)
            guard !report.data.isEmpty else { return nil }

            let summary = report.summary
            let requestCounts = report.data.compactMap(\.requestCount)
            let resolvedProjectPath = file.usage.canonicalProjectPath
                ?? projectPathResolver.canonicalProjectPath(for: file.usage.projectPath)
            let projectPath = resolvedProjectPath?.isEmpty == false ? resolvedProjectPath : nil
            var session = CostUsageSessionBreakdown(
                sessionID: sessionID,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(file.usage.mtimeUnixMs) / 1000),
                inputTokens: summary?.totalInputTokens,
                cachedInputTokens: summary?.cacheReadTokens,
                outputTokens: summary?.totalOutputTokens,
                totalTokens: summary?.totalTokens,
                requestCount: requestCounts.isEmpty ? nil : requestCounts.reduce(0, +),
                costUSD: summary?.totalCostUSD,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: report.data) ?? [],
                projectPath: projectPath,
                projectName: projectPath.map { Self.codexProjectName(path: $0) },
                title: file.usage.codexSession?.title)
            session.workingDirectory = file.usage.projectPath
            return session
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }
    }

    static func buildCodexProjectBreakdownsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata]? = nil,
        reportPreparation: CodexReportPreparation? = nil,
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> [CostUsageProjectBreakdown]
    {
        let preparation = reportPreparation ?? CodexReportPreparation(
            cache: cache,
            range: range,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot,
            priorityTurns: priorityTurns,
            modelsDevCatalogLoader: modelsDevCatalogLoader)
        let projectPathResolver = CodexCanonicalProjectPathResolver()
        var accumulatorsByProjectPath: [String: CodexProjectBreakdownAccumulator] = [:]
        for (filePath, usage) in cache.files {
            guard usage.touchesCodexScanWindow(
                sinceKey: range.scanSinceKey,
                untilKey: range.scanUntilKey,
                calendar: range.calendar)
            else {
                continue
            }
            var fileCache = CostUsageCache()
            fileCache.files[filePath] = usage
            fileCache.days = usage.days
            let report = preparation.report(key: .file(filePath), cache: fileCache)
            guard !report.data.isEmpty else { continue }
            let projectKey = usage.canonicalProjectPath
                ?? projectPathResolver.canonicalProjectPath(for: usage.projectPath)
                ?? ""
            let sourceKey = usage.projectPath ?? ""
            var accumulator = accumulatorsByProjectPath[projectKey] ?? CodexProjectBreakdownAccumulator()
            accumulator.files[filePath] = usage
            accumulator.reportsBySourcePath[sourceKey, default: []].append(report)
            accumulatorsByProjectPath[projectKey] = accumulator
        }

        return accumulatorsByProjectPath.map { projectPath, accumulator in
            var projectCache = CostUsageCache()
            projectCache.files = accumulator.files
            for usage in accumulator.files.values {
                Self.applyFileDays(cache: &projectCache, fileDays: usage.days, sign: 1)
            }
            let report = preparation.report(key: .project(projectPath), cache: projectCache)
            let resolvedPath = projectPath.isEmpty ? nil : projectPath
            return CostUsageProjectBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: report.summary?.totalTokens,
                totalCostUSD: report.summary?.totalCostUSD,
                daily: report.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: report.data),
                sources: Self.codexProjectSourceBreakdowns(from: accumulator.reportsBySourcePath))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func codexProjectName(path: String?) -> String {
        guard let path, !path.isEmpty else { return CostUsageProjectBreakdown.unknownProjectName }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private struct CodexProjectBreakdownAccumulator {
        var files: [String: CostUsageFileUsage] = [:]
        var reportsBySourcePath: [String: [CostUsageDailyReport]] = [:]
    }

    private static func codexProjectSourceBreakdowns(
        from reportsBySourcePath: [String: [CostUsageDailyReport]]) -> [CostUsageProjectSourceBreakdown]
    {
        reportsBySourcePath.map { sourcePath, reports in
            let merged = CostUsageDailyReport.merged(reports)
            let resolvedPath = sourcePath.isEmpty ? nil : sourcePath
            return CostUsageProjectSourceBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: merged.data))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func codexProjectModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        let summaries = CostUsageDailyReport.modelCostSummaries(from: entries)
        return summaries.isEmpty ? nil : Self.sortedModelBreakdowns(summaries)
    }
}
