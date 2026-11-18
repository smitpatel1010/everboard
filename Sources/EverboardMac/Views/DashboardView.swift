import AppKit
import EverboardCore
import SwiftUI

/// The dashboard window: a custom sidebar, the selected page, and a peek panel for whatever is selected.
struct DashboardView: View {
    private var model: AppModel { .shared }
    private var peek: Peek { .shared }
    @AppStorage("sidebarCollapsed") private var collapsed = false

    /// Below this window width the sidebar shows icons only.
    static let compactWidth: CGFloat = 980
    /// The page keeps at least this much room beside the peek panel; otherwise the panel floats over it.
    static let minPageWidth: CGFloat = 520

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let narrow = geo.size.width < Self.compactWidth
            let sidebarCollapsed = collapsed || narrow
            let sidebarWidth: CGFloat = sidebarCollapsed ? 60 : 228
            let peekOpen = peek.item != nil || peek.event != nil
            let peekWidth = min(380, geo.size.width * 0.6)
            let floatPeek = geo.size.width - sidebarWidth - peekWidth < Self.minPageWidth
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    Sidebar(collapsed: Binding(get: { sidebarCollapsed }, set: { collapsed = $0 }))
                        .frame(width: sidebarWidth)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    detail
                        .padding(.top, 22)
                        // Pages never set the window's minimum width; they adapt to whatever is left.
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(Theme.canvas)
                    if peekOpen && !floatPeek {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        PeekPanel()
                            .frame(width: peekWidth)
                            .background(Theme.surface)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if peekOpen && floatPeek {
                    PeekPanel()
                        .frame(width: peekWidth)
                        .frame(maxHeight: .infinity)
                        .background(Theme.surface)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                        .shadow(color: .black.opacity(0.18), radius: 18, x: -4)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .onChange(of: model.selection) {
            peek.close()
            AssistantModel.shared.stopSpeaking()
        }
        .sheet(item: $model.aiPanel) { panel in
            AIPanelSheet(panel: panel).environment(model).environment(\.refLinker, model.refLinker)
        }
        .sheet(item: Bindable(AgentCenter.shared).pending) { plan in AgentConfirmSheet(plan: plan) }
        .sheet(item: Bindable(AgentCenter.shared).presented) { p in AgentRunSheet(id: p.id) }
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
        .background { SidebarShortcuts(collapsed: $collapsed) }
        .environment(\.refLinker, model.refLinker)
    }

    @ViewBuilder var detail: some View {
        switch model.selection {
        case .home: HomeView()
        case .assistant: AssistantView()
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
        case .feed(let id):
            if let source = model.config.customSources.first(where: { $0.id == id }) {
                CustomFeedView(source: source).id(source.id)
            } else {
                EmptyHint(icon: "tray", title: "Source removed")
            }
        case .web(let id):
            if let panel = model.config.webPanels.first(where: { $0.id == id }) {
                WebPanelView(panel: panel).id(panel.id)
            } else {
                EmptyHint(icon: "globe", title: "Panel removed")
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    private var model: AppModel { .shared }
    @Binding var collapsed: Bool

    struct Entry: Identifiable {
        let item: SidebarItem
        let title: String
        let icon: String
        var badge: Int = 0
        var urgent = false
        var id: String { "\(title)|\(item)" }
    }

    var sections: [(String?, [Entry])] {
        let i = model.items
        let failed = i.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-86400) }.count
        let running = AgentCenter.shared.live.values.filter { $0.record.status == .running }.count
        var out: [(String?, [Entry])] = [
            (nil, [Entry(item: .home, title: "Home", icon: "square.grid.2x2"),
                   Entry(item: .inbox, title: "Inbox", icon: "tray", badge: model.unread),
                   Entry(item: .assistant, title: "Assistant", icon: "waveform")]),
            ("Work", [Entry(item: .mergeRequests, title: model.changesTitle, icon: "arrow.triangle.pull", badge: i.reviewReady.count),
                      Entry(item: .pipelines, title: "Pipelines", icon: "bolt.horizontal", badge: failed, urgent: failed > 0),
                      Entry(item: .jira, title: "Jira", icon: "checklist", badge: i.jiraAssigned.count),
                      Entry(item: .workBrief, title: "Work brief", icon: "sun.max")]),
            ("Team", [Entry(item: .reports, title: "Team & reports", icon: "person.2")]),
        ]
        if !model.config.customSources.isEmpty {
            out.append(("Feeds", model.config.customSources.map {
                Entry(item: .feed($0.id), title: $0.name, icon: $0.kind == .folder ? "folder" : "terminal", badge: i.custom[$0.id]?.count ?? 0)
            }))
        }
        out.append(("Personal", [Entry(item: .worldBrief, title: "World & Tech", icon: "globe")]
            + model.config.webPanels.map { Entry(item: .web($0.id), title: $0.name, icon: "globe.desk") }))
        out.append(("Agents", [Entry(item: .agentRuns, title: "Agent runs", icon: "terminal", badge: running),
                               Entry(item: .aiActivity, title: "AI activity", icon: "lock.shield")]))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 34)
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = section.0, !collapsed {
                                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10).padding(.bottom, 3)
                            }
                            ForEach(section.1) { SidebarRow(entry: $0, collapsed: collapsed) }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Spacer(minLength: 0)
            footer
        }
        .background(Theme.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                if !collapsed {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(AppInfo.name).font(.system(size: 13, weight: .semibold))
                        if let name = model.myName { Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Refresh everything (⌘R)")
                }
            }
            if collapsed {
                Button { listenHere() } label: { Image(systemName: "mic.fill") }
                    .buttonStyle(.borderless).frame(maxWidth: .infinity).help("Talk to your agents (⌥⇧Space)")
            } else {
                HStack(spacing: 6) {
                    Button { CommandPalette.shared.show() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Search").foregroundStyle(.secondary)
                            Spacer()
                            Text("⌥Space").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { listenHere() } label: {
                        Image(systemName: VoiceInput.shared.isListening ? "waveform" : "mic.fill").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 28, height: 28)
                            .background(Circle().fill(VoiceInput.shared.isListening ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accentGradient)))
                    }
                    .buttonStyle(.plain).help("Talk to your agents (⌥⇧Space)")
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }

    /// Inside the dashboard, talking happens on the Assistant page rather than in the floating panel.
    private func listenHere() {
        model.selection = .assistant
        AssistantModel.shared.toggleListening()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarRow(entry: Entry(item: .settings, title: "Settings", icon: "gearshape"), collapsed: collapsed)
            HStack(spacing: 8) {
                if !collapsed {
                    ForEach(model.health.keys.sorted(), id: \.self) { key in
                        let h = model.health[key]!
                        HStack(spacing: 4) {
                            Circle().fill(HealthChips.color(h)).frame(width: 6, height: 6)
                            Text(model.sourceName(key)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help("\(model.sourceName(key)): \(h.label)")
                    }
                }
                Spacer(minLength: 0)
                Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).help("Collapse the sidebar (⌘\\)")
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
    }
}

struct SidebarRow: View {
    private var model: AppModel { .shared }
    let entry: Sidebar.Entry
    let collapsed: Bool
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == entry.item
        Button { model.selection = entry.item } label: {
            HStack(spacing: 9) {
                Image(systemName: entry.icon).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary).frame(width: 18)
                if !collapsed {
                    Text(entry.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.badge > 0 {
                        Text("\(entry.badge)").font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(entry.urgent ? Color.white : Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(entry.urgent ? Color.red : Color.primary.opacity(0.07)))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
            .overlay(alignment: .topTrailing) {
                if collapsed && entry.badge > 0 { Circle().fill(entry.urgent ? Color.red : Theme.accent).frame(width: 6, height: 6).padding(4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? entry.title : "")
    }
}

// MARK: - Peek panel

private struct PeekPanel: View {
    private var peek: Peek { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 22)
            if let item = peek.item {
                ItemInspector(item: item) { peek.close() }.id(item.id)
            } else if let event = peek.event {
                EventInspector(event: event) { peek.close() }
            }
        }
    }
}

/// Peek content for events with no live item behind them (news, briefs, items that have since closed).
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
                Button { model.open(event) } label: { Label("Open", systemImage: "arrow.up.right") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Spacer()
        }
        .padding(16)
    }
}

/// ⌘1–⌘9 jump between screens, ⌘, opens Settings, ⌘\ collapses the sidebar, ⌘R refreshes.
struct SidebarShortcuts: View {
    private var model: AppModel { .shared }
    @Binding var collapsed: Bool
    static let order: [SidebarItem] = [.home, .inbox, .assistant, .mergeRequests, .pipelines, .jira, .workBrief, .reports, .agentRuns]

    var body: some View {
        ZStack {
            ForEach(Array(Self.order.enumerated()), id: \.offset) { i, item in
                Button("") { model.selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { model.selection = .settings }.keyboardShortcut(",", modifiers: .command)
            Button("") { withAnimation(.snappy) { collapsed.toggle() } }.keyboardShortcut("\\", modifiers: .command)
            Button("") { model.refreshAll() }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}
