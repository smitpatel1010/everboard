import Foundation

/// GitLab REST v4 + GraphQL. Needs a PAT with `read_api`.
public struct GitLabClient: Sendable {
    public let account: CodeHostAccount
    public var baseURL: URL { account.webURL }
    let http: HTTPClient

    public init(account: CodeHostAccount, session: URLSession = .everboard) {
        self.account = account
        self.http = HTTPClient(baseURL: account.webURL, headers: ["PRIVATE-TOKEN": account.token], session: session)
    }

    public init(baseURL: URL, token: String, session: URLSession = .everboard) {
        self.init(account: CodeHostAccount(kind: .gitlab, webURL: baseURL, token: token), session: session)
    }

    // MARK: REST

    public func gitlabUser() async throws -> GitLabUser {
        try await http.json(GitLabUser.self, "GET", "/api/v4/user")
    }

    public func todos() async throws -> [GitLabTodo] {
        try await http.json([GitLabTodo].self, "GET", "/api/v4/todos", query: ["state": "pending", "per_page": "100"])
    }

    public func myPipelines(projectId: String, username: String, updatedAfter: Date) async throws -> [GitLabPipeline] {
        try await http.json([GitLabPipeline].self, "GET", "/api/v4/projects/\(projectId)/pipelines", query: [
            "username": username, "updated_after": Dates.iso(updatedAfter),
            "order_by": "updated_at", "sort": "desc", "per_page": "20",
        ])
    }

