import Foundation
import Testing
@testable import EverboardCore

@Suite struct CodeHostAccountTests {
    @Test func parsesDefaultAndNamedAccounts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("secrets.env")
        try """
        GITLAB_URL=https://gitlab.example.com/
        GITLAB_TOKEN=a
        GITLAB_ORGS=Team-A, team-b/sub ,
        GITHUB_TOKEN=b
        GITHUB_OSS_TOKEN=c
        GITHUB_OSS_ORGS=acme
        GITLAB_WORK_URL=http://insecure.example
        GITLAB_WORK_TOKEN=d
        GITLAB_SELF_URL=https://gl.self
        """.write(to: file, atomically: true, encoding: .utf8)
        let s = Secrets.load(path: file, environment: [:])
        let accounts = s.codeHostAccounts

        // A bare GITHUB_TOKEN (news source) doesn't turn on GitHub tracking; GITHUB_URL does.
        #expect(accounts.map(\.id) == ["gitlab", "github.oss"])
        #expect(accounts[0].webURL.absoluteString == "https://gitlab.example.com")
        #expect(accounts[0].orgs == ["team-a", "team-b/sub"])
        #expect(accounts[1].webURL.absoluteString == "https://github.com")   // named accounts default the URL
        #expect(accounts[1].displayName == "GitHub · oss")
        #expect(s.warnings.contains("GITLAB_WORK_URL must start with https:// — ignored so tokens aren't sent unencrypted"))
        #expect(s.warnings.contains("GITLAB_SELF_URL is set but GITLAB_SELF_TOKEN is missing"))
    }

    @Test func accountsFromEnvironmentOnly() {
        let s = Secrets.load(path: URL(fileURLWithPath: "/nonexistent/secrets.env"),
                             environment: ["GITHUB_URL": "https://github.com", "GITHUB_TOKEN": "x", "GITLAB_CI_TOKEN": "y", "HOME": "/x"])
        #expect(s.codeHostAccounts.map(\.id) == ["github", "gitlab.ci"])
        #expect(s.values["HOME"] == nil)
    }

    @Test func sensitiveKeysAreRecognised() {
        #expect(Secrets.isSensitiveEnvKey("GITLAB_WORK_TOKEN"))
        #expect(Secrets.isSensitiveEnvKey("GITHUB_TOKEN"))
        #expect(Secrets.isSensitiveEnvKey("JIRA_API_TOKEN"))
        #expect(!Secrets.isSensitiveEnvKey("PATH"))
        #expect(!Secrets.isSensitiveEnvKey("GITHUB_ACTIONS"))
    }

    @Test func orgFilterAndIDs() {
        let a = CodeHostAccount(kind: .github, name: "Work", webURL: URL(string: "https://github.com")!, token: "t", orgs: ["ACME", " "])
        #expect(a.id == "github.work")
        #expect(a.scope(.mine) == "github.work.mr.mine")
        #expect(a.eventID("x") == "github.work:x")
        #expect(a.includes(path: "acme/app") && a.includes(path: "ACME/App") && a.includes(path: "acme"))
        #expect(!a.includes(path: "acme-labs/app"))
        let gitlab = CodeHostAccount(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!, token: "t")
        #expect(gitlab.eventID("x") == "x")   // unchanged ids for the default GitLab account
        #expect(gitlab.includes(path: "anything/at/all"))
    }

    @Test func pinnedProjectsPerAccount() {
        let gh = CodeHostAccount(kind: .github, webURL: URL(string: "https://github.com")!, token: "t", orgs: ["acme"])
        let entries = ["acme/app", "https://github.com/acme/web.git", "https://gitlab.example.com/acme/p", "nope", "other/x"]
        #expect(PinnedProjects.paths(entries, for: gh) == ["acme/app", "acme/web"])
        let gl = CodeHostAccount(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!, token: "t")
        #expect(PinnedProjects.paths(entries, for: gl) == ["acme/app", "acme/p", "other/x"])
    }
}

