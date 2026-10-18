import Foundation
import Testing
@testable import EverboardCore

@Suite struct SecretsTests {
    @Test func parsesDotenv() {
        let v = Secrets.parse("""
        # comment
        export GITLAB_URL=https://gl.example/
        GITLAB_TOKEN="glpat-abc"
        JIRA_EMAIL='me@x.com'
        JIRA_API_TOKEN=tok # trailing comment
        EMPTY=              # just a comment
        NOEQUALS
        """)
        #expect(v["GITLAB_URL"] == "https://gl.example/")
        #expect(v["GITLAB_TOKEN"] == "glpat-abc")
        #expect(v["JIRA_EMAIL"] == "me@x.com")
        #expect(v["JIRA_API_TOKEN"] == "tok")
        #expect(v["EMPTY"] == "")
        #expect(v["NOEQUALS"] == nil)
    }

    @Test func emptyValuesAreMissingAndEnvFillsGaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("secrets.env")
        try "GITLAB_URL=https://gl.example/\nGITLAB_TOKEN=\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let s = Secrets.load(path: file, environment: ["JIRA_URL": "https://x.atlassian.net", "GITLAB_URL": "ignored"])
        #expect(s[.gitlabURL] == "https://gl.example/")   // the file wins over the environment
        #expect(s[.gitlabToken] == nil)
        #expect(!s.hasCodeHost)
        #expect(s[.jiraURL] == "https://x.atlassian.net")
        // Over-permissive file is tightened automatically.
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test func plainHTTPEndpointsAreRejected() {
        let s = Secrets(values: ["GITLAB_URL": "http://gitlab.corp", "GITLAB_TOKEN": "t", "JIRA_URL": "http://localhost:8080"])
        #expect(!s.hasCodeHost)
        #expect(s.jiraBaseURL != nil) // localhost allowed for testing
    }

    @Test func secretsLocationPrefersEnvThenProjectThenConfigDir() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("checkout"), xdg = root.appendingPathComponent("xdg")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let env = ["XDG_CONFIG_HOME": xdg.path]
        let configFile = xdg.appendingPathComponent("everboard/secrets.env")

        // Nothing exists and no Package.swift (installed app): the config dir is the default.
        #expect(AppInfo.secretsURL(environment: env, projectRoot: project) == configFile)
        // Source checkout: the project file is the default.
        try "".write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        #expect(AppInfo.secretsURL(environment: env, projectRoot: project).lastPathComponent == "secrets.env")
        #expect(AppInfo.secretsURL(environment: env, projectRoot: project).deletingLastPathComponent().lastPathComponent == "checkout")
        // An existing config-dir file beats the not-yet-created project one.
        try fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: configFile, atomically: true, encoding: .utf8)
        #expect(AppInfo.secretsURL(environment: env, projectRoot: project) == configFile)
        // $EVERBOARD_SECRETS always wins.
        let custom = AppInfo.secretsURL(environment: env.merging(["EVERBOARD_SECRETS": "/tmp/mine.env"]) { $1 }, projectRoot: project)
        #expect(custom.path == "/tmp/mine.env")
    }

    @Test func templateParsesToNothingConfigured() {
        let s = Secrets(values: Secrets.parse(Secrets.template))
        #expect(!s.hasCodeHost)
        #expect(!s.hasJira)
    }
}

@Suite struct ConfigTests {
    @Test func lenientDecodingKeepsDefaults() throws {
        let json = #"{"reportees":[{"email":"a@b.com"}],"gitlabInterval":90,"unknownKey":true}"#
        let c = try JSONDecoder.everboard.decode(AppConfig.self, from: Data(json.utf8))
        #expect(c.reportees.first?.email == "a@b.com")
        #expect(c.gitlabInterval == 90)
        #expect(c.jiraInterval == 120)
        #expect(c.newsSources.count == NewsSource.defaults.count)
    }

