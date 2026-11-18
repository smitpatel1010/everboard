import AppKit
import EverboardCore
import SwiftUI

// Every list screen: one page header, one toolbar (tabs + filters + search), one keyboard-first list,
// and the shared peek panel for details and actions.

// MARK: - Inbox

struct InboxView: View {
    private var model: AppModel { .shared }
    private var peek: Peek { .shared }
    @State private var unreadOnly = false
    @State private var filter = "all"
    @State private var search = ""

    var filtered: [AppEvent] {
        model.events.filter { e in
            (!unreadOnly || !e.read) && (filter == "all" || e.category.source == filter)
                && (search.isEmpty || "\(e.title) \(e.body)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Inbox", subtitle: model.unread == 0 ? "All caught up" : "\(model.unread) unread") {
                Button("Mark all read") { model.markAllRead() }.disabled(model.unread == 0)
            }
            Toolbar {
                TabBar(tabs: [.init(id: "all", title: "All"), .init(id: "code", title: "Code"), .init(id: "jira", title: "Jira"),
                              .init(id: "news", title: "News"), .init(id: "brief", title: "Briefs")]
                       + (model.config.customSources.isEmpty ? [] : [.init(id: "custom", title: "Feeds")]),
                       selection: $filter)
            } trailing: {
                ChipToggle(title: "Unread", isOn: $unreadOnly)
                ListSearchField(text: $search)
            }
            if filtered.isEmpty {
                EmptyHint(icon: "tray", title: search.isEmpty ? "Inbox zero" : "No matches",
                          message: search.isEmpty ? "Pipeline failures, reportee MRs, review requests, Jira changes and major news land here." : "")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedByDay, id: \.0) { day, events in
                            Section {
                                ForEach(events) { e in InboxRow(event: e, selected: peek.event?.id == e.id).contextMenu { menu(for: e) } }
                            } header: {
                                Text(day).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4).background(Theme.canvas)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }

    var groupedByDay: [(String, [AppEvent])] {
        let cal = Calendar.current
        var out: [(String, [AppEvent])] = []
        for e in filtered {
            let label = cal.isDateInToday(e.ts) ? "Today" : cal.isDateInYesterday(e.ts) ? "Yesterday"
                : e.ts.formatted(.dateTime.weekday(.wide).day().month())
            if out.last?.0 == label { out[out.count - 1].1.append(e) } else { out.append((label, [e])) }
        }
        return out
    }

    @ViewBuilder func menu(for e: AppEvent) -> some View {
        Button("Open") { model.open(e) }
        Button(e.read ? "Already read" : "Mark read") { model.markRead([e.id]) }.disabled(e.read)
        if let item = model.item(withId: e.itemId) { ItemMenu(item: item) }
        Divider()
        if let itemId = e.itemId, !model.config.isMuted(itemId) {
            Button("Snooze this item for a day") { model.mute(itemId: itemId, for: 86400) }
        }
        Button("Turn off “\(e.category.label)” notifications") {
            model.updateConfig { $0.notifications[e.category.rawValue] = false }
        }
    }
}

private struct InboxRow: View {
    private var model: AppModel { .shared }
    let event: AppEvent
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let style = EventRow(event: event)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(style.tint.opacity(0.14))
                Image(systemName: style.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.tint)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(event.read ? .regular : .semibold).lineLimit(1)
                Text(event.body.replacingOccurrences(of: "\n", with: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering, let item = model.item(withId: event.itemId) {
                QuickActions(item: item)
            } else {
                Text(Dates.age(event.ts)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Circle().fill(event.read ? Color.clear : Theme.accent).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(event) }
        .simultaneousGesture(TapGesture().onEnded {
            Peek.shared.show(event)
            if !event.read { model.markRead([event.id]) }
        })
    }
}

// MARK: - Merge / pull requests

struct MergeRequestsView: View {
    private var model: AppModel { .shared }
    @State private var tab = "review"
    @State private var search = ""

    func list(_ tab: String) -> [FeedItem] {
        switch tab {
        case "mine": return model.items.mine
        case "assigned": return model.items.assigned
        case "reportees": return model.items.reportees
        case "todos": return model.items.todos
        default: return model.config.mrShowDraftReviews ? model.items.review : model.items.reviewReady
        }
    }

    var items: [FeedItem] { list(tab).filter { $0.matches(search) } }
    var hiddenDrafts: Int { model.items.review.count - model.items.reviewReady.count }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(model.changesTitle, subtitle: subtitle)
            Toolbar {
                TabBar(tabs: [.init(id: "review", title: "Review", count: list("review").count),
                              .init(id: "mine", title: "Mine", count: model.items.mine.count),
                              .init(id: "assigned", title: "Assigned", count: model.items.assigned.count),
                              .init(id: "reportees", title: "Team", count: model.items.reportees.count),
                              .init(id: "todos", title: "To-dos", count: model.items.todos.count)],
                       selection: $tab)
            } trailing: {
                if tab == "review" && (hiddenDrafts > 0 || model.config.mrShowDraftReviews) {
                    ChipToggle(title: "Drafts (\(hiddenDrafts))", isOn: configBinding(model, \.mrShowDraftReviews))
                }
                ListSearchField(text: $search)
            }
            if items.isEmpty {
                EmptyHint(icon: "arrow.triangle.pull", title: search.isEmpty ? "Nothing here" : "No matches", message: search.isEmpty ? emptyMessage : "")
            } else if tab == "reportees" {
                ItemList(sections: groupedByAuthor.map { .init(title: $0.0, items: $0.1) }) { ChangeRowContent(item: $0, showAuthor: false) }
            } else if tab == "todos" {
                ItemList(items) { TodoRowContent(item: $0) }
            } else {
                ItemList(items) { ChangeRowContent(item: $0, showAuthor: tab != "mine") }
            }
        }
        .onChange(of: tab) { Peek.shared.close() }
    }

    var subtitle: String {
        let red = model.items.mine.filter { $0["pipelineStatus"] == "failed" }.count
        return "\(model.items.reviewReady.count) waiting on your review · \(model.items.mine.count) of yours open" + (red > 0 ? " · \(red) red" : "")
    }

    var emptyMessage: String {
        if !model.hasCodeHost { return "Add a GitLab or GitHub account to your secrets file (Settings → Accounts)." }
        if tab == "reportees" && model.config.reportees.isEmpty { return "Add your team in Settings → Team." }
        return tab == "review" ? "No reviews waiting on you." : ""
    }

    var groupedByAuthor: [(String, [FeedItem])] {
        Dictionary(grouping: items) { $0["authorName"] ?? $0.author ?? "?" }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}

/// One MR/PR: pipeline glyph, title, ref and signals, author and age.
struct ChangeRowContent: View {
    let item: FeedItem
    var showAuthor = true

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: item["pipelineStatus"] ?? (item["draft"] == "1" ? "draft" : nil),
                        icon: item["pipelineStatus"] == nil ? "arrow.triangle.pull" : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item["draft"] == "1" { Tag(text: "Draft", color: .secondary) }
                    Text(item.title).fontWeight(.medium).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(item.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let n = item["notes"], n != "0" { Label(n, systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary) }
                    if item["approvedBy"] != nil { Label("Approved", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green) }
                    if let m = item["mergeStatus"], m != "mergeable" { Text(m.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.orange) }
                    if let keys = item["jiraKeys"] { Text(keys).font(.caption).foregroundStyle(Theme.accent).lineLimit(1) }
                    if stale { Label("Stuck \(Dates.age(item.createdAt))", systemImage: "hourglass").font(.caption).foregroundStyle(.orange) }
                }
            }
            Spacer(minLength: 8)
            if showAuthor, let a = item["authorName"] { Avatar(name: a) }
            Text(Dates.age(item.updatedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
    }

    var stale: Bool {
        guard item.kind != "mr.mine" else { return false }
        let age = Date().timeIntervalSince(item.createdAt ?? Date())
        return age > 3 * 86400 || (item["pipelineStatus"] == "failed" && age > 86400)
    }
}

struct TodoRowContent: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: nil, icon: item["action"]?.contains("mention") == true ? "at" : "bell")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subtitle).fontWeight(.medium).lineLimit(1)
                Text(item["body"].flatMap { $0.isEmpty ? nil : $0 } ?? item.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Dates.age(item.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Small colored label inside rows.
struct Tag: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
    }
}

// MARK: - Pipelines

struct PipelinesView: View {
    private var model: AppModel { .shared }
    @State private var filter = "all"
    @State private var search = ""

