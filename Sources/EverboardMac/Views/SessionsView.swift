import EverboardCore
import SwiftUI

/// Colour and symbol for a session state, shared by the page, Home and the menu bar.
@MainActor enum SessionStyle {
    static func color(_ s: AgentSession, now: Date = Date()) -> Color {
        if SessionRules.mayNeedApproval(s, now: now) { return .orange }
        switch s.state {
        case .needsApproval: return .orange
        case .needsReply: return .pink
        case .error: return .red
        case .working: return .blue
        case .done: return .green
        case .idle, .ended: return .secondary
        }
    }

    static func symbol(_ s: AgentSession) -> String {
        switch s.state {
        case .needsApproval: return "hand.raised.fill"
        case .needsReply: return "questionmark.bubble.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .working: return "circle.dotted"
        case .done: return "checkmark"
        case .idle: return "pause.fill"
        case .ended: return "stop.fill"
        }
    }

    /// The line under the title: the question, the approval, or what it's doing.
    static func line(_ s: AgentSession, now: Date = Date()) -> String {
        if s.state == .working {
            let doing = s.activity ?? "Working"
            guard SessionRules.mayNeedApproval(s, now: now), let since = s.pendingSince else { return doing }
            return "\(doing) · \(Dates.age(since, now: now)) · may be waiting for your approval"
        }
        if let d = s.detail, !d.isEmpty { return d }
        return s.state == .idle ? "Started, no prompt yet" : s.state.label
    }

    /// Errors stay on the row for an hour, informational notes for ten minutes.
    static func recentNotice(_ s: AgentSession, now: Date = Date()) -> AgentSession.Notice? {
        guard let n = s.notice else { return nil }
        return now.timeIntervalSince(n.at) < (n.level == .error ? 3600 : 600) ? n : nil
    }

    /// The session's name when it has one; otherwise its first prompt, or (with prompts hidden) the tool, folder
    /// and start time so several sessions in one folder can be told apart.
    static func title(_ s: AgentSession, hidePrompts: Bool) -> String {
        if let name = s.name ?? SessionCenter.shared.desktopTitle(s), !name.isEmpty { return name }
        if !hidePrompts, let t = s.title { return t }
        let started = "started " + s.startedAt.formatted(date: Calendar.current.isDateInToday(s.startedAt) ? .omitted : .abbreviated,
                                                          time: .shortened)
        return [s.project.map { "\(s.toolName) in \($0)" } ?? s.toolName, started].joined(separator: " · ")
    }
}

struct SessionsView: View {
    private var center: SessionCenter { .shared }
    private var model: AppModel { .shared }
    @State private var showEnded = false

