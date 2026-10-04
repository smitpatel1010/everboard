import Foundation

public enum NewsSection: String, Codable, CaseIterable, Sendable {
    case world, ai, tech, stack

    public var title: String {
        switch self {
        case .world: return "World"
        case .ai: return "AI"
        case .tech: return "Tech"
        case .stack: return "Your stack"
        }
    }
}

public struct NewsSource: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// RSS 2.0 / RSS 1.0 / Atom feed.
        case feed
        /// Hacker News front page via the Firebase API.
        case hackerNews
        /// New GitHub repos gaining stars this week (search API).
        case githubTrending
    }

    public var id: String
    public var name: String
    public var url: String
    public var kind: Kind
    public var section: NewsSection
    public var enabled: Bool

    public init(id: String? = nil, name: String, url: String, kind: Kind = .feed, section: NewsSection, enabled: Bool = true) {
        self.id = id ?? url
        self.name = name
        self.url = url
        self.kind = kind
        self.section = section
        self.enabled = enabled
    }

    public static let defaults: [NewsSource] = [
        // World
        NewsSource(name: "BBC World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", section: .world),
        NewsSource(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", section: .world),
        NewsSource(name: "NPR World", url: "https://feeds.npr.org/1004/rss.xml", section: .world),
        NewsSource(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", section: .world),
        // AI
        NewsSource(name: "OpenAI News", url: "https://openai.com/news/rss.xml", section: .ai),
        NewsSource(name: "Google DeepMind", url: "https://deepmind.google/blog/rss.xml", section: .ai),
        NewsSource(name: "Google AI", url: "https://blog.google/technology/ai/rss/", section: .ai),
        NewsSource(name: "Hugging Face", url: "https://huggingface.co/blog/feed.xml", section: .ai),
        NewsSource(name: "Simon Willison", url: "https://simonwillison.net/atom/everything/", section: .ai),
        NewsSource(name: "MIT Tech Review AI", url: "https://www.technologyreview.com/topic/artificial-intelligence/feed", section: .ai),
        // Tech
        NewsSource(id: "hackernews", name: "Hacker News", url: "https://hacker-news.firebaseio.com/v0/", kind: .hackerNews, section: .tech),
        NewsSource(id: "github-trending", name: "GitHub trending", url: "https://api.github.com/search/repositories", kind: .githubTrending, section: .tech),
        NewsSource(name: "The Verge", url: "https://www.theverge.com/rss/index.xml", section: .tech),
        NewsSource(name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", section: .tech),
        NewsSource(name: "TechCrunch", url: "https://techcrunch.com/feed/", section: .tech),
        // Your stack
        NewsSource(name: "Claude Code releases", url: "https://github.com/anthropics/claude-code/releases.atom", section: .stack),
        NewsSource(name: "Ollama releases", url: "https://github.com/ollama/ollama/releases.atom", section: .stack),
        NewsSource(name: "Swift releases", url: "https://github.com/swiftlang/swift/releases.atom", section: .stack),
        NewsSource(name: "Go blog", url: "https://go.dev/blog/feed.atom", section: .stack),
        NewsSource(name: "Swift.org blog", url: "https://www.swift.org/atom.xml", section: .stack),
        NewsSource(name: "Apple Developer News", url: "https://developer.apple.com/news/rss/news.rss", section: .stack),
        NewsSource(name: "GitLab releases", url: "https://about.gitlab.com/releases.xml", section: .stack),
        NewsSource(name: "glab releases", url: "https://gitlab.com/gitlab-org/cli/-/tags?format=atom", section: .stack),
    ]
}
