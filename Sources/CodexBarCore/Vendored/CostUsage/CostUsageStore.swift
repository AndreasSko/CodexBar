import Dispatch
import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

package enum CostUsageStoreExecutorTestControl {
    package static let suppressCurrentContextArgument = "--cost-store-suppress-current-context-for-testing"
    package static let suppressCurrentContextAnswer = CommandLine.arguments.contains(
        Self.suppressCurrentContextArgument)
}

/// Single-writer persistence for Codex cost scanning. The actor owns the only writable
/// connection; Phase 2 can keep its existing scan-queue serialization while independent
/// app and CLI readers use WAL snapshots through separate read-only connections.
actor CostUsageStore {
    private final class StoreSerialExecutor: SerialExecutor, @unchecked Sendable {
        private let queue: DispatchQueue
        private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
        private static let registryLock = NSLock()
        private nonisolated(unsafe) static var registry: [String: WeakExecutor] = [:]

        private struct WeakExecutor {
            weak var value: StoreSerialExecutor?
        }

        static func shared(for databaseURL: URL) -> StoreSerialExecutor {
            var location = databaseURL
            var visited: Set<String> = []
            while true {
                let directory = location.deletingLastPathComponent()
                // Resolve existing parents and follow file links even when their target is missing.
                // Open retries directory creation and reports errors through the normal store path.
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                location = directory.resolvingSymlinksInPath().standardizedFileURL
                    .appendingPathComponent(location.lastPathComponent)
                guard visited.insert(location.path).inserted,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: location.path)
                else { break }
                location = URL(fileURLWithPath: target, relativeTo: location.deletingLastPathComponent())
            }
            let caseSensitive = try? location.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            let key = caseSensitive == false
                ? location.path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                : location.path
            return Self.registryLock.withLock {
                if let executor = Self.registry[key]?.value { return executor }
                Self.registry = Self.registry.filter { $0.value.value != nil }
                let suffix = String(UInt(bitPattern: key.hashValue), radix: 16).suffix(8)
                let executor = StoreSerialExecutor(label: "com.steipete.codexbar.cost-usage-store.\(suffix)")
                Self.registry[key] = WeakExecutor(value: executor)
                return executor
            }
        }

        init(label: String) {
            self.queue = DispatchQueue(label: label, qos: .utility)
            self.queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let unownedJob = UnownedJob(job)
            self.queue.async { [self] in
                unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
            }
        }

        func checkIsolated() {
            dispatchPrecondition(condition: .onQueue(self.queue))
        }

        /// macOS 26+ runtimes ask this before `checkIsolated()`; the queue-specific token
        /// sees through `DispatchQueue.sync` accurately.
        @available(macOS 26.0, *)
        func isIsolatingCurrentContext() -> Bool? {
            guard !CostUsageStoreExecutorTestControl.suppressCurrentContextAnswer else { return nil }
            return DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self)
        }

        func sync<T>(_ operation: () throws -> T) rethrows -> T {
            #if DEBUG
            let hooks = CostUsageStoreTestHooks.current
            return try self.queue.sync {
                try CostUsageStoreTestHooks.$current.withValue(hooks, operation: operation)
            }
            #else
            return try self.queue.sync(execute: operation)
            #endif
        }
    }

    private final class SQLiteConnection: @unchecked Sendable {
        private(set) var handle: OpaquePointer?
        let identity: DatabaseIdentity?
        let generation = UUID()

        init(handle: OpaquePointer, identity: DatabaseIdentity?) {
            self.handle = handle
            self.identity = identity
        }

        func close() {
            guard let handle else { return }
            sqlite3_close_v2(handle)
            self.handle = nil
        }

        deinit {
            self.close()
        }
    }

    static let log = CodexBarLog.logger(LogCategories.tokenCost)
    static let databaseFilename = "cost-usage.sqlite"
    static let baseSchemaVersion = 3
    static let schemaVersion = CostUsageStore.combinedSchemaVersion(
        base: CostUsageStore.baseSchemaVersion,
        parserHash: CodexParserHash.value)
    static let cacheGeneration = "sqlite:\(CostUsageStore.schemaVersion)"
    static let compatiblePredecessorParserHashes: Set<String> = [
