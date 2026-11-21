import AppKit
import EverboardCore
import Foundation
import Observation

/// Live list of coding agent sessions. Watches the session folder (hooks write to it on every event),
/// re-checks every few seconds for things hooks can't report, and turns state changes into inbox events.
/// Sessions don't go through the `Poller`: they change many times a second and never need the network.
@MainActor @Observable
final class SessionCenter {
    static let shared = SessionCenter()

    private(set) var sessions: [AgentSession] = []
    private(set) var hookStatus: [HookInstaller.Target: HookInstaller.Status] = [:]
    var installError: String?

    @ObservationIgnored private let directory = SessionDirectory()
    @ObservationIgnored private var known: [String: AgentSession] = [:]
    @ObservationIgnored private var baselined = false
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reloadQueued = false
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var running = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Prompts answered here that the agent hasn't picked up yet: approval id → what was sent.
    private(set) var sent: [String: String] = [:]
    /// Claude desktop sidebar titles by Claude Code session id, looked up once per session (nil = none).
    private var desktopTitles: [String: String?] = [:]

    private var model: AppModel { .shared }

    var needsYou: [AgentSession] { sessions.filter { $0.state.needsYou } }
    var visible: [AgentSession] { sessions.filter { $0.state != .ended } }
    var ended: [AgentSession] { sessions.filter { $0.state == .ended } }

