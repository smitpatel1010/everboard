import AppKit
import Carbon.HIToolbox
import EverboardCore
import SwiftUI

/// Spotlight/Raycast-style palette on a global hotkey (⌥Space).
/// It's a non-activating panel: it floats over whatever app you're in without switching to Everboard.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate {
    static let shared = CommandPalette()

    private var panel: PalettePanel?
    private var hotKeyRef: EventHotKeyRef?
    private var keyMonitor: Any?
    private weak var model: AppModel?
    private var state: PaletteState?

    // MARK: Hotkey

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

    // MARK: Show / hide

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let state = PaletteState(model: model, close: { [weak self] in self?.close() })
        self.state = state
        let host = NSHostingView(rootView: PaletteView(state: state))
        host.wantsLayer = true
        panel.contentView = host
        panel.setContentSize(NSSize(width: PaletteView.width, height: PaletteView.height))
        // Centre horizontally, upper third, on the screen the mouse is on (like Spotlight).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - PaletteView.width / 2, y: f.maxY - PaletteView.height - f.height * 0.16))
        }
        // No NSApp.activate: the frontmost app stays frontmost; the panel just takes keyboard focus.
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        state = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses it — unless a confirmation alert we opened took focus.
        if NSApp.modalWindow == nil { close() }
    }

    private func makePanel() -> PalettePanel {
        let p = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: PaletteView.width, height: PaletteView.height),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        return p
    }

    /// Arrow keys, Return, Tab, Esc and ⌘ shortcuts are handled here so they work while the text field has focus.
    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow, let state = self.state else { return event }
            return state.handle(event) ? nil : event
        }
    }
}

/// Borderless non-activating panels refuse key status by default, which would block typing.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Model

enum PaletteScope: String, CaseIterable, Identifiable {
    case all, commands, mrs, jira, pipelines, inbox, news, meetings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .commands: return "Commands"
        case .mrs: return "MRs"
        case .jira: return "Jira"
        case .pipelines: return "Pipelines"
        case .inbox: return "Inbox"
        case .news: return "News"
        case .meetings: return "Meetings"
        }
    }

    /// Typing this prefix + space (or ">" alone) switches scope.
    var prefix: String {
        switch self {
        case .all: return ""
        case .commands: return ">"
        case .mrs: return "mr"
        case .jira: return "jira"
        case .pipelines: return "pl"
        case .inbox: return "in"
        case .news: return "news"
        case .meetings: return "cal"
        }
    }

    var groups: Set<PaletteGroup> {
        switch self {
        case .all: return Set(PaletteGroup.allCases)
        case .commands: return [.commands]
        case .mrs: return [.review, .myMRs, .reportees, .todos, .remoteGitLab, .fallback]
        case .jira: return [.jira, .remoteJira, .fallback]
        case .pipelines: return [.pipelines]
        case .inbox: return [.inbox]
        case .news: return [.stories, .articles, .fallback]
        case .meetings: return [.meetings]
        }
    }
}

enum PaletteGroup: Int, CaseIterable, Comparable {
    case direct, attention, recent, meetings, review, myMRs, reportees, todos, jira, pipelines, inbox, commands,
         stories, articles, remoteGitLab, remoteJira, fallback

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .direct: return "Go to"
        case .attention: return "Needs attention"
        case .recent: return "Recent"
        case .meetings: return "Today's meetings"
        case .review: return "Review requested"
        case .myMRs: return "My merge requests"
        case .reportees: return "Team merge requests"
        case .todos: return "GitLab to-dos"
        case .jira: return "Jira"
        case .pipelines: return "Pipelines"
        case .inbox: return "Inbox"
        case .commands: return "Commands"
        case .stories: return "Today's brief"
        case .articles: return "Live news"
        case .remoteGitLab: return "GitLab search"
        case .remoteJira: return "Jira search"
        case .fallback: return "More"
        }
    }
}

struct PaletteAction: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    var shortcut: String?
    var destructive = false
    /// Ask before running (approve, etc.).
    var confirm: String?
    let run: @MainActor () -> Void
}

struct PaletteEntry: Identifiable {
    let id: String
    var group: PaletteGroup
    let icon: String
    var tint: Color = .secondary
    let title: String
    var subtitle: String = ""
    var badge: String?
    var date: Date?
    var details: [(String, String)] = []
    var preview: String?
    var url: String?
    var jiraKey: String?
    var actions: [PaletteAction]
    /// Extra text that should match searches but isn't displayed (keys, people, projects).
    var keywords: String = ""
    var boost = 0

    var searchText: String { "\(title) \(subtitle) \(badge ?? "") \(keywords)" }
}

struct PaletteSection: Identifiable {
    let group: PaletteGroup
    var entries: [(entry: PaletteEntry, match: Set<Int>)]
    var id: Int { group.rawValue }
}

@MainActor @Observable
final class PaletteState {
    let model: AppModel
    let close: () -> Void

    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    var chipScope: PaletteScope = .all
    var selection = 0
    var actionsOpen = false
    var actionSelection = 0
    var extraActions: [PaletteAction] = []
    var remote: [PaletteEntry] = []
    var remoteLoading = false
    var pendingConfirm: PaletteAction?

    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var cachedEntries: [PaletteEntry]?

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    // MARK: Query parsing

