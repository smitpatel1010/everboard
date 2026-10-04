import Foundation

/// GitLab REST v4 + GraphQL. Needs a PAT with `read_api`.
public struct GitLabClient: Sendable {
    public let baseURL: URL
    let http: HTTPClient

    public init(baseURL: URL, token: String, session: URLSession = .everboard) {
        self.baseURL = baseURL
        self.http = HTTPClient(baseURL: baseURL, headers: ["PRIVATE-TOKEN": token], session: session)
    }

    public init?(secrets: Secrets, session: URLSession = .everboard) {
        guard let url = secrets.gitlabBaseURL, let token = secrets[.gitlabToken] else { return nil }
        self.init(baseURL: url, token: token, session: session)
    }

    // MARK: REST

    public func currentUser() async throws -> GitLabUser {
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
    public func resolveUser(email: String) async throws -> GitLabUser? {
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
