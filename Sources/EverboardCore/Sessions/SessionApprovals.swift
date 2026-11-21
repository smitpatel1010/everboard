import Foundation

/// How a permission prompt gets answered from Everboard.
///
/// Claude Code lets a `PermissionRequest` hook decide a prompt, but only while the hook is still running, and the
/// agent's own prompt waits until then. So the hook holds a prompt only when Everboard is running, the user turned
/// this on, and the user is in another app; it then waits for an answer file. When the time runs out it returns
/// nothing and the agent shows its own prompt as usual.
public enum SessionApprovals {
    /// What the app tells hooks, refreshed every few seconds and whenever the front app changes.
    public struct AppStatus: Codable, Equatable, Sendable {
        public var pid: Int32
        public var updatedAt: Date
        /// Bundle id of the app in front.
        public var frontmostApp: String?
        public var holdApprovals: Bool
        /// Seconds to hold a prompt before handing it back to the agent.
        public var holdSeconds: Double

        public init(pid: Int32, updatedAt: Date, frontmostApp: String?, holdApprovals: Bool, holdSeconds: Double) {
            self.pid = pid
            self.updatedAt = updatedAt
            self.frontmostApp = frontmostApp
            self.holdApprovals = holdApprovals
            self.holdSeconds = holdSeconds
        }

        /// The app hasn't refreshed in this long: treat it as gone.
        public static let staleAfter: TimeInterval = 20
    }

    public enum Behavior: String, Codable, Sendable { case allow, deny }

    public struct Answer: Codable, Equatable, Sendable {
        public var behavior: Behavior
        public var message: String?
        /// For a question: question text → chosen labels (or typed text). One entry unless the question allows several.
        public var answers: [String: [String]]?

        public init(behavior: Behavior, message: String? = nil, answers: [String: [String]]? = nil) {
            self.behavior = behavior
            self.message = message
            self.answers = answers
        }
    }

    /// Hosts seen to show their own prompt while a `PermissionRequest` hook is still running (Claude's desktop app).
    public static let promptsShowWhileHeld: Set<String> = ["com.anthropic.claudefordesktop"]

    /// How long to hold this prompt, or nil to let the agent show its own prompt right away.
    public static func holdDuration(status: AppStatus?, hostApp: String?, now: Date = Date(),
                                    isAlive: (Int32) -> Bool = SessionProcess.isAlive) -> TimeInterval? {
        guard let status, status.holdApprovals, status.holdSeconds > 0,
              now.timeIntervalSince(status.updatedAt) < AppStatus.staleAfter, isAlive(status.pid) else { return nil }
        // Apps that show their own prompt while the hook runs lose nothing by holding: answer in either place.
        // Elsewhere, when you're looking at the agent's app, its own prompt is the fastest way to answer.
        if let host = hostApp, !promptsShowWhileHeld.contains(host), let front = status.frontmostApp, host == front { return nil }
        return min(status.holdSeconds, 600)
    }

    /// The JSON a `PermissionRequest` hook prints to decide the prompt. For a question, `allow` carries the
    /// tool's own input plus `answers` (Claude Code's AskUserQuestion reads them from there).
    public static func hookOutput(for answer: Answer, approval: AgentSession.Approval? = nil) -> String {
        var decision: [String: Any] = ["behavior": answer.behavior.rawValue]
        if answer.behavior == .deny { decision["message"] = answer.message ?? "Denied from Everboard." }
        if answer.behavior == .allow, let answers = answer.answers, let approval, approval.isQuestion {
            var input = approval.toolInput.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
            var out: [String: Any] = [:]
            for q in approval.questions ?? [] {
                guard let picked = answers[q.question], !picked.isEmpty else { continue }
                out[q.question] = q.multiSelect ? picked : picked.joined(separator: ", ")
            }
            input["answers"] = out
            decision["updatedInput"] = input
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Files

    public static func readStatus(in directory: URL) -> AppStatus? {
        guard let data = try? Data(contentsOf: SessionPaths.appStatusFile(in: directory)) else { return nil }
        return try? SessionDirectory.decoder.decode(AppStatus.self, from: data)
    }

    public static func writeStatus(_ status: AppStatus, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = SessionPaths.appStatusFile(in: directory)
        try SessionDirectory.encoder.encode(status).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func answerFile(in directory: URL, session: AgentSession, approvalId: String) -> URL {
        SessionPaths.answersDirectory(in: directory)
            .appendingPathComponent("\(SessionDirectory.safe(session.id))-\(SessionDirectory.safe(approvalId)).json")
    }

    /// Records the user's answer for the hook that is holding this prompt.
    public static func writeAnswer(_ answer: Answer, for session: AgentSession, approvalId: String, in directory: URL) throws {
        let dir = SessionPaths.answersDirectory(in: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = answerFile(in: directory, session: session, approvalId: approvalId)
        try SessionDirectory.encoder.encode(answer).write(to: file, options: .atomic)
    }

    /// Takes the answer if there is one, deleting the file so it is used once.
    public static func takeAnswer(for session: AgentSession, approvalId: String, in directory: URL) -> Answer? {
        let file = answerFile(in: directory, session: session, approvalId: approvalId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return try? SessionDirectory.decoder.decode(Answer.self, from: data)
    }

    /// Waits for an answer, checking a few times a second. Returns nil when the time runs out.
    public static func waitForAnswer(for session: AgentSession, approvalId: String, in directory: URL, until deadline: Date,
                                     poll: TimeInterval = 0.1) -> Answer? {
        while Date() < deadline {
            if let a = takeAnswer(for: session, approvalId: approvalId, in: directory) { return a }
            Thread.sleep(forTimeInterval: poll)
        }
        return takeAnswer(for: session, approvalId: approvalId, in: directory)
    }
}