    /// Scope from a typed prefix ("jira foo", ">refresh") wins over the chip.
    var parsed: (scope: PaletteScope, text: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(">") { return (.commands, String(q.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        if let space = q.firstIndex(of: " ") {
            let head = q[..<space].lowercased()
            if let s = PaletteScope.allCases.first(where: { $0 != .all && $0 != .commands && $0.prefix == head }) {
                return (s, String(q[space...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (chipScope, q)
    }

    var scope: PaletteScope { parsed.scope }

    private func queryChanged() {
        selection = 0
        actionsOpen = false
        scheduleRemoteSearch()
    }

    func setScope(_ s: PaletteScope) {
        chipScope = s
        if parsed.scope != s, let space = query.firstIndex(of: " "),
           PaletteScope.allCases.contains(where: { $0.prefix == query[..<space].lowercased() }) {
            query = String(query[space...]).trimmingCharacters(in: .whitespaces)
        }
        selection = 0
        scheduleRemoteSearch()
    }

    // MARK: Results

    /// Item entries are built once per opening; query-dependent ones (direct jumps, fallbacks) every time.
    var entries: [PaletteEntry] {
        let builder = PaletteBuilder(model: model, state: self)
        let items = cachedEntries ?? builder.build()
        cachedEntries = items
        return builder.direct() + items + builder.fallbacks()
    }

    var sections: [PaletteSection] {
        let (scope, text) = parsed
        let allowed = scope.groups
        var pool = entries.filter { allowed.contains($0.group) }
        pool += remote.filter { allowed.contains($0.group) }
        var out: [PaletteSection] = []

        if text.isEmpty {
            // Empty query: what needs attention, then recents, meetings and commands.
            if scope == .all {
                let attention = PaletteBuilder(model: model, state: self).attention(from: entries)
                if !attention.isEmpty { out.append(PaletteSection(group: .attention, entries: attention.map { ($0, []) })) }
                let recentIDs = Self.recents
                let recent = recentIDs.compactMap { id in entries.first { $0.id == id } }.prefix(5)
                    .map { e -> PaletteEntry in var r = e; r.group = .recent; return r }
                if !recent.isEmpty { out.append(PaletteSection(group: .recent, entries: recent.map { ($0, []) })) }
                pool = pool.filter { [.meetings, .commands].contains($0.group) }
            }
            for (group, items) in Dictionary(grouping: pool, by: \.group).sorted(by: { $0.key < $1.key }) where group != .fallback {
                out.append(PaletteSection(group: group, entries: items.sorted { $0.boost > $1.boost }.prefix(scope == .all ? 8 : 60).map { ($0, []) }))
            }
            return dedupe(out)
        }

        var scored: [(PaletteEntry, Int, Set<Int>)] = []
        for e in pool {
            if e.group == .direct || e.group == .fallback { scored.append((e, 0, [])); continue }
            guard let m = Fuzzy.match(text, e.title) ?? Fuzzy.match(text, e.searchText).map({ (score: $0.score - 40, indices: Set<Int>()) }) else { continue }
            scored.append((e, m.score + e.boost + Self.recentBoost(e.id), m.indices))
        }
        let perGroup = Dictionary(grouping: scored, by: { $0.0.group })
        let limit = scope == .all ? 6 : 60
        // Direct jumps pinned first, fallbacks last, other groups by their best match.
        func rank(_ g: PaletteGroup) -> Int {
            switch g {
            case .direct: return .max
            case .fallback: return .min
            default: return perGroup[g]?.map(\.1).max() ?? 0
            }
        }
        let ordered = perGroup.keys.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0 < $1 }
        for g in ordered {
            let items = perGroup[g]!.sorted { $0.1 > $1.1 }.prefix(g == .fallback ? 5 : limit)
            out.append(PaletteSection(group: g, entries: items.map { ($0.0, $0.2) }))
        }
        return dedupe(out)
    }

    /// The same MR can appear as "review" and "recent"; keep the first.
    private func dedupe(_ sections: [PaletteSection]) -> [PaletteSection] {
        var seen = Set<String>()
        return sections.compactMap { s in
            var s = s
            s.entries = s.entries.filter { seen.insert($0.entry.id).inserted }
            return s.entries.isEmpty ? nil : s
        }
    }

    var flat: [PaletteEntry] { sections.flatMap { $0.entries.map(\.entry) } }

    var selected: PaletteEntry? {
        let f = flat
        return f.indices.contains(selection) ? f[selection] : f.first
    }

    var selectedActions: [PaletteAction] { (selected?.actions ?? []) + extraActions }

    // MARK: Remote search (GitLab + Jira), debounced

    private func scheduleRemoteSearch() {
        remoteTask?.cancel()
        remote = []
        let (scope, text) = parsed
        guard text.count >= 3, [.all, .mrs, .jira].contains(scope) else { remoteLoading = false; return }
        remoteLoading = true
        let secrets = model.secrets
        remoteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            async let mrs: [GitLabMR] = (scope == .jira ? [] : (try? await GitLabClient(secrets: secrets)?.searchMergeRequests(text))) ?? []
            async let issues: [JiraIssue] = (scope == .mrs ? [] : (try? await JiraClient(secrets: secrets)?.quickSearch(text))) ?? []
            let (m, i) = await (mrs, issues)
            guard !Task.isCancelled else { return }
            let builder = PaletteBuilder(model: self.model, state: self)
            let local = Set(self.entries.map(\.id))
            self.remote = (m.map(builder.remoteMR) + i.map(builder.remoteIssue)).filter { !local.contains($0.id) }
            self.remoteLoading = false
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was handled.
    func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case kVK_DownArrow: move(1); return true
        case kVK_UpArrow: move(-1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if actionsOpen { runAction(at: actionSelection) } else { runAction(at: cmd ? 1 : 0) }
            return true
        case kVK_Tab:
            let all = PaletteScope.allCases
            let i = all.firstIndex(of: scope) ?? 0
            setScope(all[(i + (shift ? all.count - 1 : 1)) % all.count])
            return true
        case kVK_Escape:
            if actionsOpen { actionsOpen = false }
            else if !query.isEmpty { query = "" }
            else if chipScope != .all { chipScope = .all }
            else { close() }
            return true
        case kVK_ANSI_K where cmd:
            toggleActions()
            return true
        case kVK_ANSI_C where cmd && shift:
            if let url = selected?.url { model.copyToClipboard(url) }
            return true
        case kVK_ANSI_1...kVK_ANSI_9 where cmd:
            // ⌘1…⌘9 pick a scope chip.
            let n = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
                .firstIndex(of: Int(e.keyCode)) ?? 0
            if PaletteScope.allCases.indices.contains(n) { setScope(PaletteScope.allCases[n]) }
            return true
        default:
            return false
        }
    }

    private func move(_ d: Int) {
        if actionsOpen {
            let n = selectedActions.count
            guard n > 0 else { return }
            actionSelection = (actionSelection + d + n) % n
        } else {
            let n = flat.count
            guard n > 0 else { return }
            selection = max(0, min(n - 1, selection + d))
            extraActions = []
        }
    }

    func toggleActions() {
        guard selected != nil else { return }
        actionsOpen.toggle()
        actionSelection = 0
        if actionsOpen, let key = selected?.jiraKey {
            Task {
                let transitions = await model.jiraTransitions(key)
                extraActions = transitions.map { t in
                    PaletteAction(title: "Move to \(t.to?.name ?? t.name)", icon: "arrow.right.circle") { [model] in model.transition(key, to: t) }
                }
            }
        }
    }

    func runAction(at index: Int) {
        let actions = selectedActions
        guard let entry = selected, actions.indices.contains(index) else { return }
        let action = actions[index]
        Self.remember(entry.id)
        if let question = action.confirm {
            let alert = NSAlert()
            alert.messageText = question
            alert.informativeText = entry.title
            alert.addButton(withTitle: action.title)
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close()
        action.run()
    }

    func click(_ entry: PaletteEntry) {
        if let i = flat.firstIndex(where: { $0.id == entry.id }) { selection = i }
        runAction(at: 0)
    }

    // MARK: Recents (persisted)

    static var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: "palette.recents") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(20)), forKey: "palette.recents") }
    }

    static func remember(_ id: String) {
        recents = [id] + recents.filter { $0 != id }
    }

    static func recentBoost(_ id: String) -> Int {
        guard let i = recents.firstIndex(of: id) else { return 0 }
        return 60 - i * 3
    }
}

// MARK: - Building entries from app state

@MainActor
struct PaletteBuilder {
    let model: AppModel
    let state: PaletteState

    func build() -> [PaletteEntry] {
        var out: [PaletteEntry] = commands()
        out += model.calendar.today.filter { $0.end > Date() }.map(meeting)
        out += model.items.review.map { mr($0, .review) }
        out += (model.items.mine + model.items.assigned).map { mr($0, .myMRs) }
        out += model.items.reportees.map { mr($0, .reportees) }
        out += model.items.todos.map(todo)
        var seenIssue = Set<String>()
        for i in model.items.jiraAssigned + model.items.jiraFilters.values.flatMap({ $0 }) where seenIssue.insert(i.id).inserted {
            out.append(issue(i))
        }
        out += model.items.pipelines.prefix(60).map(pipeline)
        out += model.events.prefix(80).map(event)
        out += (model.newsBrief?.sections.flatMap { s in s.stories.map { (s.name, $0) } } ?? []).map(story)
        out += model.latestArticles.prefix(200).map(article)
        return out
    }

    func attention(from all: [PaletteEntry]) -> [PaletteEntry] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let ids = Set(model.items.review.map(\.id)
            + model.items.mine.filter { $0["pipelineStatus"] == "failed" }.map(\.id)
            + model.items.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > dayAgo }.map(\.id)
            + model.events.filter { !$0.read }.prefix(4).map { "evt." + $0.id })
        return all.filter { ids.contains($0.id) }.prefix(8).map { var e = $0; e.group = .attention; return e }
    }

    // MARK: Item kinds

    private func link(_ url: String?) -> [PaletteAction] {
        guard let url else { return [] }
        return [PaletteAction(title: "Copy link", icon: "link", shortcut: "⇧⌘C") { model.copyToClipboard(url) }]
    }

    func mr(_ i: FeedItem, _ group: PaletteGroup) -> PaletteEntry {
        var actions = [
            PaletteAction(title: "Open in browser", icon: "safari", shortcut: "↩") { model.open(i.url) },
            PaletteAction(title: "Summarize with AI", icon: "sparkles", shortcut: "⌘↩") { model.summarize(i) },
        ] + link(i.url)
        if let p = i["pipelineUrl"] { actions.append(PaletteAction(title: "Open pipeline", icon: "gearshape.2") { model.open(p) }) }
        if i["pipelineStatus"] == "failed" {
            actions.append(PaletteAction(title: "Retry pipeline", icon: "arrow.counterclockwise") { model.retryPipeline(i) })
        }
        if group != .myMRs {
            actions.append(PaletteAction(title: "Approve", icon: "checkmark.seal", confirm: "Approve \(i.subtitle)?") { model.approve(i) })
        }
        for key in (i["jiraKeys"] ?? "").split(separator: ",").map(String.init) {
            actions.append(PaletteAction(title: "Jira digest: \(key)", icon: "checklist") {
                model.digest(jiraKey: key, url: model.secrets.jiraBaseURL.map { $0.absoluteString + "/browse/" + key })
            })
        }
        actions.append(PaletteAction(title: model.config.isMuted(i.id) ? "Unmute" : "Mute notifications", icon: "bell.slash") {
            model.config.isMuted(i.id) ? model.unmute(itemId: i.id) : model.mute(itemId: i.id, for: nil)
        })
        var details: [(String, String)] = [("Project", i["projectPath"] ?? ""), ("Author", i["authorName"] ?? i.author ?? "")]
        if let p = i["pipelineStatus"] { details.append(("Pipeline", p)) }
        if let m = i["mergeStatus"] { details.append(("Merge", m.replacingOccurrences(of: "_", with: " "))) }
        if let a = i["approvedBy"] { details.append(("Approved by", a)) }
        if let r = i["reviewers"] { details.append(("Reviewers", r)) }
        if let b = i["sourceBranch"] { details.append(("Branch", b)) }
        details.append(("Opened", Dates.age(i.createdAt) + " ago"))
        if let k = i["jiraKeys"] { details.append(("Jira", k.replacingOccurrences(of: ",", with: ", "))) }
        return PaletteEntry(id: i.id, group: group, icon: "arrow.triangle.pull", tint: i["pipelineStatus"] == "failed" ? .red : .purple,
                            title: i.title, subtitle: "\(i.subtitle) · \(i["authorName"] ?? "")", badge: i["draft"] == "1" ? "draft" : i["pipelineStatus"],
                            date: i.updatedAt, details: details, url: i.url,
                            actions: actions, keywords: "\(i["sourceBranch"] ?? "") \(i["jiraKeys"] ?? "") !\(i["iid"] ?? "")",
                            boost: group == .review ? 30 : group == .myMRs ? 15 : 5)
    }

    func todo(_ i: FeedItem) -> PaletteEntry {
        PaletteEntry(id: i.id, group: .todos, icon: "checklist.unchecked", tint: .purple, title: i.subtitle, subtitle: i.title,
                     date: i.createdAt, details: [("Project", i["projectPath"] ?? ""), ("Type", i["targetType"] ?? "")],
                     preview: i["body"], url: i.url,
                     actions: [PaletteAction(title: "Open in browser", icon: "safari", shortcut: "↩") { model.open(i.url) },
                               PaletteAction(title: "Mark done", icon: "checkmark.circle", shortcut: "⌘↩") { model.markTodoDone(i) }] + link(i.url),
                     boost: 10)
    }

    func issue(_ i: FeedItem) -> PaletteEntry {
        let key = i["key"] ?? ""
        return PaletteEntry(
            id: i.id, group: .jira, icon: "checklist", tint: .blue, title: "\(key)  \(i.title)",
            subtitle: [i.status, i["assignee"]].compactMap { $0 }.joined(separator: " · "), badge: i["priority"], date: i.updatedAt,
            details: [("Status", i.status ?? ""), ("Priority", i["priority"] ?? "—"), ("Assignee", i["assignee"] ?? "Unassigned"),
                      ("Reporter", i["reporter"] ?? "—"), ("Type", i["type"] ?? "—"), ("Updated", Dates.age(i.updatedAt) + " ago")]
                + (i["due"].map { [("Due", $0)] } ?? []),
            url: i.url, jiraKey: key,
            actions: [PaletteAction(title: "Open in Jira", icon: "safari", shortcut: "↩") { model.open(i.url) },
                      PaletteAction(title: "AI digest", icon: "sparkles", shortcut: "⌘↩") { model.digest(jiraKey: key, title: i.title, url: i.url) },
                      PaletteAction(title: "Copy key", icon: "number") { model.copyToClipboard(key) }] + link(i.url),
            keywords: "\(i["assignee"] ?? "") \(i["reporter"] ?? "")", boost: i.kind == "issue.assigned" ? 20 : 0)
    }

    func pipeline(_ i: FeedItem) -> PaletteEntry {
        var actions = [PaletteAction(title: "Open pipeline", icon: "safari", shortcut: "↩") { model.open(i.url) }] + link(i.url)
        if i.status == "failed" || i.status == "canceled" {
            actions.insert(PaletteAction(title: "Retry pipeline", icon: "arrow.counterclockwise", shortcut: "⌘↩") { model.retryPipeline(i) }, at: 1)
        }
        return PaletteEntry(id: i.id, group: .pipelines, icon: "gearshape.2", tint: i.status == "failed" ? .red : .secondary,
                            title: i.title, subtitle: i.subtitle, badge: i.status, date: i.updatedAt,
                            details: [("Status", i.status ?? ""), ("Ref", i["ref"] ?? ""), ("Trigger", i["trigger"] ?? "")],
                            url: i.url, actions: actions, boost: i.status == "failed" ? 15 : 0)
    }

    func event(_ e: AppEvent) -> PaletteEntry {
        PaletteEntry(id: "evt." + e.id, group: .inbox, icon: e.read ? "tray" : "tray.full", tint: e.read ? .secondary : .blue,
                     title: e.title, subtitle: e.body.replacingOccurrences(of: "\n", with: " · "), date: e.ts,
                     details: [("Type", e.category.label), ("When", e.ts.formatted(date: .abbreviated, time: .shortened))],
                     preview: e.body, url: e.url,
                     actions: [PaletteAction(title: "Open", icon: "safari", shortcut: "↩") { model.open(e) },
                               PaletteAction(title: "Mark read", icon: "checkmark", shortcut: "⌘↩") { model.markRead([e.id]) },
                               PaletteAction(title: "Mute this item", icon: "bell.slash") { model.mute(itemId: e.itemId, for: nil) },
                               PaletteAction(title: "Snooze a day", icon: "moon.zzz") { model.mute(itemId: e.itemId, for: 86400) }] + link(e.url),
                     boost: e.read ? 0 : 10)
    }

    func story(_ s: (section: String, story: NewsBrief.Story)) -> PaletteEntry {
        let st = s.story
        return PaletteEntry(
            id: st.key, group: .stories, icon: "globe", tint: .orange, title: st.title, subtitle: "\(s.section) · \(st.sources.joined(separator: ", "))",
            details: [("Section", s.section), ("Importance", String(repeating: "●", count: st.importance)), ("Topics", st.topics.joined(separator: ", "))],
            preview: "\(st.summary)\n\n\(st.whyItMatters)", url: st.urls.first,
            actions: [PaletteAction(title: "Read", icon: "safari", shortcut: "↩") { model.open(st.urls.first) },
                      PaletteAction(title: "Go deeper with AI", icon: "sparkles", shortcut: "⌘↩") { model.showDashboard(.worldBrief); model.goDeeper(st) },
                      PaletteAction(title: model.isFollowing(st) ? "Unfollow story" : "Follow story", icon: "binoculars") { model.toggleFollow(st) },
                      PaletteAction(title: "👍 More like this", icon: "hand.thumbsup") { model.feedback(st, .up) },
                      PaletteAction(title: "👎 Less like this", icon: "hand.thumbsdown") { model.feedback(st, .down) }] + link(st.urls.first),
            keywords: st.topics.joined(separator: " "), boost: st.importance * 2)
    }

    func article(_ a: Article) -> PaletteEntry {
        PaletteEntry(id: "art." + a.id, group: .articles, icon: "newspaper", title: a.title,
                     subtitle: "\(a.source) · \(a.section.title)", badge: a.score.map { "▲\($0)" }, date: a.publishedAt ?? a.fetchedAt,
                     details: [("Source", a.source), ("Section", a.section.title)], preview: a.snippet, url: a.url,
                     actions: [PaletteAction(title: "Read", icon: "safari", shortcut: "↩") { model.open(a.url) },
                               PaletteAction(title: "👍 More like this", icon: "hand.thumbsup") { model.feedback(article: a, .up) },
                               PaletteAction(title: "👎 Less like this", icon: "hand.thumbsdown") { model.feedback(article: a, .down) }] + link(a.url),
                     boost: -10)
    }

    func meeting(_ m: CalendarService.Meeting) -> PaletteEntry {
        var actions: [PaletteAction] = []
        if let url = m.joinURL { actions.append(PaletteAction(title: "Join", icon: "video", shortcut: "↩") { NSWorkspace.shared.open(url) }) }
        actions.append(PaletteAction(title: "Prep brief with AI", icon: "sparkles", shortcut: actions.isEmpty ? "↩" : "⌘↩") { model.prepBrief(for: m) })
        let time = "\(m.start.formatted(date: .omitted, time: .shortened))–\(m.end.formatted(date: .omitted, time: .shortened))"
        return PaletteEntry(id: "cal." + m.id, group: .meetings, icon: m.isNow ? "video.fill" : "calendar", tint: m.isNow ? .green : .blue,
                            title: m.title, subtitle: m.isNow ? "Now · \(time)" : time, badge: m.joinURL != nil ? "join" : nil,
                            details: [("When", time), ("Calendar", m.calendarName), ("Where", m.location ?? "—"),
                                      ("Attendees", m.attendees.prefix(8).joined(separator: ", "))],
                            preview: m.notes.map { String($0.prefix(400)) }, url: m.joinURL?.absoluteString, actions: actions,
                            keywords: m.attendees.joined(separator: " "), boost: m.isNow ? 40 : 20)
    }

    // MARK: Remote results

    func remoteMR(_ m: GitLabMR) -> PaletteEntry {
        PaletteEntry(id: "gitlab.mr:\(m.projectId):\(m.iid)", group: .remoteGitLab, icon: "magnifyingglass", tint: .purple,
                     title: m.title, subtitle: "\(m.ref) · \(m.author?.name ?? "") · \(m.state)", badge: m.state, date: m.updatedAt,
                     details: [("State", m.state), ("Author", m.author?.name ?? ""), ("Updated", Dates.age(m.updatedAt) + " ago")],
                     url: m.webUrl,
                     actions: [PaletteAction(title: "Open in browser", icon: "safari", shortcut: "↩") { model.open(m.webUrl) }] + link(m.webUrl))
    }

    func remoteIssue(_ i: JiraIssue) -> PaletteEntry {
        let url = model.secrets.jiraBaseURL.map { $0.absoluteString + "/browse/" + i.key }
        return PaletteEntry(id: "jira.issue:\(i.key)", group: .remoteJira, icon: "magnifyingglass", tint: .blue,
                            title: "\(i.key)  \(i.fields.summary ?? "")", subtitle: [i.fields.status?.name, i.fields.assignee?.displayName].compactMap { $0 }.joined(separator: " · "),
                            badge: i.fields.priority?.name, date: i.fields.updated,
                            details: [("Status", i.fields.status?.name ?? ""), ("Assignee", i.fields.assignee?.displayName ?? "Unassigned"),
                                      ("Updated", Dates.age(i.fields.updated) + " ago")],
                            url: url, jiraKey: i.key,
                            actions: [PaletteAction(title: "Open in Jira", icon: "safari", shortcut: "↩") { model.open(url) },
                                      PaletteAction(title: "AI digest", icon: "sparkles", shortcut: "⌘↩") { model.digest(jiraKey: i.key, title: i.fields.summary ?? "", url: url) }]
                                + link(url))
    }

    // MARK: Direct jumps & fallbacks (depend on the query)

    func direct() -> [PaletteEntry] {
        let text = state.parsed.text
        var out: [PaletteEntry] = []
        if text.range(of: #"^[A-Za-z][A-Za-z0-9]+-\d+$"#, options: .regularExpression) != nil, let base = model.secrets.jiraBaseURL {
            let key = text.uppercased()
            let url = base.absoluteString + "/browse/" + key
            out.append(PaletteEntry(id: "direct.jira." + key, group: .direct, icon: "arrow.up.forward.app", tint: .blue,
                                    title: "Open \(key) in Jira", subtitle: base.host ?? "", url: url, jiraKey: key,
                                    actions: [PaletteAction(title: "Open in Jira", icon: "safari", shortcut: "↩") { model.open(url) },
                                              PaletteAction(title: "AI digest", icon: "sparkles", shortcut: "⌘↩") { model.digest(jiraKey: key, url: url) }]))
        }
        if let u = SafeURL.web(text), text.hasPrefix("http") {
            out.append(PaletteEntry(id: "direct.url", group: .direct, icon: "link", title: "Open \(u.host ?? "link")", subtitle: text,
                                    url: text, actions: [PaletteAction(title: "Open", icon: "safari", shortcut: "↩") { model.open(text) }]))
        }
        return out
    }

    func fallbacks() -> [PaletteEntry] {
        let text = state.parsed.text
        guard text.count >= 2 else { return [] }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        var out = [PaletteEntry(id: "fb.ask", group: .fallback, icon: "bubble.left.and.text.bubble.right", tint: .orange,
                                title: "Ask the news: “\(text)”", subtitle: "Claude answers from the last 48h of articles",
                                actions: [PaletteAction(title: "Ask", icon: "sparkles", shortcut: "↩") { model.showDashboard(.worldBrief); model.ask(text) }])]
        if let jira = model.secrets.jiraBaseURL {
            let jql = "text ~ \"\(text)\" ORDER BY updated DESC".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let url = "\(jira.absoluteString)/issues/?jql=\(jql)"
            out.append(PaletteEntry(id: "fb.jira", group: .fallback, icon: "safari", tint: .blue, title: "Search Jira for “\(text)”",
                                    subtitle: "Opens in your browser", url: url,
                                    actions: [PaletteAction(title: "Open", icon: "safari", shortcut: "↩") { model.open(url) }]))
        }
        if let gl = model.secrets.gitlabBaseURL {
            let url = "\(gl.absoluteString)/dashboard/merge_requests?scope=all&search=\(q)"
            out.append(PaletteEntry(id: "fb.gitlab", group: .fallback, icon: "safari", tint: .purple, title: "Search GitLab MRs for “\(text)”",
                                    subtitle: "Opens in your browser", url: url,
                                    actions: [PaletteAction(title: "Open", icon: "safari", shortcut: "↩") { model.open(url) }]))
        }
        return out
    }

    private func commands() -> [PaletteEntry] {
        let m = model
        func cmd(_ id: String, _ icon: String, _ title: String, _ sub: String, boost: Int = 0, _ run: @escaping @MainActor () -> Void) -> PaletteEntry {
            PaletteEntry(id: "cmd." + id, group: .commands, icon: icon, tint: .accentColor, title: title, subtitle: sub,
                         actions: [PaletteAction(title: "Run", icon: "return", shortcut: "↩", run: run)], boost: boost)
        }
        return [
            cmd("dash", "rectangle.grid.2x2", "Open dashboard", "Inbox", boost: 5) { m.showDashboard(.inbox) },
            cmd("refresh", "arrow.clockwise", "Refresh now", "Poll GitLab and Jira", boost: 4) { m.refreshAll() },
            cmd("brief", "sun.max", "Generate work brief", "Claude · Work Brief", boost: 3) { m.showDashboard(.workBrief); m.generateWorkBrief() },
            cmd("standup", "text.badge.checkmark", "Write my standup", "Claude · Team & Reports", boost: 3) { m.reportsTab = "standup"; m.showDashboard(.reports); m.generateStandup() },
            cmd("weekly", "doc.text", "Write weekly report", "Claude · Team & Reports") { m.reportsTab = "weekly"; m.showDashboard(.reports); m.generateWeekly() },
            cmd("team", "person.3", "Team health", "Metrics for your reportees") { m.reportsTab = "team"; m.showDashboard(.reports) },
            cmd("news", "globe", "Open World & Tech brief", "News") { m.showDashboard(.worldBrief) },
            cmd("newsgen", "arrow.triangle.2.circlepath", "Refresh World & Tech brief", "Claude") { m.showDashboard(.worldBrief); m.generateNewsBrief() },
            cmd("mrs", "arrow.triangle.pull", "Open merge requests", "Dashboard") { m.showDashboard(.mergeRequests) },
            cmd("jira", "checklist", "Open Jira", "Dashboard") { m.showDashboard(.jira) },
            cmd("pipelines", "gearshape.2", "Open pipelines", "Dashboard") { m.showDashboard(.pipelines) },
            cmd("readall", "checkmark.circle", "Mark all read", "Inbox") { m.markAllRead() },
            cmd("listen", "speaker.wave.2", "Read work brief aloud", "Speech") {
                if let t = m.workBrief?.text { Speech.shared.toggle(id: "brief.work", text: t, voice: m.config.speechVoice, rate: m.config.speechRate) }
            },
            cmd("stop", "stop.fill", "Stop reading aloud", "Speech") { Speech.shared.stop() },
            cmd("usage", "chart.bar", "AI usage", "Settings") { m.settingsTab = "usage"; m.showDashboard(.settings) },
            cmd("settings", "gearshape", "Settings", "") { m.showDashboard(.settings) },
            cmd("quit", "power", "Quit Everboard", "") { NSApp.terminate(nil) },
        ]
    }
}

// MARK: - Views

struct PaletteView: View {
    static let width: CGFloat = 820
    static let height: CGFloat = 520

