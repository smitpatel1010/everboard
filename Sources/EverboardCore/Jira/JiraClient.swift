import Foundation

/// Jira Cloud REST v3 with email + API token (basic auth).
public struct JiraClient: Sendable {
    public let baseURL: URL
    let http: HTTPClient

    public static let listFields = ["summary", "status", "assignee", "reporter", "priority", "issuetype", "updated", "created", "duedate"]

    public init(baseURL: URL, email: String, token: String, session: URLSession = .everboard) {
        self.baseURL = baseURL
        let basic = Data("\(email):\(token)".utf8).base64EncodedString()
        self.http = HTTPClient(baseURL: baseURL, headers: ["Authorization": "Basic \(basic)"], session: session)
    }

    public init?(secrets: Secrets, session: URLSession = .everboard) {
        guard let url = secrets.jiraBaseURL, let email = secrets[.jiraEmail], let token = secrets[.jiraToken] else { return nil }
        self.init(baseURL: url, email: email, token: token, session: session)
    }

    public func browseURL(_ key: String) -> String { baseURL.absoluteString + "/browse/" + key }

    public func myself() async throws -> JiraUser {
        try await http.json(JiraUser.self, "GET", "/rest/api/3/myself")
    }

    /// `POST /search/jql` (the paginated replacement for the retired `/search`).
    public func search(_ jql: String, fields: [String] = JiraClient.listFields, max: Int = 100) async throws -> [JiraIssue] {
        var issues: [JiraIssue] = []
        var token: String?
        repeat {
            var body: [String: JSONValue] = [
                "jql": .string(jql),
                "fields": .array(fields.map { .string($0) }),
                "maxResults": .number(Double(min(100, max - issues.count))),
            ]
            if let token { body["nextPageToken"] = .string(token) }
            let page = try await http.json(JiraSearchResponse.self, "POST", "/rest/api/3/search/jql",
                                           body: try JSONEncoder().encode(body))
            issues += page.issues
            token = (page.isLast == true) ? nil : page.nextPageToken
        } while token != nil && issues.count < max
        return issues
    }

    public func favouriteFilters() async throws -> [JiraFilter] {
        try await http.json([JiraFilter].self, "GET", "/rest/api/3/filter/favourite")
    }

    public func filter(id: String) async throws -> JiraFilter {
        try await http.json(JiraFilter.self, "GET", "/rest/api/3/filter/\(id)")
    }

    public func comments(issueKey: String, max: Int = 10) async throws -> [JiraComment] {
        try await http.json(JiraCommentPage.self, "GET", "/rest/api/3/issue/\(issueKey)/comment",
                            query: ["orderBy": "-created", "maxResults": String(max)]).comments
    }

    public struct Transition: Decodable, Sendable, Identifiable, Hashable {
        public struct To: Decodable, Sendable, Hashable { public var name: String }
        public var id: String
        public var name: String
        public var to: To?
    }

    public func transitions(issueKey: String) async throws -> [Transition] {
        struct Page: Decodable { let transitions: [Transition] }
        return try await http.json(Page.self, "GET", "/rest/api/3/issue/\(issueKey)/transitions").transitions
    }

    public func transition(issueKey: String, to transitionId: String) async throws {
        let body = try JSONEncoder().encode(["transition": ["id": transitionId]])
        _ = try await http.data("POST", "/rest/api/3/issue/\(issueKey)/transitions", body: body)
    }

    /// Plain-text comment, wrapped in a minimal ADF document.
    public func addComment(issueKey: String, text: String) async throws {
        let doc: JSONValue = .object(["body": .object([
            "type": .string("doc"), "version": .number(1),
            "content": .array([.object(["type": .string("paragraph"),
                                        "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]),
        ])])
        _ = try await http.data("POST", "/rest/api/3/issue/\(issueKey)/comment", body: try JSONEncoder().encode(doc))
    }

    /// Text search, or a direct key lookup when the query looks like ABC-123.
    public func quickSearch(_ text: String, limit: Int = 8) async throws -> [JiraIssue] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[A-Za-z][A-Za-z0-9]+-\d+$"#, options: .regularExpression) != nil {
            return try await search("key = \(t.uppercased())", max: 1)
        }
        let escaped = t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await search("text ~ \"\(escaped)*\" ORDER BY updated DESC", max: limit)
    }

    /// Email → Jira accountId (for reportees' Jira activity in reports).
    public func findUser(email: String) async throws -> JiraUser? {
        try await http.json([JiraUser].self, "GET", "/rest/api/3/user/search", query: ["query": email]).first
    }

    /// Full issue with rendered HTML description, for AI digests.
    public func issue(key: String) async throws -> JiraIssue {
        try await http.json(JiraIssue.self, "GET", "/rest/api/3/issue/\(key)", query: [
            "expand": "renderedFields",
            "fields": (Self.listFields + ["description"]).joined(separator: ","),
        ])
    }
}
