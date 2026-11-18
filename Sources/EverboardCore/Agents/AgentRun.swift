import Foundation
import GRDB

/// One run of an agent action on an item, kept in the local history.
public struct AgentRun: Sendable, Hashable, Identifiable, Codable {
    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, cancelled, timedOut

        public var label: String {
            switch self {
            case .running: return "Running"
            case .succeeded: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .timedOut: return "Timed out"
            }
        }

        init(_ outcome: ShellOutcome) {
            switch outcome {
            case .succeeded: self = .succeeded
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            case .timedOut: self = .timedOut
            }
        }
    }

    public var id: String
    public var ts: Date
    public var finishedAt: Date?
    public var actionId: String
    public var actionName: String
    public var itemId: String?
    public var itemTitle: String
    /// "group/project!12", "PROJ-7", … for display and note names.
    public var itemRef: String
    public var itemUrl: String?
    /// The command with values filled in, as shown before running.
    public var command: String
    public var workingDirectory: String
    public var status: Status
    public var exitCode: Int?
    public var output: String
    /// Markdown note written to the brain folder, if any.
    public var notePath: String?

    public init(id: String = UUID().uuidString, ts: Date = Date(), finishedAt: Date? = nil, actionId: String, actionName: String,
                itemId: String?, itemTitle: String, itemRef: String, itemUrl: String?, command: String, workingDirectory: String,
                status: Status = .running, exitCode: Int? = nil, output: String = "", notePath: String? = nil) {
        self.id = id
        self.ts = ts
        self.finishedAt = finishedAt
        self.actionId = actionId
        self.actionName = actionName
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.itemRef = itemRef
        self.itemUrl = itemUrl
        self.command = command
        self.workingDirectory = workingDirectory
        self.status = status
        self.exitCode = exitCode
        self.output = output
        self.notePath = notePath
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(ts) } }
}

extension Store {
    public func saveAgentRun(_ r: AgentRun) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO agent_runs (id, ts, finishedAt, actionId, actionName, itemId, itemTitle, itemRef, itemUrl,
                                                   command, workingDirectory, status, exitCode, output, notePath)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.id, r.ts.timeIntervalSince1970, r.finishedAt?.timeIntervalSince1970, r.actionId, r.actionName,
                                 r.itemId, r.itemTitle, r.itemRef, r.itemUrl, r.command, r.workingDirectory, r.status.rawValue,
                                 r.exitCode, r.output, r.notePath])
        }
    }

    /// Newest first. `output` is left empty in the list; load one with `agentRun(id:)`.
    public func agentRuns(limit: Int = 200, itemId: String? = nil, since: Date? = nil) async throws -> [AgentRun] {
        try await db.read { db in
            var sql = "SELECT id, ts, finishedAt, actionId, actionName, itemId, itemTitle, itemRef, itemUrl, command, workingDirectory, status, exitCode, '' AS output, notePath FROM agent_runs WHERE ts >= ?"
            var args: [DatabaseValueConvertible?] = [(since ?? .distantPast).timeIntervalSince1970]
            if let itemId { sql += " AND itemId = ?"; args.append(itemId) }
            sql += " ORDER BY ts DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.decodeRun)
        }
    }

    public func agentRun(id: String) async throws -> AgentRun? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_runs WHERE id = ?", arguments: [id]).map(Self.decodeRun)
        }
    }

    public func deleteAgentRuns(ids: [String]? = nil) async throws {
        try await db.write { db in
            if let ids {
                for id in ids { try db.execute(sql: "DELETE FROM agent_runs WHERE id = ?", arguments: [id]) }
            } else {
                try db.execute(sql: "DELETE FROM agent_runs")
            }
        }
    }

    /// Runs left "running" by a quit or crash can never finish; mark them so the history doesn't lie.
    public func closeInterruptedAgentRuns(now: Date = Date()) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE agent_runs SET status = 'cancelled', finishedAt = ? WHERE status = 'running'",
                           arguments: [now.timeIntervalSince1970])
        }
    }

    static func decodeRun(_ r: Row) -> AgentRun {
        let finished: Double? = r["finishedAt"]
        return AgentRun(id: r["id"], ts: Date(timeIntervalSince1970: r["ts"]), finishedAt: finished.map(Date.init(timeIntervalSince1970:)),
                        actionId: r["actionId"], actionName: r["actionName"], itemId: r["itemId"], itemTitle: r["itemTitle"],
                        itemRef: r["itemRef"], itemUrl: r["itemUrl"], command: r["command"], workingDirectory: r["workingDirectory"],
                        status: AgentRun.Status(rawValue: r["status"]) ?? .failed, exitCode: r["exitCode"], output: r["output"] ?? "",
                        notePath: r["notePath"])
    }
}
