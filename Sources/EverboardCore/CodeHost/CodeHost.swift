import Foundation

/// A Git hosting product Everboard can track merge/pull requests, CI and to-dos on.
public enum CodeHostKind: String, Codable, Sendable, CaseIterable {
    case gitlab, github

    public var displayName: String { self == .gitlab ? "GitLab" : "GitHub" }
    /// Env var prefix: `GITLAB_URL`, `GITHUB_WORK_TOKEN`, …
    public var envPrefix: String { rawValue.uppercased() }
    public var defaultURL: URL { URL(string: self == .gitlab ? "https://gitlab.com" : "https://github.com")! }
    /// What this host calls a change: "MR" / "PR".
    public var changeNoun: String { self == .gitlab ? "MR" : "PR" }
}

/// One configured account on a code host, from the secrets file / environment:
/// `GITLAB_URL` + `GITLAB_TOKEN` (default GitLab), `GITHUB_URL` + `GITHUB_TOKEN` (default GitHub), and any number of
/// named extras like `GITLAB_WORK_URL` + `GITLAB_WORK_TOKEN` or `GITHUB_OSS_TOKEN`. `…_ORGS` optionally limits an
/// account to some groups/orgs (comma-separated).
public struct CodeHostAccount: Sendable, Hashable, Identifiable {
    public var kind: CodeHostKind
    /// Lower-case label for named accounts ("work"); nil for the default account of a kind.
    public var name: String?
    public var webURL: URL
    public var token: String
    /// Group / org paths to keep (lower-case). Empty = everything the token can see.
    public var orgs: [String]

    public init(kind: CodeHostKind, name: String? = nil, webURL: URL, token: String, orgs: [String] = []) {
        self.kind = kind
        self.name = name?.lowercased()
        self.webURL = webURL
        self.token = token
        self.orgs = orgs.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }.filter { !$0.isEmpty }
    }

    /// "gitlab", "github", "gitlab.work". The default GitLab id is unchanged from single-account versions,
    /// so its stored items, scopes and mutes carry over.
    public var id: String { name.map { "\(kind.rawValue).\($0)" } ?? kind.rawValue }

    public var displayName: String { name.map { "\(kind.displayName) · \($0)" } ?? kind.displayName }

    public var host: String { webURL.host ?? webURL.absoluteString }

    public var isGitHubDotCom: Bool { kind == .github && ["github.com", "www.github.com"].contains(webURL.host?.lowercased() ?? "") }

    public func scope(_ s: CodeScope) -> String { "\(id).\(s.rawValue)" }

    /// Event ids stay as they were for the default GitLab account; other accounts are namespaced.
    public func eventID(_ raw: String) -> String { id == "gitlab" ? raw : "\(id):\(raw)" }

    /// True when `path` ("group/sub/project", "owner/repo") belongs to one of `orgs`, or no orgs are set.
    public func includes(path: String) -> Bool {
        guard !orgs.isEmpty else { return true }
        let p = path.lowercased()
        return orgs.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
}

/// The lists every code-host source keeps, stored as scope `<account id>.<rawValue>`.
public enum CodeScope: String, CaseIterable, Sendable {
    case mine = "mr.mine"
    case review = "mr.review"
    case assigned = "mr.assigned"
    case reportees = "mr.reportees"
    case todos = "todos"
    /// Prefix: one scope per project/repo, e.g. `gitlab.pipelines.p42`.
    case pipelines = "pipelines."
}

public enum ChangeState: Sendable { case merged, open, all }

/// The account user, normalised across hosts.
public struct CodeHostUser: Codable, Sendable, Hashable {
    public var id: String
    public var username: String
    public var name: String

    public init(id: String, username: String, name: String) {
        self.id = id
        self.username = username
        self.name = name
    }
}

/// An MR/PR as returned by list/search endpoints: reports, team metrics and remote search.
public struct ChangeRecord: Sendable, Hashable, Identifiable {
    /// Same id the feed item for this change would have, so search results de-duplicate against local data.
    public var id: String
    /// "group/project!12" or "owner/repo#12".
    public var ref: String
    public var title: String
    public var url: String
    public var state: String
    public var createdAt: Date?
    public var mergedAt: Date?
    public var updatedAt: Date?
    public var authorUsername: String?
    public var authorName: String?
    public var comments: Int?
    public var filesChanged: Int?

