import Foundation

public struct Reportee: Codable, Hashable, Sendable, Identifiable {
    public var email: String
    /// Resolved GitLab username; nil until resolved (or entered manually).
    public var username: String?
    public var name: String?
    public var id: String { email.lowercased() }

    public init(email: String, username: String? = nil, name: String? = nil) {
        self.email = email
        self.username = username
        self.name = name
    }
}

public struct JiraFilterConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var notifyNew: Bool
    public var notifyStatus: Bool

    public init(id: String, name: String, notifyNew: Bool = true, notifyStatus: Bool = true) {
        self.id = id
        self.name = name
        self.notifyNew = notifyNew
        self.notifyStatus = notifyStatus
    }
}

public struct WebPanel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String

    public init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// Non-secret settings persisted as JSON. Every field has a default so older files keep decoding.
public struct AppConfig: Codable, Equatable, Sendable {
    public var reportees: [Reportee] = []
    public var jiraFilters: [JiraFilterConfig] = []
    /// GitLab project paths whose pipelines (triggered by me) are always watched.
    public var pinnedProjects: [String] = []
    /// EventCategory.rawValue → enabled. Missing keys fall back to the category default.
    public var notifications: [String: Bool] = [:]
    /// itemId → muted until. `.distantFuture` = muted forever.
    public var mutedItems: [String: Date] = [:]

    public var gitlabInterval: Double = 60
    public var jiraInterval: Double = 120
    public var newsInterval: Double = 1800

    public var workBriefEnabled = true
    public var workBriefTime = "09:30"
    public var workBriefWeekdaysOnly = true

    public var newsBriefTimes: [String] = ["08:30"]
    public var newsGapCheck = true
    public var newsMajorAlerts = true
    public var newsAlertKeywords: [String] = AppConfig.defaultAlertKeywords
    public var newsRegion = ""
    public var newsSources: [NewsSource] = NewsSource.defaults

    /// Empty = auto-detect (see `resolvedClaudePath`).
    public var claudePath = ""
    /// Empty = whatever the CLI defaults to.
    public var claudeModel = ""
    public var autoSummarizeReporteeMRs = false

    public var webPanels: [WebPanel] = []
    public var launchAtLogin = true

    /// Low-priority notifications are held and delivered as a digest (urgent ones always go straight through).
    public var batchLowPriority = true
    public var batchIntervalMinutes: Double = 60
    /// Also hold urgent-but-not-critical alerts while a calendar event marked busy is in progress.
    public var quietDuringMeetings = true
    public var urgentCategories: [String] = AppConfig.defaultUrgent

    public var calendarEnabled = true
    public var paletteEnabled = true
    /// AVSpeechSynthesisVoice identifier; empty = best available English voice.
    public var speechVoice = ""
    public var speechRate: Double = 0.5

    public var weeklyReportEnabled = true
    /// 1 = Sunday … 7 = Saturday (Calendar weekday).
    public var weeklyReportWeekday = 6
    public var weeklyReportTime = "16:00"

    public init() {}

    public static let defaultUrgent = [
        EventCategory.pipelineFailedMR, .pipelineFailedTriggered, .todoReview, .todoMention, .jiraMention, .jiraAssigned, .newsMajor,
    ].map(\.rawValue)

    public func isUrgent(_ c: EventCategory) -> Bool { urgentCategories.contains(c.rawValue) }

    public static let defaultAlertKeywords = [
        "AI", "LLM", "Claude", "Anthropic", "OpenAI", "GPT", "Gemini", "Llama", "Ollama", "open-weight",
        "Swift", "Apple", "macOS", "Golang", "Go 1.", "GitLab", "Jira",
    ]

    public func isEnabled(_ category: EventCategory) -> Bool {
        notifications[category.rawValue] ?? category.defaultEnabled
    }

    public func isMuted(_ itemId: String?, now: Date = Date()) -> Bool {
        guard let itemId, let until = mutedItems[itemId] else { return false }
        return until > now
    }