@Suite struct GitHubMappingTests {
    let dotcom = CodeHostAccount(kind: .github, webURL: URL(string: "https://github.com")!, token: "t")
    let ghe = CodeHostAccount(kind: .github, webURL: URL(string: "https://ghe.example")!, token: "t")

    @Test func apiAndWebURLs() {
        #expect(GitHubClient.apiBase(for: dotcom).absoluteString == "https://api.github.com")
        #expect(GitHubClient.apiBase(for: ghe).absoluteString == "https://ghe.example/api/v3")
        #expect(GitHubClient.webURL(forAPI: "https://api.github.com/repos/o/r/pulls/12", account: dotcom, repoHTML: nil) == "https://github.com/o/r/pull/12")
        #expect(GitHubClient.webURL(forAPI: "https://ghe.example/api/v3/repos/o/r/issues/3", account: ghe, repoHTML: nil) == "https://ghe.example/o/r/issues/3")
        #expect(GitHubClient.webURL(forAPI: "https://api.github.com/repos/o/r/releases/9", account: dotcom, repoHTML: "https://github.com/o/r") == "https://github.com/o/r/releases")
        #expect(GitHubClient.webURL(forAPI: nil, account: dotcom, repoHTML: "https://github.com/o/r") == "https://github.com/o/r")
        let client = GitHubClient(account: dotcom)
        #expect(client.changeURL(path: "o/r", number: "4") == "https://github.com/o/r/pull/4")
        #expect(client.searchPageURL("fix bug").hasPrefix("https://github.com/search?type=pullrequests&q=is%3Apr%20fix%20bug%20involves%3A%40me"))
    }

    @Test func workflowRunStatuses() throws {
        func run(_ status: String, _ conclusion: String?) throws -> String {
            let json = #"{"id":1,"status":"\#(status)","conclusion":\#(conclusion.map { "\"\($0)\"" } ?? "null")}"#
            return try JSONDecoder.everboard.decode(GitHubWorkflowRun.self, from: Data(json.utf8)).normalizedStatus
        }
        #expect(try run("completed", "success") == "success")
        #expect(try run("completed", "failure") == "failed")
        #expect(try run("completed", "timed_out") == "failed")
        #expect(try run("completed", "cancelled") == "canceled")
        #expect(try run("completed", "skipped") == "skipped")
        #expect(try run("in_progress", nil) == "running")
        #expect(try run("queued", nil) == "pending")
    }

    @Test func mergeAndCheckStatus() {
        #expect(GitHubSource.checkStatus("FAILURE") == "failed")
        #expect(GitHubSource.checkStatus("ERROR") == "failed")
        #expect(GitHubSource.checkStatus("PENDING") == "running")
        #expect(GitHubSource.checkStatus("SUCCESS") == "success")
        #expect(GitHubSource.mergeStatus(mergeable: "CONFLICTING", reviewDecision: "APPROVED") == "conflict")
        #expect(GitHubSource.mergeStatus(mergeable: "MERGEABLE", reviewDecision: "CHANGES_REQUESTED") == "changes_requested")
        #expect(GitHubSource.mergeStatus(mergeable: "MERGEABLE", reviewDecision: "REVIEW_REQUIRED") == "not_approved")
        #expect(GitHubSource.mergeStatus(mergeable: "MERGEABLE", reviewDecision: "APPROVED") == "mergeable")
        #expect(GitHubSource.mergeStatus(mergeable: "UNKNOWN", reviewDecision: nil) == nil)
    }

