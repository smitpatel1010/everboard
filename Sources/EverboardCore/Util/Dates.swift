import Foundation

public enum Dates {
    /// Parses the ISO-8601 flavours GitLab, Jira and GitHub emit:
    /// `2026-10-03T12:34:56Z`, `2026-10-03T12:34:56.123Z`, `2026-10-03T12:34:56.000+0530`.
    public static func parseISO(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d }
        // Jira uses +0530 (no colon) which ISO8601DateFormatter rejects.
        for f in jiraFormatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    /// RFC-822 dates used by RSS (`Sat, 03 Oct 2026 08:00:00 GMT`), plus ISO fallbacks.
    public static func parseFeedDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = parseISO(s) { return d }
        for f in rfc822Formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    public static func iso(_ d: Date) -> String { isoPlain.string(from: d) }

    /// "3m", "5h", "2d" — compact relative age for list rows.
    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86400: return "\(Int(s / 3600))h"
        default: return "\(Int(s / 86400))d"
        }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let jiraFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd",
    ].map(posixFormatter)

    private static let rfc822Formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm zzz",
    ].map(posixFormatter)

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }
}

extension JSONDecoder {
    /// Decoder that understands every date format our upstream APIs use.
    public static var everboard: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            guard let date = Dates.parseISO(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
            }
            return date
        }
        return d
    }
}

extension JSONEncoder {
    public static var everboard: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
