import Foundation
import Testing
@testable import EverboardCore

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("everboard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct CustomSourceTests {
    let feed = CustomSourceConfig(id: "deploys", name: "Deploys", kind: .command, notifyNew: true, notifyStatus: false)

    @Test func parsesArrayAndEnvelope() throws {
        let array = #"[{"id": 1, "title": "Deploy web", "status": "running", "updatedAt": "2026-11-01T10:00:00Z", "attrs": {"env": "prod", "n": 3, "ok": true}},"#
            + #" {"title": "no id"}, {"id": "1", "title": "dupe"}, {"id": "x", "title": "T", "createdAt": 1767225600}]"#
        let out = try CustomFeedParser.parse(Data(array.utf8), source: feed)
        #expect(out.items.map(\.id) == ["custom.deploys:1", "custom.deploys:x"])
        #expect(out.skipped == 1)
        #expect(out.mode == .replace)
        let first = out.items[0]
        #expect(first.source == "custom")
        #expect(first.subtitle == "Deploys")
        #expect(first.attrs["env"] == "prod" && first.attrs["n"] == "3" && first.attrs["ok"] == "true" && first.attrs["feed"] == "deploys")
        #expect(first.updatedAt == Dates.parseISO("2026-11-01T10:00:00Z"))
        #expect(out.items[1].createdAt == Date(timeIntervalSince1970: 1_767_225_600))

        let envelope = try CustomFeedParser.parse(Data(#"{"mode": "accumulate", "items": [{"id": "a", "title": "A"}]}"#.utf8), source: feed)
        #expect(envelope.mode == .accumulate && envelope.items.count == 1)

        #expect(throws: CustomFeedParser.ParseError.self) { try CustomFeedParser.parse(Data("hello".utf8), source: feed) }
        #expect(throws: CustomFeedParser.ParseError.self) { try CustomFeedParser.parse(Data(#"{"x": 1}"#.utf8), source: feed) }
    }

    @Test func commandSourceThroughTheEngine() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("out.json")
        func write(_ json: String) throws { try json.write(to: file, atomically: true, encoding: .utf8) }
        var config = feed
        config.command = "cat '\(file.path)'"
        let source = CommandSource(config: config)
        let store = try Store.inMemory()
        func poll() async throws -> [AppEvent] {
            let results = try await source.fetch(context: StoreFetchContext(store: store, config: AppConfig()))
            return try await Engine.process(source: source, results: results, store: store, config: AppConfig())
        }
        try write(#"[{"id": "1", "title": "Deploy web", "status": "running"}]"#)
        #expect(try await poll().isEmpty)                                    // baseline
        try write(#"[{"id": "1", "title": "Deploy web", "status": "failed"}, {"id": "2", "title": "Deploy api"}]"#)
        let events = try await poll()
        #expect(Set(events.map(\.id)) == ["custom.status:custom.deploys:1:failed", "custom.new:custom.deploys:2"])
        #expect(events.first { $0.category == .customStatus }?.wantsNotification == false)
        #expect(events.first { $0.category == .customNew }?.wantsNotification == true)
        #expect(try await poll().isEmpty)                                    // deduplicated
        #expect(try await store.items(scope: config.scope).count == 2)

        config.command = "echo nope; exit 2"
        await #expect(throws: Error.self) { try await CommandSource(config: config).fetch(context: StoreFetchContext(store: store, config: AppConfig())) }
    }

    @Test func folderSourceReadsNotes() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "---\ntitle: Launch plan\nstatus: in progress\ntags: [project, q4]\nurl: https://example.com/p\n---\nBody".write(
            to: dir.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try "# Retro notes\n\ntext".write(to: dir.appendingPathComponent("sub/retro.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent(".obsidian/x.md"), atomically: true, encoding: .utf8)
        try "not markdown".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let all = try FolderSource(config: CustomSourceConfig(id: "vault", name: "Vault", kind: .folder, folder: dir.path)).items()
            .sorted { $0.id < $1.id }
        #expect(all.map(\.id) == ["custom.vault:plan.md", "custom.vault:sub/retro.md"])
        #expect(all[0].title == "Launch plan" && all[0].status == "in progress" && all[0].url == "https://example.com/p")
        #expect(all[0].attrs["tags"] == "project, q4")
        #expect(all[1].title == "Retro notes" && all[1].subtitle == "sub")

        let tagged = try FolderSource(config: CustomSourceConfig(id: "vault", name: "Vault", kind: .folder, folder: dir.path, tag: "#Q4")).items()
        #expect(tagged.map(\.title) == ["Launch plan"])

        #expect(throws: Error.self) {
            try FolderSource(config: CustomSourceConfig(id: "v", name: "V", kind: .folder, folder: dir.appendingPathComponent("nope").path)).items()
        }
    }

    @Test func slugs() {
        #expect(CustomSourceConfig.slug("My Deploys (prod)!") == "my-deploys-prod")
        #expect(CustomSourceConfig.slug("  ") == "feed")
    }
}

@Suite struct MarkdownTests {
    @Test func frontmatterRoundTrip() {
        let note = "---\ntitle: \"Plan: v2\"\nstatus: open\ntags:\n  - a\n  - b\n---\n# Body\n"
        let (fields, body) = Frontmatter.parse(note)
        #expect(fields["title"] == "Plan: v2")
        #expect(fields["status"] == "open")
        #expect(fields["tags"] == "a, b")
        #expect(body == "# Body\n")
        #expect(Frontmatter.parse("no frontmatter").fields.isEmpty)
        let rendered = Frontmatter.render([("title", "He said \"hi\""), ("tags", "x, y")])
        #expect(rendered == "---\ntitle: \"He said \\\"hi\\\"\"\ntags: [\"x\", \"y\"]\n---\n")
        #expect(Frontmatter.parse(rendered).fields["title"] == "He said \"hi\"")
    }

    @Test func managedBlocksNeverTouchYourText() {
        let mine = "# 2026-11-18\n\nMy own thoughts.\n"
        let once = ManagedBlock.upsert(mine, id: "work-brief", content: "brief v1")
        #expect(once.hasPrefix(mine.trimmingCharacters(in: .newlines)))
        #expect(ManagedBlock.content(once, id: "work-brief") == "brief v1")
        let edited = once + "\nMore of my text.\n"
        let twice = ManagedBlock.upsert(edited, id: "work-brief", content: "brief v2")
        #expect(twice.contains("My own thoughts.") && twice.contains("More of my text."))
        #expect(ManagedBlock.content(twice, id: "work-brief") == "brief v2")
        #expect(!twice.contains("brief v1"))
        let stripped = ManagedBlock.stripAll(ManagedBlock.upsert(twice, id: "team", content: "digest"))
        #expect(!stripped.contains("brief v2") && !stripped.contains("digest") && stripped.contains("More of my text."))
    }

    @Test func noteNames() {
        #expect(NoteName.safe("acme/app!12: fix [retries]?") == "acme app!12 fix retries")
        #expect(NoteName.safe("../..") == "Untitled")
        #expect(NoteName.link("Asha K") == "[[Asha K]]")
    }
}

@Suite struct BrainTests {
    func brain(_ dir: URL) -> Brain {
        var s = BrainSettings()
        s.folder = dir.path
        return Brain(settings: s)!
    }

    @Test func offWithoutFolder() {
        #expect(Brain(settings: BrainSettings()) == nil)
    }

    @Test func refusesToLeaveTheFolder() throws {
        let dir = try tempDir()
        let b = brain(dir)
        #expect(throws: BrainError.self) { try b.url("../outside.md") }
        #expect(throws: BrainError.self) { try b.url("Daily/../../outside.md") }
        // A symlinked subfolder pointing elsewhere is refused too.
        let elsewhere = try tempDir()
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: elsewhere)
        #expect(throws: BrainError.self) { try b.url("link/x.md") }
        #expect(try b.url("Daily/2026-11-18.md").path.hasSuffix("/Daily/2026-11-18.md"))
    }

    @Test func dailyAndPersonNotes() throws {
        let dir = try tempDir()
        let b = brain(dir)
        let day = Dates.parseISO("2026-11-18T09:00:00Z")!
        try b.writeDailySection("work-brief", heading: "Work brief", markdown: "- do things", date: day)
        let path = b.dailyPath(day)
        #expect(path.hasPrefix("Daily/2026-11-1"))
        var note = b.read(path)!
        #expect(note.hasPrefix("---\ntype: \"daily\"\ndate: 2026-11-18\n"))
        #expect(Frontmatter.parse(note).fields["updated"] != nil)
        #expect(note.contains("## Work brief"))
        // You write in it; the next brief only replaces Everboard's block.
        try (note + "\nMy notes.\n").write(to: b.url(path), atomically: true, encoding: .utf8)
        try b.writeDailySection("work-brief", heading: "Work brief", markdown: "- new things", date: day)
        note = b.read(path)!
        #expect(note.contains("My notes.") && note.contains("- new things") && !note.contains("- do things"))
        #expect(b.recentDailyContext(days: 1, now: day)?.contains("My notes.") == true)
        #expect(b.recentDailyContext(days: 1, now: day)?.contains("new things") == false)

        try "---\ntags: [person]\n---\n# Asha K\n\nWants to lead the migration.\n".write(
            to: dir.appendingPathComponent("People", isDirectory: true).appendingPathComponent("Asha K.md").creatingParent(),
            atomically: true, encoding: .utf8)
        let asha = BrainPerson(name: "Asha K", username: "asha")
        #expect(try b.writeOneOnOnePrep(asha, markdown: "- ask about it", date: day) == "People/Asha K.md")
        let person = b.read(b.personPath(asha))!
        #expect(person.contains("Wants to lead the migration.") && person.contains("- ask about it"))
        #expect(person.hasPrefix("---\ntags: [person]\n---\n"))  // no `updated` field to bump, so the frontmatter is untouched
        #expect(b.personContext(asha, through: day) == "# Asha K\n\nWants to lead the migration.")
        #expect(b.personContext(BrainPerson(name: "Nobody")) == nil)
    }

    @Test func agentRunNotesAreNeverOverwritten() throws {
        let dir = try tempDir()
        let b = brain(dir)
        var run = AgentRun(ts: Dates.parseISO("2026-11-18T09:00:00Z")!, actionId: "a", actionName: "Review", itemId: "i", itemTitle: "Fix retries",
                           itemRef: "acme/app!12", itemUrl: "https://example.com/12", command: "claude -p x", workingDirectory: "/tmp",
                           status: .succeeded, output: "Looks fine.")
        let first = try b.writeAgentRun(run)
        let second = try b.writeAgentRun(run)
        #expect(first != second)
        #expect(second.hasSuffix(" 2.md"))
        #expect(b.read(first)?.contains("Looks fine.") == true)
        #expect(Frontmatter.parse(b.read(first)!).fields["item"] == "acme/app!12")
        run.notePath = first
        try b.writeAgentRunIndex([run], date: run.ts)
        #expect(b.read(b.dailyPath(run.ts))?.contains("[[\(URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent)|Review: acme/app!12]]") == true)
    }

    /// A vault that names people by username, keeps one note per 1:1, and tracks `updated` in frontmatter.
    @Test func usernameNotesAndOneOnOneFolder() throws {
        let dir = try tempDir()
        var s = BrainSettings()
        s.folder = dir.path
        s.peopleNoteName = .username
        s.oneOnOneFolder = "Meetings/1-1"
        let b = Brain(settings: s)!
        let asha = BrainPerson(name: "Asha K", username: "asha.k")
        #expect(b.personPath(asha) == "People/asha.k.md")
        #expect(b.personLink(asha) == "[[asha.k|Asha K]]")
        #expect(b.personLink(BrainPerson(name: "Bob")) == "[[Bob]]")  // no username known: falls back to the name

        func write(_ text: String, _ path: String) throws {
            try text.write(to: dir.appendingPathComponent(path).creatingParent(), atomically: true, encoding: .utf8)
        }
        try write("---\ntype: person\nupdated: 2026-01-02\n---\n# Asha K\n\nWants to lead the migration.\n", "People/asha.k.md")
        try write("---\ntype: one-on-one\n---\n# 1:1\n\nFollow up on the on-call rota.\n", "Meetings/1-1/asha.k/2026-11-04.md")
        try write("Older notes.\n", "Meetings/1-1/asha.k/2026-10-21.md")
        try write("Someone else.\n", "Meetings/1-1/vik/2026-11-05.md")
        try write("Not a 1:1.\n", "Meetings/1-1/asha.k/agenda.md")

        let day = Dates.parseISO("2026-11-18T09:00:00Z")!
        // A note started that day (by you or another tool) keeps its text; Everboard adds its own section.
        try write("# My prep\n\nAsk about growth.\n", "Meetings/1-1/asha.k/2026-11-18.md")
        #expect(try b.writeOneOnOnePrep(asha, markdown: "- wins", date: day) == "Meetings/1-1/asha.k/2026-11-18.md")
        let today = b.read("Meetings/1-1/asha.k/2026-11-18.md")!
        #expect(today.contains("Ask about growth.") && today.contains("- wins"))
        // A fresh day gets a new note with vault-style frontmatter.
        let next = try b.writeOneOnOnePrep(asha, markdown: "- more wins", date: day.addingTimeInterval(86400 * 7))
        #expect(next == "Meetings/1-1/asha.k/2026-11-25.md")
        let fields = Frontmatter.parse(b.read(next)!).fields
        #expect(fields["type"] == "one-on-one" && fields["person"] == "asha.k" && fields["date"] == "2026-11-25" && fields["updated"] != nil)
        #expect(b.read(next)!.contains("# 1:1 with [[asha.k|Asha K]], 2026-11-25"))
        #expect(b.read(b.personPath(asha))!.contains("updated: 2026-01-02"))  // person note untouched in this layout

        #expect(b.recentOneOnOnes(asha, through: day) == ["Meetings/1-1/asha.k/2026-11-18.md", "Meetings/1-1/asha.k/2026-11-04.md",
                                                          "Meetings/1-1/asha.k/2026-10-21.md"])
        let context = b.personContext(asha, through: day)!
        #expect(context.hasPrefix("# Asha K\n\nWants to lead the migration."))
        #expect(context.contains("Ask about growth.") && context.contains("Follow up on the on-call rota."))
        #expect(!context.contains("- wins") && !context.contains("Older notes.") && !context.contains("Someone else."))

        // Writing a section into a note that tracks `updated` bumps only that field.
        try b.writePersonSection(asha, block: "x", heading: "X", markdown: "- y", date: day)
        let note = b.read(b.personPath(asha))!
        #expect(note.hasPrefix("---\ntype: person\nupdated: \(Brain.format(Date(), "yyyy-MM-dd"))\n---\n"))
    }

    /// Other layouts work through the name format, for writing and for finding past notes.
    @Test func oneOnOneNameFormats() throws {
        let dir = try tempDir()
        var s = BrainSettings()
        s.folder = dir.path
        s.oneOnOneFolder = "1-1"
        s.oneOnOneNameFormat = "{date} {person}"
        let b = Brain(settings: s)!
        let asha = BrainPerson(name: "Asha K")
        let day = Dates.parseISO("2026-11-18T09:00:00Z")!
        #expect(b.oneOnOnePath(asha, date: day) == "1-1/2026-11-18 Asha K.md")
        try "Old.\n".write(to: dir.appendingPathComponent("1-1/2026-11-04 Asha K.md").creatingParent(), atomically: true, encoding: .utf8)
        try "Not hers.\n".write(to: dir.appendingPathComponent("1-1/2026-11-05 Asha Kumar.md"), atomically: true, encoding: .utf8)
        #expect(b.recentOneOnOnes(asha, through: day) == ["1-1/2026-11-04 Asha K.md"])
        // A format without both placeholders falls back to the default rather than writing one note over another.
        s.oneOnOneNameFormat = "{person}"
        #expect(Brain(settings: s)!.oneOnOnePath(asha, date: day) == "1-1/Asha K/2026-11-18.md")
    }

    @Test func usernameFallsBackToGitHubLogin() {
        #expect(Reportee(email: "a@example.com", username: "asha", githubUsername: "asha-gh", name: "Asha K").brainPerson.username == "asha")
        #expect(Reportee(email: "a@example.com", githubUsername: "asha-gh", name: "Asha K").brainPerson.username == "asha-gh")
        #expect(Reportee(email: "a@example.com", name: "Asha K").brainPerson.username == nil)
    }

    @Test func weeklyPathIsISOWeek() throws {
        let b = brain(try tempDir())
        #expect(b.weeklyPath(Dates.parseISO("2026-11-18T12:00:00Z")!) == "Weekly/2026-W47.md")
    }
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

@Suite struct TeamRadarTests {
    let now = Date()
    let team = [Reportee(email: "asha@example.com", username: "asha", githubUsername: "asha-k", name: "Asha K"),
                Reportee(email: "vik@example.com", username: "vik", name: "Vikram P")]

    func mr(_ id: String, author: String, days: Double, pipeline: String? = nil, approved: String? = nil, draft: Bool = false,
            reviewers: String? = nil) -> FeedItem {
        var attrs: [String: String] = [:]
        attrs["pipelineStatus"] = pipeline
        attrs["approvedBy"] = approved
        attrs["reviewers"] = reviewers
        if draft { attrs["draft"] = "1" }
        return FeedItem(id: id, source: "gitlab", kind: "mr.reportee", title: "MR \(id)", subtitle: "acme/app !\(id)",
                        url: "https://example.com/\(id)", author: author, createdAt: now.addingTimeInterval(-days * 86400), attrs: attrs)
    }

    @Test func perPersonLoad() {
        let reportee = [
            mr("1", author: "asha", days: 5, pipeline: "failed"),
            mr("2", author: "asha-k", days: 1, approved: "Vikram P"),
            mr("3", author: "asha", days: 0.5, draft: true),
            mr("4", author: "vik", days: 2, reviewers: "Asha K, Someone"),
        ]
        let others = [mr("9", author: "me", days: 1, reviewers: "asha"), mr("4", author: "vik", days: 2, reviewers: "Asha K")]
        let jira = [
            FeedItem(id: "j1", source: "jira", kind: "issue.filter", title: "T", updatedAt: now.addingTimeInterval(-86400),
                     attrs: ["assignee": "Asha K", "statusCategory": "done"]),
            FeedItem(id: "j2", source: "jira", kind: "issue.filter", title: "U", updatedAt: now.addingTimeInterval(-20 * 86400),
                     attrs: ["assignee": "Asha K"]),
        ]
        let radar = TeamRadar.compute(reportees: team, changes: others, reporteeChanges: reportee, jira: jira, now: now, agingDays: 3)
        let asha = radar.people[0], vik = radar.people[1]
        #expect(asha.open.map(\.id) == ["1", "2", "3"])          // oldest first, both hosts
        #expect(asha.aging.map(\.id) == ["1"])
        #expect(asha.red.map(\.id) == ["1"])
        #expect(asha.waitingForReview.map(\.id) == ["1"])         // 2 is approved, 3 is a draft
        #expect(asha.reviewing.map(\.id).sorted() == ["4", "9"])  // by name and by username, deduplicated
        #expect(asha.jiraMoved.map(\.id) == ["j1"] && asha.jiraDone == 1)
        #expect(asha.flags.contains("1 red") && asha.flags.contains("1 aging"))
        #expect((asha.medianReviewWaitHours ?? 0) > 119)
        #expect(vik.open.map(\.id) == ["4"] && vik.reviewing.isEmpty)

        let digest = radar.digestMarkdown { "[[\($0.id)|\($0.name)]]" }
        #expect(digest.contains("[[\(asha.id)|Asha K]]"))
        #expect(digest.contains("### Needs attention"))
        #expect(digest.contains("[acme/app !1](https://example.com/1)"))
        #expect(radar.digestMarkdown().contains("**Asha K**"))
    }
}

@Suite struct ExtensionConfigTests {
    @Test func oldConfigStillDecodes() throws {
        let c = try JSONDecoder.everboard.decode(AppConfig.self, from: Data(#"{"gitlabInterval": 90}"#.utf8))
        #expect(c.gitlabInterval == 90)
        #expect(c.agentActions.isEmpty && c.customSources.isEmpty && !c.brain.isEnabled && c.agentRunDays == 30)
    }

    @Test func oneBadEntryDoesNotDropTheList() throws {
        let json = #"""
        {"agentActions": [{"name": "Review", "command": "claude -p {url}"}, {"name": "broken"}],
         "customSources": [{"id": "x", "kind": "folder", "folder": "~/notes"}, {"name": "no id"}],
         "brain": {"folder": "~/vault", "readForAI": true}}
        """#
        let c = try JSONDecoder.everboard.decode(AppConfig.self, from: Data(json.utf8))
        #expect(c.agentActions.map(\.name) == ["Review"])
        #expect(c.agentActions[0].targets == [.change] && c.agentActions[0].confirm)
        #expect(c.customSources.map(\.id) == ["x"] && c.customSources[0].name == "x")
        #expect(c.brain.isEnabled && c.brain.readForAI && c.brain.dailyFolder == "Daily")
    }

    @Test func examplesUseOnlyKnownPlaceholders() {
        for e in AgentAction.examples { #expect(AgentTemplate.unknown(in: e.command + e.workingDirectory).isEmpty) }
    }
}
