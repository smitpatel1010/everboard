import Foundation

/// The folder of session files: one `<tool>-<id>.json` per session, owner-only, written atomically.
/// Several hooks can fire at once (parallel tool calls), so every read-modify-write holds a lock on the folder.
public struct SessionDirectory: Sendable {
    public let url: URL

    public init(url: URL = SessionPaths.directory()) {
        self.url = url
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
            let s = try c.decode(String.self)
            if let d = Dates.parseISO(s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date: \(s)")
        }
        return d
    }()

    public func fileURL(tool: String, sessionId: String) -> URL {
        url.appendingPathComponent("\(Self.safe(tool))-\(Self.safe(sessionId)).json")
    }

    /// Reads, changes and writes one session under the folder lock. `change` returning nil leaves the file alone.
    @discardableResult
    public func update(tool: String, sessionId: String, _ change: (AgentSession?) -> AgentSession?) throws -> AgentSession? {
        try ensureDirectory()
        return try withLock {
            let file = fileURL(tool: tool, sessionId: sessionId)
            let old = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(AgentSession.self, from: $0) }
            guard let new = change(old) else { return nil }
            // The payload can reveal a different tool (Cursor running a Claude Code hook): file it under that one.
            let target = fileURL(tool: new.tool, sessionId: new.sessionId)
            try write(new, to: target)
            return new
        }
    }

    public func write(_ session: AgentSession) throws {
        try ensureDirectory()
        try withLock { try write(session, to: fileURL(tool: session.tool, sessionId: session.sessionId)) }
    }

    /// Every readable session file. Files that don't parse are skipped.
    public func loadAll() -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { f in
            (try? Data(contentsOf: f)).flatMap { try? Self.decoder.decode(AgentSession.self, from: $0) }
        }
    }

    public func remove(_ session: AgentSession) {
        try? withLock { try? FileManager.default.removeItem(at: fileURL(tool: session.tool, sessionId: session.sessionId)) }
    }

    /// Deletes ended sessions after `endedAfter` and any session untouched for `staleAfter`.
    @discardableResult
    public func prune(now: Date = Date(), endedAfter: TimeInterval = 86400, staleAfter: TimeInterval = 3 * 86400) -> Int {
        var removed = 0
        for s in loadAll() {
            let age = now.timeIntervalSince(s.updatedAt)
            if (s.state == .ended && age > endedAfter) || age > staleAfter {
                remove(s)
                removed += 1
            }
        }
        return removed
    }

    // MARK: Internals

    private func write(_ session: AgentSession, to file: URL) throws {
        var s = session
        s.schema = AgentSession.schemaVersion
        let data = try Self.encoder.encode(s)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockPath = url.appendingPathComponent(".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// File-name-safe version of an id.
    static func safe(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return String((trimmed.isEmpty ? "_" : trimmed).prefix(120))
    }
}
