import Foundation

public struct GitHubUser: Codable, Sendable, Hashable {
    public var id: Int
    public var login: String
    public var name: String?
}

/// Decodes `T` or nothing, so one odd element (e.g. an issue in a PR search) doesn't fail the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct GHNodes<T: Decodable>: Decodable {
    let nodes: [Lossy<T>]?
    var values: [T] { (nodes ?? []).compactMap(\.value) }
}

struct GHCount: Decodable { let totalCount: Int }

struct GHActor: Decodable {
    let login: String
    let name: String?
}

/// A pull request as returned by the GraphQL `search` connection (see `GitHubClient.prFields`).
struct GHPullRequest: Decodable {
    struct Repo: Decodable { let nameWithOwner: String }
    struct CommitNode: Decodable {
        struct Commit: Decodable {
            struct Rollup: Decodable { let state: String }
            let oid: String
            let statusCheckRollup: Rollup?
        }
        let commit: Commit
    }
    struct Review: Decodable { let state: String; let author: GHActor? }
    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String?; let name: String? }
        let requestedReviewer: Reviewer?
    }

    let number: Int
    let title: String
    let url: String
    let createdAt: Date?
    let updatedAt: Date?
    let isDraft: Bool?
    let headRefName: String?
    let baseRefName: String?
    let mergeable: String?
    let reviewDecision: String?
    let author: GHActor?
    let repository: Repo
    let comments: GHCount?
    let commits: GHNodes<CommitNode>?
    let latestOpinionatedReviews: GHNodes<Review>?
    let reviewRequests: GHNodes<ReviewRequest>?
    // Report fields
    let state: String?
    let mergedAt: Date?
    let changedFiles: Int?
}

struct GHSearch: Decodable {
    let nodes: [Lossy<GHPullRequest>]?
    var pulls: [GHPullRequest] { (nodes ?? []).compactMap(\.value) }
}

public struct GitHubNotification: Decodable, Sendable {
    public struct Subject: Decodable, Sendable { public var title: String; public var url: String?; public var type: String }
    public struct Repository: Decodable, Sendable {
        public var fullName: String
        public var htmlUrl: String?
        enum CodingKeys: String, CodingKey { case fullName = "full_name"; case htmlUrl = "html_url" }
    }
    public var id: String
    public var reason: String
    public var updatedAt: Date?
    public var subject: Subject
    public var repository: Repository
    enum CodingKeys: String, CodingKey { case id, reason, subject, repository; case updatedAt = "updated_at" }
}

public struct GitHubWorkflowRun: Decodable, Sendable {
    public var id: Int
    public var runNumber: Int?
    public var name: String?
    public var headBranch: String?
    public var headSha: String?
    public var event: String?
    public var status: String?
    public var conclusion: String?
    public var htmlUrl: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name, event, status, conclusion
        case runNumber = "run_number"
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Mapped onto the GitLab pipeline vocabulary the UI and rules already use.
    public var normalizedStatus: String {
        switch status {
        case "completed":
            switch conclusion {
            case "success": return "success"
            case "failure", "timed_out", "startup_failure": return "failed"
            case "cancelled": return "canceled"
            case "action_required": return "manual"
            default: return "skipped"
            }
        case "in_progress": return "running"
        default: return "pending"
        }
    }
}

struct GitHubRuns: Decodable {
    let workflowRuns: [GitHubWorkflowRun]
    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

struct GitHubEvent: Decodable {
    struct Repo: Decodable { let name: String }
    let type: String
    let repo: Repo
}

struct GitHubPull: Decodable {
    struct Ref: Decodable { let ref: String? }
    let title: String
    let body: String?
    let head: Ref?
    let base: Ref?
    let user: GHActor?
}

struct GitHubFile: Decodable {
    let filename: String
    let previousFilename: String?
    let status: String
    let patch: String?
    enum CodingKeys: String, CodingKey { case filename, status, patch; case previousFilename = "previous_filename" }
}