    @Test func rulesNamespaceEventsPerAccount() {
        let oss = CodeHostAccount(kind: .github, name: "oss", webURL: URL(string: "https://github.com")!, token: "t")
        let pr = FeedItem(id: "github.oss.pr:o/r:5", source: "github", kind: "mr.mine", title: "Fix it", subtitle: "o/r #5",
                          url: "https://github.com/o/r/pull/5", createdAt: Date(),
                          attrs: ["pipelineStatus": "failed", "pipelineId": "abc", "projectPath": "o/r", "authorName": "Asha"])
        let failed = CodeHostRules.events(for: ItemChange(scope: oss.scope(.mine), old: nil, new: pr, wasPresent: false, everSeen: false), account: oss)
        #expect(failed.map(\.id) == ["github.oss:pipeline.failed:abc"])
        #expect(failed.first?.title == "Checks failed: Fix it")
        let opened = CodeHostRules.events(for: ItemChange(scope: oss.scope(.reportees), old: nil, new: pr, wasPresent: false, everSeen: false), account: oss)
        #expect(opened.first?.title == "Asha opened a PR")
        // Another account's scope never matches this account's rules.
        #expect(CodeHostRules.events(for: ItemChange(scope: "github.mr.mine", old: nil, new: pr, wasPresent: false, everSeen: false), account: oss).isEmpty)
    }

    @Test func linksGitHubRefsAndKnownChanges() {
        let item = FeedItem(id: "gitlab.work.mr:1:3", source: "gitlab", kind: "mr.review", title: "", url: "https://gl.work/acme/api/-/merge_requests/3",
                            attrs: ["projectPath": "acme/api", "iid": "3"])
        let linker = RefLinker(gitlabBase: nil, githubBase: URL(string: "https://github.com"), jiraBase: nil, items: [item])
        let out = linker.linkify("## Today\n- Review acme/app#12 and acme/api!3; issue #4 stays")
        #expect(out.contains("[acme/app#12](https://github.com/acme/app/pull/12)"))
        #expect(out.contains("[acme/api!3](https://gl.work/acme/api/-/merge_requests/3)"))
        #expect(out.contains("## Today"))
        #expect(out.contains("issue #4 stays"))
        #expect(linker.linkify(out) == out)
    }

    @Test func reviewsOfOwnChangesOnAnyHostDontCount() {
        let reviewed = [ChangeRecord(id: "a", ref: "o/r#1", title: "", url: "", state: "open", authorUsername: "asha-gh"),
                        ChangeRecord(id: "b", ref: "g/p!2", title: "", url: "", state: "open", authorUsername: "vik")]
        let m = TeamMath.metrics(username: "asha", name: "Asha", merged: [], reviewed: reviewed, open: [], usernames: ["asha", "asha-gh"])
        #expect(m.reviewsGiven == 1)
    }
}