    var body: some View {
        // Re-render every few seconds so ages and "may be waiting" stay current.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(spacing: 0) {
                PageHeader("Agent sessions", subtitle: subtitle) {
                    if !center.ended.isEmpty {
                        Button(showEnded ? "Hide ended" : "Show ended (\(center.ended.count))") { showEnded.toggle() }
                    }
                    Button("Settings") { model.settingsTab = "sessions"; model.selection = .settings }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if center.sessions.isEmpty {
                    EmptyHint(icon: "rectangle.stack", title: "No agent sessions yet",
                              message: center.hookStatus.values.contains(.installed)
                                  ? "Start a Claude Code or Cursor session and it shows up here. Sessions already running appear after their next step."
                                  : "Install Everboard's hook in Claude Code or Cursor to see what each session is doing and which ones need you.",
                              action: ("Set up hooks", { model.settingsTab = "sessions"; model.selection = .settings }))
                } else {
                    ScrollView {
                        // A plain stack, not a lazy one: rows move between sections as their state changes, and a lazy
                        // stack can keep showing a row's old content after the move. There are only a few sessions.
                        VStack(alignment: .leading, spacing: 1) {
                            let groups = grouped(now: context.date)
                            ForEach(groups, id: \.0) { title, list in
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                                ForEach(list) { s in
                                    // Identity includes the state, so a change always draws a fresh row.
                                    SessionRow(session: s, now: context.date)
                                        .id("\(title)|\(s.id)|\(s.state.rawValue)|\(s.stateSince.timeIntervalSince1970)|\(s.approval?.id ?? "")")
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
            }
        }
        .navigationTitle("Agent Sessions")
    }

    private var subtitle: String {
        let waiting = center.needsYou.count
        let working = center.sessions.filter { $0.state == .working }.count
        if center.sessions.isEmpty { return "Claude Code, Cursor and any tool that writes a session file" }
        return [waiting > 0 ? "\(waiting) need\(waiting == 1 ? "s" : "") you" : nil, "\(working) working"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func grouped(now: Date) -> [(String, [AgentSession])] {
        let all = center.sessions
        let needs = all.filter { $0.state.needsYou || $0.state == .error || SessionRules.mayNeedApproval($0, now: now) }
        let needIds = Set(needs.map(\.id))
        let working = all.filter { $0.state == .working && !needIds.contains($0.id) }
        let rest = all.filter { [.done, .idle].contains($0.state) }
        var out: [(String, [AgentSession])] = []
        if !needs.isEmpty { out.append(("Needs you", needs)) }
        if !working.isEmpty { out.append(("Working", working)) }
        if !rest.isEmpty { out.append(("Finished or idle", rest)) }
        if showEnded && !center.ended.isEmpty { out.append(("Ended", center.ended)) }
        return out
    }
}

struct SessionRow: View {
    private var center: SessionCenter { .shared }
    private var model: AppModel { .shared }
    let session: AgentSession
    var now = Date()
    @State private var hovering = false

    var body: some View {
        let s = session
        let tint = SessionStyle.color(s, now: now)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: SessionStyle.symbol(s)).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionStyle.title(s, hidePrompts: model.config.sessionsHidePrompts)).fontWeight(.medium).lineLimit(1)
                Text(SessionStyle.line(s, now: now)).font(.callout)
                    .foregroundStyle(s.state.needsYou ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(s.toolName)
                    if let p = s.project { Text("·"); Text(p).font(.caption.monospaced()) }
                    if !model.config.sessionsHidePrompts, let prompt = s.prompt, prompt != s.title {
                        Text("·"); Text("Last ask: \(prompt)").lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)
                if let n = SessionStyle.recentNotice(s, now: now) {
                    Label(n.text, systemImage: n.level == .error ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(n.level == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                SessionAnswerBar(session: s, now: now)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(SessionRules.mayNeedApproval(s, now: now) ? "May need approval" : s.state.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(Dates.age(s.stateSince, now: now)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("In this state since \(s.stateSince.formatted(date: .omitted, time: .shortened))")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { center.open(s) }
        .help("Click to switch to this session")
        .contextMenu {
            Button("Switch to session") { center.open(s) }
            if s.resumeCommand != nil { Button("Copy resume command") { center.copyResumeCommand(s) } }
            if s.cwd != nil { Button("Show in Finder") { center.revealFolder(s) } }
            Divider()
            let itemId = "session:\(s.id)"
            if model.config.isMuted(itemId) {
                Button("Unmute notifications") { model.unmute(itemId: itemId) }
            } else {
                Button("Mute notifications for this session") { model.mute(itemId: itemId, for: nil) }
            }
            Button("Remove from list", role: .destructive) { center.remove(s) }
        }
    }
}

// MARK: - Settings

struct SessionSettings: View {
    private var model: AppModel { .shared }
    private var center: SessionCenter { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Show agent sessions", isOn: configBinding(model, \.sessionsEnabled))
                Toggle("Hide prompt text (show the project name instead)", isOn: configBinding(model, \.sessionsHidePrompts))
                Toggle("Answer Claude Code permission prompts and questions from Everboard", isOn: configBinding(model, \.sessionsHoldApprovals))
                Stepper("Answerable here for \(Int(model.config.sessionsHoldSeconds / 60)) min \(Int(model.config.sessionsHoldSeconds) % 60 == 0 ? "" : "\(Int(model.config.sessionsHoldSeconds) % 60) s")",
                        value: configBinding(model, \.sessionsHoldSeconds), in: 30...600, step: 30)
                    .disabled(!model.config.sessionsHoldApprovals)
                Text("Allow or Deny a permission prompt, or pick an answer to Claude's question, here, in the menu bar or from the notification. Claude's desktop app shows its own prompt at the same time, so you can answer in either place. For Claude Code in a terminal, prompts wait for Everboard only while you're in another app, and the terminal asks once the time runs out. Free-text replies are typed into sessions running in Terminal or iTerm2.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Everboard shows what each Claude Code or Cursor session is doing and tells you when one needs your approval or a reply. The tools report through a small hook; nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hooks") {
                ForEach(HookInstaller.Target.allCases) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayName)
                            Text(t.settingsURL().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch center.hookStatus[t] ?? .notInstalled {
                        case .installed:
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                            Button("Remove") { center.uninstall(t) }
                        case .outdated:
                            Label("Needs update", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                            Button("Update") { center.install(t) }
                            Button("Remove") { center.uninstall(t) }
                        case .notInstalled:
                            Button("Install") { center.install(t) }.disabled(!t.configFolderExists() && !DemoData.isDemo)
                                .help(t.configFolderExists() ? "Adds Everboard's entry to this file; other entries are kept" : "\(t.displayName) doesn't seem to be installed")
                        }
                    }
                }
                if let error = center.installError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                Text("Installing adds one entry per event to the file above, keeps a copy of the original next to it (.before-everboard), and leaves your other hooks alone. Restart running sessions to pick it up. Cursor gives no signal for approval prompts, so a tool call that runs long is shown as “may be waiting for your approval”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Other tools") {
                Text("Any tool can show up here by writing a JSON file per session to the folder below. The format is in docs/agent-sessions.md.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(SessionPaths.directory().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Open folder") {
                        let dir = SessionPaths.directory()
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { center.refreshHookStatus() }
    }
}

/// Allow / Deny for a prompt Everboard is holding, or a reply box for a terminal session's question.
struct SessionAnswerBar: View {
    private var center: SessionCenter { .shared }
    let session: AgentSession
    var now = Date()
    var compact = false
    @State private var reply = ""

    var body: some View {
        let s = session
        if let sent = center.sentAnswer(s) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(sent) · waiting for \(s.toolName)…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        } else if let approval = s.approval, approval.isQuestion, s.state == .needsReply {
            QuestionForm(session: s, approval: approval, held: center.canAnswer(s, now: now), now: now, compact: compact)
                .id(approval.id)
        } else if center.canAnswer(s, now: now), let until = s.approval?.holdUntil {
            HStack(spacing: 8) {
                Button("Allow") { center.answer(s, allow: true) }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(compact ? .small : .regular)
                Button("Deny") { center.answer(s, allow: false) }
                    .controlSize(compact ? .small : .regular)
                if !compact {
                    Text("or answer in \(s.toolName) after \(max(0, Int(until.timeIntervalSince(now))))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        } else if center.canReply(s) {
            HStack(spacing: 6) {
                TextField("Reply to \(s.toolName)…", text: $reply)
                    .textFieldStyle(.roundedBorder).controlSize(compact ? .small : .regular)
                    .onSubmit(send)
                Button("Send", action: send).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                    .controlSize(compact ? .small : .regular)
            }
            .frame(maxWidth: compact ? .infinity : 560, alignment: .leading)
            .padding(.top, 2)
        } else if s.state.needsYou && !compact {
            Button(s.state == .needsApproval ? "Answer in \(s.toolName)" : "Reply in \(s.toolName)") { center.open(s) }
                .controlSize(.small).padding(.top, 2)
        }
    }

    private func send() {
        center.reply(session, text: reply)
        reply = ""
    }
}

/// A multiple-choice question with its options. While Everboard holds it, Submit sends the picks to the agent
/// and Skip declines; otherwise the options are shown for reference and you answer in the session.
struct QuestionForm: View {
    private var center: SessionCenter { .shared }
    let session: AgentSession
    let approval: AgentSession.Approval
    let held: Bool
    var now = Date()
    var compact = false
    /// Question text → picked labels.
    @State private var picks: [String: Set<String>] = [:]
    /// Question text → "Other" text.
    @State private var other: [String: String] = [:]

    var body: some View {
        let questions = approval.questions ?? []
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(questions, id: \.question) { q in
                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    if questions.count > 1 || compact {
                        Text(q.question).font(compact ? .caption.weight(.medium) : .callout.weight(.medium)).lineLimit(compact ? 2 : nil)
                    }
                    ForEach(q.options, id: \.label) { option in optionRow(q, option) }
                    if held {
                        TextField("Other…", text: Binding(get: { other[q.question] ?? "" },
                                                         set: { other[q.question] = $0; if !$0.isEmpty && !q.multiSelect { picks[q.question] = [] } }))
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            .frame(maxWidth: compact ? .infinity : 360)
                    }
                }
            }
            HStack(spacing: 8) {
                if held {
                    Button("Submit") { center.answerQuestion(session, answers: answers(questions)) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(compact ? .small : .regular)
                        .disabled(!complete(questions))
                    Button("Skip") { center.skipQuestion(session) }.controlSize(compact ? .small : .regular)
                    if !compact, let until = approval.holdUntil {
                        Text("or answer in \(session.toolName) after \(max(0, Int(until.timeIntervalSince(now))))s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Answer in \(session.toolName)") { center.open(session) }.controlSize(.small)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func optionRow(_ q: AgentSession.ChoiceQuestion, _ option: AgentSession.ChoiceQuestion.Option) -> some View {
        let on = picks[q.question]?.contains(option.label) == true
        let symbol = q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
        Button {
            var set = picks[q.question] ?? []
            if q.multiSelect { if on { set.remove(option.label) } else { set.insert(option.label) } }
            else { set = on ? [] : [option.label]; other[q.question] = "" }
            picks[q.question] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(on ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(compact ? .caption : .callout)
                    if !compact, let d = option.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!held)
        .opacity(held ? 1 : 0.75)
    }

    private func answers(_ questions: [AgentSession.ChoiceQuestion]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for q in questions {
            var picked = Array(picks[q.question] ?? []).sorted { a, b in
                (q.options.firstIndex { $0.label == a } ?? 0) < (q.options.firstIndex { $0.label == b } ?? 0)
            }
            let typed = (other[q.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { picked = q.multiSelect ? picked + [typed] : [typed] }
            if !picked.isEmpty { out[q.question] = picked }
        }
        return out
    }

    private func complete(_ questions: [AgentSession.ChoiceQuestion]) -> Bool {
        let a = answers(questions)
        return questions.allSatisfy { a[$0.question] != nil }
    }
}
