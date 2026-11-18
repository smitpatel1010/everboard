import Foundation

/// A feed you add in Settings → Sources without writing Swift: a script that prints JSON, or a folder of markdown notes.
public struct CustomSourceConfig: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Runs `command` through zsh; stdout is JSON (see `CustomFeedParser`).
        case command
        /// Reads `*.md` files in `folder`; frontmatter becomes attrs.
        case folder

        public var label: String { self == .command ? "Command (JSON)" : "Markdown folder" }
    }

    /// Stable slug; part of every item id, so changing it re-baselines the feed.
    public var id: String
    public var name: String
    public var kind: Kind
    public var command: String
    public var folder: String
    /// Folder sources: only notes whose frontmatter `tags` include this. Empty = every note.
    public var tag: String
    public var intervalMinutes: Double
    public var notifyNew: Bool
    public var notifyStatus: Bool
    public var enabled: Bool

    public init(id: String, name: String, kind: Kind, command: String = "", folder: String = "", tag: String = "",
                intervalMinutes: Double = 10, notifyNew: Bool = true, notifyStatus: Bool = false, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.folder = folder
        self.tag = tag
        self.intervalMinutes = intervalMinutes
        self.notifyNew = notifyNew
        self.notifyStatus = notifyStatus
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .command
        command = (try? c.decodeIfPresent(String.self, forKey: .command)) ?? ""
        folder = (try? c.decodeIfPresent(String.self, forKey: .folder)) ?? ""
        tag = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? ""
        intervalMinutes = (try? c.decodeIfPresent(Double.self, forKey: .intervalMinutes)) ?? 10
        notifyNew = (try? c.decodeIfPresent(Bool.self, forKey: .notifyNew)) ?? true
        notifyStatus = (try? c.decodeIfPresent(Bool.self, forKey: .notifyStatus)) ?? false
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, command, folder, tag, intervalMinutes, notifyNew, notifyStatus, enabled }

    /// Data-source id and health key.
    public var sourceID: String { "custom.\(id)" }
    /// Store scope of the feed's items.
    public var scope: String { "custom.\(id).items" }

    /// Lower-case letters, digits and dashes from `name`, for new sources.
    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "feed" : String(joined.prefix(40))
    }
}

/// Parses what a command source prints. Either a bare array of items, or `{"items": [...], "mode": "accumulate"}`.
/// Each item: `id` and `title` required; optional `url`, `subtitle`, `status`, `author`, `kind`, `createdAt`/`updatedAt`
/// (ISO 8601 or Unix seconds) and `attrs` (an object; non-string values are converted to strings).
public enum CustomFeedParser {
    public struct Output: Sendable {
        public var items: [FeedItem]
        public var mode: ScopeMode
        /// Items skipped because they had no id or title.
        public var skipped: Int
    }

    public enum ParseError: Error, LocalizedError {
        case notJSON(String)
        case wrongShape

        public var errorDescription: String? {
            switch self {
            case .notJSON(let head): return "Output isn't JSON: \(head)"
            case .wrongShape: return "Expected a JSON array of items, or an object with an \"items\" array"
            }
        }
    }

