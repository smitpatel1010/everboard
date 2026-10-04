import Foundation
import GRDB

public struct FollowedStory: Codable, Sendable, Identifiable, Hashable {
    public var key: String
    public var title: String
    public var tokens: Set<String>
    public var createdAt: Date
    public var id: String { key }
}

public struct StoryUpdate: Codable, Sendable, Identifiable, Hashable {
    public var articleId: String
    public var title: String
    public var url: String
    public var source: String
    public var publishedAt: Date?
    public var id: String { articleId }
}

public enum FollowMatch {
    /// Looser than `sameStory`: a follow-up article shares the story's key terms but has a different headline.
    public static func matches(_ story: Set<String>, _ article: Set<String>) -> Bool {
        let shared = story.intersection(article).count
        guard shared >= 2 else { return false }
        return Double(shared) / Double(min(story.count, article.count).clamped(to: 1...)) >= 0.4
    }
}

extension Comparable {
    func clamped(to r: PartialRangeFrom<Self>) -> Self { max(self, r.lowerBound) }
}

extension Store {
    public func follow(_ story: NewsBrief.Story, now: Date = Date()) async throws {
        let tokens = NewsText.tokens(story.title).union(story.topics.flatMap { NewsText.tokens($0) })
        try await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO followed_stories (key, title, tokens, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [story.key, story.title, tokens.sorted().joined(separator: " "), now.timeIntervalSince1970])
        }
    }

    public func unfollow(_ key: String) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM followed_stories WHERE key = ?", arguments: [key])
            try db.execute(sql: "DELETE FROM followed_matches WHERE storyKey = ?", arguments: [key])
        }
    }

    public func followedStories() async throws -> [FollowedStory] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM followed_stories ORDER BY createdAt DESC").map { row in
                FollowedStory(key: row["key"], title: row["title"],
                              tokens: Set((row["tokens"] as String).split(separator: " ").map(String.init)),
                              createdAt: Date(timeIntervalSince1970: row["createdAt"]))
            }
        }
    }

    public func updates(for key: String) async throws -> [StoryUpdate] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM followed_matches WHERE storyKey = ? ORDER BY publishedAt DESC", arguments: [key]).map { row in
                StoryUpdate(articleId: row["articleId"], title: row["title"], url: row["url"], source: row["source"],
                            publishedAt: (row["publishedAt"] as Double?).map { Date(timeIntervalSince1970: $0) })
            }
        }
    }

    /// Records new articles matching followed stories; returns one event per new match.
    public func matchFollowed(_ articles: [Article], now: Date = Date()) async throws -> [AppEvent] {
        let stories = try await followedStories()
        guard !stories.isEmpty, !articles.isEmpty else { return [] }
        return try await db.write { db in
            var events: [AppEvent] = []
            for a in articles {
                let t = NewsText.tokens(a.title)
                for s in stories where FollowMatch.matches(s.tokens, t) && (a.publishedAt ?? a.fetchedAt) > s.createdAt.addingTimeInterval(-3600) {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO followed_matches (storyKey, articleId, title, url, source, publishedAt) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [s.key, a.id, a.title, a.url, a.source, a.publishedAt?.timeIntervalSince1970])
                    guard db.changesCount > 0 else { continue }
                    let e = AppEvent(id: "news.follow:\(s.key):\(a.id)", ts: now, category: .newsFollow,
                                     title: "Update: \(s.title)", body: "\(a.title) — \(a.source)", url: a.url, scope: "news", itemId: s.key)
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO events (id, ts, category, title, body, url, scope, itemId, read, notified)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                        """, arguments: [e.id, now.timeIntervalSince1970, e.category.rawValue, e.title, e.body, e.url, e.scope, e.itemId])
                    if db.changesCount > 0 { events.append(e) }
                }
            }
            return events
        }
    }
}

extension NewsService {
    /// Answer a question about today's news, grounded in collected articles (+ optional web search).
    public func ask(_ question: String, brief: NewsBrief?, webSearch: Bool) async throws -> String {
        let articles = try await store.articles(since: Date().addingTimeInterval(-48 * 3600)).prefix(220)
        let lines = articles.map { "- (\($0.source)) \($0.title) — \($0.snippet.prefix(160)) <\($0.url)>" }.joined(separator: "\n")
        let briefText = brief.map { b in b.sections.flatMap { s in s.stories.map { "- [\(s.name)] \($0.title): \($0.summary)" } }.joined(separator: "\n") } ?? ""
        let prompt = """
        Answer my question about recent news using the material below\(webSearch ? " (use WebSearch if it isn't enough)" : ""). \
        Be concise, cite sources inline as markdown links, and say clearly if the material doesn't cover it.

        Question: \(question)

        # Today's brief
        \(briefText)

        # Articles from the last 48h
        \(lines)
        """
        return try await claude.run(ClaudeRequest(prompt: prompt, tools: webSearch ? ["WebSearch", "WebFetch"] : [], timeout: 240, feature: "news.ask")).text
    }
}
