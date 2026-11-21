import Foundation

/// What `everboard-hook` does with one payload: work out the session, apply the event, write the file.
/// It must stay fast and must never fail the agent's tool call, so every error is swallowed. The one time it
/// waits is a permission prompt that Everboard was asked to answer (see `SessionApprovals`).
public enum SessionHookRunner {
    /// Hook events that change the title shown for a session; only these read the transcript for it.
    static let titleEvents: Set<SessionHooks.HookEvent> = [.sessionStart, .prompt, .stop, .notification, .permissionRequest]
    /// Events after which a new notice may have been recorded.
    static let noticeEvents: Set<SessionHooks.HookEvent> = [.prompt, .toolEnd, .stop, .stopFailure, .notification, .permissionRequest]

    /// Applies the payload and returns what the hook should print (only ever a permission decision).
    @discardableResult
    public static func run(input: Data, declaredTool: String,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           directory: SessionDirectory? = nil, now: Date = Date()) -> String? {
        guard !input.isEmpty,
              let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let id = SessionHooks.sessionId(in: payload) else { return nil }
        let tool = SessionHooks.tool(for: payload, declared: declaredTool)
        let event = SessionHooks.HookEvent((payload["hook_event_name"] as? String) ?? "")
        let pid = SessionProcess.agentPID()
        // An agent started from inside a desktop session inherits that session's host id, so only keep it when the
        // desktop app's record says it runs this session. Checked on the less frequent events to stay fast.
        var hostSessionId: String?
        if titleEvents.contains(event), let host = environment["CLAUDE_CODE_HOST_SESSION_ID"],
           ClaudeDesktopSessions.confirms(hostId: host, runs: id, in: desktopRecords(environment)) == true {
            hostSessionId = host
        }
        var context = SessionHooks.Context(now: now, pid: pid, hostApp: environment["__CFBundleIdentifier"],
                                           hostSessionId: hostSessionId, tty: pid.flatMap(SessionProcess.tty))
        if let path = payload["transcript_path"] as? String {
            if titleEvents.contains(event) { context.transcriptTitle = transcriptTitle(at: path) }
            if noticeEvents.contains(event) { context.notice = SessionNotices.latest(inTranscript: path) }
        }
        let dir = directory ?? SessionDirectory(url: SessionPaths.directory(environment: environment))

        // A prompt Everboard should answer: decide before writing, so the file says it's being held.
        var holdUntil: Date?
        // A plan is meant to be read where it's shown, so plan approvals are never held.
        let toolName = ((payload["tool_name"] as? String) ?? "").lowercased()
        if event == .permissionRequest, toolName != "exitplanmode",
           let hold = SessionApprovals.holdDuration(status: SessionApprovals.readStatus(in: dir.url), hostApp: context.hostApp, now: now) {
            holdUntil = now.addingTimeInterval(hold)
        }
        let written = try? dir.update(tool: tool, sessionId: id) { old in
            var s = SessionHooks.apply(payload, tool: declaredTool, to: old, context: context)
            if let holdUntil { s?.approval?.holdUntil = holdUntil }
            return s
        }
        guard let holdUntil, let session = written ?? nil, let approval = session.approval else { return nil }

        let answer = SessionApprovals.waitForAnswer(for: session, approvalId: approval.id, in: dir.url, until: holdUntil)
        _ = try? dir.update(tool: session.tool, sessionId: session.sessionId) { current in
            guard var s = current, s.approval?.id == approval.id else { return nil }
            if let answer {
                s.set(.working, at: Date())
                s.updatedAt = Date()
                s.approval = nil
                s.approvalResolvedAt = Date()
                s.detail = nil
                s.questionIsChoice = nil
                if approval.isQuestion {
                    let picked = (answer.answers ?? [:]).values.flatMap { $0 }.joined(separator: ", ")
                    s.activity = answer.behavior == .allow ? "Answered from Everboard: \(picked)" : "Question skipped from Everboard"
                } else {
                    let what = approval.summary.hasPrefix("Allow: ") ? String(approval.summary.dropFirst("Allow: ".count))
                                                                     : String(approval.summary.dropFirst("Allow ".count))
                    s.activity = answer.behavior == .allow ? "Allowed from Everboard: \(what)" : "Denied from Everboard"
                }
            } else {
                // Handed back: the agent shows its own prompt now.
                s.approval?.holdUntil = nil
            }
            return s
        }
        return answer.map { SessionApprovals.hookOutput(for: $0, approval: approval) }
    }

    /// Where to look for Claude desktop's session records; `EVERBOARD_CLAUDE_DESKTOP_DIR` overrides it (tests).
    static func desktopRecords(_ environment: [String: String]) -> URL {
        if let dir = environment["EVERBOARD_CLAUDE_DESKTOP_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return ClaudeDesktopSessions.recordsDirectory(home: environment["HOME"] ?? NSHomeDirectory())
    }

    /// The session name a Claude Code transcript records (set by the user or generated), read from the
    /// end of the file so long transcripts stay cheap.
    public static func transcriptTitle(at path: String, tailBytes: Int = 256 * 1024) -> String? {
        guard let text = SessionNotices.tail(of: path, bytes: tailBytes) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"custom-title\"") || line.contains("\"agent-name\"") || line.contains("\"summary\"") else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title": if let t = obj["customTitle"] as? String, !t.isEmpty { return t }
            case "agent-name": if let t = obj["agentName"] as? String, !t.isEmpty { return t }
            case "summary": if let t = obj["summary"] as? String, !t.isEmpty { return t }
            default: continue
            }
        }
        return nil
    }
}
