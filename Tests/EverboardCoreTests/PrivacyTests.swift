import Foundation
import Testing
@testable import EverboardCore

/// Echoes the prompt it received, so tests can see exactly what would have been sent.
private struct EchoRunner: ClaudeRunning {
    var reply: (@Sendable (ClaudeRequest) -> String)?
    func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        ClaudeResponse(text: reply?(request) ?? request.prompt, structured: nil, costUSD: 0.01)
    }
}

@Suite struct PrivacyTests {
    @Test func masksSecrets() {
        // Fake secrets, split with interpolation so secret scanners (scripts/leakcheck.sh, GitHub) don't flag the source.
        let text = """
        GITLAB_TOKEN=glpat-\("abcdefghijklmnopqrstu")
        aws = AKIAABCDEFGHIJKLMNOP
        db: postgres://admin:s3cretpass@db.internal:5432/app
        password: "hunter2hunter"
        API_KEY=ab12cd34ef56
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345
        -----BEGIN RSA \("PRIVATE") KEY-----
        MIIEow
        -----END RSA \("PRIVATE") KEY-----
        """
        let r = Redactor.redact(text, policy: PrivacyPolicy())
        for leaked in ["glpat-", "AKIAABCD", "s3cretpass", "hunter2hunter", "ab12cd34ef56", "abcdefghijklmnopqrstuvwxyz012345", "MIIEow"] {
            #expect(!r.text.contains(leaked), "\(leaked) leaked")
        }
        #expect(r.text.contains("postgres://[SECRET]@db.internal"))
        #expect(r.text.contains("password: \"[SECRET]\""))
        #expect((r.counts["secret"] ?? 0) >= 7)
        #expect(r.map.isEmpty)  // secrets are never restored
    }

    @Test func leavesOrdinaryCodeAlone() {
        let code = """
        let token = request.header("X-Token")
        password = os.getenv("DB_PASSWORD")
        api_key: ${API_KEY}
        @Environment(AppModel.self) private var model
        """
        let r = Redactor.redact(code, policy: PrivacyPolicy())
        #expect(r.text == code)
        #expect(r.counts.isEmpty)
    }

    @Test func emailsPeopleAndTermsRoundTrip() {
        let policy = PrivacyPolicy(pseudonymizePeople: true, people: ["Priya Nair", "Asha K", "You"], terms: ["Project Falcon", "acme-corp"])
        let text = "Priya Nair (priya@acme-corp.com) asked Asha K about Project Falcon. Thanks Priya! You approved it."
        let r = Redactor.redact(text, policy: policy)
        #expect(!r.text.contains("Priya"))
        #expect(!r.text.contains("Asha"))
        #expect(!r.text.contains("Falcon"))
        #expect(!r.text.contains("priya@"))
        #expect(r.text.contains("You approved"))  // "You" is never treated as a name
        #expect(r.counts["person"] == 3)          // full name, first name, Asha K
        // Same person → same placeholder, so Claude can reason about who did what.
        #expect(r.text.contains("[PERSON-1]") && r.text.contains("[PERSON-2]") && !r.text.contains("[PERSON-3]"))

        let reply = r.text.replacingOccurrences(of: "[", with: "**[").replacingOccurrences(of: "]", with: "]**")
        let restored = Redactor.restore(reply, map: r.map)
        #expect(restored.contains("**Priya Nair**"))
        #expect(restored.contains("**Asha K**"))
        #expect(restored.contains("**Project Falcon**"))
        #expect(restored.contains("**priya@acme-corp.com**"))
        // Brackets dropped by the model still restore.
        #expect(Redactor.restore("PERSON-1 did it", map: r.map).hasSuffix(" did it"))
        #expect(!Redactor.restore("PERSON-1 did it", map: r.map).contains("PERSON"))
    }

    @Test func newsPromptsKeepNames() {
        let policy = PrivacyPolicy(pseudonymizePeople: true, people: ["Tim Cook"], terms: ["Apple"])
        let r = Redactor.redact("Tim Cook on Apple", policy: policy, isWork: false)
        #expect(r.text == "Tim Cook on Apple")
    }

    @Test func runnerMasksRestoresAndBlocks() async throws {
        let echo = EchoRunner()
        let runner = PrivacyClaudeRunner(base: echo, policy: PrivacyPolicy(pseudonymizePeople: true, terms: ["Falcon"]))
        let r = try await runner.run(ClaudeRequest(prompt: "Ravi Shah on Falcon", feature: "jira.digest", people: ["Ravi Shah"]))
        #expect(r.text == "Ravi Shah on Falcon")  // echoed placeholders restored

        let seen = EchoRunner { req in req.prompt + " | " + (req.systemPrompt ?? "") }
        let r2 = try await PrivacyClaudeRunner(base: seen, policy: PrivacyPolicy(terms: ["Falcon"]))
            .run(ClaudeRequest(prompt: "Falcon", feature: "mr.summary"))
        #expect(r2.text.contains("privacy placeholders"))

        let blocked = PrivacyClaudeRunner(base: echo, policy: PrivacyPolicy(allowWork: false))
        await #expect(throws: ClaudeError.self) { try await blocked.run(ClaudeRequest(prompt: "x", feature: "work.brief")) }
        let news = try await blocked.run(ClaudeRequest(prompt: "headlines", feature: "news.brief"))
        #expect(news.text == "headlines")
    }