    var sorted: [FeedItem] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let recentFailed = model.items.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > dayAgo }
        return recentFailed + model.items.pipelines.filter { !recentFailed.contains($0) }
    }

    static let active: Set<String> = ["running", "pending", "created", "preparing", "waiting_for_resource", "queued", "in_progress"]

    func matching(_ f: String) -> [FeedItem] {
        sorted.filter { p in
            let s = p.status ?? ""
            switch f {
            case "failed": return ["failed", "canceled"].contains(s)
            case "running": return Self.active.contains(s)
            default: return true
            }
        }
    }

    var items: [FeedItem] { matching(filter).filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Pipelines", subtitle: "Runs you triggered in the last 7 days, failures first")
            Toolbar {
                TabBar(tabs: [.init(id: "all", title: "All", count: sorted.count),
                              .init(id: "failed", title: "Failed", count: matching("failed").count),
                              .init(id: "running", title: "Running", count: matching("running").count)],
                       selection: $filter)
            } trailing: {
                ListSearchField(text: $search, prompt: "Project, branch, status")
            }
            if items.isEmpty {
                EmptyHint(icon: "bolt.horizontal", title: sorted.isEmpty ? "No recent pipelines" : "Nothing \(filter == "all" ? "matches" : filter)",
                          message: sorted.isEmpty ? "Pipelines and GitHub Actions runs you trigger in projects you're active in show up here." : "")
            } else {
                ItemList(items) { PipelineRowContent(item: $0) }
            }
        }
    }
}

