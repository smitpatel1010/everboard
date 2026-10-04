import Foundation

public struct JiraUser: Codable, Sendable, Hashable {
    public var accountId: String
    public var displayName: String?
    public var emailAddress: String?
}

public struct JiraIssue: Decodable, Sendable {
    public struct Named: Decodable, Sendable { public var name: String }
    public struct Status: Decodable, Sendable {
        public struct Category: Decodable, Sendable { public var key: String }
        public var name: String
        public var statusCategory: Category?
    }
    public struct Fields: Decodable, Sendable {
        public var summary: String?
        public var status: Status?
        public var assignee: JiraUser?
        public var reporter: JiraUser?
        public var priority: Named?
        public var issuetype: Named?
        public var updated: Date?
        public var created: Date?
        public var duedate: String?
        public var description: JSONValue?
    }
    public var id: String
    public var key: String
    public var fields: Fields
    public var renderedFields: [String: JSONValue]?
}

struct JiraSearchResponse: Decodable {
    let issues: [JiraIssue]
    let nextPageToken: String?
    let isLast: Bool?
}

public struct JiraFilter: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var jql: String?
    public var viewUrl: String?
}

public struct JiraComment: Decodable, Sendable {
    public var id: String
    public var author: JiraUser?
    public var body: JSONValue?
    public var created: Date?
    public var updated: Date?
}

struct JiraCommentPage: Decodable { let comments: [JiraComment] }

/// Atlassian Document Format helpers.
public enum ADF {
    /// Flattens an ADF document to readable text, rendering mentions as @Name.
    public static func plainText(_ doc: JSONValue?) -> String {
        guard let doc else { return "" }
        if let s = doc.stringValue { return s } // API v2-style plain strings
        var out = ""
        func visit(_ node: JSONValue) {
            let type = node["type"]?.stringValue
            switch type {
            case "text": out += node["text"]?.stringValue ?? ""
            case "mention": out += node["attrs"]?["text"]?.stringValue ?? "@someone"
            case "hardBreak": out += "\n"
            case "emoji": out += node["attrs"]?["text"]?.stringValue ?? ""
            case "inlineCard": out += node["attrs"]?["url"]?.stringValue ?? ""
            default: break
            }
            for child in node["content"]?.arrayValue ?? [] { visit(child) }
            if ["paragraph", "heading", "listItem", "codeBlock", "blockquote", "tableRow"].contains(type ?? "") { out += "\n" }
        }
        visit(doc)
        return out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func mentions(_ doc: JSONValue?, accountId: String) -> Bool {
        guard let doc else { return false }
        var found = false
        doc.walk { node in
            if node["type"]?.stringValue == "mention", node["attrs"]?["id"]?.stringValue == accountId { found = true }
        }
        return found
    }
}

public enum JQL {
    /// Strips a trailing ORDER BY so the clause can be wrapped in parentheses and combined.
    public static func stripOrderBy(_ jql: String) -> String {
        jql.replacingOccurrences(of: "(?is)\\s*order\\s+by\\s+.*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
