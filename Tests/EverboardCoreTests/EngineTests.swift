import Foundation
import Testing
@testable import EverboardCore

private let gitlab = GitLabSource(client: GitLabClient(baseURL: URL(string: "https://gitlab.example")!, token: "t"), interval: 60)
private let jira = JiraSource(client: JiraClient(baseURL: URL(string: "https://x.atlassian.net")!, email: "a@b", token: "t"), interval: 120)

private func mr(_ iid: String, kind: String = "mine", pipeline: String? = nil, pipelineId: String = "100",
                created: Date = Date()) -> FeedItem {
    var attrs = ["projectId": "7", "projectPath": "team/app", "iid": iid, "authorName": "Asha"]
    if let pipeline {
        attrs["pipelineStatus"] = pipeline
        attrs["pipelineId"] = pipelineId
    }
    return FeedItem(id: "gitlab.mr:7:\(iid)", source: "gitlab", kind: "mr.\(kind)", title: "MR \(iid)",
                    subtitle: "team/app !\(iid)", url: "https://gitlab.example/mr/\(iid)", status: pipeline,
                    author: "asha", createdAt: created, updatedAt: Date(), attrs: attrs)
}

private func process(_ source: DataSource, _ results: [ScopeResult], store: Store, config: AppConfig = AppConfig()) async throws -> [AppEvent] {
    try await Engine.process(source: source, results: results, store: store, config: config)
}

