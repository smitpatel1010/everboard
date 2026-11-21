import Foundation

/// Notices a Claude Code transcript records outside the conversation: hooks that failed or blocked,
/// API and connection errors, and informational notes. Hooks never receive these, so they're read from the
/// end of the transcript.
public enum SessionNotices {
    /// The newest notice in the last `tailBytes` of a transcript, if any.
    public static func latest(inTranscript path: String, tailBytes: Int = 64 * 1024) -> AgentSession.Notice? {
        guard let text = tail(of: path, bytes: tailBytes) else { return nil }
        return latest(inLines: text)
    }

    public static func latest(inLines text: String) -> AgentSession.Notice? {
        for line in text.split(separator: "\n").reversed() {
            // Cheap filter before parsing: most lines are messages.
            guard line.contains("hook_non_blocking_error") || line.contains("hook_blocking_error")
                    || line.contains("\"api_error\"") || line.contains("\"informational\"") else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let notice = notice(from: obj) else { continue }
            return notice
        }
        return nil
    }

    static func notice(from obj: [String: Any]) -> AgentSession.Notice? {
        let at = (obj["timestamp"] as? String).flatMap(Dates.parseISO) ?? Date()
        let uuid = (obj["uuid"] as? String) ?? (obj["timestamp"] as? String) ?? UUID().uuidString
        if let att = obj["attachment"] as? [String: Any], let type = att["type"] as? String {
            let hook = (att["hookName"] as? String) ?? "A hook"
            let detail = firstLine((att["stderr"] as? String) ?? (att["blockingError"] as? String) ?? "")
            switch type {
            case "hook_non_blocking_error":
                return .init(id: uuid, level: .error, text: clip("Hook \(hook) failed, so it didn't run" + (detail.isEmpty ? "" : ": \(detail)")), at: at, kind: .hook)
            case "hook_blocking_error":
                return .init(id: uuid, level: .error, text: clip("Hook \(hook) blocked an action" + (detail.isEmpty ? "" : ": \(detail)")), at: at, kind: .hook)
            default:
                return nil
            }
        }
        guard (obj["type"] as? String) == "system" else { return nil }
        switch obj["subtype"] as? String {
        case "api_error":
            let err = obj["error"] as? [String: Any]
            let text = (err?["formatted"] as? String) ?? (err?["message"] as? String) ?? "API error"
            return .init(id: uuid, level: .error, text: clip("API error: \(firstLine(text))"), at: at, kind: .api)
        case "informational":
            guard let content = obj["content"] as? String, !content.isEmpty else { return nil }
            let level: AgentSession.Notice.Level = ["error", "warning"].contains(obj["level"] as? String ?? "") ? .error : .info
            return .init(id: uuid, level: level, text: clip(firstLine(content)), at: at, kind: .info)
        default:
            return nil
        }
    }

    static func tail(of path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func clip(_ s: String, _ n: Int = 240) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
}
