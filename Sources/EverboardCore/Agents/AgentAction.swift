import Foundation

/// What an agent action can be run on.
public enum AgentTarget: String, Codable, Sendable, CaseIterable {
    /// Merge requests and pull requests.
    case change
    case pipeline
    /// Jira issues.
    case issue
    /// GitLab to-dos and GitHub notifications.
    case todo
    /// Items from custom (command / folder) sources.
    case custom

    public var label: String {
        switch self {
        case .change: return "MRs / PRs"
        case .pipeline: return "Pipelines"
        case .issue: return "Jira issues"
        case .todo: return "To-dos"
        case .custom: return "Custom feeds"
        }
    }

    public static func of(_ item: FeedItem) -> AgentTarget {
        if item.source == "custom" { return .custom }
        if item.isCodeChange { return .change }
        if item.kind == "pipeline" { return .pipeline }
        if item.kind == "todo" { return .todo }
        if item.source == "jira" { return .issue }
        return .custom
    }
}

/// A user-defined command you can run on an item, e.g. `claude -p "/deep-review {url}"`.
/// Everboard runs it only when you click it, shows its output, and keeps a history. It never posts the output anywhere.
public struct AgentAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Shell command line with `{placeholder}`s; see `AgentTemplate.placeholders`.
    public var command: String
    public var targets: [AgentTarget]
    /// Optional; may use placeholders (usually `{repoPath}`). Empty = `{repoPath}` when known, else a scratch folder.
    public var workingDirectory: String
    public var timeoutMinutes: Double
    /// Show the command and ask before running.
    public var confirm: Bool
    /// SF Symbol name for menus.
    public var icon: String

    public init(id: String = UUID().uuidString, name: String, command: String, targets: [AgentTarget] = [.change],
                workingDirectory: String = "", timeoutMinutes: Double = 15, confirm: Bool = true, icon: String = "terminal") {
        self.id = id
        self.name = name
        self.command = command
        self.targets = targets
        self.workingDirectory = workingDirectory
        self.timeoutMinutes = timeoutMinutes
        self.confirm = confirm
        self.icon = icon
    }

    public func applies(to item: FeedItem) -> Bool { targets.contains(AgentTarget.of(item)) }

    // Lenient decoding so hand-edited config files with missing keys still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        targets = (try? c.decodeIfPresent([AgentTarget].self, forKey: .targets)) ?? [.change]
        workingDirectory = (try? c.decodeIfPresent(String.self, forKey: .workingDirectory)) ?? ""
        timeoutMinutes = (try? c.decodeIfPresent(Double.self, forKey: .timeoutMinutes)) ?? 15
        confirm = (try? c.decodeIfPresent(Bool.self, forKey: .confirm)) ?? true
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? "terminal"
    }

    enum CodingKeys: String, CodingKey { case id, name, command, targets, workingDirectory, timeoutMinutes, confirm, icon }

    /// Starting points offered in Settings → Agents. Each only reads and reports; none posts anything.
    public static let examples: [AgentAction] = [
        AgentAction(id: "example.claude-review", name: "Claude: review this change",
                    command: #"claude -p "Review the merge/pull request at {url} ({projectPath} {iid}). Read the diff with the tools you have. Do not post comments or push anything; reply with findings only.""#,
                    targets: [.change], icon: "sparkles"),
        AgentAction(id: "example.claude-pipeline", name: "Claude: why did this fail?",
                    command: #"claude -p "Explain why the CI run at {url} failed and suggest a fix. Do not retry or change anything.""#,
                    targets: [.pipeline], icon: "stethoscope"),
        AgentAction(id: "example.claude-ticket", name: "Claude: plan this ticket",
                    command: #"claude -p "Draft an implementation plan for {jiraKey}: {title}. Ticket: {url}. Reply with the plan only.""#,
                    targets: [.issue], icon: "list.bullet.rectangle"),
        AgentAction(id: "example.cursor-review", name: "Cursor agent: review locally",
                    command: #"cursor-agent -p "Review the changes on branch {sourceBranch} against {targetBranch}. Report only; do not commit.""#,
                    targets: [.change], workingDirectory: "{repoPath}", icon: "cursorarrow.rays"),
    ]
}

/// Values available to a command template, read from a feed item and your config.
public enum AgentTemplate {
    /// Every placeholder a template may use, with a short description for Settings.
    public static let placeholders: [(name: String, help: String)] = [
        ("url", "web link of the item"),
        ("title", "item title"),
        ("id", "Everboard's item id"),
        ("kind", "change, pipeline, issue, todo or custom"),
        ("account", "code-host account id, e.g. gitlab or github.work"),
        ("projectPath", "group/project or owner/repo"),
        ("iid", "MR/PR number"),
        ("ref", "project!iid or owner/repo#number"),
        ("sourceBranch", "MR/PR source branch"),
        ("targetBranch", "MR/PR target branch"),
        ("pipelineId", "pipeline / workflow run id"),
        ("pipelineUrl", "pipeline / workflow run link"),
        ("jiraKey", "Jira key of the issue, or the first one linked from the MR/PR"),
        ("author", "author's display name"),
        ("status", "item status"),
        ("repoPath", "local checkout of the project (Settings → Agents → Local repositories)"),
        ("date", "today, yyyy-MM-dd"),
    ]

    public static let placeholderNames: Set<String> = Set(placeholders.map(\.name))

