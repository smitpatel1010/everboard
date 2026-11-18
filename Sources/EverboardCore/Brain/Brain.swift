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
    }

    enum CodingKeys: String, CodingKey {
        case folder, dailyFolder, peopleFolder, weeklyFolder, agentsFolder, writeDaily, writePeople, writeWeekly, writeAgentRuns
        case readForAI, dailyNameFormat
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

    public func personPath(_ name: String) -> String { "\(settings.peopleFolder)/\(NoteName.safe(name)).md" }

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

    /// What you wrote about a person (their note minus Everboard's blocks), trimmed to `limit` characters.
    public func personContext(_ name: String, limit: Int = 6000) -> String? {
        guard let text = read(personPath(name)) else { return nil }
        let mine = ManagedBlock.stripAll(Frontmatter.parse(text).body).trimmingCharacters(in: .whitespacesAndNewlines)
        return mine.isEmpty ? nil : String(mine.suffix(limit))
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
        let existing = (try? String(contentsOf: u, encoding: .utf8))
            ?? Frontmatter.render(frontmatter) + (title.map { "# \($0)\n\n" } ?? "")
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
                try (Frontmatter.render(frontmatter) + body).write(to: u, atomically: true, encoding: .utf8)
                return relative
            }
            n += 1
        }
    }

    // MARK: What Everboard writes

    public func writeDailySection(_ block: String, heading: String, markdown: String, date: Date = Date()) throws {
        let day = Self.format(date, "yyyy-MM-dd")
        try upsertBlock(dailyPath(date), block: block, markdown: "## \(heading)\n\n\(markdown)",
                        frontmatter: [("date", day), ("tags", "daily")])
    }

    public func writePersonSection(_ name: String, block: String, heading: String, markdown: String, date: Date = Date()) throws {
        let day = Self.format(date, "yyyy-MM-dd")
        try upsertBlock(personPath(name), block: block,
                        markdown: "## \(heading) (\(day))\n\n\(markdown)\n\nDaily note: \(NoteName.link(Self.format(date, settings.dailyNameFormat)))",
                        frontmatter: [("tags", "person")], title: name)
    }

    public func writeWeeklySection(_ block: String, heading: String, markdown: String, date: Date = Date()) throws {
        try upsertBlock(weeklyPath(date), block: block, markdown: "## \(heading)\n\n\(markdown)",
                        frontmatter: [("week", URL(fileURLWithPath: weeklyPath(date)).deletingPathExtension().lastPathComponent),
                                      ("tags", "weekly")])
    }

    /// Saves an agent run as its own note and returns its path relative to the root.
    public func writeAgentRun(_ run: AgentRun) throws -> String {
        let day = Self.format(run.ts, "yyyy-MM-dd")
        let fm: [(String, String)] = [
            ("date", day), ("action", run.actionName), ("item", run.itemRef), ("url", run.itemUrl ?? ""),
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
