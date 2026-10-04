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

    /// <project>/secrets.env — git-ignored, kept next to the code on purpose.
    public static var secretsURL: URL { projectRoot.appendingPathComponent("secrets.env") }
}
