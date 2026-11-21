import Foundation

/// Claude's desktop app keeps one record per session at
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<id>.json`, holding the
/// Claude Code session id it runs (`cliSessionId`). That maps a hook's session to the desktop session to open.
/// It's the app's own file format, not a documented one, so every lookup fails soft: no match means no link.
public enum ClaudeDesktopSessions {
    public static func recordsDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    static let hostIdPattern = #"^local_[A-Za-z0-9-]{1,64}$"#

    public static func isHostSessionId(_ s: String) -> Bool {
        s.range(of: hostIdPattern, options: .regularExpression) != nil
    }

    /// The desktop session that runs this Claude Code session, searching every record.
    public static func hostSessionId(forCLISession cliId: String, in dir: URL = recordsDirectory()) -> String? {
        session(forCLISession: cliId, in: dir)?.hostId
    }

    /// The desktop session's id and the title its sidebar shows.
    public static func session(forCLISession cliId: String, in dir: URL = recordsDirectory()) -> (hostId: String, title: String?)? {
        let needle = Data(cliId.utf8)
        for file in recordFiles(in: dir) {
            guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                  let rec = record(data), runs(rec, cliId), let id = rec["sessionId"] as? String, isHostSessionId(id) else { continue }
            let title = (rec["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return (id, title)
        }
        return nil
    }

    /// Whether the desktop session `hostId` runs `cliId`. nil when there's no record to check against.
    /// A Claude Code process started from inside a desktop session inherits that session's id, so the hook
    /// checks before trusting it.
    public static func confirms(hostId: String, runs cliId: String, in dir: URL = recordsDirectory()) -> Bool? {
        guard isHostSessionId(hostId) else { return false }
        let name = "\(hostId).json"
        guard let file = recordFiles(in: dir).first(where: { $0.lastPathComponent == name }),
              let data = try? Data(contentsOf: file), let rec = record(data) else { return nil }
        return runs(rec, cliId)
    }

    public static func openURL(hostSessionId: String) -> String? {
        isHostSessionId(hostSessionId) ? "claude://code/continue?session=\(hostSessionId)" : nil
    }

    static func runs(_ rec: [String: Any], _ cliId: String) -> Bool {
        rec["cliSessionId"] as? String == cliId || rec["lastAssistantCliSessionId"] as? String == cliId
    }

    static func record(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `<account>/<org>/local_*.json`, two levels down.
    static func recordFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                    where f.pathExtension == "json" && f.lastPathComponent.hasPrefix("local_") {
                    out.append(f)
                }
            }
        }
        return out
    }
}
