#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation

extension CodexThreadMetadataReader {
    /// A current assignment vetoes a stale legacy projectless marker during desktop migration.
    func assignedProjectSessionIDs(for sessionIDs: Set<String>) -> Set<String>? {
        guard !sessionIDs.isEmpty else { return [] }
        guard sessionIDs.count <= 4096 else { return nil }
        #if canImport(SQLite3) || canImport(CSQLite3)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        sqlite3_progress_handler(database, 100_000, { _ in 1 }, nil)
        // Supported legacy tables predate project_id; an unreadable schema is not a legacy schema.
        var schema: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK,
              let schema else { return nil }
        defer { sqlite3_finalize(schema) }
        var columns: Set<String> = []
        while true {
            let status = sqlite3_step(schema)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { return nil }
            if let name = Self.string(schema, column: 1) { columns.insert(name) }
        }
        guard columns.contains("id") else { return nil }
        guard columns.contains("project_id") else { return [] }
        var statement: OpaquePointer?
        let query = "SELECT project_id FROM threads WHERE id = ?1 LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: Set<String> = []
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for sessionID in sessionIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else { return nil }
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { return nil }
            if status == SQLITE_ROW, Self.string(statement, column: 0) != nil { result.insert(sessionID) }
        }
        return result
        #else
        return nil
        #endif
    }
}
