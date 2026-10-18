import Foundation

/// What may leave the Mac in a Claude prompt. Built from `AppConfig` plus the people Everboard knows about.
public struct PrivacyPolicy: Sendable, Hashable {
    /// When false, every work feature (briefs, summaries, reports, meeting prep) is refused before anything is sent.
    public var allowWork = true
    public var redactSecrets = true
    public var redactEmails = true
    public var pseudonymizePeople = false
    /// Names to pseudonymise (authors, assignees, your team). Only used when `pseudonymizePeople` is on.
    public var people: [String] = []
    /// Your own words to mask: customer names, codenames, internal hosts.
    public var terms: [String] = []

    public init(allowWork: Bool = true, redactSecrets: Bool = true, redactEmails: Bool = true,
                pseudonymizePeople: Bool = false, people: [String] = [], terms: [String] = []) {
        self.allowWork = allowWork
        self.redactSecrets = redactSecrets
        self.redactEmails = redactEmails
        self.pseudonymizePeople = pseudonymizePeople
        self.people = people
        self.terms = terms
    }

    /// News and the settings test never contain work data.
    public static func isWorkFeature(_ feature: String) -> Bool {
        !(feature.hasPrefix("news.") || feature.hasPrefix("settings."))
    }
}

/// Masks sensitive text before it reaches Claude. Names, emails and terms become numbered placeholders
/// (`[PERSON-1]`) that `restore` puts back in the reply, so output stays readable; secrets are dropped for good.
public enum Redactor {
    public struct Result: Sendable {
        public var text: String
        /// placeholder → original, for `restore`.
        public var map: [String: String]
        /// kind ("secret", "email", "person", "term") → occurrences masked.
        public var counts: [String: Int]
    }