    @Bindable var state: PaletteState
    @FocusState private var focused: Bool

    var body: some View {
        let sections = state.sections
        let flat = sections.flatMap { $0.entries.map(\.entry) }
        VStack(spacing: 0) {
            searchField
            scopeChips
            Divider()
            HStack(spacing: 0) {
                resultsList(sections, flat: flat)
                    .frame(width: Self.width * 0.52)
                Divider()
                PreviewPane(state: state)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) {
            if state.actionsOpen { ActionPanel(state: state).padding(.bottom, 40).padding(.trailing, 12) }
        }
        .onAppear { focused = true }
    }

    var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
            if state.scope != .all && state.parsed.scope != state.chipScope {
                Text(state.scope.title).font(.callout.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            }
            TextField("Search MRs, Jira, pipelines, news, meetings — or type > for commands", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($focused)
            if state.remoteLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(PaletteScope.allCases.enumerated()), id: \.element) { i, s in
                Button { state.setScope(s) } label: {
                    Text(s.title).font(.caption.weight(state.scope == s ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(state.scope == s ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(s == .all ? "⌘1" : "Type “\(s.prefix)\(s == .commands ? "" : " ")” or ⌘\(i + 1)")
            }
            Spacer()
            Text("Tab ⇥ to switch").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    func resultsList(_ sections: [PaletteSection], flat: [PaletteEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.tertiary)
                            Text(state.remoteLoading ? "Searching GitLab and Jira…" : "No results").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(sections) { section in
                        Text(section.group.title.uppercased())
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                        ForEach(section.entries, id: \.entry.id) { pair in
                            let index = flat.firstIndex { $0.id == pair.entry.id } ?? 0
                            ResultRow(entry: pair.entry, match: pair.match, selected: index == state.selection)
                                .id(pair.entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { state.click(pair.entry) }
                                .onTapGesture { state.selection = index; state.extraActions = [] }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: state.selection) { _, s in
                if flat.indices.contains(s) { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(flat[s].id) } }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            if let e = state.selected {
                Label(e.actions.first?.title ?? "Open", systemImage: "return").font(.caption)
                if e.actions.count > 1 { Text("⌘↩ \(e.actions[1].title)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text("↑↓ move").font(.caption2).foregroundStyle(.tertiary)
            Text("⌘K actions").font(.caption2).foregroundStyle(.secondary)
            Text("⇧⌘C copy link").font(.caption2).foregroundStyle(.tertiary)
            Text("esc").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct ResultRow: View {
    let entry: PaletteEntry
    let match: Set<Int>
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? .white : entry.tint)
                .frame(width: 26, height: 26)
                .background(selected ? Color.white.opacity(0.18) : entry.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Highlighted(text: entry.title, match: match).lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge = entry.badge {
                if selected { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.9)) }
                else { StatusPill(text: badge) }
            }
            if let date = entry.date {
                Text(Dates.age(date)).font(.caption2.monospacedDigit()).foregroundStyle(selected ? .white.opacity(0.7) : .secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 6)
    }
}

/// Bolds the characters the fuzzy matcher used.
private struct Highlighted: View {
    let text: String
    let match: Set<Int>

    var body: some View {
        guard !match.isEmpty else { return Text(text) }
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            var piece = AttributedString(String(ch))
            if match.contains(i) { piece.font = .body.weight(.bold); piece.underlineStyle = .single }
            out += piece
        }
        return Text(out)
    }
}

private struct PreviewPane: View {
    @Bindable var state: PaletteState

    var body: some View {
        if let e = state.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.icon).font(.title2).foregroundStyle(e.tint)
                            .frame(width: 38, height: 38).background(e.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            if !e.subtitle.isEmpty { Text(e.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if !e.details.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                            ForEach(Array(e.details.enumerated()), id: \.offset) { _, kv in
                                if !kv.1.isEmpty {
                                    GridRow {
                                        Text(kv.0).font(.caption).foregroundStyle(.secondary)
                                        Text(kv.1).font(.caption).textSelection(.enabled).lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    if let p = e.preview, !p.isEmpty {
                        Text(p).font(.callout).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
                        ForEach(Array(state.selectedActions.prefix(8).enumerated()), id: \.offset) { i, a in
                            Button { state.runAction(at: i) } label: {
                                HStack {
                                    Image(systemName: a.icon).frame(width: 16)
                                    Text(a.title)
                                    Spacer()
                                    if let s = a.shortcut { Text(s).font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if state.selectedActions.count > 8 || e.jiraKey != nil {
                            Text("⌘K for all actions\(e.jiraKey != nil ? " (incl. moving the issue)" : "")").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Type to search everything").foregroundStyle(.secondary)
                Text("mr · jira · pl · news · in · cal  prefixes, or > for commands").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// ⌘K list of every action for the selected item.
private struct ActionPanel: View {
    @Bindable var state: PaletteState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.selected?.title ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            VStack(spacing: 1) {
                    ForEach(Array(state.selectedActions.enumerated()), id: \.offset) { i, a in
                        HStack {
                            Image(systemName: a.icon).frame(width: 16)
                            Text(a.title)
                            Spacer()
                            if let s = a.shortcut { Text(s).font(.caption).foregroundStyle(i == state.actionSelection ? .white.opacity(0.8) : .secondary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(i == state.actionSelection ? .white : (a.destructive ? .red : .primary))
                        .background(i == state.actionSelection ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { state.runAction(at: i) }
                    }
                    if state.selected?.jiraKey != nil && state.extraActions.isEmpty {
                        HStack { ProgressView().controlSize(.mini); Text("Loading workflow…").font(.caption).foregroundStyle(.secondary) }
                            .padding(8)
                    }
                }
                .padding(6)
        }
        .frame(width: 300)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 12)
    }
}

/// Subsequence fuzzy match with bonuses for word starts and contiguous runs. Returns matched character indices.
enum Fuzzy {
    static func match(_ query: String, _ text: String) -> (score: Int, indices: Set<Int>)? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return (0, []) }
        // Exact substring: strongest signal, earlier is better.
        if let r = text.lowercased().range(of: query.lowercased()) {
            let start = text.lowercased().distance(from: text.lowercased().startIndex, to: r.lowerBound)
            let wordStart = start == 0 || " /-_.:[(".contains(t[start - 1])
            return (1000 - start * 2 + (wordStart ? 100 : 0) - t.count / 8, Set(start..<(start + q.count)))
        }
        var qi = 0, score = 0, run = 0, prev: Character = " "
        var hit = Set<Int>()
        for (i, c) in t.enumerated() {
            if qi < q.count, c == q[qi] {
                score += 10 + run * 6 + (" /-_.:[(".contains(prev) ? 18 : 0)
                run += 1
                qi += 1
                hit.insert(i)
            } else {
                run = 0
            }
            prev = c
        }
        return qi == q.count ? (score, hit) : nil
    }

    static func score(_ query: String, _ text: String) -> Int? { match(query, text)?.score }
}
