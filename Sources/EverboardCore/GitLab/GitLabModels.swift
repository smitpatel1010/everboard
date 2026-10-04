import Foundation

public struct GitLabUser: Codable, Sendable, Hashable {
    public var id: Int
    public var username: String
    public var name: String
    public var email: String?
    public var webUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name, email
        case webUrl = "web_url"
    }
}

struct GQLResponse<T: Decodable>: Decodable {
    struct GQLError: Decodable { let message: String }
    let data: T?
    let errors: [GQLError]?
}

struct GQLNodes<T: Decodable>: Decodable { let nodes: [T] }

struct GQLUserRef: Decodable { let username: String; let name: String? }

struct GQLPipeline: Decodable {
    let id: String
    let status: String
    let path: String?
    let updatedAt: Date?
}

struct GQLMergeRequest: Decodable {
    let id: String
    let iid: String
    let title: String
    let webUrl: String
    let createdAt: Date?
    let updatedAt: Date?
    let draft: Bool?
    let sourceBranch: String?
    let targetBranch: String?
    let detailedMergeStatus: String?
    let userNotesCount: Int?
    let author: GQLUserRef?
    let project: Project
    let headPipeline: GQLPipeline?
    let approvedBy: GQLNodes<GQLUserRef>?
    let reviewers: GQLNodes<GQLUserRef>?

    struct Project: Decodable { let id: String; let fullPath: String }
}

struct GQLCurrentUserMRs: Decodable {
    struct CurrentUser: Decodable {
        let username: String
        let authoredMergeRequests: GQLNodes<GQLMergeRequest>
        let reviewRequestedMergeRequests: GQLNodes<GQLMergeRequest>
        let assignedMergeRequests: GQLNodes<GQLMergeRequest>
    }
    let currentUser: CurrentUser
}

struct GQLUsersMRs: Decodable {
    struct User: Decodable {
        let username: String
        let name: String
        let authoredMergeRequests: GQLNodes<GQLMergeRequest>
    }
    let users: GQLNodes<User>
}

public struct GitLabPipeline: Codable, Sendable {
    public var id: Int
    public var iid: Int?
    public var projectId: Int
    public var ref: String?
    public var status: String
    public var source: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var webUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, iid, ref, status, source
        case projectId = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case webUrl = "web_url"
    }
}

public struct GitLabTodo: Codable, Sendable {
    public struct Author: Codable, Sendable, Hashable { public var username: String; public var name: String }
    public struct Project: Codable, Sendable {
        public var pathWithNamespace: String?
        enum CodingKeys: String, CodingKey { case pathWithNamespace = "path_with_namespace" }
    }
    public struct Target: Codable, Sendable { public var title: String?; public var iid: Int? }

    public var id: Int
    public var actionName: String
    public var targetType: String?
    public var targetUrl: String?
    public var body: String?
    public var createdAt: Date?
    public var author: Author?
    public var project: Project?
    public var target: Target?

    enum CodingKeys: String, CodingKey {
        case id, body, author, project, target
        case actionName = "action_name"
        case targetType = "target_type"
        case targetUrl = "target_url"
        case createdAt = "created_at"
    }
}

struct GitLabEvent: Decodable {
    let projectId: Int?
    enum CodingKeys: String, CodingKey { case projectId = "project_id" }
}

struct GitLabProject: Decodable {
    let id: Int
    let pathWithNamespace: String
    enum CodingKeys: String, CodingKey { case id; case pathWithNamespace = "path_with_namespace" }
}

public struct GitLabMRDetail: Decodable, Sendable {
    public var title: String
    public var description: String?
    public var sourceBranch: String?
    public var targetBranch: String?
    public var author: GitLabTodo.Author?
    enum CodingKeys: String, CodingKey {
        case title, description, author
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
    }
}

public struct GitLabDiff: Decodable, Sendable {
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile: Bool?
    public var deletedFile: Bool?
    enum CodingKeys: String, CodingKey {
        case diff
        case oldPath = "old_path"
        case newPath = "new_path"
        case newFile = "new_file"
        case deletedFile = "deleted_file"
    }
}

enum GitLabID {
    /// "gid://gitlab/Project/123" → "123"
    static func numeric(_ gid: String) -> String { gid.split(separator: "/").last.map(String.init) ?? gid }
}

public enum JiraKeys {
    /// Finds Jira keys like ABC-123 in MR titles / branches (branches often use lower case).
    public static func find(in texts: [String?]) -> [String] {
        let regex = try! NSRegularExpression(pattern: "(?i)\\b([a-z][a-z0-9]{1,9}-[0-9]{1,6})\\b")
        var out: [String] = []
        for t in texts.compactMap({ $0 }) {
            let ns = t as NSString
            for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).uppercased()
                // Skip things like "UTF-8" or "SHA-256".
                if ["UTF", "SHA", "ISO", "RFC", "MD", "HTTP"].contains(where: key.hasPrefix) { continue }
                if !out.contains(key) { out.append(key) }
            }
        }
        return out
    }
}

/// MR as returned by the REST list endpoints (used for reports and team metrics).
public struct GitLabMR: Codable, Sendable, Hashable {
    public struct Ref: Codable, Sendable, Hashable { public var full: String? }
    public var id: Int
    public var iid: Int
    public var projectId: Int
    public var title: String
    public var webUrl: String
    public var state: String
    public var createdAt: Date?
    public var mergedAt: Date?
    public var updatedAt: Date?
    public var author: GitLabTodo.Author?
    public var userNotesCount: Int?
    public var references: Ref?
    public var changesCount: String?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, state, author, references
        case projectId = "project_id"
        case webUrl = "web_url"
        case createdAt = "created_at"
        case mergedAt = "merged_at"
        case updatedAt = "updated_at"
        case userNotesCount = "user_notes_count"
        case changesCount = "changes_count"
    }

    public var ref: String { references?.full ?? "!\(iid)" }
}