    @Test func logRecordsWhatWasSent() async throws {
        let store = try Store.inMemory()
        let runner = PrivacyClaudeRunner(base: RecordingClaudeRunner(base: EchoRunner(), store: store), policy: PrivacyPolicy())
        _ = try await runner.run(ClaudeRequest(prompt: "ping me at a@b.co", systemPrompt: "sys", feature: "work.brief"))
        let list = try await store.aiLog()
        #expect(list.count == 1)
        #expect(list[0].prompt.isEmpty)  // list query skips big columns
        #expect(list[0].promptChars == "ping me at [EMAIL-1]".count)
        #expect(list[0].redactions == ["email": 1])
        #expect(list[0].isWork)
        let full = try #require(try await store.aiLogEntry(id: list[0].id))
        #expect(full.prompt == "ping me at [EMAIL-1]")
        #expect(full.systemPrompt.hasPrefix("sys"))
        try await store.prune(now: Date().addingTimeInterval(3 * 86400), aiLogDays: 1)
        #expect(try await store.aiLog().isEmpty)

        let quiet = RecordingClaudeRunner(base: EchoRunner(), store: store, logPrompts: false)
        _ = try await quiet.run(ClaudeRequest(prompt: "x"))
        #expect(try await store.aiLog().isEmpty)
    }

    @Test func linksRefs() {
        let linker = RefLinker(gitlabBase: URL(string: "https://gitlab.example.com"), jiraBase: URL(string: "https://x.atlassian.net"),
                               jiraProjects: ["PAY"], mrsByIID: ["290": ["https://gitlab.example.com/acme/api/-/merge_requests/290"],
                                                               "5": ["https://a/5", "https://b/5"]])
        let md = "- **Fix acme/payments-api!311** for PAY-1311; see !290, !5, UTF-8, `PAY-1` and [PAY-2](https://keep) and acme/ledger !12"
        let out = linker.linkify(md)
        #expect(out.contains("**Fix [acme/payments-api!311](https://gitlab.example.com/acme/payments-api/-/merge_requests/311)**"))
        #expect(out.contains("[PAY-1311](https://x.atlassian.net/browse/PAY-1311)"))
        #expect(out.contains("[!290](https://gitlab.example.com/acme/api/-/merge_requests/290)"))
        #expect(out.contains(" !5,"))                       // ambiguous bare iid stays plain
        #expect(out.contains(" UTF-8,"))                    // unknown project prefix stays plain
        #expect(out.contains("`PAY-1`"))                    // code untouched
        #expect(out.contains("[PAY-2](https://keep)"))      // existing link untouched
        #expect(out.contains("[acme/ledger !12](https://gitlab.example.com/acme/ledger/-/merge_requests/12)"))
        #expect(linker.linkify(out) == out)                 // idempotent
    }

    @Test func linkerLearnsFromItems() {
        let items = [
            FeedItem(id: "j", source: "jira", kind: "issue.assigned", title: "", attrs: ["key": "OPS-7"]),
            FeedItem(id: "m", source: "gitlab", kind: "mr.mine", title: "", url: "https://g/m/9", attrs: ["iid": "9", "jiraKeys": "PAY-1,CORE-22"]),
        ]
        let l = RefLinker(gitlabBase: nil, jiraBase: URL(string: "https://j"), items: items)
        #expect(l.jiraProjects == ["OPS", "PAY", "CORE"])
        #expect(l.mrsByIID["9"] == ["https://g/m/9"])
    }

    @Test func rendersHTMLForPasting() {
        let html = MarkdownHTML.render("## Yesterday\n- Merged **[!311](https://g/311)** <script>\n- Reviewed `x`\n\nDone.")
        #expect(html.contains("<h3>Yesterday</h3>"))
        #expect(html.contains("<ul><li>Merged <a href=\"https://g/311\"><strong>!311</strong></a> &lt;script&gt;</li><li>Reviewed <code>x</code></li></ul>"))
        #expect(html.contains("<p>Done.</p>"))
        #expect(!MarkdownHTML.render("[x](javascript:alert(1))").contains("javascript"))
    }

    @Test func configDecodesWithoutPrivacyKeys() throws {
        let c = try JSONDecoder.everboard.decode(AppConfig.self, from: Data(#"{"gitlabInterval": 90}"#.utf8))
        #expect(c.aiWorkEnabled && c.aiRedactSecrets && c.aiSendDiffs && c.aiLogDays == 14)
        #expect(!c.aiPseudonymizePeople)
    }
}