    /// The configured path, or the first `claude` found in the usual install locations.
    public var expandedClaudePath: String {
        let configured = (claudePath as NSString).expandingTildeInPath
        if !configured.isEmpty { return configured }
        return Self.detectClaude() ?? "\(NSHomeDirectory())/.local/bin/claude"
    }

    public static func detectClaude(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = NSHomeDirectory()
        var candidates = [environment["CLAUDE_PATH"]].compactMap { $0 }
        candidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                       "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Persistence

    public static func load(from url: URL = AppInfo.configURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        return (try? JSONDecoder.everboard.decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func save(to url: URL = AppInfo.configURL) throws {
        let enc = JSONEncoder.everboard
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Lenient decoding

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        reportees = v(.reportees, d.reportees)
        jiraFilters = v(.jiraFilters, d.jiraFilters)
        pinnedProjects = v(.pinnedProjects, d.pinnedProjects)
        notifications = v(.notifications, d.notifications)
        mutedItems = v(.mutedItems, d.mutedItems)
        gitlabInterval = v(.gitlabInterval, d.gitlabInterval)
        jiraInterval = v(.jiraInterval, d.jiraInterval)
        newsInterval = v(.newsInterval, d.newsInterval)
        workBriefEnabled = v(.workBriefEnabled, d.workBriefEnabled)
        workBriefTime = v(.workBriefTime, d.workBriefTime)
        workBriefWeekdaysOnly = v(.workBriefWeekdaysOnly, d.workBriefWeekdaysOnly)
        newsBriefTimes = v(.newsBriefTimes, d.newsBriefTimes)
        newsGapCheck = v(.newsGapCheck, d.newsGapCheck)
        newsMajorAlerts = v(.newsMajorAlerts, d.newsMajorAlerts)
        newsAlertKeywords = v(.newsAlertKeywords, d.newsAlertKeywords)
        newsRegion = v(.newsRegion, d.newsRegion)
        newsSources = v(.newsSources, d.newsSources)
        claudePath = v(.claudePath, d.claudePath)
        claudeModel = v(.claudeModel, d.claudeModel)
        autoSummarizeReporteeMRs = v(.autoSummarizeReporteeMRs, d.autoSummarizeReporteeMRs)
        webPanels = v(.webPanels, d.webPanels)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        batchLowPriority = v(.batchLowPriority, d.batchLowPriority)
        batchIntervalMinutes = v(.batchIntervalMinutes, d.batchIntervalMinutes)
        quietDuringMeetings = v(.quietDuringMeetings, d.quietDuringMeetings)
        urgentCategories = v(.urgentCategories, d.urgentCategories)
        calendarEnabled = v(.calendarEnabled, d.calendarEnabled)
        paletteEnabled = v(.paletteEnabled, d.paletteEnabled)
        speechVoice = v(.speechVoice, d.speechVoice)
        speechRate = v(.speechRate, d.speechRate)
        weeklyReportEnabled = v(.weeklyReportEnabled, d.weeklyReportEnabled)
        weeklyReportWeekday = v(.weeklyReportWeekday, d.weeklyReportWeekday)
        weeklyReportTime = v(.weeklyReportTime, d.weeklyReportTime)
    }

    enum CodingKeys: String, CodingKey {
        case reportees, jiraFilters, pinnedProjects, notifications, mutedItems
        case gitlabInterval, jiraInterval, newsInterval
        case workBriefEnabled, workBriefTime, workBriefWeekdaysOnly
        case newsBriefTimes, newsGapCheck, newsMajorAlerts, newsAlertKeywords, newsRegion, newsSources
        case claudePath, claudeModel, autoSummarizeReporteeMRs, webPanels, launchAtLogin
        case batchLowPriority, batchIntervalMinutes, quietDuringMeetings, urgentCategories
        case calendarEnabled, paletteEnabled, speechVoice, speechRate
        case weeklyReportEnabled, weeklyReportWeekday, weeklyReportTime
    }
}
