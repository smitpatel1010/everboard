import EverboardCore
import SwiftUI

struct DashboardView: View {
    private var model: AppModel { .shared }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
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
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
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
        .sheet(item: $model.aiPanel) { panel in
            AIPanelSheet(panel: panel).environment(model).environment(\.refLinker, model.refLinker)
        }
        .environment(\.refLinker, model.refLinker)
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
