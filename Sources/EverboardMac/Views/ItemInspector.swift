import AppKit
import EverboardCore
import SwiftUI

/// Approve / comment prompts for any item, presented once by the dashboard so lists, menus and the inspector share them.
@MainActor @Observable
final class ItemPrompts {
    static let shared = ItemPrompts()
    var approve: FeedItem?
    var comment: FeedItem?
}

extension FeedItem {
    /// Jira key of an issue item.
    var jiraKey: String? { source == "jira" ? self["key"] : nil }

    /// Everything a list search should match on.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let hay = [title, subtitle, status, author, self["authorName"], self["key"], self["assignee"], self["projectPath"],
                   self["ref"], self["sourceBranch"], self["jiraKeys"]].compactMap { $0 }.joined(separator: " ")
        return q.split(separator: " ").allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }
}

extension AppModel {
    /// Opens an item: its web page, or for folder notes the note itself.
    func openItem(_ item: FeedItem) {
        if item.url != nil { open(item.url); return }
        guard let path = item["path"], let source = config.customSources.first(where: { $0.id == item["feed"] }),
              source.kind == .folder else { return }
        let root = URL(fileURLWithPath: (source.folder as NSString).expandingTildeInPath).standardizedFileURL.path
        let file = URL(fileURLWithPath: path).standardizedFileURL
        if file.path.hasPrefix(root + "/") { NSWorkspace.shared.open(file) }
    }

    func copyLink(_ item: FeedItem) {
        guard let url = item.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        ToastCenter.shared.show(.init(title: "Link copied", body: item.subtitle, actionTitle: nil, onClick: {}, onAction: nil), duration: 2)
    }

    func toggleMute(_ item: FeedItem) {
        if config.isMuted(item.id) { unmute(itemId: item.id) } else { mute(itemId: item.id, for: nil) }
    }
}

/// The one right-click menu for an item, wherever it's listed.
struct ItemMenu: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        Button("Open") { model.openItem(item) }.disabled(item.url == nil && item["path"] == nil)
        if item.isCodeChange { Button("Summarize with AI") { model.summarize(item) } }
        if let key = item.jiraKey { Button("AI digest") { model.digest(jiraKey: key, title: item.title, url: item.url) } }
        if let p = item["pipelineUrl"], item.kind != "pipeline" { Button("Open pipeline") { model.open(p) } }
        if let path = item["path"] { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
        Divider()
        if item.isCodeChange && item.kind != "mr.mine" { Button("Approve…") { ItemPrompts.shared.approve = item } }
        if (item.isCodeChange && item["pipelineStatus"] == "failed") || (item.kind == "pipeline" && ["failed", "canceled"].contains(item.status ?? "")) {
            Button("Retry pipeline") { model.retryPipeline(item) }
        }
        if item.isCodeChange || item.jiraKey != nil { Button("Comment…") { ItemPrompts.shared.comment = item } }
        if item.kind == "todo" { Button("Mark done") { model.markTodoDone(item) } }
        AgentActionItems(item: item)
        Divider()
        if item.url != nil { Button("Copy link") { model.copyLink(item) } }
        Button(model.config.isMuted(item.id) ? "Unmute" : "Mute notifications") { model.toggleMute(item) }
    }
}

