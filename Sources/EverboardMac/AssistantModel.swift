import AppKit
import EverboardCore
import Foundation
import Observation

/// The Assistant: saved chats, each turning requests into dashboard actions. Agent runs are confirmed first.
///
/// Voice rules: a reply is spoken only when the request was spoken (voice in, voice out). Typing, clicking
/// or switching screens stops any speech. A finished run is announced aloud only if it was started by voice
/// and you're not already looking at the chat.
@MainActor @Observable
final class AssistantModel {
    static let shared = AssistantModel()

    var chats: [AssistantChat] = []
    var currentID: String?
    /// The chat waiting on Claude, if any.
    var thinkingChat: String?
    var thinking: Bool { thinkingChat != nil && thinkingChat == currentID }
    var draft = "" {
        didSet { if !draft.isEmpty, Speech.shared.speakingID == "assistant" { Speech.shared.stop() } }
    }
    /// Agent runs waiting for "yes" / Run, by message id. Not saved: a confirmation shouldn't outlive the session.
    var pending: [String: AgentPlan] = [:]
    /// Run id → whether it was confirmed by voice.
    @ObservationIgnored private var runVoice: [String: Bool] = [:]
    @ObservationIgnored private var loaded = false

    private var model: AppModel { .shared }
    private var voice: VoiceInput { .shared }

    static let suggestions = [
        "What needs me today?",
        "Which reviews have waited the longest?",
        "Why did my last pipeline fail?",
        "Open team radar",
    ]

    var current: AssistantChat? { chats.first { $0.id == currentID } }
    var messages: [AssistantChat.Message] { current?.messages ?? [] }

    // MARK: Chats

    func load() async {
        guard !loaded else { return }
        loaded = true
        // Keep anything started before the saved chats finished loading (e.g. a question asked from Home).
        let saved = (try? await model.store.chats()) ?? []
        chats += saved.filter { s in !chats.contains { $0.id == s.id } }
        if currentID == nil { currentID = chats.first?.id }
    }

    func newChat() {
        stopSpeaking()
        // Reuse an untouched empty chat instead of piling up blanks.
        if let empty = chats.first(where: { $0.messages.isEmpty }) { currentID = empty.id; return }
        let chat = AssistantChat()
        chats.insert(chat, at: 0)
        currentID = chat.id
    }

    func select(_ id: String) {
        stopSpeaking()
        currentID = id
    }

    func delete(_ id: String) {
        chats.removeAll { $0.id == id }
        if currentID == id { currentID = chats.first?.id }
        Task { try? await model.store.deleteChat(id: id) }
    }

    private func append(_ m: AssistantChat.Message, to chatID: String? = nil) {
        if let chatID, chatID != currentID { return append(m, toChat: chatID) }
        if current == nil { newChat() }
        guard let i = chats.firstIndex(where: { $0.id == currentID }) else { return }
        chats[i].messages.append(m)
        chats[i].updatedAt = Date()
        if m.role == .user, chats[i].messages.filter({ $0.role == .user }).count == 1 { chats[i].title = AssistantChat.title(from: m.text) }
        let chat = chats[i]
        // Most recent chat first.
        if i != 0 { chats.remove(at: i); chats.insert(chat, at: 0) }
        Task { try? await model.store.saveChat(chat) }
    }

