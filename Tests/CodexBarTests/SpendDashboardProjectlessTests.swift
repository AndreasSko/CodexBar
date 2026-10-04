import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardProjectlessTests {
    @Test
    func `legacy rows remain projects and detail sections retain their defaults`() {
        let row = SpendDashboardModel.ProjectRow(
            rank: 1,
            provider: .codex,
            providerName: "Codex",
            sourceID: "codex-a",
            projectName: "work",
            path: "/fixtures/work",
            totalTokens: 10,
            totalCost: 1)
        #expect(!row.isProjectless)
        #expect(spendDashboardAvailableDetailSections(hasProjects: false, hasSessions: false) == [.providers])
        #expect(spendDashboardAvailableDetailSections(hasProjects: true, hasSessions: true) == [
            .providers, .projects, .sessions,
        ])
    }

    @Test
    func `each category has consecutive ranks and preserves every ledger amount and identity`() throws {
        let group = try Self.group(projects: [
            Self.project(name: "work", path: "/fixtures/work", cost: 30, tokens: 300),
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 20, tokens: 200, isProjectless: true),
            Self.project(name: "tools", path: "/fixtures/tools", cost: 10, tokens: 100),
            Self.project(name: "Planning", path: "/fixtures/chat-b", cost: 5, tokens: 50, isProjectless: true),
        ])
        let projects = spendDashboardProjectRows(group.projects, isProjectless: false)
        let chats = spendDashboardProjectRows(group.projects, isProjectless: true)

        #expect(projects.map(\.rank) == [1, 2])
        #expect(chats.map(\.rank) == [1, 2])
        #expect(projects.map(\.path) == ["/fixtures/work", "/fixtures/tools"])
        #expect(chats.map(\.path) == ["/fixtures/chat-a", "/fixtures/chat-b"])
        let allChatsAreProjectless = chats.allSatisfy(\.isProjectless)
        #expect(allChatsAreProjectless)
        let displayed = projects + chats
        #expect(Set(displayed.map(\.id)) == Set(group.projects.map(\.id)))
        #expect(displayed.compactMap(\.totalCost).reduce(0, +) == 65)
        #expect(displayed.compactMap(\.totalTokens).reduce(0, +) == 650)
        for row in displayed {
            let original = try #require(group.projects.first { $0.id == row.id })
            #expect(row.totalCost == original.totalCost)
            #expect(row.totalTokens == original.totalTokens)
            #expect(row.providerName == original.providerName)
        }
        // Display ranking must not mutate the combined ledger ranking.
        #expect(group.projects.map(\.rank) == [1, 2, 3, 4])
    }

    @Test
    func `identical paths require unanimous classification regardless of record order`() throws {
        let chat = Self.project(name: "Planning", path: "/fixtures/shared", cost: 3, tokens: 30, isProjectless: true)
        let project = Self.project(name: "work", path: "/fixtures/shared", cost: 2, tokens: 20)
        for records in [[chat, project], [project, chat]] {
            let rows = try Self.group(projects: records).projects
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(!row.isProjectless)
            #expect(row.projectName == "work")
            #expect(row.id == "codex-a:path:/fixtures/shared")
            #expect(row.totalCost == 5)
            #expect(row.totalTokens == 50)
        }
        let unanimous = try Self.group(projects: [chat, chat]).projects
        #expect(unanimous.count == 1)
        #expect(unanimous.first?.isProjectless == true)
        #expect(unanimous.first?.totalCost == 6)
    }

    @Test
    func `same named distinct paths remain separate and disambiguate only inside their category`() throws {
        let group = try Self.group(projects: [
            Self.project(name: "Planning", path: "/fixtures/work", cost: 30),
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 20, isProjectless: true),
            Self.project(name: "Planning", path: "/fixtures/chat-b", cost: 10, isProjectless: true),
        ])
        #expect(Set(group.projects.map(\.id)).count == 3)
        let projects = spendDashboardProjectRows(group.projects, isProjectless: false)
        let chats = spendDashboardProjectRows(group.projects, isProjectless: true)
        #expect(projects.allSatisfy { !$0.needsPathDisambiguation(in: group.projects) })
        #expect(chats.allSatisfy { $0.needsPathDisambiguation(in: chats) })
        #expect(chats.allSatisfy { $0.displayIdentity(hidePersonalInfo: false).path != nil })
        let renamed = Self.row(name: "A new title", path: "/fixtures/chat-a", isProjectless: true)
        #expect(renamed.id == chats[0].id)
        #expect(Self.row(name: "Planning", path: "/fixtures/chat-a").id == chats[0].id)
    }

    @Test
    func `classification stays scoped to each source even for identical paths`() throws {
        let inputs = [
            Self.input(id: "codex-a", projects: [
                Self.project(name: "Planning", path: "/fixtures/shared", cost: 2, isProjectless: true),
            ]),
            Self.input(id: "codex-b", projects: [
                Self.project(name: "work", path: "/fixtures/shared", cost: 3),
            ]),
        ]
        let group = try #require(Self.model(inputs: inputs).groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects.first { $0.sourceID == "codex-a" }?.isProjectless == true)
        #expect(group.projects.first { $0.sourceID == "codex-b" }?.isProjectless == false)
        #expect(group.projects.compactMap(\.totalCost).reduce(0, +) == 5)
    }

    @Test
    func `classification changes no provider chart or ledger sums including unknown amounts`() throws {
        let plain = [
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 4, tokens: nil),
            Self.project(name: "work", path: "/fixtures/work", cost: nil, tokens: 40),
        ]
        let classified = [
            Self.project(name: "Planning", path: "/fixtures/chat-a", cost: 4, tokens: nil, isProjectless: true),
            plain[1],
        ]
        let before = try Self.group(projects: plain)
        let after = try Self.group(projects: classified)
        #expect(after.totalCost == before.totalCost)
        #expect(after.totalTokens == before.totalTokens)
        #expect(after.providers == before.providers)
        #expect(after.models == before.models)
        #expect(after.dailyPoints == before.dailyPoints)
        #expect(after.sessions == before.sessions)
        #expect(after.projects.map(\.id) == before.projects.map(\.id))
        #expect(after.projects.map(\.totalCost) == before.projects.map(\.totalCost))
        #expect(after.projects.map(\.totalTokens) == before.projects.map(\.totalTokens))
        let chats = spendDashboardProjectRows(after.projects, isProjectless: true)
        #expect(chats.first?.totalCost == 4)
        #expect(chats.first?.totalTokens == nil)
    }

    @Test
    func `independent chat fallback and privacy labels are localized without exposing paths`() {
        for (language, fallback, maskedChat, maskedProject) in [
            ("en", "Independent chat", "Chat 1", "Project 1"),
            ("zh-Hans", "独立聊天", "聊天 1", "项目 1"),
        ] {
            CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let chat = Self.row(name: "Private thread title", path: "/fixtures/private", isProjectless: true)
                #expect(chat.displayIdentity(hidePersonalInfo: false).name == "Private thread title")
                #expect(chat.displayIdentity(hidePersonalInfo: true).name == maskedChat)
                #expect(chat.displayIdentity(hidePersonalInfo: true).path == nil)
                #expect(Self.row(name: "work").displayIdentity(hidePersonalInfo: true).name == maskedProject)
                for name in ["Independent chat", "  "] {
                    let row = Self.row(name: name, isProjectless: true)
                    #expect(row.displayIdentity(hidePersonalInfo: false).name == fallback)
                }
                let plural = Self.row(name: "Independent chats", isProjectless: true)
                #expect(plural.displayIdentity(hidePersonalInfo: false).name == L("Independent chats"))
                #expect(plural.displayIdentity(hidePersonalInfo: true).name == maskedChat)
                #expect(SpendDashboardDetailSection.chats.title == (language == "en" ? "Independent chats" : "独立聊天"))
            }
        }
    }

    @Test
    @MainActor
    func `four small detail picker segments fit within 460 points in both supported locales`() {
        for language in ["en", "zh-Hans"] {
            CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let sections = spendDashboardAvailableDetailSections(
                    hasProjects: true,
                    hasSessions: true,
                    hasChats: true)
                let picker = NSSegmentedControl(
                    labels: sections.map(\.title),
                    trackingMode: .selectOne,
                    target: nil,
                    action: nil)
                picker.controlSize = .small
                picker.segmentStyle = .rounded
                picker.sizeToFit()
                #expect(picker.segmentCount == 4)
                #expect(picker.frame.width <= 460)
                for index in sections.indices {
                    #expect(picker.label(forSegment: index) == sections[index].title)
                }
            }
        }
    }

    @Test
    func `available detail sections cover every mix of projects chats and sessions`() {
        for hasProjects in [false, true] {
            for hasChats in [false, true] {
                for hasSessions in [false, true] {
                    var expected: [SpendDashboardDetailSection] = [.providers]
                    if hasProjects { expected.append(.projects) }
                    if hasChats { expected.append(.chats) }
                    if hasSessions { expected.append(.sessions) }
                    #expect(spendDashboardAvailableDetailSections(
                        hasProjects: hasProjects,
                        hasSessions: hasSessions,
                        hasChats: hasChats) == expected)
                }
            }
        }
    }

    private static func row(
        name: String,
        path: String = "/fixtures/work",
        isProjectless: Bool = false) -> SpendDashboardModel.ProjectRow
    {
        SpendDashboardModel.ProjectRow(
            rank: 1,
            provider: .codex,
            providerName: "Codex",
            sourceID: "codex-a",
            projectName: name,
            path: path,
            totalTokens: 10,
            totalCost: 1,
            isProjectless: isProjectless)
    }

    private static func project(
        name: String,
        path: String,
        cost: Double?,
        tokens: Int? = 10,
        isProjectless: Bool = false) -> CostUsageProjectBreakdown
    {
        CostUsageProjectBreakdown(
            name: name,
            path: path,
            totalTokens: tokens,
            totalCostUSD: cost,
            daily: [self.entry(cost: cost, tokens: tokens)],
            modelBreakdowns: nil,
            isProjectless: isProjectless)
    }

    private static func entry(cost: Double?, tokens: Int?) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func input(
        id: String = "codex-a",
        projects: [CostUsageProjectBreakdown]) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                historyDays: 30,
                daily: [self.entry(cost: 10, tokens: 100)],
                projects: projects,
                updatedAt: self.now))
    }

    private static func group(projects: [CostUsageProjectBreakdown]) throws -> SpendDashboardModel.CurrencyGroup {
        try #require(self.model(inputs: [self.input(projects: projects)]).groups.first)
    }

    private static func model(inputs: [SpendDashboardModel.ProviderInput]) -> SpendDashboardModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return SpendDashboardModel.build(inputs: inputs, requestedDays: 30, now: self.now, calendar: calendar)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
}
