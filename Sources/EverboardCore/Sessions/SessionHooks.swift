import Foundation

/// Turns one hook payload from a coding agent into an updated `AgentSession`. Pure: no files, no processes.
///
/// Claude Code and Cursor use different event names and fields for the same moments (and Cursor can also run
/// hooks configured for Claude Code), so payloads are first normalised into `HookEvent`, then applied once.
public enum SessionHooks {
    /// The moments that matter for status, in both tools' vocabularies.
    public enum HookEvent: Equatable, Sendable {
        case sessionStart, sessionEnd, prompt, toolStart, toolEnd, permissionRequest, notification
        case response, thought, stop, stopFailure, compact, other

        public init(_ name: String) {
            switch name.lowercased() {
            case "sessionstart": self = .sessionStart
            case "sessionend": self = .sessionEnd
            case "userpromptsubmit", "beforesubmitprompt": self = .prompt
            case "pretooluse", "beforeshellexecution", "beforemcpexecution", "beforereadfile": self = .toolStart
            case "posttooluse", "posttoolusefailure", "aftershellexecution", "aftermcpexecution", "afterfileedit",
                 "permissiondenied": self = .toolEnd
            case "permissionrequest": self = .permissionRequest
            case "notification": self = .notification
            case "afteragentresponse": self = .response
            case "afteragentthought": self = .thought
            case "stop": self = .stop
            case "stopfailure": self = .stopFailure
            case "precompact": self = .compact
            default: self = .other
            }
        }
    }

    /// Facts about the hook process the payload doesn't carry.
    public struct Context: Sendable {
        public var now: Date
        public var pid: Int32?
        public var hostApp: String?
        /// The session's name from its transcript, when the tool keeps one there.
        public var transcriptTitle: String?
        /// The host app's id for the session (`CLAUDE_CODE_HOST_SESSION_ID` in Claude's desktop app).
        public var hostSessionId: String?
        public var tty: String?
        /// The newest notice in the transcript.
        public var notice: AgentSession.Notice?

        public init(now: Date = Date(), pid: Int32? = nil, hostApp: String? = nil, transcriptTitle: String? = nil,
                    hostSessionId: String? = nil, tty: String? = nil, notice: AgentSession.Notice? = nil) {
            self.now = now
            self.pid = pid
            self.hostApp = hostApp
            self.transcriptTitle = transcriptTitle
            self.hostSessionId = hostSessionId
            self.tty = tty
            self.notice = notice
        }
    }

    /// The tool that sent a payload. Cursor payloads carry `conversation_id` even when Cursor runs a hook
    /// configured for Claude Code, so the payload wins over the name the hook was installed with.
    public static func tool(for payload: [String: Any], declared: String) -> String {
        if payload["conversation_id"] != nil || payload["cursor_version"] != nil { return "cursor" }
        return declared
    }

