import Foundation

/// Tokens and endpoints, read from the secrets file (see `AppInfo.secretsURL`) with the process environment as fallback.
/// GUI apps launched from Finder/login don't inherit ~/.zshrc exports, hence the file.
public struct Secrets: Sendable, Equatable {
    public enum Key: String, CaseIterable, Sendable {
        case gitlabURL = "GITLAB_URL"
        case gitlabToken = "GITLAB_TOKEN"
        case jiraURL = "JIRA_URL"
        case jiraEmail = "JIRA_EMAIL"
        case jiraToken = "JIRA_API_TOKEN"
        case gitlabOrgs = "GITLAB_ORGS"
        case githubURL = "GITHUB_URL"
        case githubToken = "GITHUB_TOKEN"
        case githubOrgs = "GITHUB_ORGS"

        public var isSecret: Bool { [.gitlabToken, .jiraToken, .githubToken].contains(self) }
    }

    /// `GITLAB_WORK_URL`, `GITHUB_OSS_TOKEN`, `GITLAB_WORK_ORGS`: extra, named code-host accounts.
    static let namedAccountKey = try! NSRegularExpression(pattern: "^(GITLAB|GITHUB)_([A-Z0-9]+)_(URL|TOKEN|ORGS)$")

    /// Anything that may hold a token: never logged, never passed to child processes.
    public static func isSensitiveEnvKey(_ key: String) -> Bool {
        Key(rawValue: key) != nil
            || namedAccountKey.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
    }

    public var values: [String: String]
    public var warnings: [String]
    public var path: URL

    public init(values: [String: String], warnings: [String] = [], path: URL = AppInfo.secretsURL) {
        self.values = values
        self.warnings = warnings
        self.path = path
    }

    public subscript(key: Key) -> String? {
        guard let v = values[key.rawValue]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }

    /// nil unless HTTPS — tokens are never sent over plain HTTP.
    public var jiraBaseURL: URL? { self[.jiraURL].flatMap { URL(string: $0.trimmingTrailingSlash) }.flatMap { SafeURL.isSecureEndpoint($0) ? $0 : nil } }
    public var hasJira: Bool { jiraBaseURL != nil && self[.jiraEmail] != nil && self[.jiraToken] != nil }
    public var hasCodeHost: Bool { !codeHostAccounts.isEmpty }

    /// Every configured GitLab / GitHub account; defaults first, then named ones by name.
    /// Default accounts need both URL and token (a bare `GITHUB_TOKEN` only feeds the news source);
    /// named accounts need a token, and their URL defaults to gitlab.com / github.com.
    public var codeHostAccounts: [CodeHostAccount] { accountsAndProblems().accounts }