extension HTTPStubTests {
    @Test func gitHubPollMapsPRsNotificationsAndRuns() async throws {
        let pr = { (repo: String, n: Int, author: String, checks: String) in """
            {"number":\(n),"title":"PAY-7 retry budget","url":"https://ghe.example/\(repo)/pull/\(n)","createdAt":"2026-10-01T10:00:00Z",
             "updatedAt":"2026-10-02T10:00:00Z","isDraft":false,"headRefName":"feature/x","baseRefName":"main","mergeable":"MERGEABLE",
             "reviewDecision":"APPROVED","author":{"login":"\(author)","name":"\(author.capitalized)"},"repository":{"nameWithOwner":"\(repo)"},
             "comments":{"totalCount":3},"commits":{"nodes":[{"commit":{"oid":"sha\(n)","statusCheckRollup":{"state":"\(checks)"}}}]},
             "latestOpinionatedReviews":{"nodes":[{"state":"APPROVED","author":{"login":"lena","name":"Lena M"}}]},
             "reviewRequests":{"nodes":[{"requestedReviewer":{"name":"core-team"}}]}}
            """ }
        let graphQL = """
        {"data":{"mine":{"nodes":[\(pr("acme/app", 5, "me", "FAILURE")),\(pr("other/x", 1, "me", "SUCCESS"))]},
                 "review":{"nodes":[{}]},"assigned":null,"r0":{"nodes":[\(pr("acme/app", 9, "asha", "PENDING"))]}},
         "errors":[{"message":"partial"}]}
        """
        let session = StubProtocol.session([
            "/api/v3/user": (200, #"{"id":1,"login":"me","name":"Me"}"#),
            "/api/graphql": (200, graphQL),
            "/api/v3/notifications": (200, """
                [{"id":"11","reason":"review_requested","updated_at":"2026-10-01T10:00:00Z",
                  "subject":{"title":"Fix","url":"https://ghe.example/api/v3/repos/acme/app/pulls/5","type":"PullRequest"},
                  "repository":{"full_name":"acme/app","html_url":"https://ghe.example/acme/app"}},
                 {"id":"12","reason":"mention","subject":{"title":"Elsewhere","type":"Issue"},"repository":{"full_name":"other/x"}}]
                """),
            "/api/v3/users/me/events": (200, #"[{"type":"PushEvent","repo":{"name":"acme/lib"}}]"#),
            "/api/v3/repos/acme/app/actions/runs": (200, """
                {"workflow_runs":[{"id":77,"run_number":3,"name":"CI","head_branch":"main","event":"push","status":"completed",
                  "conclusion":"failure","html_url":"https://ghe.example/acme/app/actions/runs/77"}]}
                """),
        ])
        let account = CodeHostAccount(kind: .github, webURL: URL(string: "https://ghe.example")!, token: "t", orgs: ["acme"])
        let source = GitHubSource(client: GitHubClient(account: account, session: session), interval: 60)
        var config = AppConfig()
        config.reportees = [Reportee(email: "asha@example.com", githubUsername: "asha")]
        let results = try await source.fetch(context: StoreFetchContext(store: try Store.inMemory(), config: config))
        func scope(_ s: String) -> [FeedItem] { results.first { $0.scope == s }?.items ?? [] }

        let mine = scope("github.mr.mine")
        #expect(mine.map(\.id) == ["github.pr:acme/app:5"])          // other/x is outside GITHUB_ORGS
        let m = try #require(mine.first)
        #expect(m.subtitle == "acme/app #5")
        #expect(m["pipelineStatus"] == "failed" && m["pipelineId"] == "sha5" && m["headSha"] == "sha5")
        #expect(m["pipelineUrl"] == "https://ghe.example/acme/app/pull/5/checks")
        #expect(m["approvedBy"] == "Lena M" && m["reviewers"] == "core-team" && m["mergeStatus"] == "mergeable")
        #expect(m["account"] == "github" && m["jiraKeys"] == "PAY-7" && m["notes"] == "3")
        #expect(scope("github.mr.review").isEmpty)                    // the non-PR node is skipped
        #expect(scope("github.mr.reportees").map(\.author) == ["asha"])
        let todo = try #require(scope("github.todos").first)
        #expect(scope("github.todos").count == 1)
        #expect(todo.url == "https://ghe.example/acme/app/pull/5" && todo["action"] == "review_requested" && todo["threadId"] == "11")
        let run = try #require(scope("github.pipelines.acme/app").first)
        #expect(run.status == "failed" && run.id == "github.run:77" && run["ref"] == "main")
        #expect(results.first { $0.scope == "github.pipelines.acme/lib" } == nil)   // 404 → skipped, not fatal

        let auth = StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer t")
        let body = StubProtocol.requests.compactMap { $0.httpBodyStream.map(Self.read) ?? $0.httpBody }.map { String(decoding: $0, as: UTF8.self) }
        #expect(body.contains { $0.contains("author:asha") && $0.contains("review-requested:@me") })
    }

    @Test func gitHubDotComNeverGuessesLoginFromEmail() async throws {
        let session = StubProtocol.session(["/search/users": (200, #"{"items":[]}"#)])
        let client = GitHubClient(account: CodeHostAccount(kind: .github, webURL: URL(string: "https://github.com")!, token: "t"), session: session)
        #expect(try await client.resolveUser(email: "asha@example.com") == nil)
        #expect(StubProtocol.requests.count == 1)
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}