    @Test func mutingExpires() {
        var c = AppConfig()
        c.mutedItems["a"] = Date().addingTimeInterval(60)
        c.mutedItems["b"] = Date().addingTimeInterval(-60)
        #expect(c.isMuted("a"))
        #expect(!c.isMuted("b"))
        #expect(!c.isMuted(nil))
    }
}

@Suite struct TextTests {
    @Test func htmlToPlain() {
        let s = HTMLText.plain("<p>Hello&nbsp;<b>world</b> &amp; friends&#8217;</p><ul><li>one</li><li>two</li></ul><script>x()</script>")
        #expect(s.contains("Hello world & friends’"))
        #expect(s.contains("• one"))
        #expect(!s.contains("x()"))
    }

    @Test func jiraDates() {
        #expect(Dates.parseISO("2026-10-03T12:34:56.000+0530") != nil)
        #expect(Dates.parseISO("2026-10-03T12:34:56Z") != nil)
        #expect(Dates.parseISO("2026-10-03T12:34:56.123Z") != nil)
        #expect(Dates.parseFeedDate("Sat, 03 Oct 2026 08:00:00 GMT") != nil)
        #expect(Dates.parseFeedDate("Sat, 3 Oct 2026 08:00:00 +0000") != nil)
    }

    @Test func jiraKeysFromTitleAndBranch() {
        #expect(JiraKeys.find(in: ["PLAT-123 fix login", "feature/plat-123-login", "Use UTF-8 and SHA-256"]) == ["PLAT-123"])
        #expect(JiraKeys.find(in: ["no keys here", nil]).isEmpty)
    }

    @Test func stripOrderBy() {
        #expect(JQL.stripOrderBy("project = X AND status != Done ORDER BY priority DESC, updated") == "project = X AND status != Done")
        #expect(JQL.stripOrderBy("assignee = currentUser()") == "assignee = currentUser()")
    }

    @Test func assignedHidesClosedAndArchived() {
        // "Closed"/"Archive" statuses often have no resolution; the Done category catches them.
        #expect(JiraSource.assignedJQL.contains("statusCategory != Done"))
        #expect(JiraSource.assignedJQL.contains("resolution = Unresolved"))
        // The done list must not share the assigned prefix, or store.items(scopePrefix:) would mix them in.
        #expect(!JiraSource.Scope.done.hasPrefix(JiraSource.Scope.assigned))
    }

    @Test func adfTextAndMentions() throws {
        let json = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hey "},{"type":"mention","attrs":{"id":"acc-1","text":"@Alex"}},{"type":"text","text":" please check"}]}]}"#
        let doc = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(ADF.plainText(doc) == "Hey @Alex please check")
        #expect(ADF.mentions(doc, accountId: "acc-1"))
        #expect(!ADF.mentions(doc, accountId: "acc-2"))
    }
}

