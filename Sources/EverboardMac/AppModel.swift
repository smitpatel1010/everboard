import AppKit
import EverboardCore
import Foundation
import Observation

/// Everything the UI shows, loaded from the store after each poll.
struct ItemsSnapshot {
    var mine: [FeedItem] = []
    var review: [FeedItem] = []
    var assigned: [FeedItem] = []
    var reportees: [FeedItem] = []
    var todos: [FeedItem] = []
    var pipelines: [FeedItem] = []
    var jiraAssigned: [FeedItem] = []
    var jiraFilters: [String: [FeedItem]] = [:]
}

/// A Claude result shown in a sheet (MR summary, Jira digest, "go deeper").
struct AIPanel: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var url: String?
    var text: String?
    var error: String?
    var refresh: (@MainActor () -> Void)?
}

enum SidebarItem: Hashable {
    case inbox, mergeRequests, pipelines, jira, workBrief, reports, worldBrief, settings
    case web(String)
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var config: AppConfig
    var secrets: Secrets
    var health: [String: SourceHealth] = [:]
    var events: [AppEvent] = []
    var unread = 0
    var items = ItemsSnapshot()
    var selection: SidebarItem = .inbox
    var settingsTab = "general"

    var workBrief: (text: String, at: Date?)?
    var workBriefRunning = false
    var workBriefError: String?

    var newsBrief: NewsBrief?
    var newsRunning = false
    var newsStatus: String?
    var newsVotes: [String: NewsFeedback.Vote] = [:]
    var preferencesUpdating = false
    var lastNewsCollect: Date?
    /// Articles collected in the last 36h, for the Live feed tab.
    var latestArticles: [Article] = []

    var aiPanel: AIPanel?
    var storeError: String?

    // Reports & team
    var reportsTab = "team"
    var teamHealth: TeamHealth?
    var standup: (text: String, at: Date?)?
    var weekly: (text: String, at: Date?)?
    var reportRunning: Set<String> = []
    var reportError: String?

    // News follow / ask
    var followed: [FollowedStory] = []
    var askRunning = false

    // Calendar + notification batching
    let calendar = CalendarService()
    var heldEvents: [AppEvent] = []
    var heldSince: Date?

    let store: Store
    private(set) var poller: Poller!
    let notifier = Notifier()
    private var tickTimer: Timer?
    private var started = false

    private init() {
        config = AppConfig.load()
        Secrets.writeTemplateIfMissing()
        secrets = Secrets.load()
        do {
            store = DemoData.isDemo ? try Store.inMemory() : try Store()
        } catch {
            // Fall back to memory so the UI still works; surface the error.
            store = try! Store.inMemory()
            storeError = "Database error: \(error.localizedDescription)"
        }
        poller = Poller(store: store, config: config) { [weak self] update in
            await self?.handle(update)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Log.info("Everboard \(AppInfo.version) starting; gitlab=\(secrets.hasGitLab) jira=\(secrets.hasJira)")
        notifier.setUp(model: self)
        SystemEvents.shared.start(
            onWake: { [weak self] in self?.refreshAll() },
            onNetworkUp: { [weak self] in self?.refreshAll() })
        if DemoData.isDemo {
            Task {
                await DemoData.seed(store)
                health = ["gitlab": .ok(Date()), "jira": .ok(Date().addingTimeInterval(-90))]
                await reloadData()
                workBrief = await assistant.latestBrief()
                newsBrief = try? await store.latestBrief()
                await reloadArticles()
                await loadReportsAndFollows()
                if let dir = DemoData.snapshotDir { await DemoData.snapshot(model: self, to: dir) }
            }
            return
        }
        if config.launchAtLogin { SystemEvents.setLaunchAtLogin(true) }
        if config.calendarEnabled { calendar.start() }
        if config.paletteEnabled { CommandPalette.shared.register(model: self) }
        configureSources()
        Task {
            await reloadData()
            workBrief = await assistant.latestBrief()
            newsBrief = try? await store.latestBrief()
            await reloadArticles()
            await refreshVotes()
            await loadReportsAndFollows()
            lastNewsCollect = await store.value("news.collected.at").flatMap(Dates.parseISO)
            try? await store.prune()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { tick() }
        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.notifier.sendTest() }
        }
    }

    func configureSources() {
        var sources: [DataSource] = []
        if let gl = GitLabClient(secrets: secrets) {
            sources.append(GitLabSource(client: gl, interval: config.gitlabInterval))
        } else {
            health["gitlab"] = .notConfigured("GitLab not configured")
        }
        if let jira = JiraClient(secrets: secrets) {
            sources.append(JiraSource(client: jira, interval: config.jiraInterval))
        } else {
            health["jira"] = .notConfigured("Jira not configured")
        }
        for s in sources where health[s.id] == nil || health[s.id].map({ if case .notConfigured = $0 { return true }; return false }) == true {
            health[s.id] = .idle
        }
        let cfg = config
        Task { await poller.configure(sources: sources, config: cfg) }
    }

