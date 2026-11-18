import EverboardCore
import SwiftUI

struct DashboardView: View {
    private var model: AppModel { .shared }

    var body: some View {
        @Bindable var model = model
        Group {
            if DemoData.snapshotDir != nil {
                // Snapshot mode: the glass sidebar of NavigationSplitView can't be captured offscreen, so draw it flat.
                HStack(spacing: 0) {
                    SnapshotSidebar(health: healthFooter)
                        .frame(width: 220)
                        .background(.background.secondary)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 210)
                } detail: {
                    detail
                        .toolbar {
                            ToolbarItem {
                                Button { CommandPalette.shared.show() } label: { Label("Search", systemImage: "magnifyingglass") }
                                    .help("Search everything (⌥Space)")
                            }
                            ToolbarItem {
                                Button { model.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                    .help("Refresh every account now (⌘R)")
                                    .keyboardShortcut("r", modifiers: .command)
                            }
                        }
                }
            }
        }
        .sheet(item: $model.aiPanel) { panel in
            AIPanelSheet(panel: panel).environment(model).environment(\.refLinker, model.refLinker)
        }
        .sheet(item: Bindable(AgentCenter.shared).pending) { plan in AgentConfirmSheet(plan: plan) }
        .sheet(item: Bindable(ItemPrompts.shared).comment) { item in
            CommentSheet(title: "Comment on \(item.jiraKey ?? item.subtitle)") { text in
                if let key = item.jiraKey { model.commentOnJira(key, text: text) } else { model.commentOnMR(item, text: text) }
            }
        }
        .confirmationDialog("Approve \(ItemPrompts.shared.approve?.subtitle ?? "")?",
                            isPresented: Binding(get: { ItemPrompts.shared.approve != nil }, set: { if !$0 { ItemPrompts.shared.approve = nil } }),
                            presenting: ItemPrompts.shared.approve) { item in
            Button("Approve") { model.approve(item) }
        } message: { item in Text(item.title) }
        .background { SidebarShortcuts() }
        .sheet(item: Bindable(AgentCenter.shared).presented) { p in AgentRunSheet(id: p.id) }
        .environment(\.refLinker, model.refLinker)
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Assistant", systemImage: "waveform").tag(SidebarItem.assistant)
            }
            Section("Work") {
                Label("Inbox", systemImage: "tray").badge(model.unread).tag(SidebarItem.inbox)
                Label(model.changesTitle, systemImage: "arrow.triangle.pull")
                    .badge(model.items.reviewReady.count).tag(SidebarItem.mergeRequests)
                Label("Pipelines", systemImage: "gearshape.2")
                    .badge(model.items.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-86400) }.count)
                    .tag(SidebarItem.pipelines)
                Label("Jira", systemImage: "checklist").badge(model.items.jiraAssigned.count).tag(SidebarItem.jira)
                Label("Work Brief", systemImage: "sun.max").tag(SidebarItem.workBrief)
                Label("Team & Reports", systemImage: "person.3").tag(SidebarItem.reports)
            }
            if !model.config.customSources.isEmpty {
                Section("Feeds") {
                    ForEach(model.config.customSources) { c in
                        Label(c.name, systemImage: c.kind == .folder ? "folder" : "terminal")
                            .badge(model.items.custom[c.id]?.count ?? 0).tag(SidebarItem.feed(c.id))
                    }
                }
            }
            if !model.config.webPanels.isEmpty {
                Section("Web") {
                    ForEach(model.config.webPanels) { p in
                        Label(p.name, systemImage: "globe.desk").tag(SidebarItem.web(p.id))
                    }
                }
            }
            Section("Personal") {
                Label("World & Tech", systemImage: "globe").tag(SidebarItem.worldBrief)
            }
            Section {
                Label("AI Activity", systemImage: "lock.shield").tag(SidebarItem.aiActivity)
                Label("Agent Runs", systemImage: "terminal")
                    .badge(AgentCenter.shared.live.values.filter { $0.record.status == .running }.count).tag(SidebarItem.agentRuns)
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .safeAreaInset(edge: .bottom) { healthFooter }
    }

    private var healthFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.health.keys.sorted(), id: \.self) { key in
                let h = model.health[key]!
                HStack(spacing: 5) {
                    Circle().fill(h.isHealthy ? .green : (h == .idle ? .gray : .orange)).frame(width: 7, height: 7)
                    Text(h.isHealthy ? "\(model.sourceName(key)) · \(h.label)" : h.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder var detail: some View {
        switch model.selection {
        case .home: HomeView()
        case .aiActivity: AIActivityView()
        case .inbox: InboxView()
        case .mergeRequests: MergeRequestsView()
        case .pipelines: PipelinesView()
        case .jira: JiraView()
        case .workBrief: WorkBriefView()
        case .reports: ReportsView()
        case .worldBrief: WorldBriefView()
        case .settings: SettingsView()
        case .agentRuns: AgentRunsView()
        case .assistant: AssistantView()
        case .feed(let id):
            if let source = model.config.customSources.first(where: { $0.id == id }) {
                CustomFeedView(source: source).id(source.id)
            } else {
                EmptyState(icon: "tray", title: "Source removed")
            }
        case .web(let id):
            if let panel = model.config.webPanels.first(where: { $0.id == id }) {
                WebPanelView(panel: panel).id(panel.id)
            } else {
                EmptyState(icon: "globe", title: "Panel removed")
            }
        }
    }
}

// MARK: - Snapshot sidebar

/// `--snapshot` only: an offscreen window is never active, so the real sidebar would render dimmed.
/// This draws the same items the way the active sidebar looks.
private struct SnapshotSidebar<Footer: View>: View {
    private var model: AppModel { .shared }
    let health: Footer

    private struct Row: Identifiable {
        let title: String, icon: String, item: SidebarItem, badge: Int
        var id: String { title }
    }

    private var sections: [(String?, [Row])] {
        let i = model.items
        let failed = i.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-86400) }.count
        return [
            (nil, [Row(title: "Home", icon: "house", item: .home, badge: 0),
                   Row(title: "Assistant", icon: "waveform", item: .assistant, badge: 0)]),
            ("Work", [Row(title: "Inbox", icon: "tray", item: .inbox, badge: model.unread),
                      Row(title: model.changesTitle, icon: "arrow.triangle.pull", item: .mergeRequests, badge: i.reviewReady.count),
                      Row(title: "Pipelines", icon: "gearshape.2", item: .pipelines, badge: failed),
                      Row(title: "Jira", icon: "checklist", item: .jira, badge: i.jiraAssigned.count),
                      Row(title: "Work Brief", icon: "sun.max", item: .workBrief, badge: 0),
                      Row(title: "Team & Reports", icon: "person.3", item: .reports, badge: 0)]),
            ("Feeds", model.config.customSources.map { c in
                Row(title: c.name, icon: c.kind == .folder ? "folder" : "terminal", item: .feed(c.id), badge: i.custom[c.id]?.count ?? 0)
            }),
            ("Personal", [Row(title: "World & Tech", icon: "globe", item: .worldBrief, badge: 0)]),
            (nil, [Row(title: "AI Activity", icon: "lock.shield", item: .aiActivity, badge: 0),
                   Row(title: "Agent Runs", icon: "terminal", item: .agentRuns, badge: 0),
                   Row(title: "Settings", icon: "gearshape", item: .settings, badge: 0)]),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 2) {
                    if let header = section.0 {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.bottom, 2)
                    }
                    ForEach(section.1) { row in
                        let selected = model.selection == row.item
                        HStack(spacing: 8) {
                            Image(systemName: row.icon).foregroundStyle(Color.accentColor)
                                .frame(width: 20, alignment: .center)
                            Text(row.title).foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            if row.badge > 0 { Text("\(row.badge)").font(.callout).foregroundStyle(.secondary) }
                        }
                        .font(.body)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(.bottom, 14)
            }
            Spacer()
            health
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
}

// MARK: - Inbox

struct InboxView: View {
    private var model: AppModel { .shared }
    @State private var unreadOnly = false
    @State private var filter: String = "all"
    @State private var search = ""
    @State private var selection: String?

    var filtered: [AppEvent] {
        model.events.filter { e in
            (!unreadOnly || !e.read) && (filter == "all" || e.category.source == filter)
                && (search.isEmpty || "\(e.title) \(e.body)".localizedCaseInsensitiveContains(search))
        }
    }

    var selectedEvent: AppEvent? { selection.flatMap { id in model.events.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag("all")
                    Text("Code").tag("code")
                    Text("Jira").tag("jira")
                    Text("News").tag("news")
                    Text("Briefs").tag("brief")
                    if !model.config.customSources.isEmpty { Text("Feeds").tag("custom") }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.checkbox)
                Spacer()
                ListSearchField(text: $search)
                Button("Mark all read") { model.markAllRead() }.disabled(model.unread == 0)
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                EmptyState(icon: "tray", title: "Inbox zero",
                           message: "Pipeline failures, reportee MRs, review requests, Jira changes and major news land here.")
            } else {
                List(selection: $selection) {
                    ForEach(groupedByDay, id: \.0) { day, events in
                        Section(day) {
                            ForEach(events) { e in
                                EventRow(event: e).tag(e.id)
                            }
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let e = model.events.first(where: { $0.id == id }) { menu(for: e) }
        } primaryAction: { ids in
            if let id = ids.first, let e = model.events.first(where: { $0.id == id }) { model.open(e) }
        }
        .inspector(isPresented: Binding(get: { selectedEvent != nil }, set: { if !$0 { selection = nil } })) {
            if let e = selectedEvent {
                if let item = model.item(withId: e.itemId) {
                    ItemInspector(item: item) { selection = nil }
                } else {
                    EventInspector(event: e) { selection = nil }
                }
            }
        }
        .onChange(of: selection) {
            if let e = selectedEvent, !e.read { model.markRead([e.id]) }
        }
        .navigationTitle("Inbox")
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
        if e.category == .reporteeNewMR || e.category == .todoReview, let item = model.item(withId: e.itemId) {
            Button("Summarize with AI") { model.summarize(item) }
        }
        if let key = Notifier.jiraKey(in: e), e.category.source == "jira" {
            Button("AI digest of \(key)") { model.digest(jiraKey: key, url: e.url) }
        }
        if let item = model.item(withId: e.itemId) { AgentActionItems(item: item) }
        Divider()
        if let itemId = e.itemId {
            if model.config.isMuted(itemId) {
                Button("Unmute this item") { model.unmute(itemId: itemId) }
            } else {
                Button("Snooze this item for a day") { model.mute(itemId: itemId, for: 86400) }
                Button("Mute this item") { model.mute(itemId: itemId, for: nil) }
            }
        }
        Button("Turn off “\(e.category.label)” notifications") {
            model.updateConfig { $0.notifications[e.category.rawValue] = false }
        }
    }
}

/// Inspector for events with no live item behind them (news, briefs, items that have since closed).
struct EventInspector: View {
    private var model: AppModel { .shared }
    let event: AppEvent
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(event.category.label, systemImage: "bell").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(event.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text(event.body).textSelection(.enabled)
            Text(event.ts.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            if event.url != nil {
                Button { model.open(event) } label: { Label("Open", systemImage: "safari") }
            }
            Spacer()
        }
        .padding(14)
        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
    }
}

/// ⌘1–⌘9 jump between the main screens.
struct SidebarShortcuts: View {
    private var model: AppModel { .shared }
    static let order: [SidebarItem] = [.home, .inbox, .mergeRequests, .pipelines, .jira, .workBrief, .reports, .assistant, .agentRuns]

    var body: some View {
        ZStack {
            ForEach(Array(Self.order.enumerated()), id: \.offset) { i, item in
                Button("") { model.selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { model.selection = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}
