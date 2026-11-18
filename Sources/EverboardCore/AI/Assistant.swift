import Foundation

/// What the assistant decided to do with one request, typed or spoken.
public struct AssistantIntent: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Run an agent action on an item (always confirmed by the user first).
        case runAgent = "run_agent"
        case open
        case summarize
        case digest
        /// Switch the dashboard to a screen.
        case show
        case workBrief = "work_brief"
        case standup
        case oneOnOne = "one_on_one"
        case refresh
        /// Just answer from the dashboard data.
        case answer
    }

    public var action: Action
    /// Item id from the candidates given to the planner.
    public var item: String?
    /// Agent action id.
    public var agent: String?
    /// Screen name for `show`.
    public var screen: String?
    /// Reportee name for `one_on_one`.
    public var person: String?
    /// Short reply, written to be read aloud.
    public var reply: String

    public init(action: Action, item: String? = nil, agent: String? = nil, screen: String? = nil, person: String? = nil, reply: String) {
        self.action = action
        self.item = item
        self.agent = agent
        self.screen = screen
        self.person = person
        self.reply = reply
    }
}

/// Everything the planner may refer to, built from what the dashboard already shows.
public struct AssistantContext: Sendable {
    public var items: [FeedItem]
    public var actions: [AgentAction]
    public var people: [String]
    public var screens: [String]
    public var now: Date

    public init(items: [FeedItem], actions: [AgentAction], people: [String], screens: [String], now: Date = Date()) {
        self.items = items
        self.actions = actions
        self.people = people
        self.screens = screens
        self.now = now
    }
}

/// Turns a request into an `AssistantIntent`. Navigation is matched locally; everything else asks Claude,
/// constrained to the items, agent actions and people it's shown, and the answer is checked against them.
public struct AssistantPlanner: Sendable {
    let claude: ClaudeRunning

    public init(claude: ClaudeRunning) { self.claude = claude }

    public static let screens = ["home", "inbox", "merge requests", "pipelines", "jira", "work brief", "reports", "team radar",
                                 "one on one", "agent runs", "world", "settings"]

    /// Cheap requests that don't need a model: "open inbox", "show pipelines", "refresh".
    public static func localIntent(_ text: String) -> AssistantIntent? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if ["refresh", "refresh everything", "sync", "update"].contains(t) {
            return AssistantIntent(action: .refresh, reply: "Refreshing every account.")
        }
        for verb in ["open ", "show ", "go to ", "show me "] where t.hasPrefix(verb) {
            let rest = String(t.dropFirst(verb.count)).replacingOccurrences(of: "my ", with: "")
            let aliases: [String: String] = ["mrs": "merge requests", "prs": "merge requests", "pull requests": "merge requests",
                                             "reviews": "merge requests", "radar": "team radar", "team": "team radar",
                                             "brief": "work brief", "news": "world", "agents": "agent runs", "1:1": "one on one"]
            let screen = aliases[rest] ?? rest
            if screens.contains(screen) { return AssistantIntent(action: .show, screen: screen, reply: "Opening \(screen).") }
        }
        return nil
    }

    static let system = """
    You are the voice and chat assistant inside a developer's work dashboard. Map the user's request to exactly one action \
    from the schema, using only the item ids, agent ids and people listed. If the request is ambiguous or nothing matches, \
    use action "answer" and ask a short clarifying question. For questions about their work, answer from the snapshot with \
    action "answer". Replies are read aloud: one or two short sentences, no markdown, no ids, refer to items by their short ref.
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["action","reply"],
     "properties":{
       "action":{"type":"string","enum":[\(AssistantIntent.Action.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]},
       "item":{"type":"string"},"agent":{"type":"string"},"screen":{"type":"string"},"person":{"type":"string"},
       "reply":{"type":"string"}}}
    """

    public func plan(_ text: String, context: AssistantContext, history: [(user: String, reply: String)] = []) async throws -> AssistantIntent {
        if let local = Self.localIntent(text) { return local }
        let prompt = Self.prompt(text, context: context, history: history)
        let r = try await claude.run(ClaudeRequest(prompt: prompt, systemPrompt: Self.system, jsonSchema: Self.schema, timeout: 90,
                                                   feature: "assistant.command", people: context.people))
        let intent: AssistantIntent
        if let structured = r.structured, let decoded = try? structured.decode(AssistantIntent.self) {
            intent = decoded
        } else if let decoded = try? JSONDecoder().decode(AssistantIntent.self, from: Data(r.text.utf8)) {
            intent = decoded
        } else {
            return AssistantIntent(action: .answer, reply: r.text.isEmpty ? "Sorry, I didn't get that." : r.text)
        }
        return Self.validate(intent, context: context)
    }

    /// Drops references the model made up, so nothing runs on an item or action that doesn't exist.
    public static func validate(_ i: AssistantIntent, context: AssistantContext) -> AssistantIntent {
        let item = i.item.flatMap { id in context.items.first { $0.id == id } }
        let agent = i.agent.flatMap { id in context.actions.first { $0.id == id } }
        func clarify(_ s: String) -> AssistantIntent { AssistantIntent(action: .answer, reply: s) }
        switch i.action {
        case .runAgent:
            guard let item else { return clarify("Which item should I run that on?") }
            guard let agent, agent.applies(to: item) else { return clarify("Which agent action should I run on \(item.subtitle)?") }
        case .open, .summarize:
            guard let item else { return clarify("Which item do you mean?") }
            if i.action == .summarize && !item.isCodeChange { return clarify("I can only summarize merge or pull requests.") }
        case .digest:
            guard let item, item.source == "jira" || item["jiraKeys"] != nil else { return clarify("Which Jira issue do you mean?") }
        case .show:
            guard let s = i.screen?.lowercased(), screens.contains(s) else { return clarify("Which screen should I open?") }
        case .oneOnOne:
            guard let p = i.person, context.people.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) else {
                return clarify("Who is the 1:1 with?")
            }
        case .workBrief, .standup, .refresh, .answer: break
        }
        var out = i
        out.item = item?.id
        out.agent = agent?.id
        out.screen = i.screen?.lowercased()
        return out
    }

    static func prompt(_ text: String, context: AssistantContext, history: [(user: String, reply: String)]) -> String {
        func line(_ i: FeedItem) -> String {
            var parts = ["id=\(i.id)", AgentTarget.of(i).rawValue, i.subtitle, i.title]
            if let s = i["pipelineStatus"] ?? i.status { parts.append("status \(s)") }
            if let a = i["authorName"] ?? i["assignee"] ?? i.author { parts.append("by \(a)") }
            parts.append("updated \(Dates.age(i.updatedAt ?? i.createdAt, now: context.now)) ago")
            return "- " + parts.joined(separator: " | ")
        }
        let items = context.items.prefix(120).map(line).joined(separator: "\n")
        let actions = context.actions.map { "- id=\($0.id) | \($0.name) | on \($0.targets.map(\.rawValue).joined(separator: ","))" }
            .joined(separator: "\n")
        let convo = history.suffix(AssistantChat.memory).map { "User: \($0.user)\nAssistant: \($0.reply)" }.joined(separator: "\n")
        return """
        Now: \(context.now.formatted(date: .abbreviated, time: .shortened))

        Items on the dashboard (change = MR/PR, pipeline, issue = Jira, todo, custom = feed item):
        \(items.isEmpty ? "(none)" : items)

        Agent actions the user defined:
        \(actions.isEmpty ? "(none; suggest adding one in Settings → Agents if they ask to run an agent)" : actions)

        Team: \(context.people.isEmpty ? "(none)" : context.people.joined(separator: ", "))
        Screens: \(screens.joined(separator: ", "))
        \(convo.isEmpty ? "" : "\nRecent conversation:\n\(convo)\n")
        Request: \(text)
        """
    }

    /// "yes", "go ahead", "run it" → true; "no", "cancel" → false; anything else → nil.
    public static func confirmation(_ text: String) -> Bool? {
        let t = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if ["yes", "yeah", "yep", "sure", "ok", "okay", "go", "go ahead", "do it", "run it", "run", "confirm", "yes please"].contains(t) { return true }
        if ["no", "nope", "cancel", "stop", "don't", "never mind", "nevermind"].contains(t) { return false }
        return nil
    }
}

