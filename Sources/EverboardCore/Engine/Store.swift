import Foundation
import GRDB

/// SQLite persistence: item snapshots, the event inbox, cursors, AI cache and news data.
public final class Store: Sendable {
    public let db: any DatabaseWriter

    public init(url: URL = AppInfo.databaseURL) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        db = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(db)
    }

    private init(writer: any DatabaseWriter) throws {
        db = writer
        try Self.migrator.migrate(db)
    }

    /// In-memory store for tests and `--dry-run`.
    public static func inMemory() throws -> Store { try Store(writer: DatabaseQueue()) }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE items (
                scope TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL,
                present INTEGER NOT NULL DEFAULT 1, firstSeen REAL NOT NULL, lastSeen REAL NOT NULL,
                PRIMARY KEY (scope, id));
            CREATE TABLE events (
                id TEXT PRIMARY KEY, ts REAL NOT NULL, category TEXT NOT NULL, title TEXT NOT NULL,
                body TEXT NOT NULL, url TEXT, scope TEXT, itemId TEXT,
                read INTEGER NOT NULL DEFAULT 0, notified INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX events_ts ON events(ts);
            CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE ai_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE TABLE articles (
                id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL, source TEXT NOT NULL,
                section TEXT NOT NULL, snippet TEXT NOT NULL, publishedAt REAL, score INTEGER,
                fetchedAt REAL NOT NULL, clusterKey TEXT NOT NULL);
            CREATE INDEX articles_fetched ON articles(fetchedAt);
            CREATE TABLE news_briefs (id TEXT PRIMARY KEY, createdAt REAL NOT NULL, json TEXT NOT NULL);
            CREATE TABLE news_feedback (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, storyKey TEXT, title TEXT,
                vote TEXT NOT NULL, topic TEXT, note TEXT, applied INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE shown_stories (key TEXT PRIMARY KEY, title TEXT NOT NULL, shownAt REAL NOT NULL);
            """)
        }
        m.registerMigration("v2-follow") { db in
            try db.execute(sql: """
            CREATE TABLE followed_stories (key TEXT PRIMARY KEY, title TEXT NOT NULL, tokens TEXT NOT NULL, createdAt REAL NOT NULL);
            CREATE TABLE followed_matches (
                storyKey TEXT NOT NULL, articleId TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL,
                source TEXT NOT NULL, publishedAt REAL, PRIMARY KEY (storyKey, articleId));
            """)
        }
        m.registerMigration("v3-usage") { db in
            try db.execute(sql: """
            CREATE TABLE ai_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, feature TEXT NOT NULL, model TEXT NOT NULL,
                inputTokens INTEGER NOT NULL, outputTokens INTEGER NOT NULL, cacheReadTokens INTEGER NOT NULL,
                cacheCreationTokens INTEGER NOT NULL, webSearches INTEGER NOT NULL, costUSD REAL NOT NULL,
                durationMs INTEGER NOT NULL, ok INTEGER NOT NULL);
            CREATE INDEX ai_usage_ts ON ai_usage(ts);
            """)
        }
        return m
    }

    // MARK: - Snapshots

    public struct ScopeState: Sendable {
        public var previous: [String: FeedItem]
        public var present: Set<String>
        public var seen: Set<String>
        public var synced: Bool
    }

    public func scopeState(_ scope: String) async throws -> ScopeState {
        try await db.read { db in
            var previous: [String: FeedItem] = [:]
            var present = Set<String>()
            for row in try Row.fetchAll(db, sql: "SELECT id, json, present FROM items WHERE scope = ?", arguments: [scope]) {
                let id: String = row["id"]
                if let item = Self.decodeItem(row["json"]) { previous[id] = item }
                if (row["present"] as Int) == 1 { present.insert(id) }
            }
            let synced = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: ["synced.\(scope)"]) != nil
            return ScopeState(previous: previous, present: present, seen: Set(previous.keys), synced: synced)
        }
    }

    /// Persist a scope fetch and its events. Returns only events that were new (dedup by id).
    @discardableResult
    public func apply(_ result: ScopeResult, events: [AppEvent], now: Date = Date()) async throws -> [AppEvent] {
        try await db.write { db in
            if result.mode == .replace {
                try db.execute(sql: "UPDATE items SET present = 0 WHERE scope = ?", arguments: [result.scope])
            }
            for item in result.items {
                try db.execute(sql: """
                    INSERT INTO items (scope, id, json, present, firstSeen, lastSeen) VALUES (?, ?, ?, 1, ?, ?)
                    ON CONFLICT(scope, id) DO UPDATE SET json = excluded.json, present = 1, lastSeen = excluded.lastSeen
                    """, arguments: [result.scope, item.id, Self.encodeItem(item), now.timeIntervalSince1970, now.timeIntervalSince1970])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                           arguments: ["synced.\(result.scope)", Dates.iso(now)])
            var inserted: [AppEvent] = []
            for e in events {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO events (id, ts, category, title, body, url, scope, itemId, read, notified)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                    """, arguments: [e.id, e.ts.timeIntervalSince1970, e.category.rawValue, e.title, e.body, e.url, e.scope, e.itemId])
                if db.changesCount > 0 { inserted.append(e) }
            }
            return inserted
        }
    }

    public func items(scopePrefix: String, presentOnly: Bool = true) async throws -> [FeedItem] {
        try await db.read { db in
            let sql = "SELECT json FROM items WHERE scope LIKE ? ESCAPE '\\'" + (presentOnly ? " AND present = 1" : "")
            let pattern = scopePrefix.replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "%", with: "\\%") + "%"
            return try String.fetchAll(db, sql: sql, arguments: [pattern]).compactMap(Self.decodeItem)
        }
    }

    public func items(scope: String, presentOnly: Bool = true) async throws -> [FeedItem] {
        try await db.read { db in
            let sql = "SELECT json FROM items WHERE scope = ?" + (presentOnly ? " AND present = 1" : "")
            return try String.fetchAll(db, sql: sql, arguments: [scope]).compactMap(Self.decodeItem)
        }
    }

    /// Drop stale rows so the database stays small.
    public func prune(now: Date = Date()) async throws {
        try await db.write { db in
            let t = now.timeIntervalSince1970
            try db.execute(sql: "DELETE FROM items WHERE present = 0 AND lastSeen < ?", arguments: [t - 30 * 86400])
            try db.execute(sql: "DELETE FROM items WHERE scope LIKE 'gitlab.pipelines.%' AND lastSeen < ?", arguments: [t - 14 * 86400])
            try db.execute(sql: "DELETE FROM items WHERE scope = 'jira.comments' AND lastSeen < ?", arguments: [t - 30 * 86400])
            try db.execute(sql: "DELETE FROM events WHERE ts < ?", arguments: [t - 45 * 86400])
            try db.execute(sql: "DELETE FROM articles WHERE fetchedAt < ?", arguments: [t - 4 * 86400])
            try db.execute(sql: "DELETE FROM shown_stories WHERE shownAt < ?", arguments: [t - 14 * 86400])
            try db.execute(sql: "DELETE FROM ai_cache WHERE createdAt < ?", arguments: [t - 30 * 86400])
            try db.execute(sql: "DELETE FROM followed_matches WHERE storyKey IN (SELECT key FROM followed_stories WHERE createdAt < ?)", arguments: [t - 30 * 86400])
            try db.execute(sql: "DELETE FROM followed_stories WHERE createdAt < ?", arguments: [t - 30 * 86400])
        }
    }

    // MARK: - Events

    public func events(limit: Int = 300, unreadOnly: Bool = false) async throws -> [AppEvent] {
        try await db.read { db in
            let sql = "SELECT * FROM events" + (unreadOnly ? " WHERE read = 0" : "") + " ORDER BY ts DESC LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [limit]).compactMap(Self.decodeEvent)
        }
    }

    public func unreadCount() async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE read = 0") ?? 0 }
    }

    public func markRead(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await db.write { db in
            for id in ids { try db.execute(sql: "UPDATE events SET read = 1 WHERE id = ?", arguments: [id]) }
        }
    }

    public func markAllRead() async throws {
        try await db.write { db in try db.execute(sql: "UPDATE events SET read = 1 WHERE read = 0") }
    }

    public func markNotified(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await db.write { db in
            for id in ids { try db.execute(sql: "UPDATE events SET notified = 1 WHERE id = ?", arguments: [id]) }
        }
    }

    /// Insert a one-off event (brief ready, major story). Returns false if it already existed.
    @discardableResult
    public func insert(event e: AppEvent) async throws -> Bool {
        try await db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO events (id, ts, category, title, body, url, scope, itemId, read, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [e.id, e.ts.timeIntervalSince1970, e.category.rawValue, e.title, e.body, e.url, e.scope, e.itemId, e.read ? 1 : 0])
            return db.changesCount > 0
        }
    }

    // MARK: - Key/value + AI cache

    public func value(_ key: String) async -> String? {
        try? await db.read { db in try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) }
    }

    public func setValue(_ key: String, _ value: String?) async {
        try? await db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    public func cached(_ key: String) async -> String? {
        try? await db.read { db in try String.fetchOne(db, sql: "SELECT value FROM ai_cache WHERE key = ?", arguments: [key]) }
    }

    public func cache(_ key: String, _ value: String, now: Date = Date()) async {
        try? await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO ai_cache (key, value, createdAt) VALUES (?, ?, ?)",
                           arguments: [key, value, now.timeIntervalSince1970])
        }
    }

    // MARK: - Coding helpers

    static func encodeItem(_ item: FeedItem) -> String {
        (try? String(decoding: JSONEncoder.everboard.encode(item), as: UTF8.self)) ?? "{}"
    }

    static func decodeItem(_ json: String) -> FeedItem? {
        try? JSONDecoder.everboard.decode(FeedItem.self, from: Data(json.utf8))
    }

    static func decodeEvent(_ row: Row) -> AppEvent? {
        guard let category = EventCategory(rawValue: row["category"]) else { return nil }
        return AppEvent(id: row["id"], ts: Date(timeIntervalSince1970: row["ts"]), category: category,
                        title: row["title"], body: row["body"], url: row["url"], scope: row["scope"],
                        itemId: row["itemId"], read: (row["read"] as Int) == 1)
    }
}

/// Bridges the store to sources without exposing write access to snapshots.
public struct StoreFetchContext: FetchContext {
    public let store: Store
    public let config: AppConfig

    public init(store: Store, config: AppConfig) {
        self.store = store
        self.config = config
    }

    public func value(_ key: String) async -> String? { await store.value(key) }
    public func setValue(_ key: String, _ value: String?) async { await store.setValue(key, value) }
    public func items(scopePrefix: String, presentOnly: Bool) async -> [FeedItem] {
        (try? await store.items(scopePrefix: scopePrefix, presentOnly: presentOnly)) ?? []
    }
}
