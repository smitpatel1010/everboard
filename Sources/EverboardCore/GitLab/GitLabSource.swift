import Foundation

/// Polls GitLab: my MRs (+ head pipelines), review requests, reportees' MRs, to-dos and pipelines I triggered.
public struct GitLabSource: DataSource {
    public let id = "gitlab"
    public let displayName = "GitLab"
    public let interval: TimeInterval
    let client: GitLabClient

    public enum Scope {
        public static let mine = "gitlab.mr.mine"
        public static let review = "gitlab.mr.review"
        public static let assigned = "gitlab.mr.assigned"
        public static let reportees = "gitlab.mr.reportees"
        public static let todos = "gitlab.todos"
        public static let pipelinesPrefix = "gitlab.pipelines."
    }

    public init(client: GitLabClient, interval: TimeInterval) {
        self.client = client
        self.interval = interval
    }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        let me = try await currentUser(context)
        let base = client.baseURL.absoluteString

        let mine = try await client.myMergeRequests()
        var results = [
            ScopeResult(scope: Scope.mine, mode: .replace, items: mine.authored.map { Self.item($0, kind: "mine", base: base) }),
            ScopeResult(scope: Scope.review, mode: .replace, items: mine.reviewRequested.map { Self.item($0, kind: "review", base: base) }),
            ScopeResult(scope: Scope.assigned, mode: .replace, items: mine.assigned.map { Self.item($0, kind: "assigned", base: base) }),
        ]

        let usernames = context.config.reportees.compactMap(\.username)
        if !usernames.isEmpty {
            let users = try await client.openMergeRequests(byUsernames: usernames)
            let items = users.flatMap { u in u.authoredMergeRequests.nodes.map { Self.item($0, kind: "reportee", base: base) } }
            results.append(ScopeResult(scope: Scope.reportees, mode: .replace, items: items))
        } else {
            results.append(ScopeResult(scope: Scope.reportees, mode: .replace, items: []))
        }

        results.append(ScopeResult(scope: Scope.todos, mode: .replace, items: try await client.todos().map(Self.item)))

