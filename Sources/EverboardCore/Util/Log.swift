import Foundation

/// Append-only log at ~/Library/Logs/Everboard.log (trimmed when it passes 2 MB).
public enum Log {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(AppInfo.name).log")
    }

    private static let queue = DispatchQueue(label: "everboard.log")

    public static func info(_ message: String) {
        let line = "\(Dates.iso(Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