    /// Projects the user pushed to recently — where "pipelines I triggered" will show up.
    func pushedProjectIDs(userId: Int, since: Date) async throws -> [Int] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let events = try await http.json([GitLabEvent].self, "GET", "/api/v4/users/\(userId)/events",
                                         query: ["action": "pushed", "after": f.string(from: since), "per_page": "100"])
        var seen: [Int] = []
        for id in events.compactMap(\.projectId) where !seen.contains(id) { seen.append(id) }
        return seen
    }

    func project(_ idOrPath: String) async throws -> GitLabProject {
        let encoded = idOrPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? idOrPath
        return try await http.json(GitLabProject.self, "GET", "/api/v4/projects/\(encoded)")
    }

    /// Email → user. Non-admin tokens only match *public* emails, so fall back to the email's local part.
    public func findUser(email: String) async throws -> GitLabUser? {
        let byEmail = try await http.json([GitLabUser].self, "GET", "/api/v4/users", query: ["search": email])
        if byEmail.count == 1 { return byEmail[0] }
        if let exact = byEmail.first(where: { $0.email?.lowercased() == email.lowercased() }) { return exact }
        let local = String(email.split(separator: "@").first ?? "")
        guard !local.isEmpty else { return nil }
        return try await user(username: local)
    }

    public func user(username: String) async throws -> GitLabUser? {
        try await http.json([GitLabUser].self, "GET", "/api/v4/users", query: ["username": username]).first
    }

    public func mergeRequest(projectId: String, iid: String) async throws -> GitLabMRDetail {
        try await http.json(GitLabMRDetail.self, "GET", "/api/v4/projects/\(projectId)/merge_requests/\(iid)")
    }

    /// Diffs for an MR; uses `/diffs` (GitLab ≥ 15.7) and falls back to the older `/changes`.
    public func mergeRequestDiffs(projectId: String, iid: String) async throws -> [GitLabDiff] {
        do {
            return try await http.json([GitLabDiff].self, "GET", "/api/v4/projects/\(projectId)/merge_requests/\(iid)/diffs",
                                       query: ["per_page": "100"])
        } catch HTTPError.status(404, _) {
            struct Changes: Decodable { let changes: [GitLabDiff] }
            return try await http.json(Changes.self, "GET", "/api/v4/projects/\(projectId)/merge_requests/\(iid)/changes").changes
        }
    }

    // MARK: Reports

    /// MRs across all projects, e.g. merged by a user since a date.
    public func mergeRequests(author: String? = nil, reviewer: String? = nil, state: String, updatedAfter: Date) async throws -> [GitLabMR] {
        var query: [String: String?] = ["scope": "all", "state": state, "updated_after": Dates.iso(updatedAfter), "per_page": "100"]
        query["author_username"] = author
        query["reviewer_username"] = reviewer
        return try await http.json([GitLabMR].self, "GET", "/api/v4/merge_requests", query: query)
    }

    /// Single MR including `changes_count` (not present on list endpoints).
    public func mergeRequestStats(projectId: Int, iid: Int) async throws -> GitLabMR {
        try await http.json(GitLabMR.self, "GET", "/api/v4/projects/\(projectId)/merge_requests/\(iid)")
    }

    /// Free-text MR search across everything the token can see (title/description).
    public func searchMergeRequests(_ text: String, limit: Int = 8) async throws -> [GitLabMR] {
        try await http.json([GitLabMR].self, "GET", "/api/v4/merge_requests", query: [
            "scope": "all", "search": text, "in": "title", "order_by": "updated_at", "per_page": String(limit),
        ])
    }

    // MARK: Actions (need a token with the `api` scope)

    public func approve(projectId: String, iid: String) async throws {
        _ = try await http.data("POST", "/api/v4/projects/\(projectId)/merge_requests/\(iid)/approve")
    }

    public func retryPipeline(projectId: String, pipelineId: String) async throws {
        _ = try await http.data("POST", "/api/v4/projects/\(projectId)/pipelines/\(pipelineId)/retry")
    }

    public func markTodoDone(id: String) async throws {
        _ = try await http.data("POST", "/api/v4/todos/\(id)/mark_as_done")
    }

    public func comment(projectId: String, iid: String, body: String) async throws {
        let payload = try JSONEncoder().encode(["body": body])
        _ = try await http.data("POST", "/api/v4/projects/\(projectId)/merge_requests/\(iid)/notes", body: payload)
    }

    // MARK: GraphQL

    static let mrFieldsFull = """
    id iid title webUrl createdAt updatedAt draft sourceBranch targetBranch detailedMergeStatus userNotesCount
    author { username name } project { id fullPath } headPipeline { id status path updatedAt }
    approvedBy { nodes { username name } } reviewers { nodes { username name } }
    """
    /// For older GitLab versions that reject some of the fields above.
    static let mrFieldsMinimal = """
    id iid title webUrl createdAt updatedAt sourceBranch targetBranch
    author { username name } project { id fullPath } headPipeline { id status path updatedAt }
    """

    func graphQL<T: Decodable>(_ type: T.Type, query: String, variables: [String: JSONValue] = [:]) async throws -> T {
        let body = try JSONEncoder().encode(["query": JSONValue.string(query), "variables": .object(variables)])
        let resp = try await http.json(GQLResponse<T>.self, "POST", "/api/graphql", body: body)
        if let data = resp.data { return data }
        throw HTTPError.decoding(resp.errors?.map(\.message).joined(separator: "; ") ?? "empty GraphQL response")
    }

    /// Runs with full fields, retrying once with the minimal set if the server rejects a field.
    func graphQLMRs<T: Decodable>(_ type: T.Type, build: (String) -> String, variables: [String: JSONValue] = [:]) async throws -> T {
        do {
            return try await graphQL(T.self, query: build(Self.mrFieldsFull), variables: variables)
        } catch HTTPError.decoding(let msg) where msg.contains("doesn't exist") || msg.contains("Field") {
            return try await graphQL(T.self, query: build(Self.mrFieldsMinimal), variables: variables)
        }
    }

    struct MyMRs {
        let authored: [GQLMergeRequest]
        let reviewRequested: [GQLMergeRequest]
        let assigned: [GQLMergeRequest]
    }

    func myMergeRequests() async throws -> MyMRs {
        let r = try await graphQLMRs(GQLCurrentUserMRs.self) { fields in """
            query { currentUser { username
              authoredMergeRequests(state: opened, first: 50) { nodes { \(fields) } }
              reviewRequestedMergeRequests(state: opened, first: 50) { nodes { \(fields) } }
              assignedMergeRequests(state: opened, first: 50) { nodes { \(fields) } }
            } }
            """ }
        return MyMRs(authored: r.currentUser.authoredMergeRequests.nodes,
                     reviewRequested: r.currentUser.reviewRequestedMergeRequests.nodes,
                     assigned: r.currentUser.assignedMergeRequests.nodes)
    }

    func openMergeRequests(byUsernames usernames: [String]) async throws -> [GQLUsersMRs.User] {
        guard !usernames.isEmpty else { return [] }
        let r = try await graphQLMRs(GQLUsersMRs.self, build: { fields in """
            query($usernames: [String!]) { users(usernames: $usernames, first: 100) { nodes { username name
              authoredMergeRequests(state: opened, first: 30) { nodes { \(fields) } }
            } } }
            """ }, variables: ["usernames": .array(usernames.map { .string($0) })])
        return r.users.nodes
    }
}

// MARK: - CodeHostClient

extension GitLabClient: CodeHostClient {
    public var writeScopeHint: String { "GitLab actions need a token with the `api` scope (read_api is read-only)." }

