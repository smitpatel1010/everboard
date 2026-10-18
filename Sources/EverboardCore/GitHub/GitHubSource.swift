import Foundation

/// Polls one GitHub account: my PRs (+ checks), review requests, assigned PRs, reportees' PRs,
/// notifications (as to-dos) and Actions runs I triggered. Items use the same scopes and attrs as GitLab's.
public struct GitHubSource: DataSource {
    public let interval: TimeInterval
    let client: GitHubClient
    public var account: CodeHostAccount { client.account }
    public var id: String { account.id }
    public var displayName: String { account.displayName }

    public init(client: GitHubClient, interval: TimeInterval) {
        self.client = client
        self.interval = interval
    }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        let me = try await currentUser(context)
        let open = "is:pr is:open archived:false"
        var searches = ["mine": "\(open) author:@me", "review": "\(open) review-requested:@me", "assigned": "\(open) assignee:@me"]
        // One search per reportee: GitHub doesn't document OR-ing several author: qualifiers.
        let reportees = context.config.reportees.compactMap(\.githubUsername).map(GitHubClient.login).filter { !$0.isEmpty }
        for (i, login) in reportees.enumerated() { searches["r\(i)"] = "\(open) author:\(login)" }
        let found = try await client.searchPulls(searches)

        let mine = found["mine"] ?? []
        var results = [
            ScopeResult(scope: account.scope(.mine), mode: .replace, items: mine.map { Self.item($0, kind: "mine", account: account) }),
            ScopeResult(scope: account.scope(.review), mode: .replace, items: (found["review"] ?? []).map { Self.item($0, kind: "review", account: account) }),
            ScopeResult(scope: account.scope(.assigned), mode: .replace, items: (found["assigned"] ?? []).map { Self.item($0, kind: "assigned", account: account) }),
            ScopeResult(scope: account.scope(.reportees), mode: .replace,
                        items: reportees.indices.flatMap { found["r\($0)"] ?? [] }.map { Self.item($0, kind: "reportee", account: account) }),
        ]

        // Fine-grained tokens can't read notifications; keep the rest of the poll working and say why once.
        do {
            let notes = try await client.notifications().filter { account.includes(path: $0.repository.fullName) }
            results.append(ScopeResult(scope: account.scope(.todos), mode: .replace, items: notes.map { Self.item($0, account: account) }))
        } catch {
            if await context.value("\(id).notifications.warned") == nil {
                Log.info("\(id): notifications unavailable (\(error.localizedDescription)); a classic token with the notifications scope is needed")
                await context.setValue("\(id).notifications.warned", "1")
            }
        }

