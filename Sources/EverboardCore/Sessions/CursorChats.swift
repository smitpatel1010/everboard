import Foundation
import GRDB

/// Reads Cursor's own chat records, for what its hooks don't report: the chat's name, and a multiple-choice
/// question its agent is waiting on (`ask_question` fires no hook). Cursor keeps them in
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `cursorDiskKV`:
/// `composerData:<chat id>` holds the chat, `bubbleId:<chat id>:<message id>/t:<call id>` its tool calls.
/// It's Cursor's internal format, so every read fails soft and returns nothing.
public enum CursorChats {
    public struct Question: Equatable, Sendable {
        public var id: String
        public var title: String?
        public var questions: [AgentSession.ChoiceQuestion]
        public var askedAt: Date?
    }

    public struct Info: Equatable, Sendable {
        public var name: String?
        /// A question shown in the chat and not answered yet.
        public var pendingQuestion: Question?
    }

    /// Opens the chat in Cursor's Agents Window. Cursor's `/agent` link takes the chat id; nil for an id that
    /// isn't one.
    public static func chatLink(chatId: String) -> String? {
        guard chatId.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return "cursor://anysphere.cursor-deeplink/agent?id=\(chatId)"
    }

    /// Whether this Cursor install handles the `/agent` link (older versions show "Unrecognized deep link").
    /// Read from the link handler Cursor ships, `extensions/cursor-deeplink/dist/main.js` inside the app.
    public static func supportsChatLinks(app: URL) -> Bool {
        let handler = app.appendingPathComponent("Contents/Resources/app/extensions/cursor-deeplink/dist/main.js")
        guard let data = try? Data(contentsOf: handler, options: .mappedIfSafe) else { return false }
        return data.range(of: Data(#""/agent""#.utf8)) != nil
    }

    public static func databaseURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public static func info(chatId: String, database: URL = databaseURL()) -> Info? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.5)
        guard let db = try? DatabaseQueue(path: database.path, configuration: config) else { return nil }
        return try? db.read { db -> Info in
            let chat = try String.fetchOne(db, sql: "SELECT CAST(value AS TEXT) FROM cursorDiskKV WHERE key = ?",
                                           arguments: ["composerData:\(chatId)"])
            // Key range scan (uses the key index), then only the tool-call rows.
            let tools = try String.fetchAll(db, sql: """
                SELECT CAST(value AS TEXT) FROM cursorDiskKV WHERE key >= ? AND key < ? AND key LIKE '%/t:%'
                """, arguments: ["bubbleId:\(chatId):", "bubbleId:\(chatId);"])
            return parse(chat: chat, toolCalls: tools)
        }
    }

    /// Pure part: the chat record and its tool-call records as JSON text.
    public static func parse(chat: String?, toolCalls: [String]) -> Info {
        var info = Info()
        if let chat, let obj = json(chat) {
            info.name = (obj["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        var pending: [Question] = []
        for text in toolCalls {
            guard let bubble = json(text), let tf = bubble["toolFormerData"] as? [String: Any],
                  (tf["name"] as? String) == "ask_question",
                  ((tf["additionalData"] as? [String: Any])?["status"] as? String) == "pending" else { continue }
            let params = (tf["params"] as? [String: Any]) ?? (tf["params"] as? String).flatMap(json) ?? [:]
            let questions = choiceQuestions(params)
            guard !questions.isEmpty else { continue }
            let id = (tf["toolCallId"] as? String) ?? (bubble["bubbleId"] as? String) ?? UUID().uuidString
            let at = (bubble["createdAt"] as? String).flatMap(Dates.parseISO)
            pending.append(Question(id: id, title: params["title"] as? String, questions: questions, askedAt: at))
        }
        info.pendingQuestion = pending.max { ($0.askedAt ?? .distantPast) < ($1.askedAt ?? .distantPast) }
        return info
    }

    static func choiceQuestions(_ params: [String: Any]) -> [AgentSession.ChoiceQuestion] {
        (params["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let prompt = (q["prompt"] as? String) ?? (q["question"] as? String), !prompt.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> AgentSession.ChoiceQuestion.Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return .init(label: label, description: (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            let multi = (q["allowMultiple"] as? Bool) ?? (q["allow_multiple"] as? Bool) ?? (q["multiSelect"] as? Bool) ?? false
            return .init(question: prompt, multiSelect: multi, options: options)
        }
    }

    static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
}

/// Finds the Cursor workspace a session's folders belong to, so a click brings that window forward instead of
/// opening one folder of a multi-folder workspace in a new window.
public enum CursorWorkspaces {
    public static func storageDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true)
    }

    /// The window a chat belongs to: its `.code-workspace` file or folder, from the workspace record that lists the
    /// chat (`workspaceStorage/<id>/state.vscdb`, key `composer.composerData`). Most recently used first.
    public static func workspace(forChat chatId: String, storage: URL = storageDirectory()) -> URL? {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { modified($0) > modified($1) }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.3)
        for dir in dirs {
            let dbPath = dir.appendingPathComponent("state.vscdb").path
            guard fm.fileExists(atPath: dbPath), let db = try? DatabaseQueue(path: dbPath, configuration: config) else { continue }
            let listed = (try? db.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ItemTable WHERE key = 'composer.composerData' AND instr(CAST(value AS TEXT), ?) > 0)",
                                  arguments: [chatId])
            }) ?? nil
            guard listed == true else { continue }
            return target(ofWorkspaceDirectory: dir)
        }
        return nil
    }

    /// `workspace.json` names either a `.code-workspace` file or a single folder.
    static func target(ofWorkspaceDirectory dir: URL) -> URL? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("workspace.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = (obj["workspace"] as? String) ?? (obj["folder"] as? String),
              let url = URL(string: raw), url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The `.code-workspace` file whose folders are exactly `roots`; failing that, the most recently used one
    /// that contains all of them. nil when the roots aren't part of a workspace file.
    public static func workspaceFile(forRoots roots: [String], storage: URL = storageDirectory()) -> URL? {
        let wanted = Set(roots.map(standard))
        guard !wanted.isEmpty else { return nil }
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var containing: [(URL, Date)] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: meta),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ws = obj["workspace"] as? String, let url = URL(string: ws), url.isFileURL,
                  fm.fileExists(atPath: url.path) else { continue }
            let folders = Set(self.folders(inWorkspaceFile: url).map(standard))
            if folders == wanted { return url }
            if wanted.isSubset(of: folders) {
                let used = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                containing.append((url, used))
            }
        }
        return roots.count > 1 ? containing.max { $0.1 < $1.1 }?.0 : nil
    }

    /// Folder paths in a `.code-workspace` file, resolved against the file's folder. Tolerates the comments and
    /// trailing commas these files often have.
    public static func folders(inWorkspaceFile url: URL) -> [String] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let cleaned = raw
            .replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #",(\s*[\]}])"#, with: "$1", options: .regularExpression)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else { return [] }
        let base = url.deletingLastPathComponent()
        return (obj["folders"] as? [[String: Any]] ?? []).compactMap { f in
            guard let path = f["path"] as? String else { return nil }
            return path.hasPrefix("/") ? path : base.appendingPathComponent(path).standardizedFileURL.path
        }
    }

    static func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