    public static func sessionId(in payload: [String: Any]) -> String? {
        let id = (payload["session_id"] as? String) ?? (payload["conversation_id"] as? String)
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// Applies one payload. Returns nil when the payload has no session id.
    public static func apply(_ payload: [String: Any], tool declared: String, to existing: AgentSession?,
                             context: Context) -> AgentSession? {
        guard let id = sessionId(in: payload) else { return nil }
        let tool = tool(for: payload, declared: declared)
        let now = context.now
        let event = HookEvent((payload["hook_event_name"] as? String) ?? "")
        var s = existing ?? AgentSession(tool: tool, sessionId: id, state: .idle, now: now)
        let isNew = existing == nil

        s.updatedAt = now
        if let cwd = (payload["cwd"] as? String) ?? (payload["workspace_roots"] as? [String])?.first, !cwd.isEmpty { s.cwd = cwd }
        if let roots = payload["workspace_roots"] as? [String], !roots.isEmpty { s.workspaceRoots = roots }
        if let pid = context.pid { s.pid = pid }
        if let host = context.hostApp { s.hostApp = host }
        if let hostId = context.hostSessionId, !hostId.isEmpty { s.hostSessionId = hostId }
        if let tty = context.tty { s.tty = tty }
        if let n = context.notice, n.id != s.notice?.id, n.at >= (s.notice?.at ?? .distantPast),
           n.at > (s.noticesClearedAt ?? .distantPast) { s.notice = n }
        // The agent retries API errors itself: any progress after one means it got through.
        if [.toolStart, .toolEnd, .response, .thought, .stop].contains(event), let n = s.notice, n.isAPIError,
           n.at < now.addingTimeInterval(-2) {
            s.notice = nil
            s.noticesClearedAt = now
        }
        if let t = payload["transcript_path"] as? String, !t.isEmpty { s.transcriptPath = t }
        if let name = context.transcriptTitle.map(oneLine), !name.isEmpty {
            s.name = clip(name, 120)
            s.title = s.name
        }
        fillOpeners(&s)

        let hadApproval = s.approval != nil
        apply(event, payload, to: &s, isNew: isNew, now: now)
        if s.state != .needsApproval && !(s.state == .needsReply && s.approval?.isQuestion == true) { s.approval = nil }
        if hadApproval && s.approval == nil { s.approvalResolvedAt = now }
        if s.state != .needsReply { s.questionIsChoice = nil }
        return s
    }

    private static func apply(_ event: HookEvent, _ payload: [String: Any], to s: inout AgentSession, isNew: Bool, now: Date) {
        switch event {
        case .sessionStart:
            if isNew || s.state == .ended { s.set(.idle, at: now) }

        case .sessionEnd:
            s.set(.ended, at: now)
            s.activity = nil
            s.pendingSince = nil

        case .prompt:
            let prompt = clip(oneLine((payload["prompt"] as? String) ?? ""), 500)
            if !prompt.isEmpty {
                s.prompt = prompt
                if s.title == nil { s.title = clip(prompt, 120) }
            }
            s.set(.working, at: now)
            s.activity = "Thinking"
            s.detail = nil
            s.lastMessage = nil
            s.pendingSince = nil

        case .toolStart:
            let (name, input) = toolCall(in: payload)
            switch name.lowercased() {
            case "askuserquestion":
                askQuestion(payload, name: name, input: input, to: &s, now: now)
                return
            case "exitplanmode":
                s.set(.needsApproval, at: now)
                s.detail = "Approve the plan"
                s.activity = nil
                s.pendingSince = nil
                return
            case "todowrite":
                if let current = currentTodo(in: input) { s.activity = clip(current, 120) }
            default:
                s.activity = describe(tool: name, input: input)
            }
            // A parallel tool call starting doesn't answer a permission prompt that is still open.
            if s.state != .needsApproval { s.set(.working, at: now); s.detail = nil }
            if s.tool == "cursor" { s.pendingSince = now }

        case .toolEnd:
            s.pendingSince = nil
            if s.state.needsYou || s.state == .idle { s.set(.working, at: now); s.detail = nil }
            if s.state == .working, s.tool == "cursor" {
                let (name, input) = toolCall(in: payload)
                let doing = describe(tool: name, input: input)
                s.activity = doing.hasPrefix("Running ") ? "Ran " + doing.dropFirst("Running ".count) : doing
            }

        case .permissionRequest:
            let (name, input) = toolCall(in: payload)
            // Claude's questions go through the permission step too; they are questions, not approvals.
            if name.lowercased() == "askuserquestion" {
                askQuestion(payload, name: name, input: input, to: &s, now: now)
                return
            }
            s.set(.needsApproval, at: now)
            let what = describe(tool: name, input: input)
            // "Allow running `make`" for our own phrasing; the agent's own description reads better after a colon.
            let ours = ["Running ", "Editing ", "Reading ", "Searching", "Using ", "Deleting "].contains { what.hasPrefix($0) }
            s.detail = ours ? "Allow " + what.prefix(1).lowercased() + what.dropFirst() : "Allow: \(what)"
            s.pendingSince = nil
            let requestId = (payload["tool_use_id"] as? String) ?? "req-\(Int(now.timeIntervalSince1970 * 1000))"
            s.approval = AgentSession.Approval(id: requestId, tool: name, summary: s.detail ?? what, requestedAt: now)

        case .notification:
            let message = clip(oneLine((payload["message"] as? String) ?? ""), 300)
            switch notificationKind(payload) {
            case .permission:
                // Claude's questions also raise a permission notification; a question stays a question.
                if s.state == .needsReply && s.approval?.isQuestion == true { break }
                // The notification can arrive after the prompt was answered: it's about that prompt.
                if s.approval == nil, let resolved = s.approvalResolvedAt, now.timeIntervalSince(resolved) < 60 { break }
                if message.contains("AskUserQuestion") {
                    s.set(.needsReply, at: now)
                    s.questionIsChoice = true
                    if s.detail == nil || s.detail?.hasPrefix("Claude needs your permission") == true { s.detail = "Answer a question" }
                    break
                }
                s.set(.needsApproval, at: now)
                if s.detail == nil || !(s.detail ?? "").hasPrefix("Allow") { s.detail = message.isEmpty ? "Approve a tool call" : message }
            case .question:
                s.set(.needsReply, at: now)
                s.detail = message.isEmpty ? "Answer a question" : message
                s.questionIsChoice = true
            case .idle:
                // "Waiting for your input" after a finished turn adds nothing; mid-turn it means a question.
                if s.state == .working { s.set(.needsReply, at: now); s.detail = message.isEmpty ? nil : message }
            case .other:
                break
            }

        case .response:
            if let text = payload["text"] as? String { s.lastMessage = clip(text, 4000) }

        case .thought:
            if s.state != .working { s.set(.working, at: now) }
            s.activity = "Thinking"

        case .stop:
            s.pendingSince = nil
            s.activity = nil
            let status = (payload["status"] as? String)?.lowercased()
            if status == "error" {
                s.set(.error, at: now)
                s.detail = "The agent stopped with an error"
                break
            }
            if status == "aborted" {
                s.set(.done, at: now)
                s.detail = "Stopped"
                break
            }
            let text = (payload["last_assistant_message"] as? String) ?? s.lastMessage ?? ""
            if let q = question(in: text) {
                s.set(.needsReply, at: now)
                s.detail = clip(q, 300)
                s.questionIsChoice = false
            } else {
                s.set(.done, at: now)
                s.detail = summary(of: text).map { clip($0, 200) }
            }
            s.lastMessage = nil

        case .stopFailure:
            s.set(.error, at: now)
            s.activity = nil
            s.pendingSince = nil
            let err = (payload["error"] as? String) ?? (payload["message"] as? String) ?? "The turn failed"
            s.detail = clip(oneLine(err), 300)

        case .compact:
            s.activity = "Compacting the conversation"

        case .other:
            break
        }
    }

    // MARK: Pieces

    /// A multiple-choice question: the first question as the line to show, the options kept for answering.
    static func askQuestion(_ payload: [String: Any], name: String, input: [String: Any], to s: inout AgentSession, now: Date) {
        s.set(.needsReply, at: now)
        s.detail = clip(askedQuestion(in: input) ?? "Answer a question", 300)
        s.questionIsChoice = true
        s.activity = nil
        s.pendingSince = nil
        let id = (payload["tool_use_id"] as? String) ?? s.approval?.id ?? "q-\(Int(now.timeIntervalSince1970 * 1000))"
        let questions = choiceQuestions(in: input)
        guard !questions.isEmpty else { return }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        let requestedAt = s.approval?.id == id ? s.approval?.requestedAt ?? now : now
        s.approval = AgentSession.Approval(id: id, tool: name, summary: s.detail ?? "Answer a question", requestedAt: requestedAt,
                                           questions: questions, toolInput: json)
    }

    /// The questions and options of an AskUserQuestion call.
    public static func choiceQuestions(in input: [String: Any]) -> [AgentSession.ChoiceQuestion] {
        let list = input["questions"] as? [[String: Any]] ?? []
        return list.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> AgentSession.ChoiceQuestion.Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                let d = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .init(label: label, description: d)
            }
            return .init(question: text, header: q["header"] as? String, multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
    }

    static func fillOpeners(_ s: inout AgentSession) {
        switch s.tool {
        case "claude-code":
            let cd = s.cwd.map { "cd \(shellQuote($0)) && " } ?? ""
            s.resumeCommand = "\(cd)claude --resume \(shellQuote(s.sessionId))"
            // Claude's desktop app opens one of its sessions from this link.
            s.openURL = s.hostSessionId.flatMap(ClaudeDesktopSessions.openURL)
        case "cursor":
            if let cwd = s.cwd, let enc = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                s.openURL = "cursor://file\(enc.hasPrefix("/") ? "" : "/")\(enc)"
            }
        default:
            break
        }
    }