    public init(id: String, ref: String, title: String, url: String, state: String, createdAt: Date? = nil, mergedAt: Date? = nil,
                updatedAt: Date? = nil, authorUsername: String? = nil, authorName: String? = nil, comments: Int? = nil,
                filesChanged: Int? = nil) {
        self.id = id
        self.ref = ref
        self.title = title
        self.url = url
        self.state = state
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.updatedAt = updatedAt
        self.authorUsername = authorUsername
        self.authorName = authorName
        self.comments = comments
        self.filesChanged = filesChanged
    }
}

/// Title, description and branches of one MR/PR, for AI summaries.
public struct ChangeDetail: Sendable {
    public var title: String
    public var description: String?
    public var sourceBranch: String?
    public var targetBranch: String?
    public var authorName: String?
}

public struct FileDiff: Sendable {
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile: Bool
    public var deletedFile: Bool
}

/// What the app needs from a code host beyond polling. Methods taking a `FeedItem` read the ids the
/// host's source stored in `attrs` (`projectId`, `iid`, `pipelineId`, …).
public protocol CodeHostClient: Sendable {
    var account: CodeHostAccount { get }
    func currentUser() async throws -> CodeHostUser
    /// Best-effort email → user (hosts only match public emails for normal tokens).
    func resolveUser(email: String) async throws -> CodeHostUser?
    func changeDetail(_ item: FeedItem) async throws -> ChangeDetail
    func changeDiffs(_ item: FeedItem) async throws -> [FileDiff]
    func approve(_ item: FeedItem) async throws
    func comment(_ item: FeedItem, body: String) async throws
    /// Re-runs the failed pipeline/workflow behind an MR/PR or pipeline item.
    func retryPipeline(_ item: FeedItem) async throws
    func markTodoDone(_ item: FeedItem) async throws
    func searchChanges(_ text: String, limit: Int) async throws -> [ChangeRecord]
    /// Changes by `author` or reviewed by `reviewer` updated since `since`. `withSize` fills `filesChanged` (may cost extra calls).
    func changes(author: String?, reviewer: String?, state: ChangeState, since: Date, withSize: Bool) async throws -> [ChangeRecord]
    /// Web search page for `text`, opened as a palette fallback.
    func searchPageURL(_ text: String) -> String
    /// Web URL of change `number` in `path`.
    func changeURL(path: String, number: String) -> String
    /// Scope the token needs for write actions, shown when one is refused.
    var writeScopeHint: String { get }
}

public enum CodeHosts {
    public static func client(for account: CodeHostAccount, session: URLSession = .everboard) -> CodeHostClient {
        switch account.kind {
        case .gitlab: return GitLabClient(account: account, session: session)
        case .github: return GitHubClient(account: account, session: session)
        }
    }

    public static func source(for account: CodeHostAccount, interval: TimeInterval, session: URLSession = .everboard) -> DataSource {
        switch account.kind {
        case .gitlab: return GitLabSource(client: GitLabClient(account: account, session: session), interval: interval)
        case .github: return GitHubSource(client: GitHubClient(account: account, session: session), interval: interval)
        }
    }

    /// The account an item came from. Items stored before multi-account support have no `account` attr and are GitLab's.
    public static func accountID(of item: FeedItem) -> String { item["account"] ?? item.source }

    /// Name for the Home greeting from any account's cached user (`<id>.me`).
    public static func cachedName(store: Store, accounts: [CodeHostAccount]) async -> String? {
        struct Named: Decodable { let name: String?; let username: String?; let login: String? }
        for a in accounts {
            guard let json = await store.value("\(a.id).me"),
                  let u = try? JSONDecoder().decode(Named.self, from: Data(json.utf8)) else { continue }
            if let n = u.name ?? u.username ?? u.login, !n.isEmpty { return n }
        }
        return nil
    }

    /// Feed items of one list across all accounts.
    public static func items(_ scope: CodeScope, accounts: [CodeHostAccount], store: Store, presentOnly: Bool = true) async throws -> [FeedItem] {
        var out: [FeedItem] = []
        for a in accounts {
            out += scope == .pipelines
                ? try await store.items(scopePrefix: a.scope(scope), presentOnly: presentOnly)
                : try await store.items(scope: a.scope(scope), presentOnly: presentOnly)
        }
        return out
    }
}

extension Array where Element == CodeHostClient {
    public func client(for item: FeedItem) -> CodeHostClient? {
        let id = CodeHosts.accountID(of: item)
        return first { $0.account.id == id }
    }

    public var accounts: [CodeHostAccount] { map(\.account) }
}

extension FeedItem {
    /// An MR or PR (as opposed to a to-do, pipeline or Jira issue).
    public var isCodeChange: Bool { kind.hasPrefix("mr.") && (source == "gitlab" || source == "github") }
}
