import Foundation

/// Adds and removes Everboard's hook entry in a coding agent's settings, leaving every other entry alone.
/// Everboard's entries are recognised by the `everboard-hook` binary name in their command.
public enum HookInstaller {
    public enum Target: String, CaseIterable, Sendable, Identifiable {
        case claudeCode = "claude-code"
        case cursor

        public var id: String { rawValue }
        public var displayName: String { AgentSession.toolName(rawValue) }

        /// `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) and `~/.cursor/hooks.json`.
        public func settingsURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory()) -> URL {
            switch self {
            case .claudeCode:
                let dir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
                    ?? "\(home)/.claude"
                return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
            case .cursor:
                return URL(fileURLWithPath: home).appendingPathComponent(".cursor/hooks.json")
            }
        }

        /// The tool's config folder; if it doesn't exist the tool probably isn't installed.
        public func configFolderExists(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: String = NSHomeDirectory()) -> Bool {
            FileManager.default.fileExists(atPath: settingsURL(environment: environment, home: home).deletingLastPathComponent().path)
        }

        /// Events Everboard listens to. Only names the tool knows: unknown names can make a settings file invalid.
        public var events: [String] {
            switch self {
            case .claudeCode:
                return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                        "PermissionRequest", "Notification", "Stop", "StopFailure", "PreCompact", "SessionEnd"]
            case .cursor:
                return ["beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
                        "beforeShellExecution", "afterShellExecution", "beforeMCPExecution", "afterMCPExecution",
                        "afterFileEdit", "afterAgentResponse", "afterAgentThought", "preCompact", "stop"]
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// Some events are missing or point at another binary path; installing again fixes it.
        case outdated
    }

    public static let marker = "everboard-hook"

    /// Seconds a tool waits for the hook. The permission hook may hold a prompt for Everboard to answer.
    static func timeout(for event: String, target: Target) -> Int {
        target == .claudeCode && event == "PermissionRequest" ? 620 : 10
    }

    /// The tools run this through a shell, so the path is quoted whenever it has anything but plain characters.
    public static func command(binary: String, target: Target) -> String {
        "\(SessionHooks.shellQuote(binary)) \(target.rawValue)"
    }

    // MARK: Pure JSON transforms

    public static func status(of json: [String: Any], target: Target, binary: String) -> Status {
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let wanted = command(binary: binary, target: target)
        var found = 0, exact = 0
        for event in target.events {
            let entries = ourEntries(in: hooks[event], target: target)
            if !entries.isEmpty { found += 1 }
            let current = entries.contains {
                $0["command"] as? String == wanted
                    && (target == .cursor || ($0["timeout"] as? Int ?? 0) >= timeout(for: event, target: target))
            }
            if current { exact += 1 }
        }
        if found == 0 { return .notInstalled }
        return exact == target.events.count ? .installed : .outdated
    }

    /// Settings with Everboard's entry on every event, replacing any older Everboard entry.
    public static func installing(into json: [String: Any], target: Target, binary: String) -> [String: Any] {
        var out = removing(from: json, target: target)
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        let cmd = command(binary: binary, target: target)
        for event in target.events {
            var list = hooks[event] as? [Any] ?? []
            switch target {
            case .claudeCode:
                list.append(["hooks": [["type": "command", "command": cmd, "timeout": timeout(for: event, target: target)]]])
            case .cursor:
                list.append(["command": cmd])
            }
            hooks[event] = list
        }
        out["hooks"] = hooks
        if target == .cursor && out["version"] == nil { out["version"] = 1 }
        return out
    }

    /// Settings without any Everboard entry. Groups and events left empty by the removal are dropped.
    public static func removing(from json: [String: Any], target: Target) -> [String: Any] {
        var out = json
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            var kept: [Any] = []
            for entry in list {
                guard var group = entry as? [String: Any] else { kept.append(entry); continue }
                switch target {
                case .claudeCode:
                    guard let inner = group["hooks"] as? [Any] else { kept.append(entry); continue }
                    let filtered = inner.filter { !isOurs($0) }
                    if filtered.count == inner.count { kept.append(entry); continue }
                    if !filtered.isEmpty { group["hooks"] = filtered; kept.append(group) }
                case .cursor:
                    if !isOurs(group) { kept.append(entry) }
                }
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        out["hooks"] = hooks
        return out
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    private static func ourEntries(in value: Any?, target: Target) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        let entries: [Any]
        switch target {
        case .claudeCode: entries = list.flatMap { (($0 as? [String: Any])?["hooks"] as? [Any]) ?? [] }
        case .cursor: entries = list
        }
        return entries.compactMap { $0 as? [String: Any] }.filter { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: Files

    public enum InstallError: LocalizedError {
        case unreadable(URL, String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let why): return "Couldn't read \(url.lastPathComponent): \(why). Fix the file, then try again."
            }
        }
    }

    public static func status(target: Target, binary: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory()) -> Status {
        guard let json = try? read(target.settingsURL(environment: environment, home: home)) else { return .notInstalled }
        return status(of: json, target: target, binary: binary)
    }

    public static func install(target: Target, binary: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: String = NSHomeDirectory()) throws {
        let url = target.settingsURL(environment: environment, home: home)
        let json = try read(url)
        try write(installing(into: json, target: target, binary: binary), to: url)
    }

    public static func uninstall(target: Target, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: String = NSHomeDirectory()) throws {
        let url = target.settingsURL(environment: environment, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try write(removing(from: try read(url), target: target), to: url)
    }

    /// A missing file is an empty object; a file that isn't a JSON object is an error, never overwritten.
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadable(url, "it isn't a JSON object")
            }
            return obj
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.unreadable(url, "it isn't valid JSON")
        }
    }

    /// Keeps a one-time backup of the original next to it, then writes atomically.
    static func write(_ json: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("before-everboard")
        if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Copies the hook binary to its stable location when it is missing or different.
    @discardableResult
    public static func installBinary(from source: URL, to destination: URL = SessionPaths.hookBinary()) throws -> Bool {
        let fm = FileManager.default
        if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: destination), a == b { return false }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try? fm.removeItem(at: destination)
        try fm.moveItem(at: tmp, to: destination)
        return true
    }
}
