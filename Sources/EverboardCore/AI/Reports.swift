import Foundation

/// Per-person delivery metrics over a window (Swarmia/LinearB-style, from GitLab data only).
public struct PersonMetrics: Codable, Sendable, Identifiable, Hashable {
    public var username: String
    public var name: String
    public var merged: Int
    /// Median hours from MR opened → merged.
    public var medianCycleHours: Double?
    /// Median files changed per merged MR.
    public var medianSize: Double?
    public var open: Int
    public var oldestOpenDays: Double?
    public var openRed: Int
    public var reviewsGiven: Int
    public var id: String { username }

    public init(username: String, name: String, merged: Int, medianCycleHours: Double?, medianSize: Double?, open: Int,
                oldestOpenDays: Double?, openRed: Int, reviewsGiven: Int) {
        self.username = username
        self.name = name
        self.merged = merged
        self.medianCycleHours = medianCycleHours
        self.medianSize = medianSize
        self.open = open
        self.oldestOpenDays = oldestOpenDays
        self.openRed = openRed
        self.reviewsGiven = reviewsGiven
    }
}

public struct TeamHealth: Codable, Sendable {
    public var generatedAt: Date
    public var days: Int
    public var people: [PersonMetrics]
    public var commentary: String?

    public init(generatedAt: Date, days: Int, people: [PersonMetrics], commentary: String? = nil) {
        self.generatedAt = generatedAt
        self.days = days
        self.people = people
        self.commentary = commentary
    }
}

public enum TeamMath {
    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func metrics(username: String, name: String, merged: [GitLabMR], reviewed: [GitLabMR],
                               open: [FeedItem], now: Date = Date()) -> PersonMetrics {
        let cycles = merged.compactMap { mr -> Double? in
            guard let c = mr.createdAt, let m = mr.mergedAt else { return nil }
            return m.timeIntervalSince(c) / 3600
        }
        let sizes = merged.compactMap { $0.changesCount.flatMap { Double($0.replacingOccurrences(of: "+", with: "")) } }
        let ages = open.compactMap { $0.createdAt.map { now.timeIntervalSince($0) / 86400 } }
        return PersonMetrics(username: username, name: name, merged: merged.count,
                             medianCycleHours: median(cycles), medianSize: median(sizes), open: open.count,
                             oldestOpenDays: ages.max(), openRed: open.filter { $0["pipelineStatus"] == "failed" }.count,
                             reviewsGiven: reviewed.filter { $0.author?.username != username }.count)
    }
}

/// Standup, weekly report and team health — GitLab + Jira data, written up by Claude.
public struct ReportService: Sendable {
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
    You write concise engineering status updates. Plain, specific, no fluff. Markdown with ## headings and - bullets. \
    Reference MRs as project!iid and Jira issues by key. No preamble.
    """

    private func me() async throws -> GitLabUser {
        guard let gitlab else { throw HTTPError.notConfigured("GitLab is not configured") }
        if let json = await store.value("gitlab.me"), let u = try? JSONDecoder().decode(GitLabUser.self, from: Data(json.utf8)) { return u }
        return try await gitlab.currentUser()
    }

    // MARK: Team health

    public func teamHealth(reportees: [Reportee], days: Int = 7, now: Date = Date()) async throws -> TeamHealth {
        guard let gitlab else { throw HTTPError.notConfigured("GitLab is not configured") }
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let open = try await store.items(scope: GitLabSource.Scope.reportees)
        var people: [PersonMetrics] = []
        for r in reportees {
            guard let u = r.username else { continue }
            let merged = try await gitlab.mergeRequests(author: u, state: "merged", updatedAfter: since)
                .filter { ($0.mergedAt ?? .distantPast) >= since }
            // Sizes need one call per MR; cap it.
            var sized: [GitLabMR] = []
            for mr in merged.prefix(25) { sized.append((try? await gitlab.mergeRequestStats(projectId: mr.projectId, iid: mr.iid)) ?? mr) }
            sized += merged.dropFirst(25)
            let reviewed = (try? await gitlab.mergeRequests(reviewer: u, state: "all", updatedAfter: since)) ?? []
            people.append(TeamMath.metrics(username: u, name: r.name ?? u, merged: sized, reviewed: reviewed,
                                           open: open.filter { $0.author == u }, now: now))
        }
        let health = TeamHealth(generatedAt: now, days: days, people: people.sorted { $0.name < $1.name })
        try await save(health)
        return health
    }

    public func commentary(on health: TeamHealth) async throws -> TeamHealth {
        let rows = health.people.map { p in
            "- \(p.name): merged \(p.merged), median cycle \(p.medianCycleHours.map { String(format: "%.0fh", $0) } ?? "-"), "
                + "median size \(p.medianSize.map { String(format: "%.0f files", $0) } ?? "-"), open \(p.open) "
                + "(oldest \(p.oldestOpenDays.map { String(format: "%.0fd", $0) } ?? "-"), red \(p.openRed)), reviews given \(p.reviewsGiven)"
        }.joined(separator: "\n")
        let prompt = """
        As my engineering-manager assistant, interpret my team's last \(health.days) days of GitLab metrics.
        ## Highlights — who shipped well. ## Watch — anyone stuck (old/red open MRs, long cycle times, very large MRs, no reviews given), with a concrete suggestion for each. ## Team trend — one or two lines.
        Be fair: low numbers can mean vacation or big design work; phrase as questions to ask, not judgements.

