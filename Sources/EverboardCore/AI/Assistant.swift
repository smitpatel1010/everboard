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
        let convo = history.suffix(4).map { "User: \($0.user)\nAssistant: \($0.reply)" }.joined(separator: "\n")
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
