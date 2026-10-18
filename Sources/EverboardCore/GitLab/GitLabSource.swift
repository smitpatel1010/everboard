import Foundation

/// Polls one GitLab account: my MRs (+ head pipelines), review requests, reportees' MRs, to-dos and pipelines I triggered.
public struct GitLabSource: DataSource {
    public let interval: TimeInterval
    let client: GitLabClient
    public var account: CodeHostAccount { client.account }
    public var id: String { account.id }
    public var displayName: String { account.displayName }

    public init(client: GitLabClient, interval: TimeInterval) {
        self.client = client
        self.interval = interval
    }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        let me = try await currentUser(context)
        let base = client.baseURL.absoluteString
        let keep = { (mr: GQLMergeRequest) in account.includes(path: mr.project.fullPath) }

        let mine = try await client.myMergeRequests()
        let authored = mine.authored.filter(keep)
        var results = [
            ScopeResult(scope: account.scope(.mine), mode: .replace, items: authored.map { item($0, kind: "mine", base: base) }),
            ScopeResult(scope: account.scope(.review), mode: .replace, items: mine.reviewRequested.filter(keep).map { item($0, kind: "review", base: base) }),
            ScopeResult(scope: account.scope(.assigned), mode: .replace, items: mine.assigned.filter(keep).map { item($0, kind: "assigned", base: base) }),
        ]

        let usernames = context.config.reportees.compactMap(\.username)
        if !usernames.isEmpty {
            let users = try await client.openMergeRequests(byUsernames: usernames)
            let items = users.flatMap { u in u.authoredMergeRequests.nodes.filter(keep).map { item($0, kind: "reportee", base: base) } }
            results.append(ScopeResult(scope: account.scope(.reportees), mode: .replace, items: items))
        } else {
            results.append(ScopeResult(scope: account.scope(.reportees), mode: .replace, items: []))
        }

        let todos = try await client.todos().filter { account.includes(path: $0.project?.pathWithNamespace ?? "") }
        results.append(ScopeResult(scope: account.scope(.todos), mode: .replace, items: todos.map(item)))

        // Pipelines I triggered, across projects I'm active in.
        let projectIDs = try await activeProjects(me: me, mrs: authored, context: context)
        let since = Date().addingTimeInterval(-24 * 3600)
        try await withThrowingTaskGroup(of: ScopeResult?.self) { group in
            for pid in projectIDs {
                group.addTask {
                    // One flaky project shouldn't fail the whole poll.
                    guard let pipelines = try? await client.myPipelines(projectId: pid, username: me.username, updatedAfter: since) else { return nil }
                    let path = await projectPath(pid, context: context)
                    guard account.includes(path: path) else { return nil }
                    return ScopeResult(scope: account.scope(.pipelines) + "p\(pid)", mode: .accumulate,
                                       items: pipelines.map { item($0, projectPath: path) })
                }
            }
            for try await r in group { if let r { results.append(r) } }
        }
        return results
    }

    // MARK: Rules

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] {
        CodeHostRules.events(for: change, account: account)
    }

    // MARK: Helpers

    private func currentUser(_ context: FetchContext) async throws -> GitLabUser {
        if let json = await context.value("\(id).me"),
           let user = try? JSONDecoder().decode(GitLabUser.self, from: Data(json.utf8)) { return user }
        let user = try await client.gitlabUser()
        await context.setValue("\(id).me", String(decoding: try JSONEncoder().encode(user), as: UTF8.self))
        return user
    }

    /// Project ids to watch for my pipelines: open MRs + recent pushes (refreshed every 30 min) + pinned.
    private func activeProjects(me: GitLabUser, mrs: [GQLMergeRequest], context: FetchContext) async throws -> [String] {
        var ids = mrs.map { GitLabID.numeric($0.project.id) }
        let cacheKey = "\(id).activeProjects"
        let stampKey = "\(id).activeProjects.at"
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
        for path in PinnedProjects.paths(context.config.pinnedProjects, for: account) {
            let key = "\(id).pinned.\(path)"
            if let pid = await context.value(key) { ids.append(pid); continue }
            guard await PinnedProjects.shouldLookUp(path, account: account, context: context) else { continue }
            if let p = try? await client.project(path) {
                await context.setValue(key, String(p.id))
                await context.setValue("\(id).project.\(p.id)", p.pathWithNamespace)
                ids.append(String(p.id))
            } else {
                await PinnedProjects.recordMiss(path, account: account, context: context)
            }
        }
        for mr in mrs { await context.setValue("\(id).project.\(GitLabID.numeric(mr.project.id))", mr.project.fullPath) }
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        return unique
    }

    private func projectPath(_ pid: String, context: FetchContext) async -> String {
        if let p = await context.value("\(id).project.\(pid)") { return p }
        if let p = try? await client.project(pid) {
            await context.setValue("\(id).project.\(pid)", p.pathWithNamespace)
            return p.pathWithNamespace
        }
        return "project \(pid)"
    }

    func item(_ mr: GQLMergeRequest, kind: String, base: String) -> FeedItem {
        let projectId = GitLabID.numeric(mr.project.id)
        var attrs: [String: String] = [
            "account": account.id, "projectId": projectId, "projectPath": mr.project.fullPath, "iid": mr.iid,
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
        return FeedItem(id: "\(account.id).mr:\(projectId):\(mr.iid)", source: "gitlab", kind: "mr.\(kind)",
                        title: mr.title, subtitle: "\(mr.project.fullPath) !\(mr.iid)", url: mr.webUrl,
                        status: mr.headPipeline?.status.lowercased(), author: mr.author?.username,
                        createdAt: mr.createdAt, updatedAt: mr.updatedAt, attrs: attrs)
    }

    func item(_ todo: GitLabTodo) -> FeedItem {
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
        var attrs = ["account": account.id, "action": todo.actionName, "todoId": String(todo.id)]
        attrs["projectPath"] = todo.project?.pathWithNamespace
        attrs["targetType"] = todo.targetType
        if let body = todo.body { attrs["body"] = String(body.prefix(300)) }
        return FeedItem(id: "\(account.id).todo:\(todo.id)", source: "gitlab", kind: "todo",
                        title: todo.target?.title ?? todo.body ?? "", subtitle: what, url: todo.targetUrl,
                        status: todo.actionName, author: todo.author?.username,
                        createdAt: todo.createdAt, updatedAt: todo.createdAt, attrs: attrs)
    }

    func item(_ p: GitLabPipeline, projectPath: String) -> FeedItem {
        var attrs = ["account": account.id, "pipelineId": String(p.id), "projectId": String(p.projectId), "projectPath": projectPath]
        attrs["ref"] = p.ref
        attrs["trigger"] = p.source
        return FeedItem(id: "\(account.id).pipeline:\(p.id)", source: "gitlab", kind: "pipeline",
                        title: "\(projectPath) · \(p.ref ?? "")", subtitle: "#\(p.iid.map(String.init) ?? String(p.id)) \(p.source ?? "")",
                        url: p.webUrl, status: p.status, createdAt: p.createdAt, updatedAt: p.updatedAt, attrs: attrs)
    }
}
