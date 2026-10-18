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
                                    .help("Refresh every account now")
                            }
                        }
                }
            }
        }
        .sheet(item: $model.aiPanel) { panel in
            AIPanelSheet(panel: panel).environment(model).environment(\.refLinker, model.refLinker)
        }
        .environment(\.refLinker, model.refLinker)
    }

    private var sidebar: some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
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
            (nil, [Row(title: "Home", icon: "house", item: .home, badge: 0)]),
            ("Work", [Row(title: "Inbox", icon: "tray", item: .inbox, badge: model.unread),
                      Row(title: model.changesTitle, icon: "arrow.triangle.pull", item: .mergeRequests, badge: i.reviewReady.count),
                      Row(title: "Pipelines", icon: "gearshape.2", item: .pipelines, badge: failed),
                      Row(title: "Jira", icon: "checklist", item: .jira, badge: i.jiraAssigned.count),
                      Row(title: "Work Brief", icon: "sun.max", item: .workBrief, badge: 0),
                      Row(title: "Team & Reports", icon: "person.3", item: .reports, badge: 0)]),
            ("Personal", [Row(title: "World & Tech", icon: "globe", item: .worldBrief, badge: 0)]),
            (nil, [Row(title: "AI Activity", icon: "lock.shield", item: .aiActivity, badge: 0),
                   Row(title: "Settings", icon: "gearshape", item: .settings, badge: 0)]),
        ]
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

    var filtered: [AppEvent] {
        model.events.filter { e in
            (!unreadOnly || !e.read) && (filter == "all" || e.category.source == filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag("all")
                    Text("Code").tag("code")
                    Text("Jira").tag("jira")
                    Text("News").tag("news")
                    Text("Briefs").tag("brief")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.checkbox)
                Spacer()
                Button("Mark all read") { model.markAllRead() }.disabled(model.unread == 0)
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                EmptyState(icon: "tray", title: "Inbox zero",
                           message: "Pipeline failures, reportee MRs, review requests, Jira changes and major news land here.")
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, events in
                        Section(day) {
                            ForEach(events) { e in
                                EventRow(event: e)
                                    .onTapGesture { model.open(e) }
                                    .contextMenu { menu(for: e) }
                            }
                        }
                    }
                }
            }
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