    /// Adds a message to a specific chat (a run can finish after you've switched chats).
    private func append(_ m: AssistantChat.Message, toChat id: String) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].messages.append(m)
        chats[i].updatedAt = Date()
        let chat = chats[i]
        Task { try? await model.store.saveChat(chat) }
    }

    // MARK: Input

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !text.isEmpty { handle(text, spoken: false) }
    }

    func toggleListening() {
        if voice.isListening { voice.stop(); return }
        voice.clearProblem()
        stopSpeaking()
        Task { await voice.start(onDeviceOnly: model.config.voiceOnDeviceOnly) { [weak self] text in self?.handle(text, spoken: true) } }
    }

    /// From the hotkey or a mic button outside the Assistant: the floating panel over whatever app you're in.
    func listenFromHotkey() {
        AssistantPanel.shared.hotkey()
    }

    // MARK: Handling

    func handle(_ text: String, spoken: Bool) {
        stopSpeaking()
        append(.init(role: .user, text: text, spoken: spoken))
        // A "yes" / "no" answers the latest pending confirmation in this chat.
        if let m = messages.last(where: { pending[$0.id] != nil }), let answer = AssistantPlanner.confirmation(text) {
            if answer { confirm(m.id, spoken: spoken) } else { decline(m.id, spoken: spoken) }
            return
        }
        guard model.config.aiWorkEnabled || AssistantPlanner.localIntent(text) != nil else {
            reply("Work features are off in Settings → AI privacy, so I can only open screens and refresh.", spoken: spoken, error: true)
            return
        }
        let context = AssistantContext(items: model.allItems, actions: model.config.agentActions,
                                       people: model.config.reportees.compactMap { $0.name ?? $0.username },
                                       screens: AssistantPlanner.screens)
        // Only this chat's last few exchanges go along, never the whole history.
        let history = current?.exchanges ?? []
        let planner = AssistantPlanner(claude: model.claude)
        let chatID = currentID
        thinkingChat = chatID
        Task {
            defer { if thinkingChat == chatID { thinkingChat = nil } }
            do {
                let intent = try await planner.plan(text, context: context, history: history)
                // If you moved to another chat meanwhile, the answer still lands in the chat you asked in,
                // but nothing happens on screen behind your back.
                if chatID == currentID { perform(intent, spoken: spoken) } else { deliverLate(intent, to: chatID) }
            } catch {
                reply(error.localizedDescription, spoken: spoken, error: true, to: chatID)
            }
        }
    }

    private func perform(_ intent: AssistantIntent, spoken: Bool) {
        let item = intent.item.flatMap { id in model.allItems.first { $0.id == id } }
        switch intent.action {
        case .runAgent:
            guard let item, let action = model.config.agentActions.first(where: { $0.id == intent.agent }) else {
                return reply(intent.reply, spoken: spoken)
            }
            let plan = AgentCenter.shared.plan(action, item: item)
            if !plan.runnable {
                return reply("I can't run \(action.name) on \(plan.itemRef): " + plan.problems.joined(separator: "; ") + ".", spoken: spoken, error: true)
            }
            let m = AssistantChat.Message(role: .assistant, text: "Run \(action.name) on \(plan.itemRef)?" + (spoken ? " Say yes, or use the button." : ""))
            pending[m.id] = plan
            append(m)
            if spoken { speak(m.text) }
        case .open:
            guard let item else { return reply(intent.reply, spoken: spoken) }
            model.openItem(item)
            reply(intent.reply, done: "Opened \(item.subtitle) in your browser.", spoken: spoken)
        case .summarize:
            guard let item else { return reply(intent.reply, spoken: spoken) }
            model.summarize(item)
            model.showDashboard()
            reply(intent.reply, done: "Summarizing \(item.subtitle); it opens in Everboard.", spoken: spoken)
        case .digest:
            guard let item, let key = item.jiraKey ?? item["jiraKeys"]?.split(separator: ",").first.map(String.init) else {
                return reply(intent.reply, spoken: spoken)
            }
            model.digest(jiraKey: key, title: item.title, url: item.url)
            model.showDashboard()
            reply(intent.reply, done: "Digesting \(key); it opens in Everboard.", spoken: spoken)
        case .show:
            let screen = intent.screen ?? "home"
            show(screen)
            reply(intent.reply, done: "Opened \(screen).", spoken: spoken)
        case .workBrief:
            model.generateWorkBrief()
            model.showDashboard(.workBrief)
            reply(intent.reply, done: "Opened the Work brief page; the new brief appears there in a minute.", spoken: spoken)
        case .standup:
            model.generateStandup()
            model.reportsTab = "standup"
            model.showDashboard(.reports)
            reply(intent.reply, done: "Drafting your standup; it's open under Team & reports.", spoken: spoken)
        case .oneOnOne:
            guard let r = model.config.reportees.first(where: { ($0.name ?? $0.username ?? "").caseInsensitiveCompare(intent.person ?? "") == .orderedSame })
            else { return reply(intent.reply, spoken: spoken) }
            TeamDesk.shared.generatePrep(r)
            TeamDesk.shared.prepPerson = r.id
            model.reportsTab = "oneonone"
            model.showDashboard(.reports)
            reply(intent.reply, done: "Drafting 1:1 prep for \(r.name ?? r.username ?? "them"); it's open under Team & reports.", spoken: spoken)
        case .refresh:
            model.refreshAll()
            reply(intent.reply, done: "Refreshing every account.", spoken: spoken)
        case .answer:
            reply(intent.reply, spoken: spoken)
        }
    }

    /// An answer for a chat you've left: keep run confirmations and replies, skip screen changes.
    private func deliverLate(_ intent: AssistantIntent, to chatID: String?) {
        guard let chatID else { return }
        if intent.action == .runAgent, let item = intent.item.flatMap({ id in model.allItems.first { $0.id == id } }),
           let action = model.config.agentActions.first(where: { $0.id == intent.agent }) {
            let plan = AgentCenter.shared.plan(action, item: item)
            let m = AssistantChat.Message(role: .assistant, text: "Run \(action.name) on \(plan.itemRef)?")
            if plan.runnable { pending[m.id] = plan }
            append(m, toChat: chatID)
        } else if intent.action == .answer {
            append(.init(role: .assistant, text: intent.reply), toChat: chatID)
        } else {
            // Nothing was done behind your back, so say so rather than leave the model's lead-in (or nothing).
            append(.init(role: .assistant, text: "Not done: you'd switched to another chat. Ask again here to do it."), toChat: chatID)
        }
    }

    func confirm(_ messageID: String, spoken: Bool = false) {
        guard let plan = pending.removeValue(forKey: messageID), let id = AgentCenter.shared.runInBackground(plan) else { return }
        runVoice[id] = spoken
        append(.init(role: .assistant, text: "Running \(plan.action.name) on \(plan.itemRef).", runID: id))
        if spoken { speak("Running \(plan.action.name). I'll tell you when it's done.") }
    }

    func decline(_ messageID: String, spoken: Bool = false) {
        guard pending.removeValue(forKey: messageID) != nil else { return }
        reply("Okay, not running it.", spoken: spoken)
    }

    /// Whether a run was started from a chat (so its finish shows up there instead of as a banner).
    func owns(_ runID: String) -> Bool { runVoice[runID] != nil }

    /// Called by AgentCenter when a run finishes.
    func runFinished(_ run: AgentRun) {
        guard let byVoice = runVoice.removeValue(forKey: run.id),
              let chat = chats.first(where: { $0.messages.contains { $0.runID == run.id } }) else { return }
        let firstLine = run.output.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        append(.init(role: .assistant, text: "\(run.actionName) on \(run.itemRef): \(run.status.label.lowercased())."
                     + (firstLine.isEmpty ? "" : " " + String(firstLine.prefix(160))), runID: run.id, isError: run.status != .succeeded),
               toChat: chat.id)
        if byVoice && !isLookingAtChat(chat.id) && model.config.voiceSpeakReplies {
            Speech.shared.say("\(run.actionName) on \(run.itemRef) is \(run.status.label.lowercased()).",
                              voice: model.config.speechVoice, rate: model.config.speechRate)
        }
    }

    /// True when this chat is on screen: the floating panel, or the Assistant page in the active app.
    func isLookingAtChat(_ id: String? = nil) -> Bool {
        let shown = AssistantPanel.shared.isVisible || (NSApp.isActive && model.selection == .assistant)
        return shown && (id == nil || id == currentID)
    }

    // MARK: Helpers

    /// The model's words, then what the app actually did. The second part comes from the app, so a reply never claims an
    /// action that didn't happen, and the chat history the planner sees says what really happened.
    private func reply(_ text: String, done: String, spoken: Bool) {
        let lead = text.trimmingCharacters(in: .whitespacesAndNewlines)
        reply(lead.isEmpty || lead.caseInsensitiveCompare(done) == .orderedSame ? done : lead + " " + done, spoken: spoken)
    }

    private func reply(_ text: String, spoken: Bool, error: Bool = false, to chatID: String? = nil) {
        append(.init(role: .assistant, text: text, isError: error), to: chatID)
        if spoken && (chatID == nil || chatID == currentID) { speak(text) }
    }

    private func speak(_ text: String) {
        guard model.config.voiceSpeakReplies else { return }
        Speech.shared.say(text, voice: model.config.speechVoice, rate: model.config.speechRate)
    }

    func stopSpeaking() {
        if Speech.shared.speakingID == "assistant" { Speech.shared.stop() }
    }

    /// Switches the dashboard to a screen and brings it forward (it may be closed when you ask from the floating panel).
    private func show(_ screen: String) {
        defer { model.showDashboard() }
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
        case "agent sessions": model.selection = .sessions
        case "world": model.selection = .worldBrief
        case "settings": model.selection = .settings
        default: model.selection = .home
        }
    }
}