    func accountsAndProblems() -> (accounts: [CodeHostAccount], problems: [String]) {
        func value(_ k: String) -> String? {
            guard let v = values[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        var accounts: [CodeHostAccount] = []
        var problems: [String] = []
        func add(_ kind: CodeHostKind, name: String?, urlKey: String, tokenKey: String, orgsKey: String, urlRequired: Bool) {
            guard let token = value(tokenKey) else {
                if name != nil, value(urlKey) != nil { problems.append("\(urlKey) is set but \(tokenKey) is missing") }
                return
            }
            guard let raw = value(urlKey) ?? (urlRequired ? nil : kind.defaultURL.absoluteString) else { return }
            guard let url = URL(string: raw.trimmingTrailingSlash), url.host != nil, SafeURL.isSecureEndpoint(url) else {
                problems.append("\(urlKey) must start with https:// — ignored so tokens aren't sent unencrypted")
                return
            }
            let orgs = (value(orgsKey) ?? "").split(separator: ",").map(String.init)
            accounts.append(CodeHostAccount(kind: kind, name: name, webURL: url, token: token, orgs: orgs))
        }
        add(.gitlab, name: nil, urlKey: Key.gitlabURL.rawValue, tokenKey: Key.gitlabToken.rawValue, orgsKey: Key.gitlabOrgs.rawValue, urlRequired: true)
        add(.github, name: nil, urlKey: Key.githubURL.rawValue, tokenKey: Key.githubToken.rawValue, orgsKey: Key.githubOrgs.rawValue, urlRequired: true)
        var named = Set<[String]>()
        for key in values.keys {
            let ns = key as NSString
            guard let m = Self.namedAccountKey.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) else { continue }
            named.insert([ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))])
        }
        for pair in named.sorted(by: { $0.joined() < $1.joined() }) {
            guard let kind = CodeHostKind(rawValue: pair[0].lowercased()) else { continue }
            let prefix = "\(pair[0])_\(pair[1])_"
            add(kind, name: pair[1], urlKey: prefix + "URL", tokenKey: prefix + "TOKEN", orgsKey: prefix + "ORGS", urlRequired: false)
        }
        return (accounts, problems)
    }

    /// Loads the file (if present) and overlays nothing — file wins; env fills gaps.
    public static func load(path: URL = AppInfo.secretsURL,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Secrets {
        var values: [String: String] = [:]
        var warnings: [String] = []
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            values = parse(text)
            if let perms = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.posixPermissions] as? NSNumber,
               perms.intValue & 0o077 != 0 {
                // Our own file: tighten it rather than just complaining.
                if (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)) == nil {
                    warnings.append("\(path.path) is readable by other users — run: chmod 600 \(path.path)")
                }
            }
        } else {
            warnings.append("No secrets file at \(path.path) — using environment variables only")
        }
        for (key, v) in environment where values[key] == nil && !v.isEmpty && isSensitiveEnvKey(key) {
            values[key] = v
        }
        if let raw = values[Key.jiraURL.rawValue], !raw.isEmpty, let u = URL(string: raw), !SafeURL.isSecureEndpoint(u) {
            warnings.append("JIRA_URL must start with https:// — ignored so tokens aren't sent unencrypted")
        }
        var secrets = Secrets(values: values, warnings: warnings, path: path)
        secrets.warnings += secrets.accountsAndProblems().problems
        return secrets
    }

    /// Parses dotenv-style text: `KEY=value`, optional `export`, quotes, `#` comments.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = value.first, q == "\"" || q == "'", value.count >= 2, value.last == q {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("#") {
                value = "" // `KEY=   # comment` means empty
            } else if let hash = value.range(of: " #") ?? value.range(of: "\t#") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Template written on first run so the user just fills in values.
    public static let template = """
    # Everboard secrets — git-ignored; keep this file private (chmod 600).
    # Fill in what you use; every service is optional.
    # Use Settings → Accounts → "Reload secrets" after editing.
    # Lives at <project>/secrets.env or ~/.config/everboard/secrets.env ($EVERBOARD_SECRETS overrides both).

    # GitLab: merge requests, pipelines and to-dos. Leave the token empty to skip.
    GITLAB_URL=https://gitlab.com    # or your self-hosted GitLab, e.g. https://gitlab.example.com
    GITLAB_TOKEN=                 # Personal access token: read_api (or api to approve/retry/comment)
    GITLAB_ORGS=                  # optional: only these groups, comma-separated (e.g. my-group,other-group/sub)

    # GitHub: pull requests, Actions runs and notifications. Set GITHUB_URL to turn it on.
    GITHUB_URL=                   # https://github.com, or your GitHub Enterprise Server URL
    GITHUB_TOKEN=                 # classic token: repo + notifications (also raises limits for the "trending repos" news source)
    GITHUB_ORGS=                  # optional: only these orgs/users, comma-separated

    # More accounts: add a name between the host and the setting, e.g.
    #   GITLAB_WORK_URL=https://gitlab.example.com
    #   GITLAB_WORK_TOKEN=...
    #   GITHUB_OSS_TOKEN=...      # URL defaults to github.com / gitlab.com
    #   GITHUB_OSS_ORGS=my-org

    JIRA_URL=https://<your-site>.atlassian.net
    JIRA_EMAIL=
    JIRA_API_TOKEN=               # https://id.atlassian.com/manage-profile/security/api-tokens

    """

    @discardableResult
    public static func writeTemplateIfMissing(at path: URL = AppInfo.secretsURL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path.path) else { return false }
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return fm.createFile(atPath: path.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600])
    }
}

extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
