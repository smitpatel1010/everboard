import Foundation

/// Single place for the app's identity. Renaming the app = change these + scripts/build-app.sh.
public enum AppInfo {
    public static let name = "Everboard"
    public static let bundleID = "local.everboard.mac"
    public static let version = "0.1.0"

    /// ~/Library/Application Support/Everboard
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ~/Library/Caches/Everboard
    public static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var databaseURL: URL { supportDirectory.appendingPathComponent("everboard.sqlite") }
    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var newsPreferencesURL: URL { supportDirectory.appendingPathComponent("news-preferences.md") }

    /// The project folder this binary was built from, baked in at compile time
    /// (this file lives at <root>/Sources/EverboardCore/AppInfo.swift).
    public static let projectRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Where secrets are read from, first match wins:
    /// 1. `$EVERBOARD_SECRETS` (a file path), 2. `<project>/secrets.env` (git-ignored),
    /// 3. `$XDG_CONFIG_HOME/everboard/secrets.env` (default `~/.config/everboard/secrets.env`).
    /// If none exist yet: the project file when built from a source checkout, else the config one.
    public static var secretsURL: URL { secretsURL(environment: ProcessInfo.processInfo.environment) }

    public static func secretsURL(environment: [String: String], projectRoot: URL = projectRoot) -> URL {
        if let custom = environment["EVERBOARD_SECRETS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let project = projectRoot.appendingPathComponent("secrets.env")
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.config"
        let config = URL(fileURLWithPath: configHome).appendingPathComponent("everboard/secrets.env")
        let fm = FileManager.default
        if fm.fileExists(atPath: project.path) { return project }
        if fm.fileExists(atPath: config.path) { return config }
        return fm.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path) ? project : config
    }
}