    /// The hook binary inside the app bundle, next to the main executable.
    var bundledHook: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("everboard-hook")
    }

    // MARK: Lifecycle

    /// Starts or stops watching to match the setting. Safe to call repeatedly.
    func configure(enabled: Bool) {
        refreshHookStatus()
        if DemoData.isDemo {
            sessions = enabled ? DemoData.sessions() : []
            return
        }
        if enabled && !running { start() } else if !enabled && running { stop() }
    }

    private func start() {
        running = true
        updateInstalledBinary()
        try? FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.writeAppStatus()
                self?.reload()
            }
        }
        // Hooks hold prompts only while you're in another app, so they need to know which app is in front.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.writeAppStatus() }
        }
        writeAppStatus()
        reload()
    }

    private func stop() {
        running = false
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        // Without a fresh status file, hooks stop holding prompts.
        try? FileManager.default.removeItem(at: SessionPaths.appStatusFile(in: directory.url))
        watcher?.cancel()
        watcher = nil
        timer?.invalidate()
        timer = nil
        sessions = []
        known = [:]
        baselined = false
    }

    private func watch() {
        let fd = Darwin.open(directory.url.path, O_EVTONLY)
        guard fd >= 0 else { Log.info("sessions: can't watch \(directory.url.path)"); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.queueReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Hooks fire in bursts (parallel tool calls); one reload per burst is enough.
    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in
                self?.reloadQueued = false
                self?.reload()
            }
        }
    }

    func reload(now: Date = Date()) {
        guard running else { return }
        if now.timeIntervalSince(lastPrune) > 3600 {
            lastPrune = now
            directory.prune(now: now)
        }
        let fresh = SessionRules.sorted(directory.loadAll().map { withCursorDetails(SessionRules.refresh($0, now: now), now: now) })
        lookUpDesktopTitles(fresh)
        let events = baselined ? SessionRules.events(old: known, new: fresh, now: now) : []
        known = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Forget sent answers once their prompt is gone from the session.
        let open = Set(fresh.compactMap { $0.approval?.id })
        if sent.keys.contains(where: { !open.contains($0) }) { sent = sent.filter { open.contains($0.key) } }
        baselined = true
        if fresh != sessions { sessions = fresh }
        guard !events.isEmpty else { return }
        Task {
            var new: [AppEvent] = []
            for e in events where (try? await model.store.insert(event: e)) == true { new.append(e) }
            guard !new.isEmpty else { return }
            model.deliver(new)
            await model.reloadData()
        }
    }

    /// Tells hooks that Everboard is running, which app is in front, and whether to hold prompts.
    func writeAppStatus() {
        guard running, !DemoData.isDemo else { return }
        let c = model.config
        let status = SessionApprovals.AppStatus(pid: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(),
                                                frontmostApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                                holdApprovals: c.sessionsHoldApprovals, holdSeconds: c.sessionsHoldSeconds)
        try? SessionApprovals.writeStatus(status, in: directory.url)
    }

    /// Cursor chat details by chat id, read from Cursor's own records at most every few seconds per chat.
    @ObservationIgnored private var cursorInfo: [String: (at: Date, info: CursorChats.Info?)] = [:]

    /// Adds what Cursor's hooks don't report: the chat's name, and a question it is waiting on.
    private func withCursorDetails(_ s: AgentSession, now: Date) -> AgentSession {
        guard s.tool == "cursor", s.state != .ended, !DemoData.isDemo else { return s }
        if cursorInfo[s.sessionId].map({ now.timeIntervalSince($0.at) > 3 }) ?? true {
            cursorInfo[s.sessionId] = (now, CursorChats.info(chatId: s.sessionId))
        }
        guard let info = cursorInfo[s.sessionId]?.info else { return s }
        var r = s
        if let name = info.name { r.name = name }
        if let q = info.pendingQuestion, let first = q.questions.first {
            // The question is newer than anything the hooks reported, so it's what the chat is waiting on.
            let asked = q.askedAt ?? s.updatedAt
            if asked >= s.stateSince || s.state == .working {
                r.state = .needsReply
                r.stateSince = asked
                r.detail = first.question
                r.questionIsChoice = true
                r.activity = nil
                r.approval = .init(id: q.id, tool: "ask_question", summary: q.title ?? first.question, requestedAt: asked,
                                   questions: q.questions)
            }
        }
        return r
    }

    /// The title Claude's desktop app shows for this session, for sessions that reported no name of their own.
    func desktopTitle(_ s: AgentSession) -> String? { desktopTitles[s.sessionId] ?? nil }

    private func lookUpDesktopTitles(_ sessions: [AgentSession]) {
        for s in sessions where s.name == nil && s.tool == "claude-code" && s.hostApp == "com.anthropic.claudefordesktop"
                                && desktopTitles[s.sessionId] == nil {
            desktopTitles[s.sessionId] = .some(ClaudeDesktopSessions.session(forCLISession: s.sessionId)?.title)
        }
    }

    // MARK: Answering

    /// A prompt the hook is holding right now, so Allow and Deny here reach the agent.
    func canAnswer(_ s: AgentSession, now: Date = Date()) -> Bool {
        guard let a = s.approval, a.isHeld(now: now), sent[a.id] == nil else { return false }
        return a.isQuestion ? s.state == .needsReply : s.state == .needsApproval
    }

    func answer(_ s: AgentSession, allow: Bool) {
        send(allow ? .init(behavior: .allow) : .init(behavior: .deny), to: s)
    }

    /// Answers a held multiple-choice question: question text → chosen labels or typed text.
    func answerQuestion(_ s: AgentSession, answers: [String: [String]]) {
        send(.init(behavior: .allow, answers: answers), to: s)
    }

    func skipQuestion(_ s: AgentSession) {
        send(.init(behavior: .deny, message: "The user skipped this question from Everboard. Carry on with your best judgement or ask again later."), to: s)
    }

    private func send(_ answer: SessionApprovals.Answer, to s: AgentSession) {
        guard let approval = s.approval, canAnswer(s), !DemoData.isDemo else { return }
        let allow = answer.behavior == .allow
        let picked = (answer.answers ?? [:]).values.flatMap { $0 }.joined(separator: ", ")
        sent[approval.id] = approval.isQuestion ? (allow ? "Answered: \(picked)" : "Skipped") : (allow ? "Allowed" : "Denied")
        do {
            try SessionApprovals.writeAnswer(answer, for: s, approvalId: approval.id, in: directory.url)
            let verb = approval.isQuestion ? (allow ? "answered" : "skipped") : (allow ? "allowed" : "denied")
            Log.info("sessions: \(verb) \(approval.tool) in \(s.id)")
        } catch {
            sent[approval.id] = nil
            ToastCenter.shared.show(.init(title: "Couldn't send the answer", body: error.localizedDescription,
                                          actionTitle: nil, onClick: {}, onAction: nil), duration: 6)
        }
    }

    /// What was sent for the session's open prompt, while the agent picks it up.
    func sentAnswer(_ s: AgentSession) -> String? { s.approval.flatMap { sent[$0.id] } }

    /// Free-text replies can be typed into Terminal and iTerm2 sessions; multiple-choice questions need the session.
    func canReply(_ s: AgentSession) -> Bool {
        s.state == .needsReply && s.questionIsChoice != true && s.tty != nil && TerminalBridge.supports(s.hostApp)
    }

    func reply(_ s: AgentSession, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canReply(s), !trimmed.isEmpty, let tty = s.tty, let host = s.hostApp, !DemoData.isDemo else { return }
        if let error = TerminalBridge.type(trimmed, tty: tty, host: host) {
            ToastCenter.shared.show(.init(title: "Couldn't send the reply", body: error, actionTitle: "Open session",
                                          onClick: { [weak self] in self?.open(s) }, onAction: { [weak self] in self?.open(s) }), duration: 8)
        } else {
            Log.info("sessions: typed a reply into \(s.id)")
        }
    }

    // MARK: Actions

    func session(itemId: String?) -> AgentSession? {
        guard let itemId, itemId.hasPrefix("session:") else { return nil }
        let id = String(itemId.dropFirst("session:".count))
        return sessions.first { $0.id == id }
    }

    /// Brings the exact session forward, most specific first: the session's own link (Claude's desktop app,
    /// Cursor's workspace), its Terminal or iTerm2 tab, the editor window for its folder, then just its app.
    func open(_ s: AgentSession) {
        // Claude's desktop app: its own records say which of its sessions runs this one, also for sessions that
        // reported before the hook knew the desktop id.
        if s.tool == "claude-code", s.hostApp == "com.anthropic.claudefordesktop",
           let host = ClaudeDesktopSessions.hostSessionId(forCLISession: s.sessionId),
           let u = ClaudeDesktopSessions.openURL(hostSessionId: host).flatMap(URL.init(string:)), NSWorkspace.shared.open(u) {
            return
        }
        // Cursor: its chat link selects the chat in the Agents Window. Without it, open the window the chat belongs
        // to (its workspace file or folder) rather than one folder of a multi-folder workspace in a new window.
        if s.tool == "cursor", let link = cursorChatLink(s), NSWorkspace.shared.open(link) {
            return
        }
        if s.tool == "cursor",
           let target = CursorWorkspaces.workspace(forChat: s.sessionId)
                ?? (s.workspaceRoots ?? s.cwd.map { [$0] }).flatMap({ CursorWorkspaces.workspaceFile(forRoots: $0) }),
           let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.hostApp ?? "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.open([target], withApplicationAt: cursor, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if let u = s.safeOpenURL, NSWorkspace.shared.open(u) { return }
        if let tty = s.tty, let host = s.hostApp, TerminalBridge.supports(host), TerminalBridge.focus(tty: tty, host: host) { return }
        if let host = s.hostApp, let cwd = s.cwd, let scheme = TerminalBridge.editorScheme(host),
           let path = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let u = URL(string: "\(scheme)://file\(path.hasPrefix("/") ? "" : "/")\(path)"), NSWorkspace.shared.open(u) { return }
        if let bundle = s.hostApp, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        revealFolder(s)
    }

    /// Checked once per Cursor install (path and version), since it reads Cursor's link handler.
    private var cursorLinkSupport: (key: String, supported: Bool)?

    private func cursorChatLink(_ s: AgentSession) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.hostApp ?? "com.todesktop.230313mzl4w4u92"),
              let link = CursorChats.chatLink(chatId: s.sessionId).flatMap(URL.init(string:)) else { return nil }
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "\(app.path)|\(version)"
        if cursorLinkSupport?.key != key {
            cursorLinkSupport = (key, CursorChats.supportsChatLinks(app: app))
        }
        return cursorLinkSupport?.supported == true ? link : nil
    }

    /// Shows the folder in Finder. Never `open`s it: a session's folder comes from its file, and opening a path
    /// that is an app bundle would launch it.
    func revealFolder(_ s: AgentSession) {
        guard let cwd = s.cwd, cwd.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    func copyResumeCommand(_ s: AgentSession) {
        guard let cmd = s.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        ToastCenter.shared.show(.init(title: "Resume command copied", body: cmd, actionTitle: nil, onClick: {}, onAction: nil), duration: 4)
    }

    func remove(_ s: AgentSession) {
        directory.remove(s)
        reload()
    }

    func clearEnded() {
        for s in ended { directory.remove(s) }
        reload()
    }

    // MARK: Hooks

    func refreshHookStatus() {
        let binary = SessionPaths.hookBinary().path
        var out: [HookInstaller.Target: HookInstaller.Status] = [:]
        for t in HookInstaller.Target.allCases {
            out[t] = DemoData.isDemo ? (t == .claudeCode ? .installed : .notInstalled) : HookInstaller.status(target: t, binary: binary)
        }
        hookStatus = out
    }

    func install(_ target: HookInstaller.Target) {
        guard !DemoData.isDemo else { return }
        installError = nil
        do {
            guard let hook = bundledHook, FileManager.default.fileExists(atPath: hook.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                    "everboard-hook isn't in this build of Everboard. Build the app with scripts/build-app.sh."])
            }
            try HookInstaller.installBinary(from: hook)
            try HookInstaller.install(target: target, binary: SessionPaths.hookBinary().path)
            Log.info("sessions: installed hook for \(target.rawValue)")
            if !model.config.sessionsEnabled { model.updateConfig { $0.sessionsEnabled = true } }
        } catch {
            installError = error.localizedDescription
        }
        refreshHookStatus()
    }

    func uninstall(_ target: HookInstaller.Target) {
        guard !DemoData.isDemo else { return }
        installError = nil
        do { try HookInstaller.uninstall(target: target) } catch { installError = error.localizedDescription }
        refreshHookStatus()
    }

    /// Keeps the stable copy of the hook in step with this build when any tool uses it.
    private func updateInstalledBinary() {
        guard hookStatus.values.contains(where: { $0 != .notInstalled }), let hook = bundledHook,
              FileManager.default.fileExists(atPath: hook.path) else { return }
        if (try? HookInstaller.installBinary(from: hook)) == true { Log.info("sessions: updated everboard-hook") }
    }
}
