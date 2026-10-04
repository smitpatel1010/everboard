import Foundation
import GRDB

public struct NewsFeedback: Codable, Sendable, Hashable {
    public enum Vote: String, Codable, Sendable { case up, down, more, less, note }
    public var ts: Date
    public var storyKey: String?
    public var title: String?
    public var vote: Vote
    public var topic: String?
    public var note: String?

    public init(ts: Date = Date(), storyKey: String? = nil, title: String? = nil, vote: Vote, topic: String? = nil, note: String? = nil) {
        self.ts = ts
        self.storyKey = storyKey
        self.title = title
        self.vote = vote
        self.topic = topic
        self.note = note
    }
}

extension Store {
    /// Inserts new articles (ignoring ones already stored) and assigns cluster keys by title similarity.
    /// Returns the articles that were new.
    @discardableResult
    public func insertArticles(_ articles: [Article], now: Date = Date()) async throws -> [Article] {
        try await db.write { db in
            let recent = try Row.fetchAll(db, sql: "SELECT title, clusterKey FROM articles WHERE fetchedAt > ?",
                                          arguments: [now.timeIntervalSince1970 - 2 * 86400])
            var known = recent.map { (tokens: NewsText.tokens($0["title"]), cluster: $0["clusterKey"] as String) }
            var inserted: [Article] = []
            for var a in articles {
                if try Bool.fetchOne(db, sql: "SELECT 1 FROM articles WHERE id = ?", arguments: [a.id]) == true { continue }
                let t = NewsText.tokens(a.title)
                if let match = known.first(where: { NewsText.sameStory($0.tokens, t) }) { a.clusterKey = match.cluster }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO articles (id, url, title, source, section, snippet, publishedAt, score, fetchedAt, clusterKey)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [a.id, a.url, a.title, a.source, a.section.rawValue, a.snippet,
                                     a.publishedAt?.timeIntervalSince1970, a.score, now.timeIntervalSince1970, a.clusterKey])
                known.append((t, a.clusterKey))
                inserted.append(a)
            }
            // HN scores move; refresh them for articles we already had.
            for a in articles where a.score != nil {
                try db.execute(sql: "UPDATE articles SET score = ? WHERE id = ?", arguments: [a.score, a.id])
            }
            return inserted
        }
    }

    public func articles(since: Date) async throws -> [Article] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM articles WHERE fetchedAt > ? ORDER BY fetchedAt DESC",
                             arguments: [since.timeIntervalSince1970]).map(Self.article)
        }
    }

    static func article(_ row: Row) -> Article {
        var a = Article(url: row["url"], title: row["title"], source: row["source"],
                        section: NewsSection(rawValue: row["section"]) ?? .tech, snippet: row["snippet"],
                        publishedAt: (row["publishedAt"] as Double?).map { Date(timeIntervalSince1970: $0) },
                        score: row["score"], fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))
        a.id = row["id"]
        a.clusterKey = row["clusterKey"]
        return a
    }

    public func shownArticleIDs() async throws -> Set<String> {
        try await db.read { db in Set(try String.fetchAll(db, sql: "SELECT key FROM shown_stories")) }
    }

    public func recentlyShownTitles(days: Double = 3, now: Date = Date()) async throws -> [String] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT title FROM shown_stories WHERE shownAt > ? AND key LIKE 'story:%'",
                                arguments: [now.timeIntervalSince1970 - days * 86400])
        }
    }

    public func markShown(_ keys: [(key: String, title: String)], now: Date = Date()) async throws {
        try await db.write { db in
            for k in keys {
                try db.execute(sql: "INSERT OR REPLACE INTO shown_stories (key, title, shownAt) VALUES (?, ?, ?)",
                               arguments: [k.key, k.title, now.timeIntervalSince1970])
            }
        }
    }

    public func saveBrief(_ brief: NewsBrief) async throws {
        let json = String(decoding: try JSONEncoder.everboard.encode(brief), as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO news_briefs (id, createdAt, json) VALUES (?, ?, ?)",
                           arguments: [brief.id, brief.createdAt.timeIntervalSince1970, json])
        }
    }

    public func latestBrief() async throws -> NewsBrief? {
        try await db.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM news_briefs ORDER BY createdAt DESC LIMIT 1") else { return nil }
            return try? JSONDecoder.everboard.decode(NewsBrief.self, from: Data(json.utf8))
        }
    }

    public func addFeedback(_ f: NewsFeedback) async throws {
        try await db.write { db in
            try db.execute(sql: "INSERT INTO news_feedback (ts, storyKey, title, vote, topic, note) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [f.ts.timeIntervalSince1970, f.storyKey, f.title, f.vote.rawValue, f.topic, f.note])
        }
    }

    public func feedback(unappliedOnly: Bool, limit: Int = 50) async throws -> [NewsFeedback] {
        try await db.read { db in
            let sql = "SELECT * FROM news_feedback" + (unappliedOnly ? " WHERE applied = 0" : "") + " ORDER BY ts DESC LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [limit]).compactMap { row in
                guard let vote = NewsFeedback.Vote(rawValue: row["vote"]) else { return nil }
                return NewsFeedback(ts: Date(timeIntervalSince1970: row["ts"]), storyKey: row["storyKey"],
                                    title: row["title"], vote: vote, topic: row["topic"], note: row["note"])
            }
        }
    }

    /// Votes per story key, so the UI can show what was already rated.
    public func votes(forStoryKeys keys: [String]) async throws -> [String: NewsFeedback.Vote] {
        guard !keys.isEmpty else { return [:] }
        return try await db.read { db in
            var out: [String: NewsFeedback.Vote] = [:]
            for k in keys {
                if let v = try String.fetchOne(db, sql: "SELECT vote FROM news_feedback WHERE storyKey = ? AND vote IN ('up','down') ORDER BY ts DESC LIMIT 1", arguments: [k]) {
                    out[k] = NewsFeedback.Vote(rawValue: v)
                }
            }
            return out
        }
    }

    public func markFeedbackApplied() async throws {
        try await db.write { db in try db.execute(sql: "UPDATE news_feedback SET applied = 1 WHERE applied = 0") }
    }
}
