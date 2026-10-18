import Foundation

/// AI features over work data: morning brief, MR/PR summary, Jira ticket digest.
public struct WorkAssistant: Sendable {
    let store: Store
    let claude: ClaudeRunning
    let codeHosts: [CodeHostClient]
    let jira: JiraClient?
    let content: AIContentPolicy

    public init(store: Store, claude: ClaudeRunning, codeHosts: [CodeHostClient], jira: JiraClient?, content: AIContentPolicy = AIContentPolicy()) {
        self.store = store
        self.claude = claude
        self.codeHosts = codeHosts
        self.jira = jira
        self.content = content
    }

    static let system = """
    You are the user's work assistant inside their personal dashboard app. Be concise and concrete. \
    Use short markdown: headings with ##, bullets with -, bold for names/IDs. No preamble, no sign-off.
    """

    // MARK: Morning brief

    public func morningBrief(now: Date = Date()) async throws -> String {
        let accounts = codeHosts.accounts
        let mine = try await CodeHosts.items(.mine, accounts: accounts, store: store)
        let review = try await CodeHosts.items(.review, accounts: accounts, store: store)
        let reportees = try await CodeHosts.items(.reportees, accounts: accounts, store: store)
        let todos = try await CodeHosts.items(.todos, accounts: accounts, store: store)
        let pipelines = try await CodeHosts.items(.pipelines, accounts: accounts, store: store, presentOnly: false)
            .filter { ($0.updatedAt ?? .distantPast) > now.addingTimeInterval(-86400) }
        let assigned = try await store.items(scopePrefix: JiraSource.Scope.assigned)
        let recentEvents = try await store.events(limit: 200).filter { $0.ts > now.addingTimeInterval(-86400) }
        func activity(_ e: AppEvent) -> String {
            // Jira comment/mention bodies are comment text; leave them out when Jira text is off.
            let withholdBody = !content.sendJiraText && [.jiraComment, .jiraMention].contains(e.category)
            return "- \(e.title)" + (withholdBody ? "" : " — \(e.body.replacingOccurrences(of: "\n", with: " "))")
        }

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

        ## My open MRs / PRs (\(mine.count))
        \(mine.map(mr).joined(separator: "\n"))

        ## MRs / PRs waiting for my review (\(review.count))
        \(review.map(mr).joined(separator: "\n"))

        ## My reportees' open MRs / PRs (\(reportees.count))
        \(reportees.map(mr).joined(separator: "\n"))

        ## Pending to-dos and notifications (\(todos.count))
        \(todos.prefix(30).map { "- \($0.subtitle): \($0.title)" }.joined(separator: "\n"))

        ## My pipelines / workflow runs in the last 24h
        \(pipelines.prefix(30).map { "- \($0.title) → \($0.status ?? "?") (\(Dates.age($0.updatedAt, now: now)) ago)" }.joined(separator: "\n"))

        ## Jira issues assigned to me (\(assigned.count))
        \(assigned.map(issue).joined(separator: "\n"))

        ## Activity in the last 24h
        \(recentEvents.prefix(60).map(activity).joined(separator: "\n"))
        """

        let prompt = """
        Write my morning work brief from this dashboard snapshot. Structure:
        ## Needs you today — the 3–7 most important actions, most urgent first (blocked reviews, red pipelines on my MRs, high-priority or due Jira issues).
        ## Your team — reportee MRs/PRs that look stuck (old, red pipeline, no approvals, waiting on review) and who might need a nudge.
        ## FYI — anything else notable, one line each.
        Skip empty sections. Reference GitLab MRs as project!iid, GitHub PRs as owner/repo#number, and issues by key.

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

    // MARK: MR / PR summary

    public func summarizeMR(_ item: FeedItem, force: Bool = false) async throws -> String {
        guard let host = codeHosts.client(for: item) else {
            throw HTTPError.notConfigured("The account for \(item.subtitle) is no longer configured")
        }
        let cacheKey = "mr.summary:\(item.id):\(item.updatedAt.map(Dates.iso) ?? "")" + (content.sendDiffs ? "" : ":nodiff")
        if !force, let cached = await store.cached(cacheKey) { return cached }

        let detail = try await host.changeDetail(item)
        let diffs = try await host.changeDiffs(item)
        let noun = host.account.kind == .gitlab ? "merge request" : "pull request"
        var diffText = ""
        let budget = 60_000
        for d in diffs {
            let header = "--- \(d.oldPath) → \(d.newPath)\(d.newFile ? " (new)" : "")\(d.deletedFile ? " (deleted)" : "")\n"
            if !content.sendDiffs {
                // File names and line counts only; no code leaves the Mac.
                let lines = d.diff.split(separator: "\n", omittingEmptySubsequences: false)
                let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                diffText += header.dropLast() + " (+\(added) −\(removed))\n"
                continue
            }
            if diffText.count + header.count + d.diff.count > budget {
                diffText += header + "[diff truncated]\n"
                continue
            }
            diffText += header + d.diff + "\n"
        }
        let prompt = """
        Summarize this \(noun) for me as the reviewer/manager. Structure:
        ## What it does — 2–4 bullets in plain language.
        ## Risk areas — concrete things that could break (migrations, concurrency, API/contract changes, config, missing tests). Say "None obvious" if so.
        ## Review focus — the files/functions worth reading closely and why.

        Title: \(detail.title)
        Author: \(detail.authorName ?? item["authorName"] ?? "?")
        Branch: \(detail.sourceBranch ?? "?") → \(detail.targetBranch ?? "?")
        Description:
        \(String((detail.description ?? "(none)").prefix(4000)))

        \(content.sendDiffs ? "Diff" : "Changed files (code withheld by the user's privacy settings; infer from names and sizes)") (\(diffs.count) files):
        \(diffText)
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "mr.summary",
                                                   people: [detail.authorName, item["authorName"]].compactMap { $0 }))
        await store.cache(cacheKey, r.text)
        return r.text
    }

    // MARK: Jira digest

    public func jiraDigest(key: String, force: Bool = false) async throws -> String {
        guard let jira else { throw HTTPError.notConfigured("Jira is not configured") }
        let issue = try await jira.issue(key: key)
        let comments = try await jira.comments(issueKey: key, max: 40)
        let cacheKey = "jira.digest:\(key):\(issue.fields.updated.map(Dates.iso) ?? "")" + (content.sendJiraText ? "" : ":notext")
        if !force, let cached = await store.cached(cacheKey) { return cached }

        let description = issue.renderedFields?["description"]?.stringValue.map { HTMLText.plain($0) }
            ?? ADF.plainText(issue.fields.description)
        let thread = comments.reversed().map {
            "[\($0.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")] \($0.author?.displayName ?? "?")"
                + (content.sendJiraText ? ": \(ADF.plainText($0.body))" : " commented")
        }.joined(separator: "\n\n")
        let withheld = "(withheld by the user's privacy settings)"
        let prompt = """
        Digest this Jira ticket for me. Structure:
        ## Current state — where it stands right now, in 2–3 sentences.
        ## Decisions made — bullets.
        ## Open questions / blockers — bullets, with who owns each if clear.
        ## Next action — the single most useful next step, and who should take it.

        \(issue.key): \(issue.fields.summary ?? "")
        Status: \(issue.fields.status?.name ?? "?") · Priority: \(issue.fields.priority?.name ?? "?") · Assignee: \(issue.fields.assignee?.displayName ?? "unassigned") · Reporter: \(issue.fields.reporter?.displayName ?? "?")

        Description:
        \(content.sendJiraText ? String(description.prefix(12_000)) : withheld)

        Comments (oldest first)\(content.sendJiraText ? "" : ", text " + withheld):
        \(String(thread.suffix(40_000)))
        """
        let people = [issue.fields.assignee?.displayName, issue.fields.reporter?.displayName].compactMap { $0 }
            + comments.compactMap { $0.author?.displayName }
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "jira.digest", people: people))
        await store.cache(cacheKey, r.text)
        return r.text
    }
}
