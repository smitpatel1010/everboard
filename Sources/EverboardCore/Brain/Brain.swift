import Foundation

/// Where Everboard writes notes inside your brain folder, and what it may do there.
public struct BrainSettings: Codable, Hashable, Sendable {
    /// The folder (e.g. an Obsidian vault). Empty = brain integration off.
    public var folder: String = ""
    public var dailyFolder = "Daily"
    public var peopleFolder = "People"
    public var weeklyFolder = "Weekly"
    public var agentsFolder = "Everboard/Agent runs"
    /// Write the work brief and team digest into the day's note.
    public var writeDaily = true
    /// Write 1:1 prep into each person's note.
    public var writePeople = true
    /// Write the weekly report draft into the week's note.
    public var writeWeekly = true
    /// Save every agent run as a note (and link it from the day's note).
    public var writeAgentRuns = true
    /// Include your own notes (person notes, recent daily notes) in AI prompts. Off by default: it sends note text to Claude.
    public var readForAI = false
    /// Daily note file name, `yyyy-MM-dd` style (DateFormatter pattern).
    public var dailyNameFormat = "yyyy-MM-dd"
    /// What person notes are named after: their display name, or their username (so scripts can join on it).
    public var peopleNoteName: PersonNoteName = .name
    /// Where 1:1 prep goes. Empty = a section in the person's note; set = one note per 1:1 in this folder.
    public var oneOnOneFolder = ""
    /// 1:1 note path inside `oneOnOneFolder`, without `.md`: `{person}` and `{date}` (yyyy-MM-dd), `/` for subfolders.
    /// The default keeps each person's 1:1s together: `asha.k/2026-11-21`.
    public var oneOnOneNameFormat = "{person}/{date}"

    public init() {}

    public var isEnabled: Bool { !folder.trimmingCharacters(in: .whitespaces).isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrainSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        folder = v(.folder, d.folder)
        dailyFolder = v(.dailyFolder, d.dailyFolder)
        peopleFolder = v(.peopleFolder, d.peopleFolder)
        weeklyFolder = v(.weeklyFolder, d.weeklyFolder)
        agentsFolder = v(.agentsFolder, d.agentsFolder)
        writeDaily = v(.writeDaily, d.writeDaily)
        writePeople = v(.writePeople, d.writePeople)
        writeWeekly = v(.writeWeekly, d.writeWeekly)
        writeAgentRuns = v(.writeAgentRuns, d.writeAgentRuns)
        readForAI = v(.readForAI, d.readForAI)
        dailyNameFormat = v(.dailyNameFormat, d.dailyNameFormat)
        peopleNoteName = v(.peopleNoteName, d.peopleNoteName)
        oneOnOneFolder = v(.oneOnOneFolder, d.oneOnOneFolder)
        oneOnOneNameFormat = v(.oneOnOneNameFormat, d.oneOnOneNameFormat)
    }

    enum CodingKeys: String, CodingKey {
        case folder, dailyFolder, peopleFolder, weeklyFolder, agentsFolder, writeDaily, writePeople, writeWeekly, writeAgentRuns
        case readForAI, dailyNameFormat, peopleNoteName, oneOnOneFolder, oneOnOneNameFormat
    }
}

public enum PersonNoteName: String, Codable, CaseIterable, Sendable {
    case name, username
}

/// Someone the brain keeps notes about: a display name, and a username when known.
public struct BrainPerson: Hashable, Sendable {
    public var name: String
    public var username: String?

    public init(name: String, username: String? = nil) {
        self.name = name
        self.username = username
    }
}

public enum BrainError: Error, LocalizedError {
    case notConfigured
    case outsideFolder(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Choose a brain folder in Settings → Brain first"
        case .outsideFolder(let p): return "Refusing to write outside the brain folder: \(p)"
        }
    }
}

