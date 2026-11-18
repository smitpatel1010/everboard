import Foundation

/// One reportee's current load and what may need a nudge, computed locally from data Everboard already polls.
public struct PersonLoad: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// Their open MRs/PRs.
    public var open: [FeedItem]
    /// Open MRs/PRs (anyone's) where they're a requested reviewer.
    public var reviewing: [FeedItem]
    /// Open longer than the aging threshold.
    public var aging: [FeedItem]
    /// Open with a failed pipeline / checks.
    public var red: [FeedItem]
    /// Open, not draft, no approval yet.
    public var waitingForReview: [FeedItem]
    /// Median hours their ready MRs/PRs have been waiting without an approval.
    public var medianReviewWaitHours: Double?
    /// Jira issues assigned to them that changed in the window (from your assigned list and filters).
    public var jiraMoved: [FeedItem]
    public var jiraDone: Int

    /// Simple load figure for sorting: authored + reviewing.
    public var load: Int { open.count + reviewing.count }

    /// Short reasons this person may need attention, most important first.
    public var flags: [String] {
        var f: [String] = []
        if !red.isEmpty { f.append("\(red.count) red") }
        if !aging.isEmpty { f.append("\(aging.count) aging") }
        if let h = medianReviewWaitHours, h > 24 { f.append("waiting ~\(TeamRadar.hours(h)) for review") }
        if reviewing.count >= 5 { f.append("\(reviewing.count) reviews queued") }
        return f
    }
}

public struct TeamRadar: Sendable, Codable {
    public var generatedAt: Date
    public var windowDays: Int
    public var agingDays: Double
    public var people: [PersonLoad]

    public init(generatedAt: Date, windowDays: Int, agingDays: Double, people: [PersonLoad]) {
        self.generatedAt = generatedAt
        self.windowDays = windowDays
        self.agingDays = agingDays
        self.people = people
    }

