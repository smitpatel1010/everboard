import EverboardCore
import SwiftUI

/// Talk or type to your agents, in as many chats as you like.
struct AssistantView: View {
    private var model: AppModel { .shared }
    private var assistant: AssistantModel { .shared }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // The chat list folds into a menu in the header when the window is narrow.
                if geo.size.width >= 720 {
                    ChatList()
                        .frame(width: 230)
                        .background(Theme.surface.opacity(0.5))
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                ChatPane(showChatMenu: geo.size.width < 720)
            }
        }
        .task { await assistant.load() }
    }
}

private struct ChatList: View {
    private var assistant: AssistantModel { .shared }
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { assistant.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New chat (⌘N)").keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(assistant.chats) { chat in
                        let selected = chat.id == assistant.currentID
                        Button { assistant.select(chat.id) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.messages.isEmpty ? "New chat" : chat.title).lineLimit(1)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text(Dates.age(chat.updatedAt) + " ago · \(chat.messages.count) messages")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if hovered == chat.id {
                                    Button { assistant.delete(chat.id) } label: { Image(systemName: "trash").font(.caption) }
                                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete chat")
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : hovered == chat.id ? Theme.hover : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? chat.id : (hovered == chat.id ? nil : hovered) }
                        .contextMenu { Button("Delete chat", role: .destructive) { assistant.delete(chat.id) } }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Text("Each message sends your dashboard snapshot and only this chat's last \(AssistantChat.memory) exchanges, so long chats don't grow the prompt.")
                .font(.caption2).foregroundStyle(.tertiary).padding(12)
        }
    }
}

private struct ChatPane: View {
    private var model: AppModel { .shared }
    private var assistant: AssistantModel { .shared }
    private var voice: VoiceInput { .shared }
    var showChatMenu = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(assistant.current.map { $0.messages.isEmpty ? "Assistant" : $0.title } ?? "Assistant", subtitle: subtitle) {
                if showChatMenu {
                    Menu {
                        Button("New chat") { assistant.newChat() }
                        Divider()
                        ForEach(assistant.chats) { c in Button(c.messages.isEmpty ? "New chat" : c.title) { assistant.select(c.id) } }
                    } label: { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .fixedSize()
                }
                Toggle(isOn: configBinding(model, \.voiceSpeakReplies)) { Label("Voice replies", systemImage: "speaker.wave.2") }
                    .toggleStyle(.button).help("Speak replies to spoken requests")
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        if assistant.messages.isEmpty { welcome } else {
                            ForEach(assistant.messages) { MessageBubble(message: $0).id($0.id) }
                        }
                        if assistant.thinking { ThinkingBubble() }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: assistant.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: assistant.thinking) { withAnimation { proxy.scrollTo("bottom") } }
            }
            composer
        }
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            guard voice.isListening else { return .ignored }
            voice.cancel()
            return .handled
        }
    }

    private var subtitle: String {
        let n = model.config.agentActions.count
        return "\(n) agent action\(n == 1 ? "" : "s") · ⌥⇧Space to talk · " + (model.config.voiceOnDeviceOnly ? "speech stays on this Mac" : "Apple speech recognition")
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            MicButton(size: 76).padding(.top, 36)
            VStack(spacing: 6) {
                Text("Talk to your agents").font(.title2.weight(.semibold))
                Text("Ask what needs you, open anything, or say “run deep review on the payments MR”. Agents always ask before they run, and nothing is posted for you.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            FlowChips(items: AssistantModel.suggestions) { assistant.handle($0, spoken: false) }
                .frame(maxWidth: 560)
            if model.config.agentActions.isEmpty {
                Button("Add your first agent action…") { model.settingsTab = "agents"; model.selection = .settings }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        @Bindable var assistant = assistant
        return VStack(spacing: 6) {
            if case .unavailable(let problem) = voice.state {
                Label(problem, systemImage: "mic.slash").font(.caption).foregroundStyle(.orange).frame(maxWidth: 720, alignment: .leading)
            }
            HStack(spacing: 10) {
                HStack {
                    if voice.isListening {
                        Text(voice.transcript.isEmpty ? "Listening… (esc to cancel)" : voice.transcript)
                            .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary).lineLimit(2)
                        Spacer()
                    } else {
                        TextField("Ask or tell your agents…", text: $assistant.draft, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...5).focused($focused)
                            .onSubmit { assistant.submitDraft() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(voice.isListening ? Theme.accent : Theme.hairline, lineWidth: voice.isListening ? 2 : 1))
                MicButton(size: 40)
                Button { assistant.submitDraft() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                        .background(Circle().fill(assistant.draft.isEmpty ? Color.secondary.opacity(0.2) : Theme.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 720)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Round push-to-talk button that pulses with your voice.
struct MicButton: View {
    private var voice: VoiceInput { .shared }
    let size: CGFloat

    var body: some View {
        Button { AssistantModel.shared.toggleListening() } label: {
            ZStack {
                if voice.isListening {
                    Circle().fill(Color.red.opacity(0.18)).scaleEffect(1 + voice.level * 0.6)
                        .animation(.easeOut(duration: 0.12), value: voice.level)
                }
                Circle().fill(voice.isListening ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accentGradient))
                Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help(voice.isListening ? "Stop and send" : "Talk (⌥⇧Space)")
    }
}

private struct MessageBubble: View {
    private var agents: AgentCenter { .shared }
    private var assistant: AssistantModel { .shared }
    let message: AssistantChat.Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 80) } else {
                Circle().fill(Theme.accentGradient).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if message.spoken { Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                    Text(message.text).textSelection(.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(bubble, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                if let plan = assistant.pending[message.id] { ConfirmCard(plan: plan, messageID: message.id) }
                if let id = message.runID, let run = agents.record(id) {
                    HStack(spacing: 8) {
                        AgentStatusBadge(run: run)
                        Button("Show output") { agents.show(id) }.buttonStyle(.link).font(.caption)
                        if run.status == .running { Button("Stop") { agents.cancel(id) }.buttonStyle(.link).font(.caption) }
                    }
                }
            }
            if message.role == .assistant { Spacer(minLength: 80) }
        }
    }

    var bubble: AnyShapeStyle {
        if message.role == .user { return AnyShapeStyle(Theme.accent) }
        return message.isError ? AnyShapeStyle(Color.orange.opacity(0.15)) : AnyShapeStyle(Theme.surface)
    }
}

/// The "run this?" card inside the conversation.
private struct ConfirmCard: View {
    let plan: AgentPlan
    let messageID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.action.name, systemImage: plan.action.icon).font(.callout.weight(.semibold))
            Text(plan.item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(plan.preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Run") { AssistantModel.shared.confirm(messageID) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Cancel") { AssistantModel.shared.decline(messageID) }
                Spacer()
                Text("in \(plan.workingDirectory.lastPathComponent)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.4)))
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.accentGradient).frame(width: 26, height: 26)
                .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
    }
}

/// Wrapping row of tappable suggestion chips.
struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { tap(s) } label: {
                    Text(s).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.surface))
                        .overlay(Capsule().stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out left to right, wrapping and centering each line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var lines: [[(Subviews.Element, CGSize)]] = [[]]
        var x: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { lines.append([]); x = 0 }
            lines[lines.count - 1].append((s, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for line in lines {
            let lineWidth = line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(line.count - 1, 0))
            var x = bounds.minX + (bounds.width - lineWidth) / 2
            let h = line.map(\.1.height).max() ?? 0
            for (s, size) in line {
                s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + spacing
        }
    }
}