        let repos = await activeRepos(me: me, mine: mine, context: context)
        let since = Date().addingTimeInterval(-24 * 3600)
        await withTaskGroup(of: ScopeResult?.self) { group in
            for repo in repos {
                group.addTask {
                    guard let runs = try? await client.workflowRuns(repo: repo, actor: me.login, since: since) else { return nil }
                    return ScopeResult(scope: account.scope(.pipelines) + repo, mode: .accumulate,
                                       items: runs.map { Self.item($0, repo: repo, account: account) })
                }
            }
            for await r in group { if let r { results.append(r) } }
        }
        return results
    }

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] {
        CodeHostRules.events(for: change, account: account)
    }

    // MARK: Helpers

    private func currentUser(_ context: FetchContext) async throws -> GitHubUser {
        if let json = await context.value("\(id).me"),
           let user = try? JSONDecoder().decode(GitHubUser.self, from: Data(json.utf8)) { return user }
        let user = try await client.viewer()
        await context.setValue("\(id).me", String(decoding: try JSONEncoder().encode(user), as: UTF8.self))
        return user
    }

    /// Repos to watch for my workflow runs: open PRs + recent pushes (refreshed every 30 min) + pinned.
    private func activeRepos(me: GitHubUser, mine: [GHPullRequest], context: FetchContext) async -> [String] {
        var repos = mine.map(\.repository.nameWithOwner)
        let cacheKey = "\(id).activeRepos", stampKey = "\(id).activeRepos.at"
        let stamp = await context.value(stampKey).flatMap(Dates.parseISO) ?? .distantPast
        var recent = (await context.value(cacheKey))?.split(separator: ",").map(String.init) ?? []
        if Date().timeIntervalSince(stamp) > 30 * 60, let fresh = try? await client.recentRepos(login: me.login) {
            recent = fresh.filter { account.includes(path: $0) }.prefix(15).map { $0 }
            await context.setValue(cacheKey, recent.joined(separator: ","))
            await context.setValue(stampKey, Dates.iso(Date()))
        }
        repos += recent
        for path in PinnedProjects.paths(context.config.pinnedProjects, for: account) {
            guard await PinnedProjects.shouldLookUp(path, account: account, context: context) else { continue }
            if await context.value("\(id).pinned.\(path)") == nil {
                guard (try? await client.workflowRuns(repo: path)) != nil else {
                    await PinnedProjects.recordMiss(path, account: account, context: context)
                    continue
                }
                await context.setValue("\(id).pinned.\(path)", "1")
            }
            repos.append(path)
        }
        var unique: [String] = []
        for r in repos where !unique.contains(r) { unique.append(r) }
        return unique
    }

    static func item(_ pr: GHPullRequest, kind: String, account: CodeHostAccount) -> FeedItem {
        let repo = pr.repository.nameWithOwner
        var attrs: [String: String] = ["account": account.id, "projectId": repo, "projectPath": repo, "iid": String(pr.number)]
        attrs["sourceBranch"] = pr.headRefName
        attrs["targetBranch"] = pr.baseRefName
        attrs["authorName"] = pr.author.map { $0.name ?? $0.login }
        if pr.isDraft == true { attrs["draft"] = "1" }
        if let n = pr.comments?.totalCount { attrs["notes"] = String(n) }
        let approvers = (pr.latestOpinionatedReviews?.values ?? []).filter { $0.state == "APPROVED" }.compactMap { $0.author.map { $0.name ?? $0.login } }
        if !approvers.isEmpty { attrs["approvedBy"] = approvers.joined(separator: ", ") }
        let reviewers = (pr.reviewRequests?.values ?? []).compactMap { $0.requestedReviewer.flatMap { $0.name ?? $0.login } }
        if !reviewers.isEmpty { attrs["reviewers"] = reviewers.joined(separator: ", ") }
        attrs["mergeStatus"] = mergeStatus(mergeable: pr.mergeable, reviewDecision: pr.reviewDecision)
        let pipeline: String?
        if let commit = pr.commits?.values.last?.commit {
            attrs["headSha"] = commit.oid
            if let state = commit.statusCheckRollup?.state {
                let status = checkStatus(state)
                attrs["pipelineId"] = commit.oid
                attrs["pipelineStatus"] = status
                attrs["pipelineUrl"] = pr.url + "/checks"
                pipeline = status
            } else { pipeline = nil }
        } else { pipeline = nil }
        let keys = JiraKeys.find(in: [pr.title, pr.headRefName])
        if !keys.isEmpty { attrs["jiraKeys"] = keys.joined(separator: ",") }
        return FeedItem(id: "\(account.id).pr:\(repo):\(pr.number)", source: "github", kind: "mr.\(kind)",
                        title: pr.title, subtitle: "\(repo) #\(pr.number)", url: pr.url, status: pipeline,
                        author: pr.author?.login, createdAt: pr.createdAt, updatedAt: pr.updatedAt, attrs: attrs)
    }

    /// Check-suite rollup → the pipeline statuses the UI knows.
    static func checkStatus(_ rollup: String) -> String {
        switch rollup {
        case "SUCCESS": return "success"
        case "FAILURE", "ERROR": return "failed"
        case "PENDING": return "running"
        default: return "pending"
        }
    }

    /// GitLab-style merge status so "ready to merge" and blocker hints work the same.
    static func mergeStatus(mergeable: String?, reviewDecision: String?) -> String? {
        if mergeable == "CONFLICTING" { return "conflict" }
        if reviewDecision == "CHANGES_REQUESTED" { return "changes_requested" }
        if reviewDecision == "REVIEW_REQUIRED" { return "not_approved" }
        return mergeable == "MERGEABLE" ? "mergeable" : nil
    }

    static func item(_ n: GitHubNotification, account: CodeHostAccount) -> FeedItem {
        let what: String, action: String
        switch n.reason {
        case "review_requested": (what, action) = ("Review requested", "review_requested")
        case "mention": (what, action) = ("You were mentioned", "mentioned")
        case "team_mention": (what, action) = ("Your team was mentioned", "mentioned")
        case "assign": (what, action) = ("You were assigned", "assigned")
        case "approval_requested": (what, action) = ("Your approval is required", "approval_required")
        case "ci_activity": (what, action) = ("Workflow run finished", "build_failed")
        case "author": (what, action) = ("Activity on your thread", "author")
        case "comment": (what, action) = ("New comment", "comment")
        case "state_change": (what, action) = ("State changed", "state_change")
        default: (what, action) = (n.reason.replacingOccurrences(of: "_", with: " ").capitalized, n.reason)
        }
        let attrs = ["account": account.id, "action": action, "threadId": n.id, "projectPath": n.repository.fullName,
                     "targetType": n.subject.type]
        return FeedItem(id: "\(account.id).notification:\(n.id)", source: "github", kind: "todo",
                        title: n.subject.title, subtitle: what,
                        url: GitHubClient.webURL(forAPI: n.subject.url, account: account, repoHTML: n.repository.htmlUrl),
                        status: action, createdAt: n.updatedAt, updatedAt: n.updatedAt, attrs: attrs)
    }

    static func item(_ run: GitHubWorkflowRun, repo: String, account: CodeHostAccount) -> FeedItem {
        var attrs = ["account": account.id, "pipelineId": String(run.id), "projectId": repo, "projectPath": repo]
        attrs["ref"] = run.headBranch
        attrs["trigger"] = run.event
        let label = [run.name, run.event.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return FeedItem(id: "\(account.id).run:\(run.id)", source: "github", kind: "pipeline",
                        title: "\(repo) · \(run.headBranch ?? "")", subtitle: "#\(run.runNumber.map(String.init) ?? String(run.id)) \(label)",
                        url: run.htmlUrl, status: run.normalizedStatus, createdAt: run.createdAt, updatedAt: run.updatedAt, attrs: attrs)
    }
}
