import Foundation
import GRDB

/// One Claude call exactly as it left the Mac (after masking), and what came back. Kept locally for review.
public struct AILogEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var ts: Date
    public var feature: String
    public var model: String
    public var tools: [String]
    public var systemPrompt: String
    public var prompt: String
    public var response: String
    public var ok: Bool
    public var error: String?
    public var redactions: [String: Int]
    public var costUSD: Double
    public var inputTokens: Int
    public var outputTokens: Int
    /// Prompt size; set even when the list query leaves `prompt` empty.
    public var promptChars: Int

    public var isWork: Bool { PrivacyPolicy.isWorkFeature(feature) }
    public var redactionTotal: Int { redactions.values.reduce(0, +) }
}

extension Store {
    public func logAICall(_ request: ClaudeRequest, response: ClaudeResponse?, error: Error?, now: Date = Date()) async {
        let redactions = (try? String(decoding: JSONEncoder().encode(request.redactions), as: UTF8.self)) ?? "{}"
        try? await db.write { db in
            try db.execute(sql: """
                INSERT INTO ai_log (ts, feature, model, tools, systemPrompt, prompt, response, ok, error, redactions,
                                    costUSD, inputTokens, outputTokens) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [now.timeIntervalSince1970, request.feature, response?.usage.model ?? request.model ?? "",
                                 request.tools.joined(separator: ","), request.systemPrompt ?? "", request.prompt,
                                 response?.text ?? "", response == nil ? 0 : 1, error?.localizedDescription, redactions,
                                 response?.costUSD ?? 0, response?.usage.inputTokens ?? 0, response?.usage.outputTokens ?? 0])
        }
    }

    /// Newest first. Big text columns are left empty; load one with `aiLogEntry(id:)`.
    public func aiLog(limit: Int = 300, since: Date? = nil) async throws -> [AILogEntry] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, ts, feature, model, tools, '' AS systemPrompt, '' AS prompt, '' AS response, ok, error, redactions,
                       costUSD, inputTokens, outputTokens, length(prompt) AS promptChars
                FROM ai_log WHERE ts >= ? ORDER BY ts DESC LIMIT ?
                """, arguments: [(since ?? .distantPast).timeIntervalSince1970, limit]).map(Self.decodeLog)
        }
    }

    public func aiLogEntry(id: Int64) async throws -> AILogEntry? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT *, length(prompt) AS promptChars FROM ai_log WHERE id = ?", arguments: [id]).map(Self.decodeLog)
        }
    }

    public func clearAILog() async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM ai_log") }
    }

    static func decodeLog(_ r: Row) -> AILogEntry {
        let redactionsJSON: String = r["redactions"] ?? "{}"
        let tools: String = r["tools"] ?? ""
        return AILogEntry(id: r["id"], ts: Date(timeIntervalSince1970: r["ts"]), feature: r["feature"], model: r["model"],
                          tools: tools.split(separator: ",").map(String.init), systemPrompt: r["systemPrompt"] ?? "",
                          prompt: r["prompt"] ?? "", response: r["response"] ?? "", ok: (r["ok"] as Int) == 1, error: r["error"],
                          redactions: (try? JSONDecoder().decode([String: Int].self, from: Data(redactionsJSON.utf8))) ?? [:],
                          costUSD: r["costUSD"] ?? 0, inputTokens: r["inputTokens"] ?? 0, outputTokens: r["outputTokens"] ?? 0,
                          promptChars: r["promptChars"] ?? 0)
    }
}