/// Right-hand panel with an item's details and every action as a labeled button.
struct ItemInspector: View {
    private var model: AppModel { .shared }
    private var agents: AgentCenter { .shared }
    let item: FeedItem
    var close: () -> Void
    @State private var transitions: [JiraClient.Transition] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                facts
                Divider()
                actions
                runs
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) {
            transitions = []
            if let key = item.jiraKey { transitions = await model.jiraTransitions(key) }
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Label(kindLabel, systemImage: kindIcon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
            }
            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let s = item.status { StatusPill(text: s) }
                if item["draft"] == "1" { StatusPill(text: "draft") }
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !jiraKeys.isEmpty {
                GridRow {
                    Text("Jira").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(jiraKeys, id: \.self) { key in
                            Button(key) { model.digest(jiraKey: key, url: model.secrets.jiraBaseURL.map { $0.absoluteString + "/browse/" + key }) }
                                .buttonStyle(.link).help("AI digest of \(key)")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            action("Open in browser", "safari") { model.openItem(item) }.disabled(item.url == nil && item["path"] == nil)
            if item.isCodeChange { action("Summarize with AI", "sparkles") { model.summarize(item) } }
            if let key = item.jiraKey { action("AI digest", "sparkles") { model.digest(jiraKey: key, title: item.title, url: item.url) } }
            if let p = item["pipelineUrl"], item.kind != "pipeline" { action("Open pipeline", "gearshape.2") { model.open(p) } }
            if item.isCodeChange && item.kind != "mr.mine" { action("Approve…", "checkmark.seal") { ItemPrompts.shared.approve = item } }
            if canRetry { action("Retry pipeline", "arrow.counterclockwise") { model.retryPipeline(item) } }
            if item.isCodeChange || item.jiraKey != nil { action("Comment…", "text.bubble") { ItemPrompts.shared.comment = item } }
            if item.kind == "todo" { action("Mark done", "checkmark.circle") { model.markTodoDone(item) } }
            if let key = item.jiraKey, !transitions.isEmpty {
                Menu {
                    ForEach(transitions) { t in Button("→ \(t.to?.name ?? t.name)") { model.transition(key, to: t) } }
                } label: { Label("Move to…", systemImage: "arrow.right.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            let agentActions = agents.actions(for: item)
            if agentActions.isEmpty {
                action("Add an agent action…", "terminal") { model.settingsTab = "agents"; model.selection = .settings }
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    ForEach(agentActions) { a in
                        Button { agents.request(a, item: item) } label: { Label(a.name, systemImage: a.icon) }
                    }
                } label: { Label("Run agent", systemImage: "terminal") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if item.url != nil { action("Copy link", "link") { model.copyLink(item) } }
            action(model.config.isMuted(item.id) ? "Unmute" : "Mute notifications",
                   model.config.isMuted(item.id) ? "bell" : "bell.slash") { model.toggleMute(item) }
        }
    }

    @ViewBuilder private var runs: some View {
        let history = agents.history.filter { $0.itemId == item.id }.prefix(5)
        if !history.isEmpty {
            Divider()
            Text("Agent runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(history)) { r in
                Button { agents.show(r.id) } label: {
                    HStack {
                        Text(r.actionName).lineLimit(1)
                        Spacer()
                        AgentStatusBadge(run: agents.live[r.id]?.record ?? r)
                        AgeText(date: r.ts)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.borderless)
    }

    // MARK: Data

    private var canRetry: Bool {
        (item.isCodeChange && item["pipelineStatus"] == "failed") || (item.kind == "pipeline" && ["failed", "canceled"].contains(item.status ?? ""))
    }

    private var jiraKeys: [String] {
        item.jiraKey == nil ? (item["jiraKeys"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []) : []
    }

    private var kindLabel: String {
        switch AgentTarget.of(item) {
        case .change: return item.source == "github" ? "Pull request" : "Merge request"
        case .pipeline: return item.source == "github" ? "Workflow run" : "Pipeline"
        case .issue: return "Jira issue"
        case .todo: return item.source == "github" ? "Notification" : "To-do"
        case .custom: return item["feedName"] ?? "Feed item"
        }
    }

    private var kindIcon: String {
        switch AgentTarget.of(item) {
        case .change: return "arrow.triangle.pull"
        case .pipeline: return "gearshape.2"
        case .issue: return "checklist"
        case .todo: return "checkmark.circle"
        case .custom: return "tray"
        }
    }

    private var rows: [(String, String)] {
        var r: [(String, String?)] = []
        let age = { (d: Date?) in d.map { Dates.age($0) + " ago" } }
        switch AgentTarget.of(item) {
        case .change:
            r = [("Author", item["authorName"] ?? item.author),
                 ("Branch", item["sourceBranch"].map { "\($0) → \(item["targetBranch"] ?? "?")" }),
                 ("Pipeline", item["pipelineStatus"]),
                 ("Merge", item["mergeStatus"].map { $0.replacingOccurrences(of: "_", with: " ") }),
                 ("Approved by", item["approvedBy"]),
                 ("Reviewers", item["reviewers"]),
                 ("Comments", item["notes"]),
                 ("Opened", age(item.createdAt)), ("Updated", age(item.updatedAt))]
        case .pipeline:
            r = [("Project", item["projectPath"]), ("Ref", item["ref"]), ("Trigger", item["trigger"]),
                 ("Run", item["pipelineId"].map { "#\($0)" }), ("Updated", age(item.updatedAt))]
        case .issue:
            r = [("Priority", item["priority"]), ("Type", item["type"]), ("Assignee", item["assignee"] ?? "Unassigned"),
                 ("Reporter", item["reporter"]), ("Due", item["due"]), ("Updated", age(item.updatedAt))]
        case .todo:
            r = [("Project", item["projectPath"]), ("Note", item["body"]), ("Created", age(item.createdAt))]
        case .custom:
            let hidden: Set<String> = ["feed", "feedName", "title", "status", "url", "author", "owner"]
            r = [("Author", item.author), ("Updated", age(item.updatedAt ?? item.createdAt))]
                + item.attrs.keys.sorted().filter { !hidden.contains($0) }.map { ($0 == "path" ? "File" : $0.capitalized, item.attrs[$0]) }
        }
        return r.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
    }
}

/// Search field for list headers.
struct ListSearchField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 200)
    }
}