/// Reads and writes markdown notes in a folder you choose (Obsidian-compatible: frontmatter, `[[links]]`).
/// Everboard only ever replaces its own marked blocks inside notes you might edit, and creates new files with unique names,
/// so it never overwrites your writing.
public struct Brain: Sendable {
    public let root: URL
    public let settings: BrainSettings

    public init?(settings: BrainSettings) {
        guard settings.isEnabled else { return nil }
        self.settings = settings
        root = URL(fileURLWithPath: (settings.folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    // MARK: Paths

    /// `relative` resolved inside the root, or an error if it escapes (`..`, absolute paths, symlinked folders).
    public func url(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains("..") else { throw BrainError.outsideFolder(relative) }
        let u = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        let rootPath = Self.canonical(root)
        let parent = Self.canonical(u.deletingLastPathComponent())
        guard u.path.hasPrefix(root.path + "/"), parent == rootPath || parent.hasPrefix(rootPath + "/") else {
            throw BrainError.outsideFolder(relative)
        }
        return u
    }

    /// Real path of `u` with symlinks resolved, for the part of it that exists.
    static func canonical(_ u: URL) -> String {
        var existing = u.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let base = realpath(existing.path, &buf) != nil ? String(cString: buf) : existing.path
        return rest.reduce(base == "/" ? "" : base) { $0 + "/" + $1 }
    }

    public func dailyPath(_ date: Date) -> String {
        "\(settings.dailyFolder)/\(Self.format(date, settings.dailyNameFormat)).md"
    }

    /// The person's note name: their username when notes are named that way and it's known, else their display name.
    public func personKey(_ p: BrainPerson) -> String {
        if settings.peopleNoteName == .username, let u = p.username?.trimmingCharacters(in: .whitespaces), !u.isEmpty { return NoteName.safe(u) }
        return NoteName.safe(p.name)
    }

    public func personPath(_ p: BrainPerson) -> String { "\(settings.peopleFolder)/\(personKey(p)).md" }

    /// `[[key|Name]]` when the note is named by username, so the link shows the name and opens the existing note.
    public func personLink(_ p: BrainPerson) -> String {
        let key = personKey(p)
        return key == NoteName.safe(p.name) ? "[[\(key)]]" : "[[\(key)|\(p.name)]]"
    }

    public var usesOneOnOneFolder: Bool { !settings.oneOnOneFolder.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The name format, or the default if it lacks `{person}` or `{date}` (notes would collide or never be found again).
    var oneOnOneFormat: String {
        let f = settings.oneOnOneNameFormat.trimmingCharacters(in: .whitespaces)
        return f.contains("{person}") && f.contains("{date}") ? f : BrainSettings().oneOnOneNameFormat
    }

    public func oneOnOnePath(_ p: BrainPerson, date: Date) -> String {
        let name = oneOnOneFormat.replacingOccurrences(of: "{person}", with: personKey(p))
            .replacingOccurrences(of: "{date}", with: Self.format(date, "yyyy-MM-dd"))
        return "\(settings.oneOnOneFolder)/\(name).md"
    }

    public func weeklyPath(_ date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(settings.weeklyFolder)/\(c.yearForWeekOfYear ?? 0)-W\(String(format: "%02d", c.weekOfYear ?? 0)).md"
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern.isEmpty ? "yyyy-MM-dd" : pattern
        return f.string(from: date)
    }

    // MARK: Reading

    public func read(_ relative: String) -> String? {
        guard let u = try? url(relative) else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    /// What you wrote about a person: their note, then their latest 1:1 notes (newest first), each without Everboard's
    /// own sections and trimmed to `limit` characters in all.
    public func personContext(_ p: BrainPerson, oneOnOnes: Int = 2, through date: Date = Date(), limit: Int = 6000) -> String? {
        var parts: [String] = []
        if let text = read(personPath(p)), let mine = Self.ownText(text) {
            parts.append(String(mine.suffix(limit / 2)))
        }
        for path in recentOneOnOnes(p, through: date).prefix(oneOnOnes) {
            if let text = read(path), let mine = Self.ownText(text) {
                parts.append("### 1:1 notes, \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)\n\(mine)")
            }
        }
        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : String(joined.prefix(limit))
    }

    /// 1:1 notes for this person in the 1:1 folder up to and including `date`, newest first. Found by matching the
    /// name format, so subfolder and flat layouts both work.
    public func recentOneOnOnes(_ p: BrainPerson, through date: Date = Date()) -> [String] {
        guard usesOneOnOneFolder, let dir = try? url(settings.oneOnOneFolder + "/x.md").deletingLastPathComponent(),
              let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let parts = oneOnOneFormat.components(separatedBy: "{date}")
        let pattern = "^" + parts.map { NSRegularExpression.escapedPattern(for: $0)
            .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{person}"), with: NSRegularExpression.escapedPattern(for: personKey(p))) }
            .joined(separator: #"(\d{4}-\d{2}-\d{2})"#) + #"\.md$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let today = Self.format(date, "yyyy-MM-dd")
        let base = dir.standardizedFileURL.path + "/"
        var found: [(day: String, path: String)] = []
        for case let u as URL in files where u.pathExtension == "md" {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            guard let m = re.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)),
                  let r = Range(m.range(at: 1), in: rel) else { continue }
            let day = String(rel[r])
            if day <= today { found.append((day, "\(settings.oneOnOneFolder)/\(rel)")) }
            if found.count > 500 { break }
        }
        return found.sorted { $0.day > $1.day }.map(\.path)
    }

    static func ownText(_ note: String) -> String? {
        let mine = ManagedBlock.stripAll(Frontmatter.parse(note).body).trimmingCharacters(in: .whitespacesAndNewlines)
        return mine.isEmpty ? nil : mine
    }

    /// Your own text from the last `days` daily notes, newest first.
    public func recentDailyContext(days: Int = 3, now: Date = Date(), limit: Int = 6000) -> String? {
        var out: [String] = []
        for d in 0..<max(days, 0) {
            let date = now.addingTimeInterval(-Double(d) * 86400)
            guard let text = read(dailyPath(date)) else { continue }
            let mine = ManagedBlock.stripAll(Frontmatter.parse(text).body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !mine.isEmpty { out.append("### \(Self.format(date, "yyyy-MM-dd"))\n\(mine)") }
        }
        let joined = out.joined(separator: "\n\n")
        return joined.isEmpty ? nil : String(joined.prefix(limit))
    }

    // MARK: Writing

    /// Sets block `block` in the note at `relative`, creating the note (with `frontmatter` and `title`) if it doesn't exist.
    @discardableResult
    public func upsertBlock(_ relative: String, block: String, markdown: String, frontmatter: [(String, String)] = [],
                            title: String? = nil) throws -> URL {
        let u = try url(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let today = Self.format(Date(), "yyyy-MM-dd")
        let existing = (try? String(contentsOf: u, encoding: .utf8)).map { Frontmatter.setting("updated", to: today, in: $0) }
            ?? Frontmatter.render(frontmatter + [("updated", today)]) + (title.map { "# \($0)\n\n" } ?? "")
        try ManagedBlock.upsert(existing, id: block, content: markdown).write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// Writes a new note, adding " 2", " 3"… to the name rather than overwriting. Returns the path relative to the root.
    @discardableResult
    public func createNote(folder: String, name: String, frontmatter: [(String, String)], body: String) throws -> String {
        let base = NoteName.safe(name)
        var n = 1
        while true {
            let relative = "\(folder)/\(base)\(n == 1 ? "" : " \(n)").md"
            let u = try url(relative)
            if !FileManager.default.fileExists(atPath: u.path) {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (Frontmatter.render(frontmatter + [("updated", Self.format(Date(), "yyyy-MM-dd"))]) + body)
                    .write(to: u, atomically: true, encoding: .utf8)
                return relative
            }
            n += 1
        }
    }

    // MARK: What Everboard writes

    public func writeDailySection(_ block: String, heading: String, markdown: String, date: Date = Date()) throws {
        let day = Self.format(date, "yyyy-MM-dd")
        try upsertBlock(dailyPath(date), block: block, markdown: "## \(heading)\n\n\(markdown)",
                        frontmatter: [("type", "daily"), ("date", day), ("tags", "daily")])
    }

    public func writePersonSection(_ p: BrainPerson, block: String, heading: String, markdown: String, date: Date = Date()) throws {
        let day = Self.format(date, "yyyy-MM-dd")
        var fm: [(String, String)] = [("type", "person"), ("name", p.name)]
        if let u = p.username, !u.isEmpty { fm.append(("username", u)) }
        try upsertBlock(personPath(p), block: block,
                        markdown: "## \(heading) (\(day))\n\n\(markdown)\n\nDaily note: \(NoteName.link(Self.format(date, settings.dailyNameFormat)))",
                        frontmatter: fm + [("tags", "person")], title: p.name)
    }

    /// 1:1 prep: the day's note in the 1:1 folder when one is set (Everboard's section only, so a note you or another
    /// tool started that day is kept), otherwise a section in the person's note. Returns the note's path.
    @discardableResult
    public func writeOneOnOnePrep(_ p: BrainPerson, markdown: String, date: Date = Date()) throws -> String {
        guard usesOneOnOneFolder else {
            try writePersonSection(p, block: "one-on-one-prep", heading: "1:1 prep", markdown: markdown, date: date)
            return personPath(p)
        }
        let day = Self.format(date, "yyyy-MM-dd")
        let path = oneOnOnePath(p, date: date)
        try upsertBlock(path, block: "one-on-one-prep",
                        markdown: "## Prep (Everboard draft)\n\n\(markdown)",
                        frontmatter: [("type", "one-on-one"), ("person", personKey(p)), ("date", day), ("tags", "one-on-one")],
                        title: "1:1 with \(personLink(p)), \(day)")
        return path
    }

    public func writeWeeklySection(_ block: String, heading: String, markdown: String, date: Date = Date()) throws {
        try upsertBlock(weeklyPath(date), block: block, markdown: "## \(heading)\n\n\(markdown)",
                        frontmatter: [("type", "weekly"), ("week", URL(fileURLWithPath: weeklyPath(date)).deletingPathExtension().lastPathComponent),
                                      ("tags", "weekly")])
    }

    /// Saves an agent run as its own note and returns its path relative to the root.
    public func writeAgentRun(_ run: AgentRun) throws -> String {
        let day = Self.format(run.ts, "yyyy-MM-dd")
        let fm: [(String, String)] = [
            ("type", "agent-run"), ("date", day), ("action", run.actionName), ("item", run.itemRef), ("url", run.itemUrl ?? ""),
            ("status", run.status.rawValue), ("tags", "everboard, agent-run"),
        ]
        let body = """
        # \(run.actionName): \(run.itemRef)

        \(run.itemUrl.map { "[\(run.itemTitle)](\($0))" } ?? run.itemTitle) · \(run.status.label) · \(NoteName.link(Self.format(run.ts, settings.dailyNameFormat)))

        ```sh
        \(run.command)
        ```

        \(run.output.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        return try createNote(folder: settings.agentsFolder, name: "\(day) \(run.actionName) \(run.itemRef)", frontmatter: fm, body: body)
    }

    /// Rebuilds the day's "Agent runs" block from the runs saved as notes that day.
    public func writeAgentRunIndex(_ runs: [AgentRun], date: Date = Date()) throws {
        let lines = runs.sorted { $0.ts < $1.ts }.compactMap { r -> String? in
            guard let path = r.notePath else { return nil }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "- \(r.ts.formatted(date: .omitted, time: .shortened)) [[\(name)|\(r.actionName): \(r.itemRef)]] · \(r.status.label)"
        }
        guard !lines.isEmpty else { return }
        try writeDailySection("agent-runs", heading: "Agent runs", markdown: lines.joined(separator: "\n"), date: date)
    }
}