@Suite struct NewsTests {
    @Test func parsesRSS() {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title>
        <item><title>Big &amp; bold</title><link>https://ex.com/a?utm_source=rss</link>
        <description><![CDATA[<p>Snippet <b>here</b></p>]]></description><pubDate>Sat, 03 Oct 2026 08:00:00 GMT</pubDate></item>
        <item><title>No link</title></item>
        </channel></rss>
        """
        let entries = FeedParser.parse(Data(rss.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].title == "Big & bold")
        #expect(entries[0].summary == "Snippet here")
        #expect(entries[0].published != nil)
    }

    @Test func parsesAtom() {
        let atom = """
        <?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Releases</title>
        <updated>2026-10-01T00:00:00Z</updated>
        <entry><title>v2.1.0</title><link rel="replies" href="https://ex.com/r"/><link rel="alternate" href="https://ex.com/v2.1.0"/>
        <updated>2026-10-02T10:00:00Z</updated><content type="html">&lt;p&gt;Notes&lt;/p&gt;</content></entry></feed>
        """
        let e = FeedParser.parse(Data(atom.utf8))
        #expect(e.count == 1)
        #expect(e[0].link == "https://ex.com/v2.1.0")
        #expect(e[0].summary == "Notes")
    }

    @Test func canonicalURLs() {
        #expect(NewsText.canonicalURL("http://www.Example.com/a/?utm_source=x&id=2#frag") == "https://example.com/a?id=2")
        #expect(NewsText.hash("a") == NewsText.hash("a"))
    }

    @Test func storySimilarity() {
        let a = NewsText.tokens("Google DeepMind announces Gemini 4 Argon frontier model")
        let b = NewsText.tokens("DeepMind unveils Gemini 4 Argon, its new frontier model")
        let c = NewsText.tokens("Russia strikes Kyiv bridge")
        #expect(NewsText.sameStory(a, b))
        #expect(!NewsText.sameStory(a, c))
    }

    @Test func keywordMatchingIsWholeWord() {
        #expect(NewsText.matches("New AI model released", keywords: ["AI"]))
        #expect(!NewsText.matches("The minister said today", keywords: ["AI"]))
        #expect(NewsText.matches("Go 1.27 is out", keywords: ["Go 1."]))
        #expect(NewsText.matches("anthropic ships claude", keywords: ["Claude"]))
    }

    @Test func articleClusteringOnInsert() async throws {
        let store = try Store.inMemory()
        let a1 = Article(url: "https://a.com/1", title: "Google DeepMind announces Gemini 4 Argon frontier model", source: "A", section: .ai, snippet: "", publishedAt: nil)
        let a2 = Article(url: "https://b.com/2", title: "DeepMind unveils Gemini 4 Argon, its new frontier model", source: "B", section: .ai, snippet: "", publishedAt: nil)
        let inserted = try await store.insertArticles([a1, a2])
        #expect(inserted.count == 2)
        #expect(inserted[0].clusterKey == inserted[1].clusterKey)
        #expect(try await store.insertArticles([a1]).isEmpty)
    }

    @Test func majorStoryHeuristic() {
        func art(_ source: String, _ title: String, score: Int? = nil) -> Article {
            var a = Article(url: "https://\(source).com/x", title: title, source: source, section: .ai, snippet: "", publishedAt: nil, score: score)
            a.clusterKey = "c-\(title.prefix(5))"
            return a
        }
        let threeSources = [art("BBC", "OpenAI ships GPT-7"), art("Verge", "OpenAI ships GPT-7"), art("Ars", "OpenAI ships GPT-7")]
        #expect(MajorStory.detect(articles: threeSources, keywords: ["OpenAI"]).count == 1)
        #expect(MajorStory.detect(articles: threeSources, keywords: ["Swift"]).isEmpty)
        let hn = [art("Hacker News", "Claude 6 released", score: 900)]
        #expect(MajorStory.detect(articles: hn, keywords: ["Claude"]).count == 1)
        let small = [art("Hacker News", "Claude tip", score: 120)]
        #expect(MajorStory.detect(articles: small, keywords: ["Claude"]).isEmpty)
    }
}

@Suite struct SecurityTests {
    @Test func onlyWebLinksOpen() {
        #expect(SafeURL.web("https://example.com/a") != nil)
        #expect(SafeURL.web("http://example.com") != nil)
        #expect(SafeURL.web("file:///etc/passwd") == nil)
        #expect(SafeURL.web("x-apple.systempreferences:foo") == nil)
        #expect(SafeURL.web("javascript:alert(1)") == nil)
        #expect(SafeURL.web(nil) == nil)
    }

    @Test func claudeRunsNeverGetDangerousTools() {
        let runner = ClaudeCLIRunner(executable: "/usr/bin/true")
        let args = runner.arguments(for: ClaudeRequest(prompt: "x", tools: ["Bash", "WebSearch", "Edit"]))
        let i = args.firstIndex(of: "--tools")!
        #expect(args[i + 1] == "WebSearch")
        #expect(!args.contains("--dangerously-skip-permissions"))
        let none = runner.arguments(for: ClaudeRequest(prompt: "x"))
        #expect(none[none.firstIndex(of: "--tools")! + 1] == "")
        #expect(none.contains { $0.contains("untrusted data") })
    }
}