/// One saved Assistant conversation. Each request only sends the last few exchanges of its own chat,
/// so a long chat doesn't make prompts grow, and separate chats never mix.
public struct AssistantChat: Codable, Sendable, Identifiable, Equatable {
    public struct Message: Codable, Sendable, Identifiable, Equatable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var id: String
        public var role: Role
        public var text: String
        /// Agent run this message is about.
        public var runID: String?
        public var isError: Bool
        /// Whether the user said it (rather than typed it); voice replies only answer voice.
        public var spoken: Bool

        public init(id: String = UUID().uuidString, role: Role, text: String, runID: String? = nil, isError: Bool = false, spoken: Bool = false) {
            self.id = id
            self.role = role
            self.text = text
            self.runID = runID
            self.isError = isError
            self.spoken = spoken
        }
    }

    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]

    public init(id: String = UUID().uuidString, title: String = "New chat", createdAt: Date = Date(), messages: [Message] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.messages = messages
    }

    /// How many past exchanges go along with each request.
    public static let memory = 4

    /// (request, reply) pairs, oldest first, for the planner.
    public var exchanges: [(user: String, reply: String)] {
        var out: [(String, String)] = []
        var pending: String?
        for m in messages {
            if m.role == .user { pending = m.text } else if let u = pending { out.append((u, m.text)); pending = nil }
        }
        return Array(out.suffix(Self.memory))
    }

    /// A short title from the first request.
    public static func title(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 48 ? t : String(t.prefix(47)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension Store {
    public func saveChat(_ chat: AssistantChat) async throws {
        let json = String(decoding: try JSONEncoder.everboard.encode(chat), as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO assistant_chats (id, title, updatedAt, json) VALUES (?, ?, ?, ?)",
                           arguments: [chat.id, chat.title, chat.updatedAt.timeIntervalSince1970, json])
        }
    }

    /// Newest first.
    public func chats(limit: Int = 100) async throws -> [AssistantChat] {
        try await db.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM assistant_chats ORDER BY updatedAt DESC LIMIT ?", arguments: [limit])
                .compactMap { try? JSONDecoder.everboard.decode(AssistantChat.self, from: Data($0.utf8)) }
        }
    }

    public func deleteChat(id: String) async throws {
        try await db.write { db in try db.execute(sql: "DELETE FROM assistant_chats WHERE id = ?", arguments: [id]) }
    }
}