    func reloadSecrets() {
        secrets = Secrets.load()
        health = [:]
        configureSources()
    }

    func updateConfig(_ change: (inout AppConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        let intervalsChanged = c.gitlabInterval != config.gitlabInterval || c.jiraInterval != config.jiraInterval
        let filtersChanged = c.jiraFilters.map(\.id) != config.jiraFilters.map(\.id) || c.reportees != config.reportees
        config = c
        try? c.save()
        if intervalsChanged || filtersChanged {
            configureSources()
        } else {
            Task { await poller.updateConfig(c) }
        }
    }

    private var lastManualRefresh = Date.distantPast

    func refreshAll() {
        // Wake + network-change events often arrive together; coalesce them.
        guard Date().timeIntervalSince(lastManualRefresh) > 10 else { return }
        lastManualRefresh = Date()
        Task { await poller.refreshNow() }
    }

    // MARK: Poll results

    private func handle(_ update: PollUpdate) async {
        if health[update.sourceId] != update.health || !update.newEvents.isEmpty {
            Log.info("\(update.sourceId): \(update.health.label), \(update.newEvents.count) new events")
        }
        health[update.sourceId] = update.health
        if !update.newEvents.isEmpty { deliver(update.newEvents) }
        await reloadData()
        if config.autoSummarizeReporteeMRs {
            for e in update.newEvents where e.category == .reporteeNewMR {
                if let item = item(withId: e.itemId) { _ = try? await assistant.summarizeMR(item) }
            }
        }
    }

    func deliver(_ events: [AppEvent]) {
        for e in events { Log.info("event \(e.category.rawValue): \(e.title)") }
        let toNotify = events.filter {
            $0.wantsNotification && config.isEnabled($0.category) && !config.isMuted($0.itemId)
        }
        // Urgent alerts go straight out (unless you're in a meeting); the rest wait for the next digest.
        let inMeeting = config.quietDuringMeetings && calendar.inMeeting
        var now: [AppEvent] = []
        for e in toNotify {
            let urgent = config.isUrgent(e.category) || [.workBriefReady, .newsBriefReady, .reportReady].contains(e.category)
            if !inMeeting && (urgent || !config.batchLowPriority) { now.append(e) } else { heldEvents.append(e) }
        }
        if !heldEvents.isEmpty && heldSince == nil { heldSince = Date() }
        notifier.post(now)
        Task { try? await store.markNotified(now.map(\.id)) }
    }

    /// Called every minute: releases held notifications after a meeting or when the batch window elapses.
    func flushHeldIfDue(now: Date = Date()) {
        guard !heldEvents.isEmpty, let since = heldSince else { return }
        let inMeeting = config.quietDuringMeetings && calendar.inMeeting
        let hasUrgent = heldEvents.contains { config.isUrgent($0.category) }
        let windowElapsed = now.timeIntervalSince(since) >= config.batchIntervalMinutes * 60
        guard !inMeeting && (hasUrgent || windowElapsed) else { return }
        let batch = heldEvents
        heldEvents = []
        heldSince = nil
        notifier.postDigest(batch)
        Task { try? await store.markNotified(batch.map(\.id)) }
    }

    func reloadData() async {
        do {
            var s = ItemsSnapshot()
            s.mine = try await store.items(scopePrefix: GitLabSource.Scope.mine).sortedByUpdate()
            s.review = try await store.items(scopePrefix: GitLabSource.Scope.review).sortedByUpdate()
            s.assigned = try await store.items(scopePrefix: GitLabSource.Scope.assigned).sortedByUpdate()
            s.reportees = try await store.items(scopePrefix: GitLabSource.Scope.reportees).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            s.todos = try await store.items(scopePrefix: GitLabSource.Scope.todos).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            let weekAgo = Date().addingTimeInterval(-7 * 86400)
            s.pipelines = try await store.items(scopePrefix: GitLabSource.Scope.pipelinesPrefix, presentOnly: false)
                .filter { ($0.updatedAt ?? .distantPast) > weekAgo }.sortedByUpdate()
            s.jiraAssigned = try await store.items(scopePrefix: JiraSource.Scope.assigned).sortedByUpdate()
            for f in config.jiraFilters {
                s.jiraFilters[f.id] = try await store.items(scope: JiraSource.Scope.filterPrefix + f.id).sortedByUpdate()
            }
            items = s
            events = try await store.events(limit: 300)
            unread = try await store.unreadCount()
        } catch {
            storeError = error.localizedDescription
        }
    }

    func item(withId id: String?) -> FeedItem? {
        guard let id else { return nil }
        let all = items.mine + items.review + items.assigned + items.reportees + items.todos + items.pipelines
            + items.jiraAssigned + items.jiraFilters.values.flatMap { $0 }
        return all.first { $0.id == id }
    }

    // MARK: Inbox actions

    func open(_ event: AppEvent) {
        if let u = SafeURL.web(event.url) { NSWorkspace.shared.open(u) }
        markRead([event.id])
    }

    func open(_ urlString: String?) {
        if let u = SafeURL.web(urlString) { NSWorkspace.shared.open(u) }
    }

    func markRead(_ ids: [String]) {
        Task {
            try? await store.markRead(ids)
            await reloadData()
        }
    }

    func markAllRead() {
        Task {
            try? await store.markAllRead()
            await reloadData()
        }
    }

    func mute(itemId: String?, for duration: TimeInterval?) {
        guard let itemId else { return }
        updateConfig { $0.mutedItems[itemId] = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture }
    }

    func unmute(itemId: String) {
        updateConfig { $0.mutedItems[itemId] = nil }
    }

    // MARK: AI

    /// Every Claude call goes through the recorder so Settings → AI usage sees it.
    var claude: ClaudeRunning {
        RecordingClaudeRunner(base: ClaudeCLIRunner(executable: config.expandedClaudePath, defaultModel: config.claudeModel), store: store)
    }
    var assistant: WorkAssistant {
        WorkAssistant(store: store, claude: claude, gitlab: GitLabClient(secrets: secrets), jira: JiraClient(secrets: secrets))
    }
    var news: NewsService { NewsService(store: store, claude: claude, secrets: secrets) }

    func summarize(_ item: FeedItem, force: Bool = false) {
        showDashboard()
        aiPanel = AIPanel(title: "MR summary", subtitle: "\(item.subtitle) — \(item.title)", url: item.url,
                          refresh: { [weak self] in self?.summarize(item, force: true) })
        let panelID = aiPanel?.id
        Task {
            do {
                let text = try await assistant.summarizeMR(item, force: force)
                if aiPanel?.id == panelID { aiPanel?.text = text }
            } catch {
                if aiPanel?.id == panelID { aiPanel?.error = error.localizedDescription }
            }
        }
    }

    func digest(jiraKey key: String, title: String = "", url: String? = nil, force: Bool = false) {
        showDashboard()
        aiPanel = AIPanel(title: "Jira digest", subtitle: "\(key) \(title)", url: url,
                          refresh: { [weak self] in self?.digest(jiraKey: key, title: title, url: url, force: true) })
        let panelID = aiPanel?.id
        Task {
            do {
                let text = try await assistant.jiraDigest(key: key, force: force)
                if aiPanel?.id == panelID { aiPanel?.text = text }
            } catch {
                if aiPanel?.id == panelID { aiPanel?.error = error.localizedDescription }
            }
        }
    }

    func generateWorkBrief(notify: Bool = false) {
        guard !workBriefRunning else { return }
        workBriefRunning = true
        workBriefError = nil
        Task {
            defer { workBriefRunning = false }
            do {
                let text = try await assistant.morningBrief()
                workBrief = (text, Date())
                if notify {
                    let e = AppEvent(id: "brief.work:\(Dates.iso(Date()))", category: .workBriefReady,
                                     title: "Your work brief is ready", body: String(text.prefix(140)), scope: "brief")
                    if try await store.insert(event: e) { deliver([e]) }
                    await reloadData()
                }
            } catch {
                workBriefError = error.localizedDescription
                Log.info("work brief failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: News

    func collectNews() async {
        do {
            let r = try await news.collect(config: config)
            lastNewsCollect = Date()
            await reloadArticles()
            if !r.majorEvents.isEmpty || !r.followEvents.isEmpty {
                deliver(r.majorEvents + r.followEvents)
                await reloadData()
            }
        } catch {
            newsStatus = "Collect failed: \(error.localizedDescription)"
            Log.info("news collect failed: \(error.localizedDescription)")
        }
    }

    func generateNewsBrief(notify: Bool = false) {
        guard !newsRunning else { return }
        newsRunning = true
        newsStatus = "Collecting news…"
        Task {
            defer { newsRunning = false }
            await collectNews()
            newsStatus = "Writing your brief with Claude… (1–3 min)"
            do {
                let brief = try await news.generateBrief(config: config)
                newsBrief = brief
                newsStatus = nil
                await refreshVotes()
                if notify {
                    let e = AppEvent(id: "brief.news:\(brief.id)", category: .newsBriefReady,
                                     title: "World & Tech brief ready", body: brief.headline, scope: "news")
                    if try await store.insert(event: e) { deliver([e]) }
                    await reloadData()
                }
            } catch {
                newsStatus = "Brief failed: \(error.localizedDescription)"
                Log.info("news brief failed: \(error.localizedDescription)")
            }
        }
    }

    func reloadArticles() async {
        let all = (try? await store.articles(since: Date().addingTimeInterval(-36 * 3600))) ?? []
        // One row per story: keep the highest-scored article of each cluster.
        var best: [String: Article] = [:]
        for a in all where (best[a.clusterKey]?.score ?? -1) < (a.score ?? 0) { best[a.clusterKey] = a }
        latestArticles = best.values.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
    }

    func refreshVotes() async {
        let keys = newsBrief?.sections.flatMap { $0.stories.map(\.key) } ?? []
        newsVotes = (try? await store.votes(forStoryKeys: keys)) ?? [:]
    }

    func feedback(_ story: NewsBrief.Story?, _ vote: NewsFeedback.Vote, topic: String? = nil, note: String? = nil) {
        let f = NewsFeedback(storyKey: story?.key, title: story?.title, vote: vote, topic: topic, note: note)
        if let key = story?.key, vote == .up || vote == .down { newsVotes[key] = vote }
        Task {
            try? await store.addFeedback(f)
            // Free-text notes and topic changes are applied right away; votes batch until the next brief.
            if vote == .note || vote == .more || vote == .less { applyNewsFeedback() }
        }
    }

    /// 👍/👎 on a raw article in the Live feed; feeds the same preference learning as brief stories.
    func feedback(article: Article, _ vote: NewsFeedback.Vote) {
        let key = "article:" + article.id
        newsVotes[key] = vote
        Task { try? await store.addFeedback(NewsFeedback(storyKey: key, title: "\(article.title) (\(article.source))", vote: vote)) }
    }

    func applyNewsFeedback() {
        guard !preferencesUpdating else { return }
        preferencesUpdating = true
        Task {
            defer { preferencesUpdating = false }
            do {
                if let update = try await news.applyFeedback(), !update.alertKeywords.isEmpty {
                    updateConfig { $0.newsAlertKeywords = update.alertKeywords }
                }
            } catch {
                newsStatus = "Couldn't update preferences: \(error.localizedDescription)"
            }
        }
    }

    func goDeeper(_ story: NewsBrief.Story) {
        aiPanel = AIPanel(title: "Go deeper", subtitle: story.title, url: story.urls.first)
        let panelID = aiPanel?.id
        Task {
            do {
                let text = try await news.goDeeper(story)
                if aiPanel?.id == panelID { aiPanel?.text = text }
            } catch {
                if aiPanel?.id == panelID { aiPanel?.error = error.localizedDescription }
            }
        }
    }

    // MARK: Scheduler (runs every minute)

    func tick(now: Date = Date()) {
        flushHeldIfDue(now: now)
        calendar.reload()
        if config.weeklyReportEnabled, Calendar.current.component(.weekday, from: now) == config.weeklyReportWeekday,
           let due = Self.dueTime(config.weeklyReportTime, now: now) {
            Task {
                if await shouldRun(lastKey: "report.weekly.at", due: due, now: now) { generateWeekly(notify: true) }
            }
        }
        if lastNewsCollect.map({ now.timeIntervalSince($0) >= config.newsInterval }) ?? true, !newsRunning {
            lastNewsCollect = now
            Task { await collectNews() }
        }
        Task {
            let isWeekday = !Calendar.current.isDateInWeekend(now)
            if config.workBriefEnabled, isWeekday || !config.workBriefWeekdaysOnly,
               let due = Self.dueTime(config.workBriefTime, now: now),
               await shouldRun(lastKey: "brief.work.at", due: due, now: now) {
                generateWorkBrief(notify: true)
            }
            for time in config.newsBriefTimes {
                if let due = Self.dueTime(time, now: now), await shouldRun(lastKey: "news.brief.at", due: due, now: now) {
                    generateNewsBrief(notify: true)
                    break
                }
            }
        }
    }

    /// Today's occurrence of "HH:mm" if it has passed within the last 6 hours (catches up after sleep).
    static func dueTime(_ hhmm: String, now: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let due = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) else { return nil }
        return (due <= now && now.timeIntervalSince(due) < 6 * 3600) ? due : nil
    }

    func shouldRun(lastKey: String, due: Date, now: Date) async -> Bool {
        let last = await store.value(lastKey).flatMap(Dates.parseISO) ?? .distantPast
        return last < due
    }

    // MARK: Windows

    func showDashboard(_ item: SidebarItem? = nil) {
        if let item { selection = item }
        DashboardWindow.shared.show(model: self)
    }
}

extension Array where Element == FeedItem {
    func sortedByUpdate() -> [FeedItem] { sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) } }
}
