import Foundation

public struct Article: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var source: String
    public var section: NewsSection
    public var snippet: String
    public var publishedAt: Date?
    /// Popularity where available (HN points, GitHub stars).
    public var score: Int?
    public var fetchedAt: Date
    /// Articles about the same story share a cluster key.
    public var clusterKey: String

    public init(url: String, title: String, source: String, section: NewsSection, snippet: String,
                publishedAt: Date?, score: Int? = nil, fetchedAt: Date = Date()) {
        let canonical = NewsText.canonicalURL(url)
        self.id = NewsText.hash(canonical)
        self.url = url
        self.title = title
        self.source = source
        self.section = section
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.score = score
        self.fetchedAt = fetchedAt
        self.clusterKey = id
    }
}

public enum NewsText {
    /// Normalises a URL for dedupe: https, no www, no tracking params, no fragment, no trailing slash.
    public static func canonicalURL(_ raw: String) -> String {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)) else { return raw }
        c.scheme = "https"
        if let h = c.host?.lowercased() { c.host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }
        c.fragment = nil
        c.queryItems = c.queryItems?.filter { item in
            !(item.name.hasPrefix("utm_") || ["ref", "ref_src", "cmpid", "ocid", "src", "fbclid", "gclid"].contains(item.name))
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        while c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path == "/" { c.path = "" }
        return c.string ?? raw
    }

    /// 64-bit FNV-1a, hex. Stable across launches (unlike Hasher).
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "has", "have", "its", "into", "over",
        "after", "about", "new", "says", "say", "will", "how", "why", "what", "who", "but", "not", "you", "your",
        "out", "more", "than", "his", "her", "they", "their", "been", "amid", "could", "would", "can",
    ]

    public static func tokens(_ title: String) -> Set<String> {
        let lowered = title.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        return Set(lowered.split(separator: " ").map(String.init).filter { $0.count > 2 && !stopwords.contains($0) })
    }

    /// Jaccard similarity of title tokens; ≥ 0.5 with ≥ 3 shared tokens counts as the same story.
    public static func sameStory(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shared = a.intersection(b).count
        guard shared >= 3 else { return false }
        return Double(shared) / Double(a.union(b).count) >= 0.5
    }

    /// Whole-word, case-insensitive keyword match ("AI" doesn't match "said").
    public static func matches(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { kw in
            let k = kw.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: k)
            let pattern = "(?<![A-Za-z0-9])" + escaped + (k.last?.isLetter == true || k.last?.isNumber == true ? "(?![A-Za-z0-9])" : "")
            let caseInsensitive = k.count > 3 || k != k.uppercased()
            return text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
        }
    }
}