    public static func parse(_ data: Data, source: CustomSourceConfig) throws -> Output {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ParseError.notJSON(String(String(decoding: data.prefix(120), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let list: [JSONValue]
        var mode = ScopeMode.replace
        switch json {
        case .array(let a): list = a
        case .object:
            guard case .array(let a) = json["items"] ?? .null else { throw ParseError.wrongShape }
            list = a
            if json["mode"]?.stringValue == "accumulate" { mode = .accumulate }
        default: throw ParseError.wrongShape
        }
        var items: [FeedItem] = [], skipped = 0, seen = Set<String>()
        for v in list.prefix(1000) {
            guard let rawID = scalar(v["id"]), !rawID.isEmpty, let title = scalar(v["title"]), !title.isEmpty else { skipped += 1; continue }
            let id = "\(source.sourceID):\(rawID)"
            guard seen.insert(id).inserted else { continue }
            var attrs: [String: String] = [:]
            if case .object(let o) = v["attrs"] ?? .null {
                for (k, value) in o { if let s = scalar(value) { attrs[k] = s } }
            }
            attrs["feed"] = source.id
            attrs["feedName"] = source.name
            items.append(FeedItem(id: id, source: "custom", kind: scalar(v["kind"]) ?? "item", title: title,
                                  subtitle: scalar(v["subtitle"]) ?? source.name, url: scalar(v["url"]), status: scalar(v["status"]),
                                  author: scalar(v["author"]), createdAt: date(v["createdAt"]), updatedAt: date(v["updatedAt"]),
                                  attrs: attrs))
        }
        return Output(items: items, mode: mode, skipped: skipped)
    }

    static func scalar(_ v: JSONValue?) -> String? {
        switch v ?? .null {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func date(_ v: JSONValue?) -> Date? {
        switch v ?? .null {
        case .string(let s): return Dates.parseISO(s)
        case .number(let n): return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        default: return nil
        }
    }
}

/// Events shared by both custom source kinds: a new item, or an item whose status changed.
enum CustomEvents {
    static func events(for change: ItemChange, source: CustomSourceConfig) -> [AppEvent] {
        let item = change.new
        if !change.everSeen {
            return [AppEvent(id: "custom.new:\(item.id)", category: .customNew, title: "\(source.name): \(item.title)",
                             body: [item.status, item.author].compactMap { $0 }.joined(separator: " · "), url: item.url,
                             scope: change.scope, itemId: item.id, wantsNotification: source.notifyNew)]
        }
        if let old = change.old?.status, let new = item.status, old != new {
            return [AppEvent(id: "custom.status:\(item.id):\(new)", category: .customStatus, title: "\(source.name): \(item.title)",
                             body: "\(old) → \(new)", url: item.url, scope: change.scope, itemId: item.id,
                             wantsNotification: source.notifyStatus)]
        }
        return []
    }
}

#if os(macOS)
/// Runs a command and turns its JSON output into feed items.
public struct CommandSource: DataSource {
    public let config: CustomSourceConfig
    public var id: String { config.sourceID }
    public var displayName: String { config.name }
    public var interval: TimeInterval { max(config.intervalMinutes, 1) * 60 }

    public init(config: CustomSourceConfig) { self.config = config }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        let shell = ShellCommand(command: config.command, environment: ["EVERBOARD_SOURCE": config.id], timeout: 120)
        let result = try await shell.run()
        guard result.outcome == .succeeded else {
            let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            throw HTTPError.notConfigured("command \(result.outcome == .timedOut ? "timed out" : "exited \(result.exitCode ?? -1)")"
                                          + (tail.isEmpty ? "" : " — \(tail)"))
        }
        let out = try CustomFeedParser.parse(result.stdout, source: config)
        return [ScopeResult(scope: config.scope, mode: out.mode, items: out.items)]
    }

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] { CustomEvents.events(for: change, source: self.config) }
}
#endif

/// Reads a folder of markdown notes (e.g. a project or tasks folder in your vault) as a feed.
public struct FolderSource: DataSource {
    public let config: CustomSourceConfig
    public var id: String { config.sourceID }
    public var displayName: String { config.name }
    public var interval: TimeInterval { max(config.intervalMinutes, 1) * 60 }
    public static let maxFiles = 500

    public init(config: CustomSourceConfig) { self.config = config }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        [ScopeResult(scope: config.scope, mode: .replace, items: try items())]
    }

    public func items() throws -> [FeedItem] {
        let root = URL(fileURLWithPath: (config.folder as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw HTTPError.notConfigured("folder not found: \(config.folder)")
        }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let wantedTag = config.tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        var items: [FeedItem] = []
        var scanned = 0
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "md" else { continue }
            scanned += 1
            if scanned > Self.maxFiles { break }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (fields, body) = Frontmatter.parse(text)
            if !wantedTag.isEmpty {
                let tags = (fields["tags"] ?? fields["tag"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() }
                guard tags.contains(wantedTag) else { continue }
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let heading = body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            var attrs = fields.filter { !$0.value.isEmpty }
            attrs["path"] = url.path
            attrs["feed"] = config.id
            attrs["feedName"] = config.name
            let folderName = (relative as NSString).deletingLastPathComponent
            items.append(FeedItem(id: "\(config.sourceID):\(relative)", source: "custom", kind: "note",
                                  title: fields["title"] ?? heading ?? url.deletingPathExtension().lastPathComponent,
                                  subtitle: folderName.isEmpty ? config.name : folderName,
                                  url: fields["url"].flatMap { $0.hasPrefix("http") ? $0 : nil }, status: fields["status"],
                                  author: fields["author"] ?? fields["owner"],
                                  createdAt: fields["created"].flatMap(Dates.parseISO) ?? values?.creationDate,
                                  updatedAt: values?.contentModificationDate, attrs: attrs))
        }
        return items
    }

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] { CustomEvents.events(for: change, source: self.config) }
}

public enum CustomSources {
    /// Data sources for every enabled custom feed.
    public static func sources(_ configs: [CustomSourceConfig]) -> [DataSource] {
        configs.filter(\.enabled).compactMap { c -> DataSource? in
            switch c.kind {
            case .folder: return c.folder.isEmpty ? nil : FolderSource(config: c)
            case .command:
                #if os(macOS)
                return c.command.isEmpty ? nil : CommandSource(config: c)
                #else
                return nil
                #endif
            }
        }
    }
}
