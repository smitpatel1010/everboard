import EverboardCore
import Foundation
import Observation

/// The Assistant conversation: type or talk, it works out the action, asks before running agents, and does it.
@MainActor @Observable
final class AssistantModel {
    static let shared = AssistantModel()

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        /// An agent run this message is about (shows its live status and output button).
        var runID: String?
        /// A run waiting for "yes" / the Run button.
        var pending: AgentPlan?
        var isError = false

        static func == (a: Message, b: Message) -> Bool {
            a.id == b.id && a.text == b.text && a.runID == b.runID && (a.pending?.id == b.pending?.id) && a.isError == b.isError
        }
    }

    var messages: [Message] = []
    var thinking = false
    var draft = ""

    private var model: AppModel { .shared }
    private var voice: VoiceInput { .shared }

    static let suggestions = [
        "What needs me today?",
        "Which reviews have waited the longest?",
        "Why did my last pipeline fail?",
        "Open team radar",
    ]

    // MARK: Input

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !text.isEmpty { handle(text) }
    }

    func toggleListening() {
        if voice.isListening { voice.stop(); return }
        voice.clearProblem()
        Speech.shared.stop()
        Task { await voice.start(onDeviceOnly: model.config.voiceOnDeviceOnly) { [weak self] text in self?.handle(text, spoken: true) } }
    }

    /// From the global hotkey: show the assistant and start listening.
    func listenFromHotkey() {
        model.showDashboard(.assistant)
        if !voice.isListening { toggleListening() }
    }

    // MARK: Handling

    func handle(_ text: String, spoken: Bool = false) {
        messages.append(Message(role: .user, text: text))
        // A "yes" / "no" answers the pending confirmation, if there is one.
        if let i = messages.lastIndex(where: { $0.pending != nil }), let answer = AssistantPlanner.confirmation(text) {
            if answer { confirm(messages[i].id) } else { decline(messages[i].id) }
            return
        }
        guard model.config.aiWorkEnabled || AssistantPlanner.localIntent(text) != nil else {
            reply("Work features are off in Settings → AI privacy, so I can only open screens and refresh.", error: true)
            return
        }
        thinking = true
        let context = AssistantContext(items: model.allItems, actions: model.config.agentActions,
                                       people: model.config.reportees.compactMap { $0.name ?? $0.username },
                                       screens: AssistantPlanner.screens)
        let history = conversationPairs()
        let planner = AssistantPlanner(claude: model.claude)
        Task {
            defer { thinking = false }
            do {
                let intent = try await planner.plan(text, context: context, history: history)
                perform(intent)
            } catch {
                reply(error.localizedDescription, error: true)
            }
        }
    }

    private func perform(_ intent: AssistantIntent) {
        let item = intent.item.flatMap { id in model.allItems.first { $0.id == id } }
        switch intent.action {
        case .runAgent:
            guard let item, let action = model.config.agentActions.first(where: { $0.id == intent.agent }) else { return reply(intent.reply) }
            let plan = AgentCenter.shared.plan(action, item: item)
            if !plan.runnable {
                return reply("I can't run \(action.name) on \(plan.itemRef): " + plan.problems.joined(separator: "; ") + ".", error: true)
            }
            var m = Message(role: .assistant, text: "Run \(action.name) on \(plan.itemRef)? Say yes, or use the button.")
            m.pending = plan
            messages.append(m)
            speak(m.text)
        case .open:
            if let item { model.openItem(item) }
            reply(intent.reply)
        case .summarize:
            if let item { model.summarize(item) }
            reply(intent.reply)
        case .digest:
            if let item, let key = item.jiraKey ?? item["jiraKeys"]?.split(separator: ",").first.map(String.init) {
                model.digest(jiraKey: key, title: item.title, url: item.url)
            }
            reply(intent.reply)
        case .show:
            show(intent.screen ?? "home")
            reply(intent.reply)
        case .workBrief:
            model.selection = .workBrief
            model.generateWorkBrief()
            reply(intent.reply)
        case .standup:
            model.reportsTab = "standup"
            model.selection = .reports
            model.generateStandup()
            reply(intent.reply)
        case .oneOnOne:
            if let r = model.config.reportees.first(where: { ($0.name ?? $0.username ?? "").caseInsensitiveCompare(intent.person ?? "") == .orderedSame }) {
                OneOnOneView.selected = r.id
                model.reportsTab = "oneonone"
                model.selection = .reports
                TeamDesk.shared.generatePrep(r)
            }
            reply(intent.reply)
        case .refresh:
            model.refreshAll()
            reply(intent.reply)
        case .answer:
            reply(intent.reply)
        }
    }

    func confirm(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), let plan = messages[i].pending else { return }
        messages[i].pending = nil
        let id = AgentCenter.shared.runInBackground(plan)
        var m = Message(role: .assistant, text: "Running \(plan.action.name) on \(plan.itemRef). I'll tell you when it's done.")
        m.runID = id
        messages.append(m)
        speak(m.text)
    }

    func decline(_ messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].pending = nil
        reply("Okay, not running it.")
    }

    /// Called by AgentCenter when a run started from here finishes.
    func runFinished(_ run: AgentRun) {
        guard messages.contains(where: { $0.runID == run.id }) else { return }
        let firstLine = run.output.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        var m = Message(role: .assistant, text: "\(run.actionName) on \(run.itemRef): \(run.status.label.lowercased()). "
                        + (firstLine.isEmpty ? "" : String(firstLine.prefix(160))))
        m.runID = run.id
        m.isError = run.status != .succeeded
        messages.append(m)
        speak("\(run.actionName) on \(run.itemRef) is \(run.status.label.lowercased()).")
    }

    func clear() {
        messages = []
        Speech.shared.stop()
    }

    // MARK: Helpers

    private func reply(_ text: String, error: Bool = false) {
        var m = Message(role: .assistant, text: text)
        m.isError = error
        messages.append(m)
        speak(text)
    }

    private func speak(_ text: String) {
        guard model.config.voiceSpeakReplies else { return }
        Speech.shared.say(text, voice: model.config.speechVoice, rate: model.config.speechRate)
    }

    private func show(_ screen: String) {
        switch screen {
        case "inbox": model.selection = .inbox
        case "merge requests": model.selection = .mergeRequests
        case "pipelines": model.selection = .pipelines
        case "jira": model.selection = .jira
        case "work brief": model.selection = .workBrief
        case "reports": model.selection = .reports
        case "team radar": model.reportsTab = "radar"; model.selection = .reports
        case "one on one": model.reportsTab = "oneonone"; model.selection = .reports
        case "agent runs": model.selection = .agentRuns
        case "world": model.selection = .worldBrief
        case "settings": model.selection = .settings
        default: model.selection = .home
        }
    }

    private func conversationPairs() -> [(user: String, reply: String)] {
        var out: [(String, String)] = []
        var lastUser: String?
        for m in messages.dropLast() {
            if m.role == .user { lastUser = m.text } else if let u = lastUser { out.append((u, m.text)); lastUser = nil }
        }
        return out
    }
}
