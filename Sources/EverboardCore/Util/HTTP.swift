import Foundation

public enum HTTPError: Error, LocalizedError, Sendable {
    /// DNS / connect / timeout — for a self-hosted GitLab this usually means the VPN is off.
    case unreachable(String)
    case unauthorized(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case status(Int, String)
    case decoding(String)
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "Unreachable: \(m)"
        case .unauthorized(let c): return "Auth failed (HTTP \(c)) — check the token"
        case .rateLimited(let r): return "Rate limited" + (r.map { ", retry in \(Int($0))s" } ?? "")
        case .status(let c, let body): return "HTTP \(c): \(body.prefix(200))"
        case .decoding(let m): return "Unexpected response: \(m)"
        case .notConfigured(let m): return m
        }
    }
}

/// Thin JSON-over-HTTPS client shared by the GitLab, GitHub, Jira and news fetchers.
public struct HTTPClient: Sendable {
    public let baseURL: URL?
    public let headers: [String: String]
    public let session: URLSession

    public init(baseURL: URL?, headers: [String: String] = [:], session: URLSession = .everboard) {
        self.baseURL = baseURL
        self.headers = headers
        self.session = session
    }

    public func url(_ path: String, query: [String: String?] = [:]) throws -> URL {
        let full: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let u = URL(string: path) else { throw HTTPError.notConfigured("Bad URL \(path)") }
            full = u
        } else {
            guard let baseURL else { throw HTTPError.notConfigured("No base URL") }
            // Paths may already contain percent-encoding (e.g. GitLab project paths), so append raw.
            let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
            guard let u = URL(string: base + path) else { throw HTTPError.notConfigured("Bad path \(path)") }
            full = u
        }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        guard !items.isEmpty, var comps = URLComponents(url: full, resolvingAgainstBaseURL: false) else { return full }
        comps.queryItems = (comps.queryItems ?? []) + items
        // URLComponents leaves '+' unescaped, which servers read as a space (breaks ISO dates with +05:30).
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? full
    }

    public func data(_ method: String = "GET", _ path: String, query: [String: String?] = [:], body: Data? = nil,
                     extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: try url(path, query: query))
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers.merging(extraHeaders, uniquingKeysWith: { $1 }) { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw HTTPError.unreachable(e.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.decoding("non-HTTP response") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401, 403: throw HTTPError.unauthorized(http.statusCode)
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HTTPError.rateLimited(retryAfter: retry)
        case 502, 503, 504: throw HTTPError.unreachable("HTTP \(http.statusCode)")
        default: throw HTTPError.status(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    public func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String,
                                   query: [String: String?] = [:], body: Data? = nil) async throws -> T {
        let (data, _) = try await self.data(method, path, query: query, body: body)
        do {
            return try JSONDecoder.everboard.decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding("\(T.self): \(error)")
        }
    }
}

extension URLSession {
    /// Short timeouts so a dead VPN fails fast instead of hanging a poll cycle.
    public static let everboard: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()
}

public enum SafeURL {
    /// Only web links may be opened from untrusted data (feeds, API fields, AI output) — never file:// or app schemes.
    public static func web(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// Token-bearing API endpoints must be HTTPS (plain HTTP allowed only for localhost testing).
    public static func isSecureEndpoint(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
}