    /// - Parameters:
    ///   - changes: every open MR/PR you can see (mine, review, assigned, reportees), for reviewer counts.
    ///   - reporteeChanges: your reportees' open MRs/PRs.
    ///   - jira: Jira issue items from any list (assigned, done, filters).
    public static func compute(reportees: [Reportee], changes: [FeedItem], reporteeChanges: [FeedItem], jira: [FeedItem],
                               now: Date = Date(), agingDays: Double = 3, windowDays: Int = 7) -> TeamRadar {
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)
        let allChanges = unique(changes + reporteeChanges)
        let people = reportees.map { r -> PersonLoad in
            let handles = Set([r.username, r.githubUsername].compactMap { $0?.lowercased() })
            let names = handles.union([r.name?.lowercased()].compactMap { $0 })
            let open = unique(reporteeChanges.filter { handles.contains(($0.author ?? "").lowercased()) })
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            let reviewing = allChanges.filter { item in
                guard !handles.contains((item.author ?? "").lowercased()) else { return false }
                let reviewers = (item["reviewers"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                return reviewers.contains { names.contains($0) }
            }
            let aging = open.filter { now.timeIntervalSince($0.createdAt ?? now) > agingDays * 86400 }
            let red = open.filter { $0["pipelineStatus"] == "failed" }
            let waiting = open.filter { $0["draft"] != "1" && ($0["approvedBy"] ?? "").isEmpty }
            let waits = waiting.compactMap { $0.createdAt.map { now.timeIntervalSince($0) / 3600 } }
            let myJira = jira.filter { issue in
                guard let a = issue["assignee"]?.lowercased() else { return false }
                return names.contains(a) || (r.name.map { a == $0.lowercased() } ?? false)
            }
            let moved = unique(myJira.filter { ($0.updatedAt ?? .distantPast) >= since })
                .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return PersonLoad(id: r.id, name: r.name ?? r.username ?? r.githubUsername ?? r.email, open: open, reviewing: reviewing,
                              aging: aging, red: red, waitingForReview: waiting, medianReviewWaitHours: TeamMath.median(waits),
                              jiraMoved: moved, jiraDone: moved.filter { $0["statusCategory"] == "done" }.count)
        }
        return TeamRadar(generatedAt: now, windowDays: windowDays, agingDays: agingDays, people: people)
    }

    static func unique(_ items: [FeedItem]) -> [FeedItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func hours(_ h: Double) -> String { h < 48 ? String(format: "%.0fh", h) : String(format: "%.1fd", h / 24) }

    /// Markdown digest. `wikiLinks` writes people as `[[Name]]` (for the brain folder) instead of bold.
    public func digestMarkdown(wikiLinks: Bool = false) -> String {
        func person(_ n: String) -> String { wikiLinks ? NoteName.link(n) : "**\(n)**" }
        func change(_ i: FeedItem) -> String {
            let ref = i.url.map { "[\(i.subtitle)](\($0))" } ?? i.subtitle
            return "\(ref) \(i.title)"
        }
        var lines: [String] = []
        for p in people.sorted(by: { ($0.flags.count, $0.load) > ($1.flags.count, $1.load) }) {
            var parts = ["\(p.open.count) open"]
            if !p.reviewing.isEmpty { parts.append("reviewing \(p.reviewing.count)") }
            if let h = p.medianReviewWaitHours { parts.append("waiting for review ~\(Self.hours(h))") }
            if !p.jiraMoved.isEmpty { parts.append("Jira: \(p.jiraMoved.count) moved, \(p.jiraDone) done") }
            lines.append("- \(person(p.name)) — " + parts.joined(separator: " · ") + (p.flags.isEmpty ? "" : " — ⚠︎ " + p.flags.joined(separator: ", ")))
        }
        let attention = people.flatMap { p in
            Self.unique(p.red + p.aging).map { i -> String in
                var why: [String] = ["open \(Dates.age(i.createdAt, now: generatedAt))"]
                if i["pipelineStatus"] == "failed" { why.append("pipeline failed") }
                if (i["approvedBy"] ?? "").isEmpty, i["draft"] != "1" { why.append("no approval") }
                return "- \(change(i)) — \(person(p.name)), " + why.joined(separator: ", ")
            }
        }
        var out = "Team of \(people.count) · aging = open > \(Int(agingDays))d · Jira window \(windowDays)d\n\n" + lines.joined(separator: "\n")
        if !attention.isEmpty { out += "\n\n### Needs attention\n\n" + attention.joined(separator: "\n") }
        return out
    }
}

/// AI drafts for managers: 1:1 prep. Drafts only; nothing is sent anywhere.
public struct TeamService: Sendable {
    let store: Store
    let claude: ClaudeRunning
    let codeHosts: [CodeHostClient]

    public init(store: Store, claude: ClaudeRunning, codeHosts: [CodeHostClient]) {
        self.store = store
        self.claude = claude
        self.codeHosts = codeHosts
    }

    /// The radar from what's in the store right now.
    public func radar(reportees: [Reportee], agingDays: Double, now: Date = Date()) async throws -> TeamRadar {
        let accounts = codeHosts.accounts
        var changes: [FeedItem] = []
        for scope in [CodeScope.mine, .review, .assigned] {
            changes += try await CodeHosts.items(scope, accounts: accounts, store: store)
        }
        let reporteeChanges = try await CodeHosts.items(.reportees, accounts: accounts, store: store)
        let jira = try await store.items(scopePrefix: "jira.", presentOnly: false).filter { $0.kind.hasPrefix("issue.") }
        return TeamRadar.compute(reportees: reportees, changes: changes, reporteeChanges: reporteeChanges, jira: jira,
                                 now: now, agingDays: agingDays)
    }

    static let system = """
    You help an engineering manager prepare for 1:1s. Be specific and kind. Markdown with ## headings and - bullets. \
    Reference GitLab MRs as project!iid, GitHub PRs as owner/repo#number, and Jira issues by key. No preamble. \
    This is a private draft for the manager; never address the report directly.
    """

    /// A 1:1 prep draft for one person from the last `days` of their work, plus your own notes about them if given.
    public func oneOnOnePrep(_ person: Reportee, load: PersonLoad?, notes: String?, days: Int = 14, now: Date = Date()) async throws -> String {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        var merged: [ChangeRecord] = [], reviewed: [ChangeRecord] = []
        for host in codeHosts {
            guard let u = person.username(on: host.account.kind) else { continue }
            merged += (try? await host.changes(author: u, reviewer: nil, state: .merged, since: since, withSize: false)) ?? []
            reviewed += ((try? await host.changes(author: nil, reviewer: u, state: .all, since: since, withSize: false)) ?? [])
                .filter { $0.authorUsername != u }
        }
        let name = person.name ?? person.username ?? person.githubUsername ?? person.email
        func item(_ i: FeedItem) -> String {
            "- \(i.subtitle): \(i.title) · opened \(Dates.age(i.createdAt, now: now)) ago"
                + (i["pipelineStatus"].map { " · pipeline \($0)" } ?? "") + ((i["approvedBy"] ?? "").isEmpty ? " · no approval yet" : "")
        }
        let prompt = """
        Prepare my 1:1 with \(name). Sections:
        ## Wins to recognise — specific shipped work worth calling out.
        ## In flight — what they're carrying now, and anything that looks stuck.
        ## Where I can help — blockers, review waits, red pipelines, overload (lots of reviews), with one concrete offer each.
        ## Questions to ask — 3–5 open questions (growth, workload, blockers), not yes/no.
        \(notes == nil ? "" : "## Follow-ups from my notes — open threads from my own notes below.\n")
        Treat low activity neutrally (leave, design work, interviews); phrase concerns as questions.

        Merged in the last \(days) days (\(merged.count)):
        \(merged.map { "- \($0.ref): \($0.title)" }.joined(separator: "\n"))

        Reviews they gave (\(reviewed.count)):
        \(reviewed.prefix(30).map { "- \($0.ref): \($0.title) (by \($0.authorName ?? "?"))" }.joined(separator: "\n"))

        Open now (\(load?.open.count ?? 0)):
        \((load?.open ?? []).map(item).joined(separator: "\n"))

        Reviews waiting on them (\(load?.reviewing.count ?? 0)):
        \((load?.reviewing ?? []).map { "- \($0.subtitle): \($0.title)" }.joined(separator: "\n"))

        Jira issues that moved recently:
        \((load?.jiraMoved ?? []).map { "- \($0["key"] ?? $0.subtitle) [\($0.status ?? "")] \($0.title)" }.joined(separator: "\n"))
        \(notes.map { "\nMy own notes about \(name) (private, may be partial):\n\($0)" } ?? "")
        """
        let text = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, feature: "team.oneonone",
                                                      people: [name])).text
        await store.cache("team.oneonone.\(person.id)", text, now: now)
        await store.setValue("team.oneonone.\(person.id).at", Dates.iso(now))
        return text
    }

    public func latestPrep(_ person: Reportee) async -> (text: String, at: Date?)? {
        guard let text = await store.cached("team.oneonone.\(person.id)") else { return nil }
        return (text, await store.value("team.oneonone.\(person.id).at").flatMap(Dates.parseISO))
    }
}
