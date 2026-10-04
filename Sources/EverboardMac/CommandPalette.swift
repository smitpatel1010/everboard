import AppKit
import Carbon.HIToolbox
import EverboardCore
import SwiftUI

/// Raycast-style palette on a global hotkey (⌥Space). Carbon hotkeys need no Accessibility permission.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private weak var model: AppModel?

    func register(model: AppModel) {
        self.model = model
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { CommandPalette.shared.toggle() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4556_4244), id: 1) // "EVBD"
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.info(status == noErr ? "palette hotkey ⌥Space registered" : "palette hotkey failed (\(status)) — ⌥Space may be taken")
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        guard let model else { return }
        if panel == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.delegate = self
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: PaletteView(close: { [weak self] in self?.close() }).environment(model))
        panel?.center()
        if let f = panel?.frame, let screen = NSScreen.main?.visibleFrame {
            panel?.setFrameOrigin(NSPoint(x: screen.midX - f.width / 2, y: screen.maxY - f.height - screen.height * 0.18))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Borderless/non-activating panels can't become key by default, which would block typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Palette UI

struct PaletteEntry: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    /// Lower = more important when scores tie.
    let rank: Int
    let action: @MainActor () -> Void
    let secondary: (@MainActor () -> Void)?
    let secondaryLabel: String?
}

struct PaletteView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var results: [PaletteEntry] {
        let all = entries
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(all.sorted { $0.rank < $1.rank }.prefix(40)) }
        return all.compactMap { e -> (PaletteEntry, Int)? in
            guard let s = Fuzzy.score(q, "\(e.title) \(e.subtitle) \(e.badge ?? "")") else { return nil }
            return (e, s - e.rank)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40)
        .map(\.0)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.title3)
                TextField("Search MRs, Jira, pipelines, news, commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(items, secondary: NSEvent.modifierFlags.contains(.command)) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.element.id) { i, e in
                    HStack(spacing: 10) {
                        Image(systemName: e.icon).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).lineLimit(1)
                            Text(e.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let b = e.badge { StatusPill(text: b) }
                        if i == selected, let label = e.secondaryLabel {
                            Text("⌘↩ \(label)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(i == selected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = i; run(items, secondary: false) }
                    .id(i)
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, s in proxy.scrollTo(s) }
            }
            HStack {
                Text("↑↓ move · ↩ open · ⌘↩ AI action · esc close").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("⌥Space").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial)
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    func run(_ items: [PaletteEntry], secondary: Bool) {
        guard items.indices.contains(selected) else { return }
        let e = items[selected]
        close()
        if secondary, let s = e.secondary { s() } else { e.action() }
    }

    var entries: [PaletteEntry] {
        var out: [PaletteEntry] = []
        let m = model
        func cmd(_ id: String, _ icon: String, _ title: String, _ sub: String, _ action: @escaping @MainActor () -> Void) {
            out.append(PaletteEntry(id: "cmd." + id, icon: icon, title: title, subtitle: sub, badge: "command", rank: 50,
                                    action: action, secondary: nil, secondaryLabel: nil))
        }
        cmd("dash", "rectangle.grid.2x2", "Open dashboard", "Inbox") { m.showDashboard(.inbox) }
        cmd("refresh", "arrow.clockwise", "Refresh now", "Poll GitLab and Jira") { m.refreshAll() }
        cmd("brief", "sun.max", "Generate work brief", "Claude") { m.showDashboard(.workBrief); m.generateWorkBrief() }
        cmd("news", "globe", "Refresh World & Tech brief", "Claude") { m.showDashboard(.worldBrief); m.generateNewsBrief() }
        cmd("standup", "text.badge.checkmark", "Write my standup", "Claude") { m.showDashboard(.reports); m.reportsTab = "standup"; m.generateStandup() }
        cmd("weekly", "doc.text", "Write weekly report", "Claude") { m.showDashboard(.reports); m.reportsTab = "weekly"; m.generateWeekly() }
        cmd("team", "person.3", "Team health", "Metrics for your reportees") { m.showDashboard(.reports); m.reportsTab = "team" }
        cmd("readall", "checkmark.circle", "Mark all read", "Inbox") { m.markAllRead() }
        cmd("settings", "gearshape", "Settings", "") { m.showDashboard(.settings) }

        let mrs = m.items.review + m.items.mine + m.items.assigned + m.items.reportees
        var seen = Set<String>()
        for i in mrs where seen.insert(i.id).inserted {
            out.append(PaletteEntry(id: i.id, icon: "arrow.triangle.pull", title: i.title,
                                    subtitle: "\(i.subtitle) · \(i["authorName"] ?? "")", badge: i["pipelineStatus"],
                                    rank: i.kind == "mr.review" ? 0 : 10, action: { m.open(i.url) },
                                    secondary: { m.summarize(i) }, secondaryLabel: "Summarize"))
        }
        for i in m.items.jiraAssigned + m.items.jiraFilters.values.flatMap({ $0 }) where seen.insert(i.id).inserted {
            let key = i["key"] ?? ""
            out.append(PaletteEntry(id: i.id, icon: "checklist", title: "\(key) \(i.title)", subtitle: i["assignee"] ?? "unassigned",
                                    badge: i.status, rank: i.kind == "issue.assigned" ? 5 : 20, action: { m.open(i.url) },
                                    secondary: { m.digest(jiraKey: key, title: i.title, url: i.url) }, secondaryLabel: "Digest"))
        }
        for i in m.items.pipelines.prefix(30) {
            out.append(PaletteEntry(id: i.id, icon: "gearshape.2", title: i.title, subtitle: i.subtitle, badge: i.status,
                                    rank: i.status == "failed" ? 8 : 30, action: { m.open(i.url) }, secondary: nil, secondaryLabel: nil))
        }
        for e in m.events.prefix(60) where !e.read {
            out.append(PaletteEntry(id: "evt." + e.id, icon: "tray", title: e.title, subtitle: e.body.replacingOccurrences(of: "\n", with: " · "),
                                    badge: nil, rank: 3, action: { m.open(e) }, secondary: nil, secondaryLabel: nil))
        }
        for s in m.newsBrief?.sections.flatMap({ $0.stories }) ?? [] {
            out.append(PaletteEntry(id: s.key, icon: "globe", title: s.title, subtitle: s.summary, badge: nil, rank: 40,
                                    action: { m.open(s.urls.first) }, secondary: { m.showDashboard(.worldBrief); m.goDeeper(s) },
                                    secondaryLabel: "Go deeper"))
        }
        for a in m.latestArticles.prefix(150) {
            out.append(PaletteEntry(id: "art." + a.id, icon: "newspaper", title: a.title, subtitle: a.source, badge: nil, rank: 60,
                                    action: { m.open(a.url) }, secondary: nil, secondaryLabel: nil))
        }
        return out
    }
}

/// Subsequence fuzzy match with bonuses for word starts and contiguous runs. nil = no match.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        if text.lowercased().contains(query.lowercased()) { return 1000 - t.count / 4 }
        var qi = 0, score = 0, run = 0, prev: Character = " "
        for c in t {
            if qi < q.count, c == q[qi] {
                score += 10 + run * 5 + (prev == " " || prev == "/" || prev == "-" ? 15 : 0)
                run += 1
                qi += 1
            } else {
                run = 0
            }
            prev = c
        }
        return qi == q.count ? score : nil
    }
}
