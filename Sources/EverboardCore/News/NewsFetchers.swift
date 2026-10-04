import Foundation

/// Fetches one news source into articles.
public enum NewsFetchers {
    public static func fetch(_ source: NewsSource, secrets: Secrets, session: URLSession = .everboard) async throws -> [Article] {
        switch source.kind {
        case .feed: return try await feed(source, session: session)
        case .hackerNews: return try await hackerNews(source, session: session)
        case .githubTrending: return try await githubTrending(source, token: secrets[.githubToken], session: session)
        }
    }

    static func feed(_ source: NewsSource, session: URLSession) async throws -> [Article] {
        let http = HTTPClient(baseURL: nil, session: session)
        let (data, _) = try await http.data("GET", source.url, extraHeaders: ["Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"])
        let entries = FeedParser.parse(data)
        if entries.isEmpty { throw HTTPError.decoding("no entries parsed") }
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        return entries.prefix(40)
            .filter { ($0.published ?? Date()) > cutoff }
            .map { Article(url: $0.link, title: $0.title, source: source.name, section: source.section,
                           snippet: $0.summary, publishedAt: $0.published) }
    }

    struct HNItem: Decodable {
        let id: Int
        let title: String?
        let url: String?
        let score: Int?
        let descendants: Int?
        let time: Double?
        let type: String?
    }

    static func hackerNews(_ source: NewsSource, session: URLSession, minScore: Int = 100) async throws -> [Article] {
        let http = HTTPClient(baseURL: URL(string: "https://hacker-news.firebaseio.com/v0"), session: session)
        let ids = try await http.json([Int].self, "GET", "/topstories.json").prefix(60)
        let items = await withTaskGroup(of: HNItem?.self) { group in
            for id in ids { group.addTask { try? await http.json(HNItem.self, "GET", "/item/\(id).json") } }
            var out: [HNItem] = []
            for await i in group { if let i { out.append(i) } }
            return out
        }
        return items.filter { ($0.score ?? 0) >= minScore && $0.type == "story" }.compactMap { i in
            guard let title = i.title else { return nil }
            let discussion = "https://news.ycombinator.com/item?id=\(i.id)"
            return Article(url: i.url ?? discussion, title: title, source: source.name, section: source.section,
                           snippet: "\(i.score ?? 0) points · \(i.descendants ?? 0) comments · \(discussion)",
                           publishedAt: i.time.map { Date(timeIntervalSince1970: $0) }, score: i.score)
        }
    }

    struct GHSearch: Decodable {
        struct Repo: Decodable {
            let fullName: String
            let htmlUrl: String
            let description: String?
            let stargazersCount: Int
            let language: String?
            let createdAt: Date?
            enum CodingKeys: String, CodingKey {
                case description, language
                case fullName = "full_name"
                case htmlUrl = "html_url"
                case stargazersCount = "stargazers_count"
                case createdAt = "created_at"
            }
        }
        let items: [Repo]
    }

    static func githubTrending(_ source: NewsSource, token: String?, session: URLSession) async throws -> [Article] {
        var headers = ["Accept": "application/vnd.github+json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let http = HTTPClient(baseURL: nil, headers: headers, session: session)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let since = f.string(from: Date().addingTimeInterval(-7 * 86400))
        let r = try await http.json(GHSearch.self, "GET", source.url,
                                    query: ["q": "created:>\(since)", "sort": "stars", "order": "desc", "per_page": "15"])
        return r.items.map { repo in
            Article(url: repo.htmlUrl, title: "\(repo.fullName): \(repo.description ?? "new repository")",
                    source: source.name, section: source.section,
                    snippet: "★ \(repo.stargazersCount) in its first week · \(repo.language ?? "unknown language")",
                    publishedAt: repo.createdAt, score: repo.stargazersCount)
        }
    }
}