    enum NotificationKind { case permission, question, idle, other }

    static func notificationKind(_ p: [String: Any]) -> NotificationKind {
        switch (p["notification_type"] as? String)?.lowercased() {
        case "permission_prompt": return .permission
        case "elicitation_dialog": return .question
        case "idle_prompt": return .idle
        case .some: return .other
        case nil:
            // Older versions send only the message.
            let m = ((p["message"] as? String) ?? "").lowercased()
            if m.contains("permission") { return .permission }
            if m.contains("waiting for your input") { return .idle }
            return .other
        }
    }

    /// Tool name and input across both tools' payload shapes.
    static func toolCall(in p: [String: Any]) -> (String, [String: Any]) {
        var input: [String: Any] = [:]
        if let d = p["tool_input"] as? [String: Any] { input = d }
        else if let str = p["tool_input"] as? String, let d = jsonObject(str) { input = d }
        if let name = p["tool_name"] as? String, !name.isEmpty { return (name, input) }
        switch ((p["hook_event_name"] as? String) ?? "").lowercased() {
        case "beforeshellexecution", "aftershellexecution":
            if let c = p["command"] { input["command"] = c }
            return ("Shell", input)
        case "beforereadfile":
            if let f = p["file_path"] { input["file_path"] = f }
            return ("Read", input)
        case "afterfileedit":
            if let f = p["file_path"] { input["file_path"] = f }
            return ("Edit", input)
        default:
            return ("a tool", input)
        }
    }

