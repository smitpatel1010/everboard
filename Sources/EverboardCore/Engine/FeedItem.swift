import Foundation

/// Normalised record every source produces. Source-specific detail lives in `attrs`.
public struct FeedItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var source: String
    public var kind: String
    public var title: String
    public var subtitle: String
    public var url: String?
    public var status: String?
    public var author: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var attrs: [String: String]

    public init(id: String, source: String, kind: String, title: String, subtitle: String = "",
                url: String? = nil, status: String? = nil, author: String? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil, attrs: [String: String] = [:]) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.status = status
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attrs = attrs
    }

    public subscript(attr: String) -> String? { attrs[attr] }
}

/// What notifications and the inbox are grouped by; each has a user toggle.
public enum EventCategory: String, CaseIterable, Codable, Sendable {
    case pipelineFailedMR = "gitlab.pipeline.failed.mr"
    case pipelineFailedTriggered = "gitlab.pipeline.failed.triggered"
    case reporteeNewMR = "gitlab.mr.reportee.new"
    case todoReview = "gitlab.todo.review"
    case todoMention = "gitlab.todo.mention"
    case todoOther = "gitlab.todo.other"
    case jiraAssigned = "jira.assigned"
    case jiraComment = "jira.comment"
    case jiraMention = "jira.mention"
    case jiraFilterNew = "jira.filter.new"
    case jiraFilterStatus = "jira.filter.status"
    case workBriefReady = "brief.work.ready"
    case newsBriefReady = "news.brief.ready"
    case newsMajor = "news.major"
    case newsFollow = "news.follow"
    case reportReady = "report.ready"

    public var label: String {
        switch self {
        case .pipelineFailedMR: return "Pipeline / checks failed on my MR or PR"
        case .pipelineFailedTriggered: return "Pipeline or workflow run I triggered failed"
        case .reporteeNewMR: return "Reportee opened an MR or PR"
        case .todoReview: return "Review requested from me"
        case .todoMention: return "Mentioned in GitLab or GitHub"
        case .todoOther: return "Other to-dos and notifications (assigned, approval, unmergeable)"
        case .jiraAssigned: return "Jira issue assigned to me"
        case .jiraComment: return "New comment on my Jira issues"
        case .jiraMention: return "Mentioned in Jira"
        case .jiraFilterNew: return "New issue in a watched filter"
        case .jiraFilterStatus: return "Status change in a watched filter"
        case .workBriefReady: return "Work brief ready"
        case .newsBriefReady: return "World & Tech brief ready"
        case .newsMajor: return "Major story alert"
        case .newsFollow: return "Update on a story I follow"
        case .reportReady: return "Weekly report / team health ready"
        }
    }

    public var defaultEnabled: Bool { true }

    public var source: String {
        switch self {
        case .pipelineFailedMR, .pipelineFailedTriggered, .reporteeNewMR, .todoReview, .todoMention, .todoOther: return "code"
        case .jiraAssigned, .jiraComment, .jiraMention, .jiraFilterNew, .jiraFilterStatus: return "jira"
        case .workBriefReady, .reportReady: return "brief"
        case .newsBriefReady, .newsMajor, .newsFollow: return "news"
        }
    }
}

/// Something that happened, shown in the inbox and possibly notified.
/// `id` is deterministic so the same real-world event seen via two paths is stored once.
public struct AppEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ts: Date
    public var category: EventCategory
    public var title: String
    public var body: String
    public var url: String?
    public var scope: String?
    public var itemId: String?
    public var read: Bool
    /// When false the event only lands in the inbox (e.g. a per-filter toggle is off).
    public var wantsNotification: Bool

    public init(id: String, ts: Date = Date(), category: EventCategory, title: String, body: String,
                url: String? = nil, scope: String? = nil, itemId: String? = nil,
                read: Bool = false, wantsNotification: Bool = true) {
        self.id = id
        self.ts = ts
        self.category = category
        self.title = title
        self.body = body
        self.url = url
        self.scope = scope
        self.itemId = itemId
        self.read = read
        self.wantsNotification = wantsNotification
    }
}
