import EverboardCore
import SwiftUI

/// Talk or type to your agents. Requests become dashboard actions; agent runs are always confirmed first.
struct AssistantView: View {
    private var model: AppModel { .shared }
    private var assistant: AssistantModel { .shared }
    private var voice: VoiceInput { .shared }
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var assistant = assistant
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        if assistant.messages.isEmpty { welcome } else {
                            ForEach(assistant.messages) { MessageBubble(message: $0).id($0.id) }
                        }
                        if assistant.thinking { ThinkingBubble() }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: assistant.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: assistant.thinking) { withAnimation { proxy.scrollTo("bottom") } }
            }
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Assistant")
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").foregroundStyle(.white).font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: configBinding(model, \.voiceSpeakReplies)) { Image(systemName: "speaker.wave.2") }
                .toggleStyle(.button).help("Read replies aloud")
            if !assistant.messages.isEmpty {
                Button { assistant.clear() } label: { Image(systemName: "trash") }.help("Clear the conversation")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var subtitle: String {
        let n = model.config.agentActions.count
        let where_ = model.config.voiceOnDeviceOnly ? "speech stays on this Mac" : "Apple speech recognition"
        return "\(n) agent action\(n == 1 ? "" : "s") · ⌥⇧Space to talk · \(where_)"
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            MicButton(size: 84)
                .padding(.top, 40)
            VStack(spacing: 6) {
                Text("Talk to your agents").font(.title2.weight(.semibold))
                Text("Ask what needs you, open anything, or say “run deep review on the payments MR”. Agents always ask before they run, and nothing is posted for you.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            FlowChips(items: AssistantModel.suggestions) { assistant.handle($0) }
                .frame(maxWidth: 560)
            if model.config.agentActions.isEmpty {
                Button("Add your first agent action…") { model.settingsTab = "agents"; model.selection = .settings }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        @Bindable var assistant = assistant
        return VStack(spacing: 6) {
            if case .unavailable(let problem) = voice.state {
                Label(problem, systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: 740, alignment: .leading)
            }
            HStack(spacing: 10) {
                HStack {
                    if voice.isListening {
                        Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                            .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary).lineLimit(2)
                        Spacer()
                    } else {
                        TextField("Ask or tell your agents…", text: $assistant.draft, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...4).focused($focused)
                            .onSubmit { assistant.submitDraft() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(voice.isListening ? Color.accentColor : Color.primary.opacity(0.12),
                                                                   lineWidth: voice.isListening ? 2 : 1))
                MicButton(size: 40)
                Button { assistant.submitDraft() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
                        .background(Circle().fill(assistant.draft.isEmpty ? Color.secondary.opacity(0.2) : Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .frame(maxWidth: 740)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Big round push-to-talk button that pulses with your voice.
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
                Circle().fill(voice.isListening ? AnyShapeStyle(Color.red)
                              : AnyShapeStyle(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
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
    private var model: AppModel { .shared }
    private var agents: AgentCenter { .shared }
    let message: AssistantModel.Message

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 80) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(bubble, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                if let plan = message.pending { ConfirmCard(plan: plan, messageID: message.id) }
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
        if message.role == .user { return AnyShapeStyle(Color.accentColor) }
        return message.isError ? AnyShapeStyle(Color.orange.opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06))
    }
}

/// The "run this?" card inside the conversation.
private struct ConfirmCard: View {
    let plan: AgentPlan
    let messageID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.action.name, systemImage: plan.action.icon).font(.callout.weight(.semibold))
            Text(plan.item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(plan.preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Run") { AssistantModel.shared.confirm(messageID) }.buttonStyle(.borderedProminent)
                Button("Cancel") { AssistantModel.shared.decline(messageID) }
                Spacer()
                Text("in \(plan.workingDirectory.lastPathComponent)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.4)))
    }
}

private struct ThinkingBubble: View {
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
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
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
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
        // Center each line.
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
