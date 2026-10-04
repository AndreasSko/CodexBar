import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CodexProjectlessWorkspaceTests {
    @Test
    func `explicit chats use saved titles without changing ledger values or CLI folders`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat", "attachment"])
            let projects = [Self.project("/chat"), Self.project("/attachment"), Self.project("/cli")]
            let sessions = [
                Self.session("chat", path: "/chat", title: "Repair the local service"),
                Self.session("attachment", path: "/attachment", title: "# Files mentioned by the user:\nattachment"),
                Self.session("cli", path: "/cli", title: "A real code project"),
            ]
            let result = Self.overlay(home, projects: projects, sessions: sessions)
            var expected = projects
            expected[0].isProjectless = true
            expected[0].name = "Repair the local service"
            expected[1].isProjectless = true
            expected[1].name = "Independent chat"
            #expect(result.projects == expected)
            var expectedSessions = sessions
            expectedSessions[0].projectName = nil
            expectedSessions[1].projectName = nil
            #expect(result.sessions == expectedSessions)
            #expect(result.projects.map(\.path) == projects.map(\.path))
            #expect(result.projects.map(\.daily) == projects.map(\.daily))
        }
    }

    @Test
    func `mixed directory ownership and unproven worktree sources keep project classification`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat", "second"])
            let shared = Self.project("/shared", sessionIDs: ["chat", "cli"])
            let worktree = Self.project("/canonical", sources: ["/chat", "/missing"])
            let sessions = [
                Self.session("chat", path: "/shared"), Self.session("cli", path: "/shared"),
                Self.session("second", path: "/chat"),
            ]
            #expect(Self.overlay(home, projects: [shared, worktree], sessions: sessions).projects == [shared, worktree])
            let unknown = Self.project("/unknown", sources: [])
            #expect(Self.overlay(home, projects: [unknown], sessions: []).projects == [unknown])
        }
    }

    @Test
    func `multiple independent sessions in one directory keep a neutral label and their accounting`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["first", "second"])
            let project = Self.project("/shared", sessionIDs: ["first", "second"])
            let result = Self.overlay(home, projects: [project], sessions: [
                Self.session("first", path: "/shared", title: "First topic"),
                Self.session("second", path: "/shared", title: "Second topic"),
            ])
            var expected = project
            expected.name = "Independent chats"
            expected.isProjectless = true
            #expect(result.projects == [expected])
        }
    }

    @Test
    func `missing malformed oversized and unrelated home metadata never infer ownership from a folder name`() throws {
        try Self.withHome { home in
            let path = "/files-mentioned-by-the-user-codex"
            let projects = [Self.project(path)]
            let sessions = [Self.session("chat", path: path)]
            let state = home.appendingPathComponent(".codex-global-state.json")
            #expect(Self.overlay(home, projects: projects, sessions: sessions).projects == projects)
            #expect(!FileManager.default.fileExists(atPath: state.path))
            for invalid in [Data("{".utf8), Data(repeating: 32, count: 8 * 1024 * 1024 + 1)] {
                try invalid.write(to: state)
                #expect(Self.overlay(home, projects: projects, sessions: sessions).projects == projects)
                #expect(try Data(contentsOf: state) == invalid)
            }
            try Self.writeState(home, ids: ["unrelated"])
            #expect(Self.overlay(home, projects: projects, sessions: sessions).projects == projects)
        }
    }

    @Test
    func `current and legacy project assignments veto stale independent chat markers`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["legacy", "current", "chat"], assignments: [
                "legacy": ["projectKind": "local", "projectId": "saved-project"],
            ])
            let projects = [Self.project("/legacy"), Self.project("/current"), Self.project("/chat")]
            let sessions = [
                Self.session("legacy", path: "/legacy"), Self.session("current", path: "/current"),
                Self.session("chat", path: "/chat"),
            ]
            let result = CostUsageFetcher.codexBreakdownsWithProjectlessMetadata(
                projects: projects,
                sessions: sessions,
                codexHomeDirectory: home,
                assignedSessionIDs: ["current"])
            #expect(result.projects.map(\.isProjectless) == [false, false, true])
            #expect(result.sessions.map(\.projectName) == ["legacy", "current", nil])
        }
    }

    @Test
    func `merged project copies preserve classification conservatively without changing totals`() throws {
        var chat = Self.project("/shared")
        chat.isProjectless = true
        chat.name = "Chat title"
        let named = Self.project("/shared")
        let classified = try #require(CostUsageFetcher.mergedProjectBreakdowns([chat, chat]).first)
        let mixed = try #require(CostUsageFetcher.mergedProjectBreakdowns([chat, named]).first)
        #expect(classified.isProjectless)
        #expect(!mixed.isProjectless)
        #expect(mixed.name == named.name)
        #expect(CostUsageFetcher.mergedProjectBreakdowns([named, chat]).first?.name == named.name)
        #expect(classified.totalTokens == mixed.totalTokens)
        #expect(classified.totalCostUSD == mixed.totalCostUSD)
        #expect(classified.daily == mixed.daily)
        #expect(classified.path == mixed.path)
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    @Test
    func `missing corrupt locked and unsupported databases preserve project presentation`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat"])
            let database = home.appendingPathComponent("state_5.sqlite")
            let reader = CodexThreadMetadataReader(databaseURL: database)
            let project = Self.project("/chat")
            let session = Self.session("chat", path: "/chat")
            func remainsProject() -> Bool {
                let result = CostUsageFetcher.codexBreakdownsWithMetadata(
                    [session],
                    projects: [project],
                    sessionsRoot: home.appendingPathComponent("sessions"),
                    environment: [:])
                return result.projects[0].isProjectless == false && result.sessions[0].projectName == "chat"
            }
            #expect(reader.assignedProjectSessionIDs(for: ["chat"]) == nil)
            #expect(remainsProject())
            #expect(!FileManager.default.fileExists(atPath: database.path))
            try Data("invalid database".utf8).write(to: database)
            #expect(reader.assignedProjectSessionIDs(for: ["chat"]) == nil)
            #expect(remainsProject())
            try FileManager.default.removeItem(at: database)
            try Self.execute(database, "CREATE TABLE unrelated (id TEXT)")
            #expect(reader.assignedProjectSessionIDs(for: ["chat"]) == nil)
            #expect(remainsProject())
            try Self.execute(database, "CREATE TABLE threads (id TEXT, title TEXT, agent_path TEXT, project_id TEXT)")
            var handle: OpaquePointer?
            #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
            let locked = try #require(handle)
            defer { sqlite3_close(locked) }
            #expect(sqlite3_exec(locked, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            defer { sqlite3_exec(locked, "ROLLBACK", nil, nil, nil) }
            #expect(reader.assignedProjectSessionIDs(for: ["chat"]) == nil)
            #expect(remainsProject())
        }
    }

    @Test
    func `supported legacy thread tables still classify explicit desktop chats`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat"])
            let database = home.appendingPathComponent("state_5.sqlite")
            try Self.execute(database, "CREATE TABLE threads (id TEXT, title TEXT, agent_path TEXT)")
            #expect(CodexThreadMetadataReader(databaseURL: database).assignedProjectSessionIDs(for: ["chat"]) == [])
            let result = CostUsageFetcher.codexBreakdownsWithMetadata(
                [Self.session("chat", path: "/chat")],
                projects: [Self.project("/chat")],
                sessionsRoot: home.appendingPathComponent("sessions"),
                environment: [:])
            #expect(result.projects[0].isProjectless)
        }
    }

    @Test
    func `directory membership includes older contributing files when a thread moves directories`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat"])
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
            let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
            var cache = CostUsageCache()
            for (filename, id, path, modified) in [
                ("chat", "chat", "/shared", Int64(1)),
                ("older", "cli", "/shared", Int64(2)),
                ("latest", "cli", "/elsewhere", Int64(3)),
            ] {
                var usage = CostUsageFileUsage(
                    mtimeUnixMs: modified,
                    size: 1,
                    days: ["2026-01-01": ["gpt-5": [10, 2, 3]]])
                usage.sessionId = id
                usage.projectPath = path
                usage.canonicalProjectPath = path
                cache.files["/synthetic/sessions/\(filename).jsonl"] = usage
            }
            let projects = CostUsageStoreReadView(cache: cache, purpose: .report).projects(
                range: range,
                cacheRoot: home)
            let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                cache: cache, range: range, modelsDevCatalog: ModelsDevCatalog(providers: [:]))
            #expect(sessions.count == 2)
            #expect(sessions.first { $0.sessionID == "cli" }?.workingDirectory == "/elsewhere")
            let shared = try #require(projects.first { $0.path == "/shared" })
            #expect(shared.sources.first?.sessionIDs == ["chat", "cli"])
            #expect(shared.totalTokens == 26)
            let result = Self.overlay(home, projects: projects, sessions: sessions)
            #expect(result.projects == projects)
        }
    }

    @Test
    func `fresh and cached metadata overlays pick up chat renames and current database assignments`() throws {
        try Self.withHome { home in
            try Self.writeState(home, ids: ["chat", "assigned"])
            let database = home.appendingPathComponent("state_5.sqlite")
            try Self.execute(database, """
            CREATE TABLE threads (id TEXT, title TEXT, agent_path TEXT, project_id TEXT);
            INSERT INTO threads VALUES ('chat', 'Raw old title', NULL, NULL),
                ('assigned', 'Assigned title', NULL, 'project');
            """)
            let projects = [Self.project("/chat"), Self.project("/assigned")]
            let sessions = [Self.session("chat", path: "/chat"), Self.session("assigned", path: "/assigned")]
            func overlay() -> (projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown]) {
                CostUsageFetcher.codexBreakdownsWithMetadata(
                    sessions,
                    projects: projects,
                    sessionsRoot: home.appendingPathComponent("sessions"),
                    environment: [:])
            }
            let index = home.appendingPathComponent("session_index.jsonl")
            try Data("{\"id\":\"chat\",\"thread_name\":\"Saved title\",\"updated_at\":\"2026-01-01T00:00:00Z\"}\n".utf8)
                .write(to: index)
            let first = overlay()
            #expect(first.projects.map(\.isProjectless) == [true, false])
            #expect(first.projects[0].name == "Saved title")
            try Data("{\"id\":\"chat\",\"thread_name\":\"Renamed title\",\"updated_at\":\"2026-01-02T00:00:00Z\"}\n"
                .utf8)
                .write(to: index)
            let renamed = overlay()
            #expect(renamed.projects[0].name == "Renamed title")
            #expect(renamed.projects[0].path == first.projects[0].path)
            #expect(renamed.projects[0].daily == first.projects[0].daily)
            #expect(renamed.projects[0].sources == first.projects[0].sources)
            #expect(CodexThreadMetadataReader(databaseURL: database).assignedProjectSessionIDs(
                for: ["chat", "assigned", "missing"]) == ["assigned"])
        }
    }

    private static func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }
    #endif

    private static func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private static func writeState(
        _ home: URL, ids: [String], assignments: [String: [String: String]] = [:]) throws
    {
        let state: [String: Any] = ["projectless-thread-ids": ids, "thread-project-assignments": assignments]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: home.appendingPathComponent(".codex-global-state.json"))
    }

    private static func overlay(
        _ home: URL, projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])
        -> (projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])
    {
        CostUsageFetcher.codexBreakdownsWithProjectlessMetadata(
            projects: projects, sessions: sessions, codexHomeDirectory: home, assignedSessionIDs: [])
    }

    private static func session(
        _ id: String, path: String, title: String? = "Chat title") -> CostUsageSessionBreakdown
    {
        var session = CostUsageSessionBreakdown(
            sessionID: id,
            lastActivity: Date(timeIntervalSince1970: 0),
            inputTokens: 10,
            cachedInputTokens: 2,
            outputTokens: 3,
            totalTokens: 13,
            requestCount: 1,
            costUSD: 1,
            modelBreakdowns: [],
            projectPath: path,
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            title: title)
        session.workingDirectory = path
        return session
    }

    private static func project(
        _ path: String, sources: [String]? = nil, sessionIDs: Set<String>? = nil) -> CostUsageProjectBreakdown
    {
        let daily = [CostUsageDailyReport.Entry(
            date: "2026-01-01",
            inputTokens: 10,
            outputTokens: 3,
            totalTokens: 13,
            costUSD: 1,
            modelsUsed: nil,
            modelBreakdowns: nil)]
        return CostUsageProjectBreakdown(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            totalTokens: 13,
            totalCostUSD: 1,
            daily: daily,
            modelBreakdowns: [],
            sources: (sources ?? [path]).map {
                CostUsageProjectSourceBreakdown(
                    name: URL(fileURLWithPath: $0).lastPathComponent,
                    path: $0,
                    totalTokens: 13,
                    totalCostUSD: 1,
                    daily: daily,
                    modelBreakdowns: [],
                    sessionIDs: sessionIDs ?? [URL(fileURLWithPath: $0).lastPathComponent])
            })
    }
}