struct PipelineRowContent: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: item.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let t = item["trigger"] { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            StatusPill(text: item.status ?? "?")
            Text(Dates.age(item.updatedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Jira

struct JiraView: View {
    private var model: AppModel { .shared }
    @State private var tab = "assigned"
    @State private var search = ""

    func items(_ tab: String) -> [FeedItem] {
        let showDone = model.config.jiraShowDone
        if tab == "assigned" {
            guard showDone else { return model.items.jiraAssigned }
            let open = Set(model.items.jiraAssigned.map(\.id))
            return (model.items.jiraAssigned + model.items.jiraDone.filter { !open.contains($0.id) }).sortedByUpdate()
        }
        let all = model.items.jiraFilters[tab] ?? []
        return showDone ? all : all.filter { $0["statusCategory"] != "done" }
    }

    var items: [FeedItem] { items(tab).filter { $0.matches(search) } }

    /// Grouped by status, in workflow order (to do → in progress → done).
    var sections: [ItemList<IssueRowContent>.Section] {
        let order = ["new": 0, "indeterminate": 1, "done": 2]
        return Dictionary(grouping: items) { $0.status ?? "No status" }
            .sorted { (order[$0.value[0]["statusCategory"] ?? ""] ?? 1, $0.key) < (order[$1.value[0]["statusCategory"] ?? ""] ?? 1, $1.key) }
            .map { .init(title: $0.key, items: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Jira", subtitle: model.secrets.hasJira ? "\(model.items.jiraAssigned.count) assigned to you" : "Not connected")
            Toolbar {
                TabBar(tabs: [.init(id: "assigned", title: "Assigned to me", count: items("assigned").count)]
                       + model.config.jiraFilters.map { .init(id: $0.id, title: $0.name, count: items($0.id).count) },
                       selection: $tab)
            } trailing: {
                ChipToggle(title: "Done", isOn: configBinding(model, \.jiraShowDone))
                ListSearchField(text: $search)
            }
            if items.isEmpty {
                EmptyHint(icon: "checklist", title: search.isEmpty ? "No issues" : "No matches",
                          message: !search.isEmpty ? "" : model.secrets.hasJira ? (model.config.jiraFilters.isEmpty ? "Add saved filters in Settings → Jira." : "")
                              : "Add JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN in Settings → Accounts.")
            } else {
                ItemList(sections: sections) { IssueRowContent(item: $0) }
            }
        }
        .onChange(of: tab) { Peek.shared.close() }
    }
}

struct IssueRowContent: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            PriorityGlyph(priority: item["priority"])
            Text(item["key"] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(item.title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 8)
            if let d = item["due"] { Label(d, systemImage: "calendar").font(.caption).foregroundStyle(.orange) }
            if let a = item["assignee"] { Avatar(name: a) }
            Text(Dates.age(item.updatedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
        }
    }
}

/// Jira-style priority bars.
struct PriorityGlyph: View {
    let priority: String?

    var body: some View {
        let level = switch priority?.lowercased() ?? "" {
        case "highest", "blocker", "critical": 4
        case "high": 3
        case "medium": 2
        case "low", "lowest": 1
        default: 0
        }
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= 4 ? Color.red : i <= level ? Color.primary.opacity(0.7) : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .frame(width: 22, height: 22)
        .help(priority.map { "Priority: \($0)" } ?? "No priority")
    }
}

// MARK: - Custom feeds

struct CustomFeedView: View {
    private var model: AppModel { .shared }
    let source: CustomSourceConfig
    @State private var search = ""

    var items: [FeedItem] { (model.items.custom[source.id] ?? []).filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(source.name, subtitle: source.kind == .folder ? source.folder : source.command) {
                Button { Task { await model.poller.refreshNow(source.sourceID) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh this feed now")
            }
            Toolbar {
                if let h = model.health[source.sourceID], !h.isHealthy, h != .idle {
                    Label(h.label, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            } trailing: {
                ListSearchField(text: $search)
            }
            if items.isEmpty {
                EmptyHint(icon: source.kind == .folder ? "folder" : "terminal", title: "Nothing here",
                          message: source.kind == .folder ? "No markdown notes found\(source.tag.isEmpty ? "" : " tagged #\(source.tag)")."
                              : "The command printed no items yet. See docs/extending.md for the JSON format.")
            } else {
                ItemList(items) { CustomRowContent(item: $0) }
            }
        }
    }
}

struct CustomRowContent: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status: item.status, icon: item.status == nil ? (item.kind == "note" ? "doc.text" : "circle.fill") : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let a = item.author { Text(a).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            if let s = item.status { StatusPill(text: s) }
            Text(Dates.age(item.updatedAt ?? item.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