    public func currentUser() async throws -> CodeHostUser {
        let u = try await gitlabUser()
        return CodeHostUser(id: String(u.id), username: u.username, name: u.name)
    }

    public func resolveUser(email: String) async throws -> CodeHostUser? {
        let u = try await findUser(email: email)
        return u.map { CodeHostUser(id: String($0.id), username: $0.username, name: $0.name) }
    }

    private func ids(_ item: FeedItem) throws -> (String, String) {
        guard let pid = item["projectId"], let iid = item["iid"] else { throw HTTPError.notConfigured("Not a GitLab merge request") }
        return (pid, iid)
    }

    public func changeDetail(_ item: FeedItem) async throws -> ChangeDetail {
        let (pid, iid) = try ids(item)
        let d = try await mergeRequest(projectId: pid, iid: iid)
        return ChangeDetail(title: d.title, description: d.description, sourceBranch: d.sourceBranch, targetBranch: d.targetBranch,
                            authorName: d.author?.name)
    }

    public func changeDiffs(_ item: FeedItem) async throws -> [FileDiff] {
        let (pid, iid) = try ids(item)
        return try await mergeRequestDiffs(projectId: pid, iid: iid).map {
            FileDiff(oldPath: $0.oldPath, newPath: $0.newPath, diff: $0.diff, newFile: $0.newFile ?? false, deletedFile: $0.deletedFile ?? false)
        }
    }

    public func approve(_ item: FeedItem) async throws {
        let (pid, iid) = try ids(item)
        try await approve(projectId: pid, iid: iid)
    }

    public func comment(_ item: FeedItem, body: String) async throws {
        let (pid, iid) = try ids(item)
        try await comment(projectId: pid, iid: iid, body: body)
    }

    public func retryPipeline(_ item: FeedItem) async throws {
        guard let pid = item["projectId"], let pipeline = item["pipelineId"] else { throw HTTPError.notConfigured("No pipeline to retry") }
        try await retryPipeline(projectId: pid, pipelineId: pipeline)
    }

    public func markTodoDone(_ item: FeedItem) async throws {
        // Items stored by older versions have no todoId attr; the id ends in it.
        let id = item["todoId"] ?? String(item.id.split(separator: ":").last ?? "")
        try await markTodoDone(id: id)
    }

    func record(_ mr: GitLabMR) -> ChangeRecord {
        ChangeRecord(id: account.id + ".mr:\(mr.projectId):\(mr.iid)", ref: mr.ref, title: mr.title, url: mr.webUrl, state: mr.state,
                     createdAt: mr.createdAt, mergedAt: mr.mergedAt, updatedAt: mr.updatedAt, authorUsername: mr.author?.username,
                     authorName: mr.author?.name, comments: mr.userNotesCount,
                     filesChanged: mr.changesCount.flatMap { Int($0.replacingOccurrences(of: "+", with: "")) })
    }

    /// `references.full` is "group/project!12"; drop MRs outside the account's groups.
    private func inScope(_ mr: GitLabMR) -> Bool {
        guard !account.orgs.isEmpty else { return true }
        guard let full = mr.references?.full, let bang = full.lastIndex(of: "!") else { return false }
        return account.includes(path: String(full[..<bang]))
    }

    public func searchChanges(_ text: String, limit: Int) async throws -> [ChangeRecord] {
        try await searchMergeRequests(text, limit: limit).filter(inScope).map(record)
    }

    public func changes(author: String?, reviewer: String?, state: ChangeState, since: Date, withSize: Bool) async throws -> [ChangeRecord] {
        let s: String
        switch state {
        case .merged: s = "merged"
        case .open: s = "opened"
        case .all: s = "all"
        }
        var mrs = try await mergeRequests(author: author, reviewer: reviewer, state: s, updatedAfter: since).filter(inScope)
        if state == .merged { mrs = mrs.filter { ($0.mergedAt ?? .distantPast) >= since } }
        if withSize {
            // `changes_count` is only on the single-MR endpoint; cap the extra calls.
            for i in mrs.indices.prefix(25) {
                if let full = try? await mergeRequestStats(projectId: mrs[i].projectId, iid: mrs[i].iid) { mrs[i] = full }
            }
        }
        return mrs.map(record)
    }

    public func searchPageURL(_ text: String) -> String {
        "\(baseURL.absoluteString)/dashboard/merge_requests?scope=all&search=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)"
    }

    public func changeURL(path: String, number: String) -> String { "\(baseURL.absoluteString)/\(path)/-/merge_requests/\(number)" }
}
