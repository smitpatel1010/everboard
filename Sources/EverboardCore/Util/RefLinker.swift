import Foundation

/// Turns MR/PR references (`group/project!123`, `group/project !123`, `!123`, `owner/repo#123`) and Jira keys
/// (`PAY-1311`) in markdown into links, so AI reports and summaries are clickable. Existing links, URLs and code
/// spans are left alone.
public struct RefLinker: Sendable, Hashable {
    /// Fallback hosts for refs not found in your data (the first GitLab / GitHub account).
    public var gitlabBase: URL?
    public var githubBase: URL?
    public var jiraBase: URL?
    /// Jira project keys seen in your data ("PAY"); only these are linked, so "UTF-8" or "ISO-8601" never are.
    public var jiraProjects: Set<String>
    /// MR iid → web URLs of known GitLab MRs, to resolve a bare `!123` when it's unambiguous.
    public var mrsByIID: [String: [String]]
    /// "path!iid" / "path#number" → URL of changes in your data, so refs land on the right account.
    public var knownRefs: [String: String]

    public init(gitlabBase: URL? = nil, githubBase: URL? = nil, jiraBase: URL? = nil, jiraProjects: Set<String> = [],
                mrsByIID: [String: [String]] = [:], knownRefs: [String: String] = [:]) {
        self.gitlabBase = gitlabBase
        self.githubBase = githubBase
        self.jiraBase = jiraBase
        self.jiraProjects = jiraProjects
        self.mrsByIID = mrsByIID
        self.knownRefs = knownRefs
    }

    /// Builds the lookups from feed items: Jira keys (and changes' linked keys) give project prefixes; MRs/PRs give refs.
    public init(gitlabBase: URL?, githubBase: URL? = nil, jiraBase: URL?, items: [FeedItem]) {
        var projects = Set<String>()
        var mrs: [String: [String]] = [:]
        var known: [String: String] = [:]
        for i in items {
            var keys = i["jiraKeys"]?.split(separator: ",").map(String.init) ?? []
            if i.source == "jira", let k = i["key"] { keys.append(k) }
            for k in keys { if let dash = k.firstIndex(of: "-") { projects.insert(String(k[..<dash])) } }
            guard i.isCodeChange, let iid = i["iid"], let url = i.url else { continue }
            if let path = i["projectPath"] { known[path + (i.source == "github" ? "#" : "!") + iid] = url }
            if i.source == "gitlab", !(mrs[iid]?.contains(url) ?? false) { mrs[iid, default: []].append(url) }
        }
        self.init(gitlabBase: gitlabBase, githubBase: githubBase, jiraBase: jiraBase, jiraProjects: projects, mrsByIID: mrs,
                  knownRefs: known)
    }

    // Links, autolinks, bare URLs and code spans are copied through untouched.
    static let protected = try! NSRegularExpression(pattern: #"\[[^\]]*\]\([^)]*\)|<https?://[^>]*>|https?://[^\s)\]>]+|`[^`]*`"#)
    // 1–2: full path + iid ("acme/payments-api!311", "acme/payments-api !311"); 3: bare "!311"; 4: Jira key;
    // 5–6: GitHub "owner/repo#12".
    static let refs = try! NSRegularExpression(pattern:
        #"(?<![\w/.\-])([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+) ?!(\d+)\b|(?<![\w/!\[])!(\d+)\b|(?<![\w\-/])([A-Z][A-Z0-9_]+-\d+)\b|(?<![\w/.\-])([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)#(\d+)\b"#)

    public func linkify(_ markdown: String) -> String {
        guard gitlabBase != nil || githubBase != nil || jiraBase != nil || !mrsByIID.isEmpty || !knownRefs.isEmpty else { return markdown }
        let ns = markdown as NSString
        var out = ""
        var last = 0
        for m in Self.protected.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            out += linkifyPlain(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            out += ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        return out + linkifyPlain(ns.substring(from: last))
    }

    func linkifyPlain(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in Self.refs.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range)
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            var url: String?
            if let path = group(1), let iid = group(2) {
                url = knownRefs[path + "!" + iid] ?? gitlabBase.map { $0.absoluteString + "/" + path + "/-/merge_requests/" + iid }
            } else if let path = group(5), let number = group(6) {
                url = knownRefs[path + "#" + number] ?? githubBase.map { $0.absoluteString + "/" + path + "/pull/" + number }
            } else if let iid = group(3), let known = mrsByIID[iid], known.count == 1 {
                url = known[0]
            } else if let key = group(4), let base = jiraBase, let dash = key.firstIndex(of: "-"), jiraProjects.contains(String(key[..<dash])) {
                url = base.absoluteString + "/browse/" + key
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let url, SafeURL.web(url) != nil { out += "[\(whole)](\(url))" } else { out += whole }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Renders the same small markdown subset `MarkdownView` shows as HTML, so a copied report keeps
/// its headings, bold text and clickable links when pasted into Teams, Outlook or Confluence.
public enum MarkdownHTML {
    public static func render(_ markdown: String) -> String {
        var html = ""
        var openList: String?  // "ul" / "ol"
        func closeList() { if let l = openList { html += "</\(l)>"; openList = nil } }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }
            if line == "---" || line == "***" { closeList(); html += "<hr>"; continue }
            if line.hasPrefix("#") {
                closeList()
                let level = min(line.prefix { $0 == "#" }.count + 1, 6)  // "##" → h3: reads well in chat clients
                html += "<h\(level)>\(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))</h\(level)>"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if openList != "ul" { closeList(); html += "<ul>"; openList = "ul" }
                html += "<li>\(inline(String(line.dropFirst(2))))</li>"
            } else if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                if openList != "ol" { closeList(); html += "<ol>"; openList = "ol" }
                html += "<li>\(inline(line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))</li>"
            } else {
                closeList()
                html += "<p>\(inline(line))</p>"
            }
        }
        closeList()
        return "<meta charset=\"utf-8\">" + html
    }

    /// Inline markdown → HTML via AttributedString runs (bold, italic, code, links).
    static func inline(_ s: String) -> String {
        guard let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return escape(s)
        }
        var out = ""
        for run in a.runs {
            var piece = escape(String(a[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { piece = "<code>\(piece)</code>" }
                if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
                if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            }
            if let link = run.link, let safe = SafeURL.web(link.absoluteString) {
                piece = "<a href=\"\(escape(safe.absoluteString))\">\(piece)</a>"
            }
            out += piece
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
