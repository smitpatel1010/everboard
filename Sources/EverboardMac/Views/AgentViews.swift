import EverboardCore
import SwiftUI

/// Menu items for every agent action that applies to `item`. Drop into any context menu.
struct AgentActionItems: View {
    let item: FeedItem
    private var agents: AgentCenter { .shared }

    var body: some View {
        let actions = agents.actions(for: item)
        if !actions.isEmpty {
            Divider()
            ForEach(actions) { action in
                Button { agents.request(action, item: item) } label: { Label(action.name, systemImage: action.icon) }
            }
        }
    }
}

/// "Run this?" with the exact command, folder, and any problems.
struct AgentConfirmSheet: View {
    let plan: AgentPlan
    private var agents: AgentCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(plan.action.name, systemImage: plan.action.icon).font(.headline)
            Text("\(plan.itemRef) — \(plan.item.title)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            GroupBox("Command") {
                Text(plan.preview).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Runs in \(plan.workingDirectory.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !plan.runnable {
                ForEach(plan.problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            } else {
                Text("The command runs on your Mac with your permissions. Everboard shows its output and posts nothing anywhere.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Edit actions…") {
                    agents.pending = nil
                    AppModel.shared.settingsTab = "agents"
                    AppModel.shared.showDashboard(.settings)
                }
                Spacer()
                Button("Cancel") { agents.pending = nil }.keyboardShortcut(.cancelAction)
                Button("Run") { agents.run(plan) }.keyboardShortcut(.defaultAction).disabled(!plan.runnable)
            }
        }
        .padding()
        .frame(width: 560)
    }
}

/// Output of one run, live or from history.
struct AgentRunSheet: View {
    let id: String
    private var agents: AgentCenter { .shared }
    private var model: AppModel { .shared }
    @State private var commenting = false

    var body: some View {
        let run = agents.record(id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(run?.actionName ?? "Agent run", systemImage: "terminal").font(.headline)
                    Text(run.map { "\($0.itemRef) — \($0.itemTitle)" } ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if let run {
                    AgentStatusBadge(run: run)
                    if run.status == .running {
                        Button("Stop") { agents.cancel(id) }
                    } else {
                        if !run.output.isEmpty {
                            Button { model.copyToClipboard(run.output) } label: { Image(systemName: "doc.on.doc") }.help("Copy output")
                        }
                        if let item = agents.item(for: run), item.isCodeChange, !run.output.isEmpty {
                            Button { commenting = true } label: { Image(systemName: "text.bubble") }
                                .help("Post as a comment… (you review and edit it first)")
                        }
                        if let note = run.notePath {
                            Button { model.openInBrain(note) } label: { Image(systemName: "note.text") }.help("Open the saved note")
                        } else if model.brain != nil {
                            Button { agents.saveToBrain(id) } label: { Image(systemName: "square.and.arrow.down") }.help("Save to your notes")
                        }
                    }
                    if run.itemUrl != nil {
                        Button { model.open(run.itemUrl) } label: { Image(systemName: "safari") }.help("Open item")
                    }
                }
                Button("Done") { agents.presented = nil }.keyboardShortcut(.cancelAction)
            }
            .padding()
            if let run {
                Text(run.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        if let output = run?.output, !output.isEmpty {
                            Text(output).font(.callout.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if run?.status == .running {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for output…").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No output.").foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: run?.output.count ?? 0) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 440, idealHeight: 600)
        .sheet(isPresented: $commenting) {
            if let run, let item = agents.item(for: run) {
                CommentSheet(title: "Comment on \(item.subtitle)", initial: run.output) { model.commentOnMR(item, text: $0) }
            }
        }
    }
}

struct AgentStatusBadge: View {
    let run: AgentRun

    var body: some View {
        HStack(spacing: 4) {
            if run.status == .running { ProgressView().controlSize(.mini) }
            Text(run.status.label + (run.exitCode.map { $0 != 0 ? " (\($0))" : "" } ?? ""))
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }

    var color: Color {
        switch run.status {
        case .running: return .blue
        case .succeeded: return .green
        case .failed, .timedOut: return .red
        case .cancelled: return .secondary
        }
    }
}

/// Sidebar → Agent runs: the history of every run, newest first.
struct AgentRunsView: View {
    private var agents: AgentCenter { .shared }
    private var model: AppModel { .shared }
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.config.agentActions.isEmpty ? "No agent actions yet — add one in Settings → Agents."
                     : "\(model.config.agentActions.count) action\(model.config.agentActions.count == 1 ? "" : "s") · right-click any MR, PR, pipeline or issue to run one")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") { model.settingsTab = "agents"; model.selection = .settings }
                Button("Clear history") { confirmClear = true }.disabled(agents.history.isEmpty)
            }
            .padding(10)
            Divider()
            if agents.history.isEmpty {
                EmptyState(icon: "terminal", title: "No agent runs yet",
                           message: "Agent actions run your own CLI commands, such as claude -p or cursor-agent, on an item. Output and history stay on this Mac.")
            } else {
                List {
                    ForEach(agents.history) { run in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(run.actionName) · \(run.itemRef)").font(.body.weight(.medium)).lineLimit(1)
                                Text(run.itemTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            AgentStatusBadge(run: agents.live[run.id]?.record ?? run)
                            if run.notePath != nil { Image(systemName: "note.text").foregroundStyle(.secondary).help("Saved to your notes") }
                            AgeText(date: run.ts)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture { agents.show(run.id) }
                        .contextMenu {
                            Button("Show output") { agents.show(run.id) }
                            if let url = run.itemUrl { Button("Open item") { model.open(url) } }
                            if let note = run.notePath { Button("Open note") { model.openInBrain(note) } }
                            if agents.isRunning(run.id) { Button("Stop") { agents.cancel(run.id) } }
                            Divider()
                            Button("Delete", role: .destructive) { agents.delete([run.id]) }.disabled(agents.isRunning(run.id))
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent Runs")
        .task { await agents.reloadHistory() }
        .confirmationDialog("Delete all agent run history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { agents.clearHistory() }
        } message: { Text("Notes already saved to your brain folder are kept.") }
    }
}
