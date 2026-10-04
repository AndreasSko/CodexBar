import Foundation

extension CostUsageFetcher {
    static func codexBreakdownsWithProjectlessMetadata(
        projects: [CostUsageProjectBreakdown],
        sessions: [CostUsageSessionBreakdown],
        codexHomeDirectory: URL,
        assignedSessionIDs: Set<String>,
        metadata: CodexProjectlessWorkspaceMetadata? = nil)
        -> (projects: [CostUsageProjectBreakdown], sessions: [CostUsageSessionBreakdown])
    {
        guard let metadata = metadata
            ?? CodexProjectlessWorkspaceMetadata.load(codexHomeDirectory: codexHomeDirectory)
        else {
            return (projects, sessions)
        }
        var result = (projects: projects, sessions: sessions)
        for index in projects.indices {
            let project = projects[index]
            guard !project.sources.isEmpty,
                  project.sources.allSatisfy({ $0.path != nil && $0.sessionIDs?.isEmpty == false }) else { continue }
            let sessionIDs = project.sources.reduce(into: Set<String>()) { $0.formUnion($1.sessionIDs ?? []) }
            guard sessionIDs.allSatisfy({ metadata.contains($0, assignedSessionIDs: assignedSessionIDs) })
            else { continue }
            result.projects[index].isProjectless = true
            let titles = Set(sessions.filter { sessionIDs.contains($0.sessionID) }
                .compactMap { Self.independentChatTitle($0.title) })
            if sessionIDs.count == 1, titles.count == 1, let title = titles.first {
                result.projects[index].name = title
            } else {
                result.projects[index].name = sessionIDs.count == 1 ? "Independent chat" : "Independent chats"
            }
        }
        for index in sessions.indices where metadata.contains(
            sessions[index].sessionID, assignedSessionIDs: assignedSessionIDs)
        {
            // The session title identifies the chat; its temporary folder is not a project subtitle.
            result.sessions[index].projectName = nil
        }
        return result
    }

    private static func independentChatTitle(_ rawTitle: String?) -> String? {
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !title.hasPrefix("# Files mentioned by the user:"),
              !title.hasPrefix("## Referenced ChatGPT conversation:") else { return nil }
        return String(title.prefix(128))
    }
}