@Suite struct EngineTests {
    @Test func baselineEmitsNothing() async throws {
        let store = try Store.inMemory()
        let events = try await process(gitlab, [
            ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "failed")]),
            ScopeResult(scope: GitLabSource.Scope.reportees, mode: .replace, items: [mr("2", kind: "reportee")]),
        ], store: store)
        #expect(events.isEmpty)
    }

    @Test func pipelineTurningRedNotifiesOnce() async throws {
        let store = try Store.inMemory()
        _ = try await process(gitlab, [ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "running")])], store: store)
        let first = try await process(gitlab, [ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "failed")])], store: store)
        #expect(first.map(\.id) == ["pipeline.failed:100"])
        #expect(first.first?.category == .pipelineFailedMR)
        let again = try await process(gitlab, [ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "failed")])], store: store)
        #expect(again.isEmpty)
        // A new pipeline on the same MR failing again is a new event.
        let retry = try await process(gitlab, [ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "failed", pipelineId: "101")])], store: store)
        #expect(retry.map(\.id) == ["pipeline.failed:101"])
    }

    @Test func samePipelineViaMRAndTriggeredPathIsDeduped() async throws {
        let store = try Store.inMemory()
        let scopeP = GitLabSource.Scope.pipelinesPrefix + "p7"
        let pipeline = { (status: String) in
            FeedItem(id: "gitlab.pipeline:100", source: "gitlab", kind: "pipeline", title: "team/app · main",
                     status: status, attrs: ["pipelineId": "100", "ref": "main", "projectPath": "team/app"])
        }
        _ = try await process(gitlab, [
            ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "running")]),
            ScopeResult(scope: scopeP, mode: .accumulate, items: [pipeline("running")]),
        ], store: store)
        let events = try await process(gitlab, [
            ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: [mr("1", pipeline: "failed")]),
            ScopeResult(scope: scopeP, mode: .accumulate, items: [pipeline("failed")]),
        ], store: store)
        #expect(events.count == 1)
    }

    @Test func reporteeNewMRNotifiesOnlyForRecentUnseen() async throws {
        let store = try Store.inMemory()
        let scope = GitLabSource.Scope.reportees
        _ = try await process(gitlab, [ScopeResult(scope: scope, mode: .replace, items: [mr("1", kind: "reportee")])], store: store)
        let events = try await process(gitlab, [ScopeResult(scope: scope, mode: .replace, items: [
            mr("1", kind: "reportee"),
            mr("2", kind: "reportee"),
            mr("3", kind: "reportee", created: Date().addingTimeInterval(-10 * 86400)),
        ])], store: store)
        #expect(events.map(\.id) == ["mr.new:gitlab.mr:7:2"])
        #expect(events.first?.title == "Asha opened an MR")
    }

    @Test func todoRules() {
        let todo = { (action: String) in
            FeedItem(id: "gitlab.todo:\(action)", source: "gitlab", kind: "todo", title: "Fix it", subtitle: "x", attrs: ["action": action])
        }
        func category(_ a: String) -> EventCategory? {
            gitlab.events(for: ItemChange(scope: GitLabSource.Scope.todos, old: nil, new: todo(a), wasPresent: false, everSeen: false),
                          config: AppConfig()).first?.category
        }
        #expect(category("review_requested") == .todoReview)
        #expect(category("mentioned") == .todoMention)
        #expect(category("approval_required") == .todoOther)
        #expect(category("build_failed") == nil)
    }

    @Test func jiraFilterNewAndStatusChange() async throws {
        let store = try Store.inMemory()
        var config = AppConfig()
        config.jiraFilters = [JiraFilterConfig(id: "42", name: "Sprint", notifyNew: true, notifyStatus: false)]
        let issue = { (key: String, status: String) in
            FeedItem(id: "jira.issue:\(key)", source: "jira", kind: "issue.filter", title: "Summary \(key)",
                     subtitle: key, url: "https://x/browse/\(key)", status: status, updatedAt: Date(), attrs: ["key": key])
        }
        let scope = JiraSource.Scope.filterPrefix + "42"
        _ = try await process(jira, [ScopeResult(scope: scope, mode: .replace, items: [issue("A-1", "To Do")])], store: store, config: config)
        let events = try await process(jira, [ScopeResult(scope: scope, mode: .replace, items: [issue("A-1", "In Progress"), issue("A-2", "To Do")])],
                                       store: store, config: config)
        let byCategory = Dictionary(grouping: events, by: \.category)
        #expect(byCategory[.jiraFilterNew]?.first?.title == "New in Sprint: A-2")
        let status = try #require(byCategory[.jiraFilterStatus]?.first)
        #expect(status.title == "A-1: To Do → In Progress")
        #expect(status.wantsNotification == false) // per-filter toggle off → inbox only
    }

    @Test func jiraAssignedFiresWhenEnteringSet() async throws {
        let store = try Store.inMemory()
        let issue = FeedItem(id: "jira.issue:A-9", source: "jira", kind: "issue.assigned", title: "Do it", subtitle: "A-9",
                             status: "To Do", updatedAt: Date(), attrs: ["key": "A-9"])
        _ = try await process(jira, [ScopeResult(scope: JiraSource.Scope.assigned, mode: .replace, items: [])], store: store)
        let events = try await process(jira, [ScopeResult(scope: JiraSource.Scope.assigned, mode: .replace, items: [issue])], store: store)
        #expect(events.first?.category == .jiraAssigned)
        let none = try await process(jira, [ScopeResult(scope: JiraSource.Scope.assigned, mode: .replace, items: [issue])], store: store)
        #expect(none.isEmpty)
    }

    @Test func jiraCommentRules() {
        let comment = { (author: String, mentions: Bool, involvement: String) in
            FeedItem(id: "jira.comment:A-1:\(author)\(involvement)", source: "jira", kind: "comment", title: "hello", subtitle: "A-1",
                     author: author, attrs: ["issueKey": "A-1", "authorId": author, "me": "me",
                                             "mentionsMe": mentions ? "1" : "0", "involvement": involvement])
        }
        func cat(_ c: FeedItem) -> EventCategory? {
            jira.events(for: ItemChange(scope: JiraSource.Scope.comments, old: nil, new: c, wasPresent: false, everSeen: false),
                        config: AppConfig()).first?.category
        }
        #expect(cat(comment("bob", false, "assignee")) == .jiraComment)
        #expect(cat(comment("bob", true, "watcher")) == .jiraMention)
        #expect(cat(comment("bob", false, "watcher")) == nil)
        #expect(cat(comment("me", true, "assignee")) == nil)
    }

    @Test func replaceModeMarksMissingItemsAbsent() async throws {
        let store = try Store.inMemory()
        try await store.apply(ScopeResult(scope: "s", mode: .replace, items: [mr("1"), mr("2")]), events: [])
        try await store.apply(ScopeResult(scope: "s", mode: .replace, items: [mr("2")]), events: [])
        let present = try await store.items(scope: "s")
        #expect(present.map(\.id) == ["gitlab.mr:7:2"])
        let state = try await store.scopeState("s")
        #expect(state.seen.count == 2)
        #expect(state.present == ["gitlab.mr:7:2"])
    }

    @Test func eventsReadState() async throws {
        let store = try Store.inMemory()
        let e = AppEvent(id: "x", category: .newsMajor, title: "t", body: "b")
        #expect(try await store.insert(event: e))
        #expect(try await store.insert(event: e) == false)
        #expect(try await store.unreadCount() == 1)
        try await store.markRead(["x"])
        #expect(try await store.unreadCount() == 0)
    }
}