        // Pipelines I triggered, across projects I'm active in.
        let projectIDs = try await activeProjects(me: me, mrs: mine.authored, context: context)
        let since = Date().addingTimeInterval(-24 * 3600)
        try await withThrowingTaskGroup(of: ScopeResult?.self) { group in
            for pid in projectIDs {
                group.addTask {
                    // One flaky project shouldn't fail the whole poll.
                    guard let pipelines = try? await client.myPipelines(projectId: pid, username: me.username, updatedAfter: since) else { return nil }
                    let path = await projectPath(pid, context: context)
                    return ScopeResult(scope: Scope.pipelinesPrefix + "p\(pid)", mode: .accumulate,
                                       items: pipelines.map { Self.item($0, projectPath: path) })
                }
            }
            for try await r in group { if let r { results.append(r) } }
        }
        return results
    }

    // MARK: Rules

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] {
        let new = change.new
        switch change.scope {
        case Scope.mine, Scope.review, Scope.assigned:
            // Head pipeline turned red (or a newly seen MR is already red).
            guard new["pipelineStatus"] == "failed", let pid = new["pipelineId"] else { return [] }
            let old = change.old
            if let old, old["pipelineId"] == pid, old["pipelineStatus"] == "failed" { return [] }
            return [AppEvent(id: "pipeline.failed:\(pid)", ts: new.updatedAt ?? Date(), category: .pipelineFailedMR,
                             title: "Pipeline failed: \(new.title)",
                             body: "\(new["projectPath"] ?? "") · \(new["sourceBranch"] ?? "")",
                             url: new["pipelineUrl"] ?? new.url)]

        case Scope.reportees:
            // Only MRs created recently: avoids a burst when a reportee is first added to the list.
            guard !change.everSeen, let created = new.createdAt, created > Date().addingTimeInterval(-3 * 86400) else { return [] }
            return [AppEvent(id: "mr.new:\(new.id)", ts: created, category: .reporteeNewMR,
                             title: "\(new["authorName"] ?? new.author ?? "Reportee") opened an MR",
                             body: "\(new.title)\n\(new["projectPath"] ?? "")", url: new.url)]

        case Scope.todos:
            guard !change.everSeen else { return [] }
            let action = new["action"] ?? ""
            let category: EventCategory
            switch action {
            case "review_requested": category = .todoReview
            case "mentioned", "directly_addressed": category = .todoMention
            case "build_failed": return [] // covered by the pipeline rule with a better message
            default: category = .todoOther
            }
            return [AppEvent(id: "todo:\(new.id)", ts: new.createdAt ?? Date(), category: category,
                             title: new.subtitle, body: new.title, url: new.url)]

        default:
            guard change.scope.hasPrefix(Scope.pipelinesPrefix), new.status == "failed" else { return [] }
            if let old = change.old, old.status == "failed" { return [] }
            return [AppEvent(id: "pipeline.failed:\(new["pipelineId"] ?? new.id)", ts: new.updatedAt ?? Date(),
                             category: .pipelineFailedTriggered,
                             title: "Your pipeline failed on \(new["ref"] ?? "?")",
                             body: new["projectPath"] ?? "", url: new.url)]
        }
    }

    // MARK: Helpers

    private func currentUser(_ context: FetchContext) async throws -> GitLabUser {
        if let json = await context.value("gitlab.me"),
           let user = try? JSONDecoder().decode(GitLabUser.self, from: Data(json.utf8)) { return user }
        let user = try await client.currentUser()
        await context.setValue("gitlab.me", String(decoding: try JSONEncoder().encode(user), as: UTF8.self))
        return user
    }

    /// Project ids to watch for my pipelines: open MRs + recent pushes (refreshed every 30 min) + pinned.
    private func activeProjects(me: GitLabUser, mrs: [GQLMergeRequest], context: FetchContext) async throws -> [String] {
        var ids = mrs.map { GitLabID.numeric($0.project.id) }
        let cacheKey = "gitlab.activeProjects"
        let stampKey = "gitlab.activeProjects.at"
        let stamp = await context.value(stampKey).flatMap(Dates.parseISO) ?? .distantPast
        var pushed = (await context.value(cacheKey))?.split(separator: ",").map(String.init) ?? []
        if Date().timeIntervalSince(stamp) > 30 * 60 {
            if let fresh = try? await client.pushedProjectIDs(userId: me.id, since: Date().addingTimeInterval(-7 * 86400)) {
                pushed = fresh.prefix(15).map(String.init)
                await context.setValue(cacheKey, pushed.joined(separator: ","))
                await context.setValue(stampKey, Dates.iso(Date()))
            }
        }
        ids += pushed
        for path in context.config.pinnedProjects {
            let key = "gitlab.pinned.\(path)"
            if let id = await context.value(key) { ids.append(id); continue }
            if let p = try? await client.project(path) {
                await context.setValue(key, String(p.id))
                await context.setValue("gitlab.project.\(p.id)", p.pathWithNamespace)
                ids.append(String(p.id))
            }
        }
        for mr in mrs { await context.setValue("gitlab.project.\(GitLabID.numeric(mr.project.id))", mr.project.fullPath) }
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        return unique
    }

    private func projectPath(_ id: String, context: FetchContext) async -> String {
        if let p = await context.value("gitlab.project.\(id)") { return p }
        if let p = try? await client.project(id) {
            await context.setValue("gitlab.project.\(id)", p.pathWithNamespace)
            return p.pathWithNamespace
        }
        return "project \(id)"
    }

    static func item(_ mr: GQLMergeRequest, kind: String, base: String) -> FeedItem {
        let projectId = GitLabID.numeric(mr.project.id)
        var attrs: [String: String] = [
            "projectId": projectId, "projectPath": mr.project.fullPath, "iid": mr.iid,
        ]
        attrs["sourceBranch"] = mr.sourceBranch
        attrs["targetBranch"] = mr.targetBranch
        attrs["authorName"] = mr.author?.name
        attrs["mergeStatus"] = mr.detailedMergeStatus?.lowercased()
        if mr.draft == true { attrs["draft"] = "1" }
        if let n = mr.userNotesCount { attrs["notes"] = String(n) }
        if let approvers = mr.approvedBy?.nodes, !approvers.isEmpty {
            attrs["approvedBy"] = approvers.map { $0.name ?? $0.username }.joined(separator: ", ")
        }
        if let reviewers = mr.reviewers?.nodes, !reviewers.isEmpty {
            attrs["reviewers"] = reviewers.map { $0.name ?? $0.username }.joined(separator: ", ")
        }
        if let p = mr.headPipeline {
            attrs["pipelineId"] = GitLabID.numeric(p.id)
            attrs["pipelineStatus"] = p.status.lowercased()
            if let path = p.path { attrs["pipelineUrl"] = base + path }
            if let u = p.updatedAt { attrs["pipelineUpdatedAt"] = Dates.iso(u) }
        }
        let keys = JiraKeys.find(in: [mr.title, mr.sourceBranch])
        if !keys.isEmpty { attrs["jiraKeys"] = keys.joined(separator: ",") }
        return FeedItem(id: "gitlab.mr:\(projectId):\(mr.iid)", source: "gitlab", kind: "mr.\(kind)",
                        title: mr.title, subtitle: "\(mr.project.fullPath) !\(mr.iid)", url: mr.webUrl,
                        status: mr.headPipeline?.status.lowercased(), author: mr.author?.username,
                        createdAt: mr.createdAt, updatedAt: mr.updatedAt, attrs: attrs)
    }

    static func item(_ todo: GitLabTodo) -> FeedItem {
        let who = todo.author?.name ?? "Someone"
        let what: String
        switch todo.actionName {
        case "review_requested": what = "\(who) requested your review"
        case "mentioned": what = "\(who) mentioned you"
        case "directly_addressed": what = "\(who) addressed you"
        case "assigned": what = "\(who) assigned you"
        case "approval_required": what = "Your approval is required"
        case "build_failed": what = "Pipeline failed"
        case "unmergeable": what = "MR can't be merged"
        case "marked": what = "\(who) added a to-do"
        default: what = todo.actionName.replacingOccurrences(of: "_", with: " ").capitalized
        }
        var attrs = ["action": todo.actionName]
        attrs["projectPath"] = todo.project?.pathWithNamespace
        attrs["targetType"] = todo.targetType
        if let body = todo.body { attrs["body"] = String(body.prefix(300)) }
        return FeedItem(id: "gitlab.todo:\(todo.id)", source: "gitlab", kind: "todo",
                        title: todo.target?.title ?? todo.body ?? "", subtitle: what, url: todo.targetUrl,
                        status: todo.actionName, author: todo.author?.username,
                        createdAt: todo.createdAt, updatedAt: todo.createdAt, attrs: attrs)
    }

    static func item(_ p: GitLabPipeline, projectPath: String) -> FeedItem {
        var attrs = ["pipelineId": String(p.id), "projectId": String(p.projectId), "projectPath": projectPath]
        attrs["ref"] = p.ref
        attrs["trigger"] = p.source
        return FeedItem(id: "gitlab.pipeline:\(p.id)", source: "gitlab", kind: "pipeline",
                        title: "\(projectPath) · \(p.ref ?? "")", subtitle: "#\(p.iid.map(String.init) ?? String(p.id)) \(p.source ?? "")",
                        url: p.webUrl, status: p.status, createdAt: p.createdAt, updatedAt: p.updatedAt, attrs: attrs)
    }
}
