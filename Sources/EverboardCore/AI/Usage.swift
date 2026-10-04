import Foundation
import GRDB

/// One row of the usage dashboard.
public struct UsageTotals: Sendable, Hashable, Identifiable {
    public var key: String
    public var runs = 0
    public var failures = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public var webSearches = 0
    public var costUSD = 0.0
    public var durationMs = 0
    public var id: String { key }

    public init(key: String) { self.key = key }

    init(key: String, runs: Int, failures: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
         cacheCreationTokens: Int, webSearches: Int, costUSD: Double, durationMs: Int) {
        self.key = key
        self.runs = runs
        self.failures = failures
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.webSearches = webSearches
        self.costUSD = costUSD
        self.durationMs = durationMs
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    public var avgSeconds: Double { runs > 0 ? Double(durationMs) / Double(runs) / 1000 : 0 }
}

extension Store {
    public func recordUsage(feature: String, usage: ClaudeUsage, costUSD: Double?, ok: Bool, now: Date = Date()) async {
        try? await db.write { db in
            try db.execute(sql: """
                INSERT INTO ai_usage (ts, feature, model, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens,
                                      webSearches, costUSD, durationMs, ok) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [now.timeIntervalSince1970, feature, usage.model, usage.inputTokens, usage.outputTokens,
                                 usage.cacheReadTokens, usage.cacheCreationTokens, usage.webSearches, costUSD ?? 0,
                                 usage.durationMs, ok ? 1 : 0])
        }
    }

    /// Totals grouped by `groupBy` ("feature", "model" or "day") since a date.
    public func usage(since: Date, groupBy: String) async throws -> [UsageTotals] {
        let key: String
        switch groupBy {
        case "model": key = "model"
        case "day": key = "date(ts, 'unixepoch', 'localtime')"
        default: key = "feature"
        }
        return try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(key) AS k, COUNT(*) AS runs, SUM(1 - ok) AS failures, SUM(inputTokens) AS i, SUM(outputTokens) AS o,
                       SUM(cacheReadTokens) AS cr, SUM(cacheCreationTokens) AS cc, SUM(webSearches) AS ws,
                       SUM(costUSD) AS cost, SUM(durationMs) AS dur
                FROM ai_usage WHERE ts >= ? GROUP BY k ORDER BY \(groupBy == "day" ? "k" : "cost DESC")
                """, arguments: [since.timeIntervalSince1970]).map { r in
                UsageTotals(key: r["k"] ?? "?", runs: r["runs"], failures: r["failures"] ?? 0, inputTokens: r["i"] ?? 0,
                            outputTokens: r["o"] ?? 0, cacheReadTokens: r["cr"] ?? 0, cacheCreationTokens: r["cc"] ?? 0,
                            webSearches: r["ws"] ?? 0, costUSD: r["cost"] ?? 0, durationMs: r["dur"] ?? 0)
            }
        }
    }

    public func usageTotal(since: Date) async throws -> UsageTotals {
        let rows = try await usage(since: since, groupBy: "feature")
        return rows.reduce(into: UsageTotals(key: "total")) { t, r in
            t.runs += r.runs; t.failures += r.failures; t.inputTokens += r.inputTokens; t.outputTokens += r.outputTokens
            t.cacheReadTokens += r.cacheReadTokens; t.cacheCreationTokens += r.cacheCreationTokens
            t.webSearches += r.webSearches; t.costUSD += r.costUSD; t.durationMs += r.durationMs
        }
    }
}

/// Wraps any runner and records tokens/cost for every call (failures too) in the usage table.
public struct RecordingClaudeRunner: ClaudeRunning {
    let base: ClaudeRunning
    let store: Store

    public init(base: ClaudeRunning, store: Store) {
        self.base = base
        self.store = store
    }

    public func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let started = Date()
        do {
            let r = try await base.run(request)
            var usage = r.usage
            if usage.durationMs == 0 { usage.durationMs = Int(Date().timeIntervalSince(started) * 1000) }
            await store.recordUsage(feature: request.feature, usage: usage, costUSD: r.costUSD, ok: true)
            return r
        } catch {
            var usage = ClaudeUsage()
            usage.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            await store.recordUsage(feature: request.feature, usage: usage, costUSD: nil, ok: false)
            throw error
        }
    }
}