        \(rows)
        """
        var h = health
        h.commentary = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "team.commentary")).text
        try await save(h)
        return h
    }

    public func latestTeamHealth() async -> TeamHealth? {
        guard let json = await store.cached("team.health.latest") else { return nil }
        return try? JSONDecoder.everboard.decode(TeamHealth.self, from: Data(json.utf8))
    }

    private func save(_ h: TeamHealth) async throws {
        await store.cache("team.health.latest", String(decoding: try JSONEncoder.everboard.encode(h), as: UTF8.self))
    }

    // MARK: Standup & weekly report

    public func standup(now: Date = Date()) async throws -> String {
        guard let gitlab else { throw HTTPError.notConfigured("GitLab is not configured") }
        let user = try await me()
        // Since the previous working day's start (Monday → Friday).
        var since = Calendar.current.startOfDay(for: now.addingTimeInterval(-86400))
        while Calendar.current.isDateInWeekend(since) { since = since.addingTimeInterval(-86400) }

        let merged = try await gitlab.mergeRequests(author: user.username, state: "merged", updatedAfter: since)
        let reviewed = try await gitlab.mergeRequests(reviewer: user.username, state: "all", updatedAfter: since)
            .filter { $0.author?.username != user.username }
        let openMine = try await store.items(scope: GitLabSource.Scope.mine)
        let jiraDone = (try? await jira?.search("assignee = currentUser() AND updated >= \"\(jqlDate(since))\" ORDER BY updated DESC", max: 30)) ?? []
        let jiraNow = try await store.items(scope: JiraSource.Scope.assigned)

        let prompt = """
        Write my daily standup update (I'll paste it into team chat). Sections: ## Yesterday ## Today ## Blockers (say "None" if none).
        Keep each bullet short. Infer "Today" from open MRs and in-progress Jira issues. A red pipeline or an MR waiting a long time for review is a possible blocker.

        Merged since \(since.formatted(date: .abbreviated, time: .omitted)):
        \(merged.map { "- \($0.ref): \($0.title)" }.joined(separator: "\n"))

        Reviewed for others:
        \(reviewed.map { "- \($0.ref): \($0.title) (by \($0.author?.name ?? "?"))" }.joined(separator: "\n"))

        Jira issues I touched:
        \(jiraDone.map { "- \($0.key) [\($0.fields.status?.name ?? "")] \($0.fields.summary ?? "")" }.joined(separator: "\n"))

        My open MRs:
        \(openMine.map { "- \($0.subtitle): \($0.title) · pipeline \($0["pipelineStatus"] ?? "-") · opened \(Dates.age($0.createdAt, now: now)) ago" }.joined(separator: "\n"))

        Jira assigned to me now:
        \(jiraNow.map { "- \($0["key"] ?? "") [\($0.status ?? "")] \($0.title)" }.joined(separator: "\n"))
        """
        let text = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "report.standup")).text
        await store.cache("report.standup.latest", text)
        await store.setValue("report.standup.at", Dates.iso(now))
        return text
    }

    public func weeklyReport(reportees: [Reportee], now: Date = Date()) async throws -> String {
        guard let gitlab else { throw HTTPError.notConfigured("GitLab is not configured") }
        let user = try await me()
        let since = now.addingTimeInterval(-7 * 86400)
        var sections: [String] = []
        let people = [(user.username, "Me (\(user.name))")] + reportees.compactMap { r in r.username.map { ($0, r.name ?? $0) } }
        for (username, label) in people {
            let merged = try await gitlab.mergeRequests(author: username, state: "merged", updatedAfter: since)
                .filter { ($0.mergedAt ?? .distantPast) >= since }
            let opened = try await gitlab.mergeRequests(author: username, state: "opened", updatedAfter: since)
            sections.append("""
            ### \(label)
            Merged (\(merged.count)):
            \(merged.map { "- \($0.ref): \($0.title)" }.joined(separator: "\n"))
            Still open (\(opened.count)):
            \(opened.map { "- \($0.ref): \($0.title) (opened \(Dates.age($0.createdAt, now: now)) ago)" }.joined(separator: "\n"))
            """)
        }
        var jiraText = ""
        if let jira {
            var ids: [String] = []
            for r in reportees {
                let key = "jira.account.\(r.id)"
                if let id = await store.value(key) { ids.append(id); continue }
                if let u = try? await jira.findUser(email: r.email) { await store.setValue(key, u.accountId); ids.append(u.accountId) }
            }
            let who = (["currentUser()"] + ids.map { "\"\($0)\"" }).joined(separator: ", ")
            let resolved = (try? await jira.search("assignee in (\(who)) AND resolved >= -7d ORDER BY resolved DESC", max: 80)) ?? []
            jiraText = resolved.map { "- \($0.key) \($0.fields.summary ?? "") — \($0.fields.assignee?.displayName ?? "?")" }.joined(separator: "\n")
        }
        let prompt = """
        Write my weekly engineering report for my manager. Sections:
        ## Summary — 3–4 sentences on what the team delivered and its impact.
        ## Shipped — grouped by theme, not by person, mentioning who did what.
        ## In progress — notable open work and expected next steps.
        ## Risks & asks — blockers, stuck work, help needed (or "None").

        Week ending \(now.formatted(date: .abbreviated, time: .omitted)).

        \(sections.joined(separator: "\n\n"))

        Jira resolved this week:
        \(jiraText)
        """
        let text = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "report.weekly")).text
        await store.cache("report.weekly.latest", text)
        await store.setValue("report.weekly.at", Dates.iso(now))
        return text
    }

    public func latest(_ kind: String) async -> (text: String, at: Date?)? {
        guard let text = await store.cached("report.\(kind).latest") else { return nil }
        return (text, await store.value("report.\(kind).at").flatMap(Dates.parseISO))
    }

    private func jqlDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
