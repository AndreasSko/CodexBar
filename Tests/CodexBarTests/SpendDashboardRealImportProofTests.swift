import Foundation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in production import proof. Receipts contain private data and must stay outside the checkout.
/// Run cold and warm phases in separate processes with an isolated CFFIXED_USER_HOME.
@MainActor
final class SpendDashboardRealImportProofTests: XCTestCase {
    func test_copiedLogTraversesProductionImportAndCache() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["CODEXBAR_MODEL_IMPORT_PROOF_ROOT"],
              let phase = environment["CODEXBAR_MODEL_IMPORT_PROOF_PHASE"],
              let nowValue = environment["CODEXBAR_MODEL_IMPORT_PROOF_NOW"].flatMap(Double.init)
        else {
            throw XCTSkip("Set the isolated model-import proof controls to replay a copied local log.")
        }
        XCTAssertTrue(["cold", "warm"].contains(phase))
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let cacheRoot = OpenCodexUsageLog.cacheRoot().standardizedFileURL
        let pricingURL = ModelsDevCache.cacheFileURL().standardizedFileURL
        let prefix = root.path + "/"
        // Fail before the production reader can touch a host cache.
        guard cacheRoot.path.hasPrefix(prefix), pricingURL.path.hasPrefix(prefix) else {
            XCTFail("Foundation cache directories must belong to the isolated proof root.")
            return
        }
        let manager = FileManager.default
        let cacheURL = cacheRoot.appendingPathComponent(OpenCodexUsageStore.databaseFilename)
        let logRoot = root.appendingPathComponent("inputs/opencodex", isDirectory: true)
        XCTAssertTrue(manager.fileExists(atPath: logRoot.appendingPathComponent("usage.jsonl").path))
        if phase == "cold" {
            XCTAssertFalse(manager.fileExists(atPath: cacheURL.path))
            try manager.createDirectory(at: pricingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent("inputs/models-dev-v1.json")).write(to: pricingURL)
        } else {
            XCTAssertTrue(manager.fileExists(atPath: cacheURL.path))
        }

        let now = Date(timeIntervalSince1970: nowValue)
        let configuration = SpendDashboardConfiguration(
            costUsageEnabled: true,
            providerIDs: [],
            codexAccountIdentities: [],
            bucketTimeZoneIdentifier: "UTC",
            openCodexUsageLogsEnabled: true,
            hideNativeCodexCostWhenOpenCodexPresent: true)
        let request = SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: now,
            force: false)
        let recorder = OpenCodexUsageParser.LogReadRecorder()
        let imported = OpenCodexUsageStore.withLogReadRecorderForTesting(recorder) {
            SpendDashboardSource.mergingOpenCodexInputsWithObservation(
                [], request: request, environment: ["OPENCODEX_HOME": logRoot.path])
        }
        XCTAssertEqual(imported.observation, .available)
        let input = try XCTUnwrap(imported.inputs.first { $0.provider == .codex })
        XCTAssertEqual(input.sourceKind, .openCodex)
        let model = SpendDashboardModel.build(
            inputs: imported.inputs,
            requestedDays: 7,
            now: now,
            calendar: configuration.bucketCalendar)
        let group = try XCTUnwrap(model.groups.first)
        let source = try XCTUnwrap(group.providers.first { $0.provider == .codex })
        let calendar = configuration.bucketCalendar
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let firstKey = formatter.string(from: firstDay)
        let lastKey = formatter.string(from: now)
        let window = input.snapshot.daily.filter { $0.date >= firstKey && $0.date <= lastKey }
        let expectedNames = Set(window.flatMap { ($0.modelBreakdowns ?? []).map(\.modelName) })
        XCTAssertFalse(expectedNames.isEmpty)
        let isBaseline = environment["CODEXBAR_MODEL_IMPORT_PROOF_BASELINE"] == "1"
        if isBaseline {
            XCTAssertTrue(group.models.isEmpty)
            XCTAssertEqual(group.incompleteRequestCount, 0)
        } else {
            XCTAssertEqual(Set(group.models.map(\.modelName)), expectedNames)
            XCTAssertGreaterThan(group.incompleteRequestCount, 0)
        }
        XCTAssertEqual(group.totalTokens, source.totalTokens)
        XCTAssertEqual(group.totalCost, source.totalCost)
        XCTAssertTrue(ShareStatsBuilder.make(model: model)?.topModels.isEmpty == true)
        XCTAssertTrue(manager.fileExists(atPath: cacheURL.path))
        let reads = recorder.snapshot()
        if phase == "cold" {
            XCTAssertGreaterThan(reads.bytesRead, 0)
            XCTAssertGreaterThan(reads.completeLines, 0)
        } else {
            XCTAssertEqual(reads.bytesRead, 0)
            XCTAssertEqual(reads.completeLines, 0)
        }

        let receipt: [String: Any] = try [
            "knownTokens": group.totalTokens.map { $0 as Any } ?? NSNull(),
            "knownCost": group.totalCost.map { $0 as Any } ?? NSNull(),
            "modelNames": group.models.map(\.modelName).sorted(),
            "expectedModelNames": expectedNames.sorted(),
            "incompleteRequests": group.incompleteRequestCount,
            "daily": JSONSerialization.jsonObject(with: JSONEncoder().encode(input.snapshot.daily)),
        ]
        let receipts = root.appendingPathComponent("private-receipts", isDirectory: true)
        try manager.createDirectory(at: receipts, withIntermediateDirectories: true)
        if phase == "warm" {
            let cold = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: receipts.appendingPathComponent("cold.json"))) as? NSDictionary)
            XCTAssertEqual(receipt as NSDictionary, cold)
        }
        let receiptURL = receipts.appendingPathComponent("\(phase).json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        // These observable diagnostics contain no model identifiers, timestamps, quantities, or amounts.
        print("IMPORT_PROOF phase=\(phase) productionSource=available sourceKind=openCodex")
        print("IMPORT_PROOF storeCachePresent=true reader=\(phase == "cold" ? "full-log" : "cached-zero-log-bytes")")
        let modelState = isBaseline ? "hidden" : "retained"
        let exclusionState = isBaseline ? "absent" : "propagated"
        print("IMPORT_PROOF namedModels=\(modelState) exclusions=\(exclusionState)")
        print("IMPORT_PROOF knownSubtotals=preserved-on-dashboard")
        if phase == "warm" { print("IMPORT_PROOF freshProcessReload=identical-daily-and-dashboard-accounting") }
    }
}