    /// A short, readable line for a tool call: "Running yarn test", "Editing Select.swift".
    public static func describe(tool: String, input: [String: Any]) -> String {
        func str(_ keys: String...) -> String? {
            for k in keys { if let v = input[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        func file(_ keys: String...) -> String? {
            for k in keys { if let v = input[k] as? String, !v.isEmpty { return URL(fileURLWithPath: v).lastPathComponent } }
            return nil
        }
        let key = tool.lowercased()
        let line: String
        if key.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            let server = parts.count > 1 ? String(parts[1]) : "MCP"
            let name = parts.dropFirst(2).joined(separator: " ")
            line = "Using \(server)\(name.isEmpty ? "" : ": \(name)")"
        } else {
            switch key {
            case "bash", "shell", "run_terminal_cmd", "terminal":
                if let d = str("description") { line = d }
                else { line = "Running " + (str("command").map { "`\(oneLine($0))`" } ?? "a command") }
            case "read", "read_file", "readfile":
                line = "Reading " + (file("file_path", "path", "target_file") ?? "a file")
            case "edit", "multiedit", "write", "notebookedit", "edit_file", "write_file", "search_replace", "delete_file", "delete":
                line = (key.hasPrefix("delete") ? "Deleting " : "Editing ") + (file("file_path", "path", "target_file", "notebook_path") ?? "a file")
            case "grep", "glob", "codebase_search", "file_search", "grep_search", "list_dir", "ls":
                line = "Searching" + (str("pattern", "query", "path").map { " for \(oneLine($0))" } ?? "")
            case "webfetch", "fetch":
                let host = str("url").flatMap { URL(string: $0)?.host } ?? "a page"
                line = "Reading \(host)"
            case "websearch", "web_search":
                line = "Searching the web" + (str("query", "search_term").map { " for \($0)" } ?? "")
            case "task", "agent":
                line = "Running a subagent" + (str("description").map { ": \($0)" } ?? "")
            default:
                line = "Using \(tool)"
            }
        }
        return clip(oneLine(line), 120)
    }

    /// The in-progress item of a TodoWrite call.
    static func currentTodo(in input: [String: Any]) -> String? {
        guard let todos = input["todos"] as? [[String: Any]] else { return nil }
        let current = todos.first { ($0["status"] as? String) == "in_progress" }
        return (current?["activeForm"] as? String) ?? (current?["content"] as? String)
    }

    static func askedQuestion(in input: [String: Any]) -> String? {
        if let qs = input["questions"] as? [[String: Any]], let q = qs.first?["question"] as? String { return oneLine(q) }
        return (input["question"] as? String).map(oneLine)
    }

    private static let askPhrases = try! NSRegularExpression(
        pattern: #"\b(should i|shall i|want me to|would you like|do you want|which (one|option|approach)|let me know (if|whether|which|what|how))\b"#,
        options: [.caseInsensitive])

    /// The question a reply ends with, if it ends with one. Looks only at the last few lines, so a question
    /// quoted earlier in a long answer doesn't count.
    public static func question(in text: String) -> String? {
        var inFence = false
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            lines.append(line)
        }
        for line in lines.suffix(3).reversed() {
            let plain = stripMarkdown(line)
            if plain.hasSuffix("?") { return plain }
            let range = NSRange(plain.startIndex..., in: plain)
            if askPhrases.firstMatch(in: plain, range: range) != nil { return plain }
        }
        return nil
    }

    /// First meaningful line of a reply.
    public static func summary(of text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = stripMarkdown(raw.trimmingCharacters(in: .whitespaces))
            if line.isEmpty || line.hasPrefix("```") || line.allSatisfy({ "-=|:".contains($0) }) { continue }
            return line
        }
        return nil
    }

    static func stripMarkdown(_ s: String) -> String {
        var t = s
        while let f = t.first, "#>*-+ ".contains(f) { t.removeFirst() }
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func shellQuote(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_./=:@%+-]+$"#, options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func jsonObject(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
