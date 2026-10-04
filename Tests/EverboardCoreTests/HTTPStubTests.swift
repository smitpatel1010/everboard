import Foundation
import Testing
@testable import EverboardCore

/// Serves canned responses keyed by path + query, and records requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session(_ routes: [String: (Int, String)]) -> URLSession {
        Self.routes = routes
        Self.requests = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let (status, body) = Self.routes[key] ?? Self.routes[url.path] ?? (404, "{}")
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct HTTPStubTests {
    @Test func resolveUserFallsBackToEmailLocalPart() async throws {
        let session = StubProtocol.session([
            "/api/v4/users?search=asha.k@example.com": (200, "[]"),
            "/api/v4/users?username=asha.k": (200, #"[{"id":5,"username":"asha.k","name":"Asha K"}]"#),
        ])
        let client = GitLabClient(baseURL: URL(string: "https://gl.example")!, token: "t", session: session)
        let user = try await client.resolveUser(email: "asha.k@example.com")
        #expect(user?.username == "asha.k")
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "t")
    }

    @Test func unauthorizedMapsToAuthError() async {
        let session = StubProtocol.session(["/rest/api/3/myself": (401, "{}")])
        let client = JiraClient(baseURL: URL(string: "https://x.atlassian.net")!, email: "a@b.c", token: "t", session: session)
        await #expect(throws: HTTPError.self) { try await client.myself() }
        let auth = StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Basic " + Data("a@b.c:t".utf8).base64EncodedString())
    }

    @Test func jiraSearchPaginates() async throws {
        // Both pages share a path; the stub serves page 1, so cap via max to prove the loop terminates.
        let page = #"{"issues":[{"id":"1","key":"A-1","fields":{"summary":"One","status":{"name":"To Do"}}}],"nextPageToken":"n2","isLast":false}"#
        let session = StubProtocol.session(["/rest/api/3/search/jql": (200, page)])
        let client = JiraClient(baseURL: URL(string: "https://x.atlassian.net")!, email: "a", token: "t", session: session)
        let issues = try await client.search("assignee = currentUser()", max: 3)
        #expect(issues.count == 3)
        #expect(issues.first?.fields.status?.name == "To Do")
    }

    @Test func plusSignsInQueryAreEscaped() throws {
        let http = HTTPClient(baseURL: URL(string: "https://gl.example")!)
        let url = try http.url("/api/v4/x", query: ["updated_after": "2026-10-03T10:00:00+05:30"])
        #expect(url.absoluteString.contains("%2B05:30"))
    }
}
