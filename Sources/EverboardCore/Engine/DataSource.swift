import Foundation

/// How a fetched scope relates to what's stored.
public enum ScopeMode: String, Sendable {
    /// The fetch is the complete current set; stored items missing from it are marked not-present.
    case replace
    /// The fetch is incremental (e.g. `updated_after`); only upsert, prune by age.
    case accumulate
}

/// One logical list a source fetched, e.g. "gitlab.mr.mine" or "jira.filter.10042".
public struct ScopeResult: Sendable {
    public var scope: String
    public var mode: ScopeMode
    public var items: [FeedItem]

    public init(scope: String, mode: ScopeMode, items: [FeedItem]) {
        self.scope = scope
        self.mode = mode
        self.items = items
    }
}

/// A fetched item compared with what we knew before.
public struct ItemChange: Sendable {
    public var scope: String
    public var old: FeedItem?
    public var new: FeedItem
    /// Present in the previous snapshot of this scope.
    public var wasPresent: Bool
    /// Ever seen in this scope (survives the item dropping out of a bounded query).
    public var everSeen: Bool

    public init(scope: String, old: FeedItem?, new: FeedItem, wasPresent: Bool, everSeen: Bool) {
        self.scope = scope
        self.old = old
        self.new = new
        self.wasPresent = wasPresent
        self.everSeen = everSeen
    }
}

/// Read-only view of persisted state a source may need while fetching (cursors, known items).
public protocol FetchContext: Sendable {
    func value(_ key: String) async -> String?
    func setValue(_ key: String, _ value: String?) async
    func items(scopePrefix: String, presentOnly: Bool) async -> [FeedItem]
    var config: AppConfig { get }
}

/// A pollable integration (GitLab, Jira, news, later personal sources).
public protocol DataSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var interval: TimeInterval { get }
    func fetch(context: FetchContext) async throws -> [ScopeResult]
    /// Turn one item change into zero or more events. Called for every fetched item, never on baseline.
    func events(for change: ItemChange, config: AppConfig) -> [AppEvent]
}

/// Health of a source, shown as status chips in the menu bar and dashboard.
public enum SourceHealth: Sendable, Equatable {
    case idle
    case ok(Date)
    case unreachable(String)
    case authFailed(String)
    case failing(String)
    case notConfigured(String)

    public var label: String {
        switch self {
        case .idle: return "Starting…"
        case .ok(let d):
            let age = Dates.age(d)
            return age == "now" ? "Updated just now" : "Updated \(age) ago"
        case .unreachable(let m): return m
        case .authFailed(let m): return m
        case .failing(let m): return m
        case .notConfigured(let m): return m
        }
    }

    public var isHealthy: Bool { if case .ok = self { return true }; return false }
}
