import Foundation

/// GitHub REST v3 + GraphQL, for github.com and GitHub Enterprise Server.
/// A classic token with `repo` (and `notifications` for the to-do list) covers everything; `public_repo` is enough
/// for public work. Fine-grained tokens work for PRs and Actions but can't read notifications.
public struct GitHubClient: Sendable {
    public let account: CodeHostAccount
    let http: HTTPClient
    let graphQLURL: String

    public init(account: CodeHostAccount, session: URLSession = .everboard) {
        self.account = account
        let api = Self.apiBase(for: account)
        self.http = HTTPClient(baseURL: api, headers: [
            "Authorization": "Bearer \(account.token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ], session: session)
        self.graphQLURL = account.isGitHubDotCom ? "https://api.github.com/graphql" : account.webURL.absoluteString + "/api/graphql"
    }

    /// api.github.com for github.com; `<host>/api/v3` for GitHub Enterprise Server.
    public static func apiBase(for account: CodeHostAccount) -> URL {
        account.isGitHubDotCom ? URL(string: "https://api.github.com")! : account.webURL.appendingPathComponent("api/v3")
    }

    var webBase: String { account.webURL.absoluteString }

    // MARK: REST

    public func viewer() async throws -> GitHubUser {
        try await http.json(GitHubUser.self, "GET", "/user")
    }

    /// Threads you participate in or were mentioned/requested on (GitHub's closest thing to GitLab to-dos).
    public func notifications() async throws -> [GitHubNotification] {
        try await http.json([GitHubNotification].self, "GET", "/notifications", query: ["participating": "true", "per_page": "50"])
    }

    func recentRepos(login: String) async throws -> [String] {
        let events = try await http.json([GitHubEvent].self, "GET", "/users/\(login)/events", query: ["per_page": "100"])
        var seen: [String] = []
        for e in events where ["PushEvent", "PullRequestEvent", "CreateEvent"].contains(e.type) && !seen.contains(e.repo.name) {
            seen.append(e.repo.name)
        }
        return seen
    }

    public func workflowRuns(repo: String, actor: String? = nil, headSha: String? = nil, since: Date? = nil) async throws -> [GitHubWorkflowRun] {
        var query: [String: String?] = ["per_page": "20", "actor": actor, "head_sha": headSha]
        if let since { query["created"] = ">=" + Self.day(since) }
        return try await http.json(GitHubRuns.self, "GET", "/repos/\(repo)/actions/runs", query: query).workflowRuns
    }

    func rerunFailedJobs(repo: String, runId: String) async throws {
        _ = try await http.data("POST", "/repos/\(repo)/actions/runs/\(runId)/rerun-failed-jobs")
    }

    // MARK: GraphQL

    static let prFields = """
    number title url createdAt updatedAt isDraft headRefName baseRefName mergeable reviewDecision
    author { login ... on User { name } } repository { nameWithOwner } comments { totalCount }
    commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
    latestOpinionatedReviews(first: 10, writersOnly: true) { nodes { state author { login ... on User { name } } } }
    reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login name } ... on Team { name } } } }
    """
    static let recordFields = """
    number title url state createdAt mergedAt updatedAt changedFiles
    author { login ... on User { name } } repository { nameWithOwner } comments { totalCount }
    """

    /// Runs several PR searches in one request: `searches` maps an alias to a search query.
    /// GitHub answers partially (data + errors) when e.g. one username doesn't exist; missing aliases come back empty.
    func searchPulls(_ searches: [String: String], fields: String = prFields, first: Int = 50) async throws -> [String: [GHPullRequest]] {
        guard !searches.isEmpty else { return [:] }
        let aliases = searches.keys.sorted()
        let vars = aliases.enumerated().map { "$q\($0.offset): String!" }.joined(separator: ", ")
        let body = aliases.enumerated().map {
            "\($0.element): search(query: $q\($0.offset), type: ISSUE, first: \(first)) { nodes { ... on PullRequest { \(fields) } } }"
        }.joined(separator: "\n")
        var variables: [String: JSONValue] = [:]
        for (i, alias) in aliases.enumerated() { variables["q\(i)"] = .string(searches[alias] ?? "") }
        let payload = try JSONEncoder().encode(["query": JSONValue.string("query(\(vars)) {\n\(body)\n}"), "variables": .object(variables)])
        let resp = try await http.json(GQLResponse<[String: GHSearch?]>.self, "POST", graphQLURL, body: payload)
        guard let data = resp.data else {
            throw HTTPError.decoding(resp.errors?.map(\.message).joined(separator: "; ") ?? "empty GraphQL response")
        }
        if let errors = resp.errors, !errors.isEmpty { Log.info("\(account.id): GraphQL: \(errors.map(\.message).joined(separator: "; "))") }
        var out: [String: [GHPullRequest]] = [:]
        for alias in aliases {
            out[alias] = (data[alias] ?? nil)?.pulls.filter { account.includes(path: $0.repository.nameWithOwner) } ?? []
        }
        return out
    }

    /// GitHub logins are `[A-Za-z0-9-]`; anything else would change the meaning of a search query.
    static func login(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" }) }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// The API URL in a notification (`…/repos/o/r/pulls/12`) → its page (`https://github.com/o/r/pull/12`).
    public static func webURL(forAPI api: String?, account: CodeHostAccount, repoHTML: String?) -> String? {
        let prefix = apiBase(for: account).absoluteString + "/repos/"
        guard let api, api.hasPrefix(prefix) else { return repoHTML }
        var rest = String(api.dropFirst(prefix.count))
        for (from, to) in [("/pulls/", "/pull/"), ("/commits/", "/commit/")] { rest = rest.replacingOccurrences(of: from, with: to) }
        if rest.contains("/releases/") { return repoHTML.map { $0 + "/releases" } }
        return account.webURL.absoluteString + "/" + rest
    }
}

// MARK: - CodeHostClient

extension GitHubClient: CodeHostClient {
    public var writeScopeHint: String {
        "GitHub actions need a classic token with the `repo` scope, or a fine-grained token with Pull requests and Actions write access."
    }

    public func currentUser() async throws -> CodeHostUser {
        let u = try await viewer()
        return CodeHostUser(id: String(u.id), username: u.login, name: u.name ?? u.login)
    }

    public func resolveUser(email: String) async throws -> CodeHostUser? {
        struct Found: Decodable { struct Item: Decodable { let login: String }; let items: [Item] }
        let found = try await http.json(Found.self, "GET", "/search/users", query: ["q": "\(email) in:email"])
        var login = found.items.count == 1 ? found.items[0].login : nil
        // On a company GitHub Enterprise the email's local part is usually the login; on github.com it's a stranger.
        if login == nil, !account.isGitHubDotCom, let local = email.split(separator: "@").first { login = String(local) }
        guard let login else { return nil }
        guard let u = try? await http.json(GitHubUser.self, "GET", "/users/\(login)") else { return nil }
        return CodeHostUser(id: String(u.id), username: u.login, name: u.name ?? u.login)
    }

    private func pr(_ item: FeedItem) throws -> (repo: String, number: String) {
        guard let repo = item["projectPath"], let n = item["iid"] else { throw HTTPError.notConfigured("Not a GitHub pull request") }
        return (repo, n)
    }

    public func changeDetail(_ item: FeedItem) async throws -> ChangeDetail {
        let (repo, n) = try pr(item)
        let p = try await http.json(GitHubPull.self, "GET", "/repos/\(repo)/pulls/\(n)")
        return ChangeDetail(title: p.title, description: p.body, sourceBranch: p.head?.ref, targetBranch: p.base?.ref,
                            authorName: p.user?.name ?? p.user?.login)
    }

    public func changeDiffs(_ item: FeedItem) async throws -> [FileDiff] {
        let (repo, n) = try pr(item)
        let files = try await http.json([GitHubFile].self, "GET", "/repos/\(repo)/pulls/\(n)/files", query: ["per_page": "100"])
        return files.map {
            FileDiff(oldPath: $0.previousFilename ?? $0.filename, newPath: $0.filename, diff: $0.patch ?? "",
                     newFile: $0.status == "added", deletedFile: $0.status == "removed")
        }
    }

    public func approve(_ item: FeedItem) async throws {
        let (repo, n) = try pr(item)
        _ = try await http.data("POST", "/repos/\(repo)/pulls/\(n)/reviews", body: try JSONEncoder().encode(["event": "APPROVE"]))
    }

    public func comment(_ item: FeedItem, body: String) async throws {
        let (repo, n) = try pr(item)
        _ = try await http.data("POST", "/repos/\(repo)/issues/\(n)/comments", body: try JSONEncoder().encode(["body": body]))
    }

    public func retryPipeline(_ item: FeedItem) async throws {
        guard let repo = item["projectPath"] else { throw HTTPError.notConfigured("No repository") }
        if item.kind == "pipeline", let run = item["pipelineId"] {
            return try await rerunFailedJobs(repo: repo, runId: run)
        }
        guard let sha = item["headSha"] else { throw HTTPError.notConfigured("No commit to re-run checks for") }
        let failed = try await workflowRuns(repo: repo, headSha: sha).filter { $0.normalizedStatus == "failed" }
        guard !failed.isEmpty else {
            throw HTTPError.notConfigured("No failed GitHub Actions runs on this commit; other checks must be re-run where they live.")
        }
        for run in failed { try await rerunFailedJobs(repo: repo, runId: String(run.id)) }
    }

    public func markTodoDone(_ item: FeedItem) async throws {
        guard let thread = item["threadId"] else { throw HTTPError.notConfigured("Not a GitHub notification") }
        _ = try await http.data("PATCH", "/notifications/threads/\(thread)")
    }

    func record(_ p: GHPullRequest) -> ChangeRecord {
        ChangeRecord(id: account.id + ".pr:\(p.repository.nameWithOwner):\(p.number)", ref: "\(p.repository.nameWithOwner)#\(p.number)",
                     title: p.title, url: p.url, state: (p.state ?? "open").lowercased(), createdAt: p.createdAt, mergedAt: p.mergedAt,
                     updatedAt: p.updatedAt, authorUsername: p.author?.login, authorName: p.author?.name ?? p.author?.login,
                     comments: p.comments?.totalCount, filesChanged: p.changedFiles)
    }

    /// Without orgs, searching all of github.com would return strangers' PRs; limit it to ones involving you.
    private var searchScopes: [String] {
        if !account.orgs.isEmpty { return account.orgs.prefix(5).map { "org:\(Self.login($0))" } }
        return account.isGitHubDotCom ? ["involves:@me"] : [""]
    }

    public func searchChanges(_ text: String, limit: Int) async throws -> [ChangeRecord] {
        var searches: [String: String] = [:]
        for (i, scope) in searchScopes.enumerated() { searches["s\(i)"] = "is:pr in:title sort:updated-desc \(scope) \(text)" }
        let results = try await searchPulls(searches, fields: Self.recordFields, first: limit)
        var seen = Set<String>()
        return results.keys.sorted().flatMap { results[$0] ?? [] }.map(record).filter { seen.insert($0.id).inserted }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(limit).map { $0 }
    }

    public func changes(author: String?, reviewer: String?, state: ChangeState, since: Date, withSize: Bool) async throws -> [ChangeRecord] {
        var q = "is:pr"
        switch state {
        case .merged: q += " is:merged merged:>=\(Self.day(since))"
        case .open: q += " is:open updated:>=\(Self.day(since))"
        case .all: q += " updated:>=\(Self.day(since))"
        }
        if let author { q += " author:\(Self.login(author))" }
        if let reviewer { q += " reviewed-by:\(Self.login(reviewer))" }
        let pulls = try await searchPulls(["r": q], fields: Self.recordFields, first: 100)["r"] ?? []
        return pulls.map(record).filter { state != .merged || ($0.mergedAt ?? .distantPast) >= since }
    }

    public func searchPageURL(_ text: String) -> String {
        let q = "is:pr \(text) " + searchScopes.joined(separator: " ")
        return "\(webBase)/search?type=pullrequests&q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)"
    }

    public func changeURL(path: String, number: String) -> String { "\(webBase)/\(path)/pull/\(number)" }
}
