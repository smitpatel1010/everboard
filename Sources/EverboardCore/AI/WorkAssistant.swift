import Foundation

/// AI features over work data: morning brief, reportee MR summary, Jira ticket digest.
public struct WorkAssistant: Sendable {
    let store: Store
    let claude: ClaudeRunning
    let gitlab: GitLabClient?
    let jira: JiraClient?

    public init(store: Store, claude: ClaudeRunning, gitlab: GitLabClient?, jira: JiraClient?) {
        self.store = store
        self.claude = claude
        self.gitlab = gitlab
        self.jira = jira
    }

    static let system = """
    You are the user's work assistant inside their personal dashboard app. Be concise and concrete. \
    Use short markdown: headings with ##, bullets with -, bold for names/IDs. No preamble, no sign-off.
    """

    // MARK: Morning brief

    public func morningBrief(now: Date = Date()) async throws -> String {
        let mine = try await store.items(scopePrefix: GitLabSource.Scope.mine)
        let review = try await store.items(scopePrefix: GitLabSource.Scope.review)
        let reportees = try await store.items(scopePrefix: GitLabSource.Scope.reportees)
        let todos = try await store.items(scopePrefix: GitLabSource.Scope.todos)
        let pipelines = try await store.items(scopePrefix: GitLabSource.Scope.pipelinesPrefix, presentOnly: false)
            .filter { ($0.updatedAt ?? .distantPast) > now.addingTimeInterval(-86400) }
        let assigned = try await store.items(scopePrefix: JiraSource.Scope.assigned)
        let recentEvents = try await store.events(limit: 200).filter { $0.ts > now.addingTimeInterval(-86400) }

        func mr(_ i: FeedItem) -> String {
            var parts = ["\(i.subtitle): \(i.title)", "by \(i["authorName"] ?? i.author ?? "?")",
                         "opened \(Dates.age(i.createdAt, now: now)) ago"]
            if let s = i["pipelineStatus"] { parts.append("pipeline \(s)") }
            if let m = i["mergeStatus"] { parts.append("merge status \(m)") }
            if i["draft"] == "1" { parts.append("draft") }
            if let a = i["approvedBy"] { parts.append("approved by \(a)") }
            return "- " + parts.joined(separator: " · ")
        }
        func issue(_ i: FeedItem) -> String {
            "- \(i["key"] ?? "") [\(i.status ?? "")] \(i.title) · priority \(i["priority"] ?? "-")"
                + (i["due"].map { " · due \($0)" } ?? "") + " · updated \(Dates.age(i.updatedAt, now: now)) ago"
        }

        let snapshot = """
        Today is \(now.formatted(date: .complete, time: .shortened)).

        ## My open MRs (\(mine.count))
        \(mine.map(mr).joined(separator: "\n"))

        ## MRs waiting for my review (\(review.count))
        \(review.map(mr).joined(separator: "\n"))

        ## My reportees' open MRs (\(reportees.count))
        \(reportees.map(mr).joined(separator: "\n"))

        ## Pending GitLab to-dos (\(todos.count))
        \(todos.prefix(30).map { "- \($0.subtitle): \($0.title)" }.joined(separator: "\n"))

        ## My pipelines in the last 24h
        \(pipelines.prefix(30).map { "- \($0.title) → \($0.status ?? "?") (\(Dates.age($0.updatedAt, now: now)) ago)" }.joined(separator: "\n"))

        ## Jira issues assigned to me (\(assigned.count))
        \(assigned.map(issue).joined(separator: "\n"))

        ## Activity in the last 24h
        \(recentEvents.prefix(60).map { "- \($0.title) — \($0.body.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n"))
        """

        let prompt = """
        Write my morning work brief from this dashboard snapshot. Structure:
        ## Needs you today — the 3–7 most important actions, most urgent first (blocked reviews, red pipelines on my MRs, high-priority or due Jira issues).
        ## Your team — reportee MRs that look stuck (old, red pipeline, no approvals, waiting on review) and who might need a nudge.
        ## FYI — anything else notable, one line each.
        Skip empty sections. Reference MRs as project!iid and issues by key.

        \(snapshot)
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "work.brief"))
        await store.cache("brief.work.latest", r.text, now: now)
        await store.setValue("brief.work.at", Dates.iso(now))
        return r.text
    }

    public func latestBrief() async -> (text: String, at: Date?)? {
        guard let text = await store.cached("brief.work.latest") else { return nil }
        return (text, await store.value("brief.work.at").flatMap(Dates.parseISO))
    }

    // MARK: MR summary

    public func summarizeMR(_ item: FeedItem, force: Bool = false) async throws -> String {
        guard let gitlab, let pid = item["projectId"], let iid = item["iid"] else {
            throw HTTPError.notConfigured("GitLab is not configured")
        }
        let cacheKey = "mr.summary:\(item.id):\(item.updatedAt.map(Dates.iso) ?? "")"
        if !force, let cached = await store.cached(cacheKey) { return cached }

        let detail = try await gitlab.mergeRequest(projectId: pid, iid: iid)
        let diffs = try await gitlab.mergeRequestDiffs(projectId: pid, iid: iid)
        var diffText = ""
        let budget = 60_000
        for d in diffs {
            let header = "--- \(d.oldPath) → \(d.newPath)\(d.newFile == true ? " (new)" : "")\(d.deletedFile == true ? " (deleted)" : "")\n"
            if diffText.count + header.count + d.diff.count > budget {
                diffText += header + "[diff truncated]\n"
                continue
            }
            diffText += header + d.diff + "\n"
        }
        let prompt = """
        Summarize this merge request for me as the reviewer/manager. Structure:
        ## What it does — 2–4 bullets in plain language.
        ## Risk areas — concrete things that could break (migrations, concurrency, API/contract changes, config, missing tests). Say "None obvious" if so.
        ## Review focus — the files/functions worth reading closely and why.

        Title: \(detail.title)
        Author: \(detail.author?.name ?? item["authorName"] ?? "?")
        Branch: \(detail.sourceBranch ?? "?") → \(detail.targetBranch ?? "?")
        Description:
        \(String((detail.description ?? "(none)").prefix(4000)))

        Diff (\(diffs.count) files):
        \(diffText)
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "mr.summary"))
        await store.cache(cacheKey, r.text)
        return r.text
    }

    // MARK: Jira digest

    public func jiraDigest(key: String, force: Bool = false) async throws -> String {
        guard let jira else { throw HTTPError.notConfigured("Jira is not configured") }
        let issue = try await jira.issue(key: key)
        let comments = try await jira.comments(issueKey: key, max: 40)
        let cacheKey = "jira.digest:\(key):\(issue.fields.updated.map(Dates.iso) ?? "")"
        if !force, let cached = await store.cached(cacheKey) { return cached }

        let description = issue.renderedFields?["description"]?.stringValue.map { HTMLText.plain($0) }
            ?? ADF.plainText(issue.fields.description)
        let thread = comments.reversed().map {
            "[\($0.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")] \($0.author?.displayName ?? "?"): \(ADF.plainText($0.body))"
        }.joined(separator: "\n\n")
        let prompt = """
        Digest this Jira ticket for me. Structure:
        ## Current state — where it stands right now, in 2–3 sentences.
        ## Decisions made — bullets.
        ## Open questions / blockers — bullets, with who owns each if clear.
        ## Next action — the single most useful next step, and who should take it.

        \(issue.key): \(issue.fields.summary ?? "")
        Status: \(issue.fields.status?.name ?? "?") · Priority: \(issue.fields.priority?.name ?? "?") · Assignee: \(issue.fields.assignee?.displayName ?? "unassigned") · Reporter: \(issue.fields.reporter?.displayName ?? "?")

        Description:
        \(String(description.prefix(12_000)))

        Comments (oldest first):
        \(String(thread.suffix(40_000)))
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "jira.digest"))
        await store.cache(cacheKey, r.text)
        return r.text
    }
}