    /// Patterns for credentials that turn up in diffs, configs and pasted logs. Each match becomes `[SECRET]`.
    static let secretPatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"\bgl(?:pat|ptt|dt|rt|cbt|oas|soat|ffct|imt|agent)-[A-Za-z0-9_\-]{16,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}"#,
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bATATT3[A-Za-z0-9_\-=]{20,}"#,
        #"\bAIza[0-9A-Za-z_\-]{35}"#,
        #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{20,}=*"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// `password: "hunter22"`, `API_KEY=abc123…`, `user:pass@host`: keep the key, mask the value.
    /// Unquoted values must contain a digit and no parentheses, so code like `token = req.header(…)` survives.
    static let secretKey = #"(?:[A-Za-z0-9]+[_\-])*(?:password|passwd|pwd|secret|api[_\-]?key|access[_\-]?key|access[_\-]?token|auth[_\-]?token|client[_\-]?secret|private[_\-]?key|token)"#
    static let assignmentPatterns: [NSRegularExpression] = [
        #"(?i)\b("# + secretKey + #"["']?\s*[:=]\s*["'])([^"'\s]{6,})(?=["'])"#,
        #"(?i)\b("# + secretKey + #"\s*[:=]\s*)((?=[^\s"',;()]*\d)[^\s"',;()]{8,})"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    static let urlCredentialPattern = try! NSRegularExpression(pattern: #"(://)([^/\s:@]+:[^/\s@]+)(@)"#)
    static let emailPattern = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)
    static let placeholderPattern = try! NSRegularExpression(pattern: #"\[?\b(PERSON|EMAIL|TERM)-(\d+)\b\]?"#)

    public static func redact(_ text: String, policy: PrivacyPolicy, isWork: Bool = true) -> Result {
        var out = text
        var map: [String: String] = [:]
        var counts: [String: Int] = [:]
        var assigned: [String: String] = [:]  // original (lowercased for terms) → placeholder

        if policy.redactSecrets {
            for re in secretPatterns { out = replace(re, in: out, kind: "secret", counts: &counts) { _ in "[SECRET]" } }
            out = replace(urlCredentialPattern, in: out, kind: "secret", counts: &counts) { g in g[1] + "[SECRET]" + g[3] }
            for re in assignmentPatterns {
                out = replace(re, in: out, kind: "secret", counts: &counts) { g in
                    g[2].hasPrefix("[SECRET") || g[2].hasPrefix("${") || g[2].hasPrefix("{{") ? g[0] : g[1] + "[SECRET]"
                }
            }
        }
        if policy.redactEmails {
            var n = 0
            out = replace(emailPattern, in: out, kind: "email", counts: &counts) { g in
                let key = g[0].lowercased()
                if let p = assigned[key] { return p }
                n += 1
                let p = "[EMAIL-\(n)]"
                assigned[key] = p
                map[p] = g[0]
                return p
            }
        }
        // People and custom terms only matter for work prompts.
        guard isWork else { return Result(text: out, map: map, counts: counts) }

        if !policy.terms.isEmpty {
            var n = 0
            for term in uniqueLongestFirst(policy.terms) {
                let re = wordRegex(term, caseInsensitive: true)
                out = replace(re, in: out, kind: "term", counts: &counts) { g in
                    let key = "term:" + term.lowercased()
                    if let p = assigned[key] { return p }
                    n += 1
                    let p = "[TERM-\(n)]"
                    assigned[key] = p
                    map[p] = term
                    return p
                }
            }
        }
        if policy.pseudonymizePeople {
            var n = 0
            for (variant, full) in peopleVariants(policy.people) {
                let re = wordRegex(variant, caseInsensitive: false)
                out = replace(re, in: out, kind: "person", counts: &counts) { _ in
                    let key = "person:" + full
                    if let p = assigned[key] { return p }
                    n += 1
                    let p = "[PERSON-\(n)]"
                    assigned[key] = p
                    map[p] = full
                    return p
                }
            }
        }
        return Result(text: out, map: map, counts: counts)
    }

    /// Puts names, emails and terms back into Claude's reply. Tolerates the brackets being dropped.
    public static func restore(_ text: String, map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var counts: [String: Int] = [:]
        return replace(placeholderPattern, in: text, kind: "", counts: &counts) { g in
            map["[\(g[1])-\(g[2])]"] ?? g[0]
        }
    }

    // MARK: Helpers

    /// Full names, plus first names when they're unambiguous, mapped to the full name. Longest first.
    static func peopleVariants(_ people: [String]) -> [(String, String)] {
        let ignored: Set<String> = ["you", "me", "unassigned", "?", "-"]
        let full = uniqueLongestFirst(people.map { $0.trimmingCharacters(in: .whitespaces) })
            .filter { $0.count >= 3 && !ignored.contains($0.lowercased()) }
        var firstNames: [String: [String]] = [:]
        for name in full where name.contains(" ") {
            if let first = name.split(separator: " ").first.map(String.init), first.count >= 3 { firstNames[first, default: []].append(name) }
        }
        var out = full.map { ($0, $0) }
        for (first, owners) in firstNames where owners.count == 1 && !full.contains(first) { out.append((first, owners[0])) }
        return out.sorted { $0.0.count > $1.0.count }
    }

    static func uniqueLongestFirst(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.sorted { $0.count > $1.count }
    }

    static func wordRegex(_ literal: String, caseInsensitive: Bool) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: literal)
        return try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#,
                                        options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// Regex replace with a closure over capture groups (group 0 = whole match). Counts replacements under `kind`.
    static func replace(_ re: NSRegularExpression, in text: String, kind: String, counts: inout [String: Int],
                        _ make: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            let replacement = make(groups)
            if replacement != groups[0] && !kind.isEmpty { counts[kind, default: 0] += 1 }
            out += replacement
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Applies the privacy policy to every request: refuses work features when they're off,
/// masks the prompt, and restores placeholders in the reply.
public struct PrivacyClaudeRunner: ClaudeRunning {
    let base: ClaudeRunning
    let policy: PrivacyPolicy

    public init(base: ClaudeRunning, policy: PrivacyPolicy) {
        self.base = base
        self.policy = policy
    }

    public func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let isWork = PrivacyPolicy.isWorkFeature(request.feature)
        if isWork && !policy.allowWork {
            throw ClaudeError.blocked("Sending work data to Claude is turned off (Settings → AI privacy).")
        }
        var p = policy
        p.people += request.people
        let masked = Redactor.redact(request.prompt, policy: p, isWork: isWork)
        var r = request
        r.prompt = masked.text
        r.redactions = masked.counts
        if !masked.map.isEmpty {
            let note = "Tokens like [PERSON-1], [EMAIL-1] and [TERM-1] are privacy placeholders: use them verbatim, never guess what they stand for."
            r.systemPrompt = [r.systemPrompt, note].compactMap { $0 }.joined(separator: "\n\n")
        }
        var response = try await base.run(r)
        response.text = Redactor.restore(response.text, map: masked.map)
        return response
    }
}

/// Which free-text work content features may include. Titles, statuses and names are always sent.
public struct AIContentPolicy: Sendable, Hashable {
    public var sendDiffs = true
    public var sendJiraText = true
    public var sendMeetingNotes = true

    public init(sendDiffs: Bool = true, sendJiraText: Bool = true, sendMeetingNotes: Bool = true) {
        self.sendDiffs = sendDiffs
        self.sendJiraText = sendJiraText
        self.sendMeetingNotes = sendMeetingNotes
    }
}