    /// Placeholder names used in `template`, in order of first use.
    public static func used(in template: String) -> [String] {
        var out: [String] = []
        for name in scan(template).compactMap({ if case .placeholder(let n, _) = $0 { return n }; return nil }) where !out.contains(name) {
            out.append(name)
        }
        return out
    }

    /// Placeholders in `template` that Everboard doesn't know (typos).
    public static func unknown(in template: String) -> [String] { used(in: template).filter { !placeholderNames.contains($0) } }

    /// Values for every known placeholder that the item has.
    public static func values(for item: FeedItem, repoPaths: [String: String] = [:], now: Date = Date()) -> [String: String] {
        var v: [String: String] = ["id": item.id, "title": item.title, "kind": AgentTarget.of(item).rawValue]
        v["url"] = item.url
        v["status"] = item.status
        v["account"] = item["account"] ?? (item.source == "jira" ? nil : item.source)
        v["projectPath"] = item["projectPath"]
        v["iid"] = item["iid"]
        v["sourceBranch"] = item["sourceBranch"]
        v["targetBranch"] = item["targetBranch"]
        v["pipelineId"] = item["pipelineId"]
        v["pipelineUrl"] = item["pipelineUrl"] ?? (item.kind == "pipeline" ? item.url : nil)
        v["author"] = item["authorName"] ?? item.author
        v["jiraKey"] = item["key"] ?? item["jiraKeys"]?.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        if item.isCodeChange, let p = item["projectPath"], let n = item["iid"] {
            v["ref"] = item.source == "github" ? "\(p)#\(n)" : "\(p)!\(n)"
        } else if !item.subtitle.isEmpty {
            v["ref"] = item.subtitle
        }
        if let p = item["projectPath"], let local = repoPath(for: p, in: repoPaths) { v["repoPath"] = local }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        v["date"] = f.string(from: now)
        return v.filter { !$0.value.isEmpty }
    }

    /// The local folder for `projectPath`: an exact key, else a key matching its last path component ("payments-api").
    public static func repoPath(for projectPath: String, in repoPaths: [String: String]) -> String? {
        let p = projectPath.lowercased()
        let hit = repoPaths.first { $0.key.lowercased() == p }
            ?? repoPaths.first { $0.key.lowercased() == p.split(separator: "/").last.map(String.init) }
        return hit.map { ($0.value as NSString).expandingTildeInPath }
    }

    /// Placeholders the template uses that this item can't fill.
    public static func missing(_ template: String, values: [String: String]) -> [String] {
        used(in: template).filter { placeholderNames.contains($0) && values[$0] == nil }
    }

    /// Env var that carries a placeholder's value: `{projectPath}` → `EVERBOARD_PROJECTPATH`.
    public static func envName(_ placeholder: String) -> String { "EVERBOARD_" + placeholder.uppercased() }

    /// The command line actually run. Each `{name}` becomes a quoted reference to `$EVERBOARD_NAME`, chosen to fit the
    /// quoting around it, so a title like `$(rm -rf ~)` is passed as text and never executed. Unknown names stay as-is.
    public static func shellCommand(_ template: String) -> String {
        var out = ""
        for token in scan(template) {
            switch token {
            case .text(let s): out += s
            case .placeholder(let name, let context):
                guard placeholderNames.contains(name) else { out += "{\(name)}"; continue }
                let ref = "${\(envName(name))}"
                switch context {
                case .none: out += "\"\(ref)\""
                case .double: out += ref
                case .single: out += "'\"\(ref)\"'"
                }
            }
        }
        return out
    }

    /// Environment for `shellCommand(_:)`.
    public static func environment(_ values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { (envName($0.key), $0.value) })
    }

    /// The template with values filled in literally, for showing to the user (never executed).
    public static func preview(_ template: String, values: [String: String]) -> String {
        var out = ""
        for token in scan(template) {
            switch token {
            case .text(let s): out += s
            case .placeholder(let name, _): out += values[name] ?? "{\(name)}"
            }
        }
        return out
    }

    /// Working directory for a run: the action's (with placeholders filled), else `{repoPath}`, else nil.
    public static func workingDirectory(_ action: AgentAction, values: [String: String]) -> String? {
        let raw = action.workingDirectory.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return values["repoPath"] }
        let filled = preview(raw, values: values)
        return filled.contains("{") ? nil : (filled as NSString).expandingTildeInPath
    }

    // MARK: Scanning

    enum Quote { case none, single, double }
    enum Token: Equatable {
        case text(String)
        case placeholder(String, Quote)
    }

    /// Splits a template into text and `{name}` placeholders, tracking shell quoting around each placeholder.
    static func scan(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var quote = Quote.none
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // `${VAR}` is the shell's own syntax, not a placeholder.
            if c == "{", i == 0 || chars[i - 1] != "$", let close = chars[(i + 1)...].firstIndex(of: "}") {
                let name = String(chars[(i + 1)..<close])
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    if !text.isEmpty { tokens.append(.text(text)); text = "" }
                    tokens.append(.placeholder(name, quote))
                    i = close + 1
                    continue
                }
            }
            switch (c, quote) {
            case ("\\", .none), ("\\", .double):
                text.append(c)
                if i + 1 < chars.count { text.append(chars[i + 1]); i += 1 }
            case ("'", .none): quote = .single; text.append(c)
            case ("'", .single): quote = .none; text.append(c)
            case ("\"", .none): quote = .double; text.append(c)
            case ("\"", .double): quote = .none; text.append(c)
            default: text.append(c)
            }
            i += 1
        }
        if !text.isEmpty { tokens.append(.text(text)) }
        return tokens
    }
}
