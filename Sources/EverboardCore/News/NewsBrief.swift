import Foundation

public struct NewsBrief: Codable, Sendable, Identifiable {
    public struct Story: Codable, Sendable, Hashable, Identifiable {
        /// Stable key used for feedback and "already shown".
        public var key: String
        public var title: String
        public var summary: String
        public var whyItMatters: String
        public var urls: [String]
        public var sources: [String]
        public var topics: [String]
        public var importance: Int
        public var id: String { key }
    }
    public struct Section: Codable, Sendable, Identifiable {
        public var name: String
        public var stories: [Story]
        public var id: String { name }
    }
    public var id: String
    public var createdAt: Date
    public var headline: String
    public var sections: [Section]
    public var candidateCount: Int
    public var costUSD: Double?
}

/// Collects news, alerts on major stories, writes the brief and learns from feedback.
public struct NewsService: Sendable {
    let store: Store
    let claude: ClaudeRunning
    let secrets: Secrets
    let preferencesURL: URL

    public init(store: Store, claude: ClaudeRunning, secrets: Secrets, preferencesURL: URL = AppInfo.newsPreferencesURL) {
        self.store = store
        self.claude = claude
        self.secrets = secrets
        self.preferencesURL = preferencesURL
    }

    // MARK: Collection

    public struct CollectResult: Sendable {
        public var newArticles: [Article]
        public var errors: [String: String]
        public var majorEvents: [AppEvent]
        public var followEvents: [AppEvent]
    }

    public func collect(config: AppConfig, now: Date = Date()) async throws -> CollectResult {
        let sources = config.newsSources.filter(\.enabled)
        let secrets = self.secrets
        var all: [Article] = []
        var errors: [String: String] = [:]
        await withTaskGroup(of: (String, Result<[Article], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s.name, .success(try await NewsFetchers.fetch(s, secrets: secrets))) }
                    catch { return (s.name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let a): all += a
                case .failure(let e): errors[name] = e.localizedDescription
                }
            }
        }
        let fresh = try await store.insertArticles(all, now: now)
        await store.setValue("news.collected.at", Dates.iso(now))
        var major: [AppEvent] = []
        if config.newsMajorAlerts {
            for e in MajorStory.detect(articles: try await store.articles(since: now.addingTimeInterval(-3 * 3600)),
                                       keywords: config.newsAlertKeywords, now: now) {
                if try await store.insert(event: e) { major.append(e) }
            }
        }
        let follow = try await store.matchFollowed(fresh, now: now)
        return CollectResult(newArticles: fresh, errors: errors, majorEvents: major, followEvents: follow)
    }

    // MARK: Brief

    static let briefSchema = """
    {"type":"object","properties":{"headline":{"type":"string"},"sections":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string","enum":["World","AI","Your tech","Worth a look"]},"items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"},"whyItMatters":{"type":"string"},"articleIds":{"type":"array","items":{"type":"string"}},"urls":{"type":"array","items":{"type":"string"}},"topics":{"type":"array","items":{"type":"string"}},"importance":{"type":"integer","minimum":1,"maximum":5}},"required":["title","summary","whyItMatters","articleIds","topics","importance"]}}},"required":["name","items"]}}},"required":["headline","sections"]}
    """

    private struct RawBrief: Decodable {
        struct Item: Decodable {
            let title: String
            let summary: String
            let whyItMatters: String
            let articleIds: [String]?
            let urls: [String]?
            let topics: [String]?
            let importance: Int?
        }
        struct Section: Decodable { let name: String; let items: [Item] }
        let headline: String
        let sections: [Section]
    }

    public func generateBrief(config: AppConfig, now: Date = Date()) async throws -> NewsBrief {
        let lastAt = await store.value("news.brief.at").flatMap(Dates.parseISO)
        let since = max(lastAt ?? .distantPast, now.addingTimeInterval(-36 * 3600)).addingTimeInterval(-3600)
        let shown = try await store.shownArticleIDs()
        var candidates = try await store.articles(since: since).filter { !shown.contains($0.id) }
        // Keep at most ~150, balanced across sections, highest score / newest first.
        candidates.sort { ($0.score ?? 0, $0.publishedAt ?? $0.fetchedAt) > ($1.score ?? 0, $1.publishedAt ?? $1.fetchedAt) }
        var perSection: [NewsSection: Int] = [:]
        candidates = candidates.filter { a in
            perSection[a.section, default: 0] += 1
            return perSection[a.section]! <= 45
        }

        var refs: [String: Article] = [:]
        let lines = candidates.enumerated().map { i, a -> String in
            let ref = "a\(i)"
            refs[ref] = a
            let score = a.score.map { " ★\($0)" } ?? ""
            return "[\(ref)] (\(a.section.title) · \(a.source)\(score)) \(a.title) — \(a.snippet.prefix(220))"
        }

        let preferences = loadPreferences()
        let feedback = try await store.feedback(unappliedOnly: false, limit: 30)
        let alreadyCovered = try await store.recentlyShownTitles()
        let gap = config.newsGapCheck

        let prompt = """
        Build my personal World & Tech brief for \(now.formatted(date: .complete, time: .shortened)).

        # My preferences (follow these strictly)
        \(preferences)
        \(config.newsRegion.isEmpty ? "" : "\nRegion of interest: \(config.newsRegion)\n")
        # Recent feedback on past items (newest first)
        \(feedback.map(Self.describe).joined(separator: "\n"))

        # Already covered in the last 3 days — do not repeat unless there is a significant update (then say what changed)
        \(alreadyCovered.prefix(80).map { "- \($0)" }.joined(separator: "\n"))

        # Instructions
        - Sections, in order: "World", "AI", "Your tech", "Worth a look". "Your tech" covers releases and news for the tools/languages in my preferences.
        - Merge articles about the same story into one item and list all their ids in articleIds.
        - 3–7 items per section, ranked by importance (1–5) to me. Skip a section only if nothing qualifies.
        - summary: 1–2 plain sentences of what happened. whyItMatters: one line on why I should care.
        - topics: 1–3 short lowercase topic tags (e.g. "llm releases", "geopolitics", "swift").
        - headline: one sentence capturing the day.
        \(gap ? "- Then use WebSearch (at most 3 searches) to check for major AI, tech or world stories from the last 24 hours missing from the candidates; add them with their urls and an empty articleIds." : "- Use only the candidates below.")

        # Candidates (\(candidates.count))
        \(lines.joined(separator: "\n"))
        """

        let r = try await claude.run(ClaudeRequest(
            prompt: prompt,
            systemPrompt: "You are a sharp news editor writing a personal daily brief. Be factual and concise; never invent facts beyond the provided material or your searches.",
            jsonSchema: Self.briefSchema, tools: gap ? ["WebSearch"] : [], timeout: 420, feature: "news.brief"))
        guard let structured = r.structured else { throw ClaudeError.failed("no structured output") }
        let raw = try structured.decode(RawBrief.self)

        var shownKeys: [(key: String, title: String)] = []
        let sections = raw.sections.map { s in
            NewsBrief.Section(name: s.name, stories: s.items.map { item in
                let arts = (item.articleIds ?? []).compactMap { refs[$0] }
                var urls = arts.map(\.url)
                for u in item.urls ?? [] where !urls.contains(u) { urls.append(u) }
                let key = "story:" + NewsText.hash(NewsText.tokens(item.title).sorted().joined(separator: " "))
                shownKeys += arts.map { ($0.id, item.title) }
                shownKeys.append((key, item.title))
                return NewsBrief.Story(key: key, title: item.title, summary: item.summary, whyItMatters: item.whyItMatters,
                                       urls: urls, sources: Array(Set(arts.map(\.source))).sorted(),
                                       topics: item.topics ?? [], importance: item.importance ?? 3)
            })
        }
        let brief = NewsBrief(id: Dates.iso(now), createdAt: now, headline: raw.headline, sections: sections,
                              candidateCount: candidates.count, costUSD: r.costUSD)
        try await store.saveBrief(brief)
        try await store.markShown(shownKeys, now: now)
        await store.setValue("news.brief.at", Dates.iso(now))
        return brief
    }

    // MARK: Go deeper

    public func goDeeper(_ story: NewsBrief.Story) async throws -> String {
        let cacheKey = "news.deeper:\(story.key)"
        if let cached = await store.cached(cacheKey) { return cached }
        let prompt = """
        Go deeper on this story for me. Read the sources with WebFetch (and WebSearch if they're thin), then write:
        ## What happened — the key facts, numbers and dates.
        ## Context — how we got here.
        ## What to watch — what happens next, and what it means for someone working in software/AI.
        Keep it under 300 words. End with a "Sources" list of the links you used.

        Story: \(story.title)
        Summary: \(story.summary)
        Sources:
        \(story.urls.map { "- \($0)" }.joined(separator: "\n"))
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, tools: ["WebFetch", "WebSearch"], timeout: 300, feature: "news.deeper"))
        await store.cache(cacheKey, r.text)
        return r.text
    }

    // MARK: Preferences & feedback

    public static let defaultPreferences = """
    # News preferences

    ## Include
    - AI: frontier model releases and evals (Anthropic/Claude, OpenAI, Google, Meta), open-weight and local models (Ollama, llama.cpp), AI coding tools and agents, notable research with practical impact, AI policy.
    - My stack: Go, Swift / SwiftUI / macOS, Claude Code, GitLab, Jira/Atlassian, developer tooling.
    - Tech: big-tech moves, security incidents and major outages, notable open-source projects.
    - World: the most important global headlines of the day, briefly.

    ## Exclude
    - Celebrity and entertainment gossip, sports results, deal-of-the-day posts, listicles.

    ## Style
    - Prefer primary sources (official blogs, release notes) over aggregators.
    - Depth: short summaries; flag anything I can try hands-on.
    """

    public func loadPreferences() -> String {
        if let s = try? String(contentsOf: preferencesURL, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        try? Self.defaultPreferences.write(to: preferencesURL, atomically: true, encoding: .utf8)
        return Self.defaultPreferences
    }

    public func savePreferences(_ text: String) throws {
        try text.write(to: preferencesURL, atomically: true, encoding: .utf8)
    }

    static func describe(_ f: NewsFeedback) -> String {
        switch f.vote {
        case .up: return "- 👍 liked: \(f.title ?? "")"
        case .down: return "- 👎 disliked: \(f.title ?? "")"
        case .more: return "- wants MORE about \"\(f.topic ?? "")\" (from: \(f.title ?? ""))"
        case .less: return "- wants LESS about \"\(f.topic ?? "")\" (from: \(f.title ?? ""))"
        case .note: return "- note: \(f.note ?? "")"
        }
    }

    public struct PreferenceUpdate: Sendable {
        public var markdown: String
        public var alertKeywords: [String]
    }

    /// Rewrites the preferences file from accumulated feedback. Returns the new text and alert keywords.
    public func applyFeedback() async throws -> PreferenceUpdate? {
        let pending = try await store.feedback(unappliedOnly: true)
        guard !pending.isEmpty else { return nil }
        let schema = """
        {"type":"object","properties":{"preferences":{"type":"string"},"alertKeywords":{"type":"array","items":{"type":"string"}}},"required":["preferences","alertKeywords"]}
        """
        let prompt = """
        Update my news preferences document based on my new feedback. Keep the same markdown structure \
        (Include / Exclude / Style sections), merge the feedback in, keep it concise (under 40 lines), \
        and don't drop existing preferences unless the feedback contradicts them. Also return 10–25 alertKeywords: \
        short names/terms (products, companies, technologies) that should trigger a "major story" alert for me.

        # Current preferences
        \(loadPreferences())

        # New feedback (newest first)
        \(pending.map(Self.describe).joined(separator: "\n"))
        """
        let r = try await claude.run(ClaudeRequest(prompt: prompt, jsonSchema: schema, feature: "news.preferences"))
        guard let s = r.structured, let md = s["preferences"]?.stringValue else { throw ClaudeError.failed("no structured output") }
        try savePreferences(md)
        try await store.markFeedbackApplied()
        let keywords = (s["alertKeywords"]?.arrayValue ?? []).compactMap(\.stringValue)
        return PreferenceUpdate(markdown: md, alertKeywords: keywords)
    }
}

/// Cheap, Claude-free detection of big stories for instant alerts.
public enum MajorStory {
    public static func detect(articles: [Article], keywords: [String], now: Date = Date(),
                              minHNScore: Int = 600, minSources: Int = 3) -> [AppEvent] {
        let clusters = Dictionary(grouping: articles, by: \.clusterKey)
        var events: [AppEvent] = []
        for (key, group) in clusters {
            let sources = Set(group.map(\.source))
            let topHN = group.filter { $0.source == "Hacker News" }.compactMap(\.score).max() ?? 0
            guard sources.count >= minSources || topHN >= minHNScore else { continue }
            guard let lead = group.max(by: { ($0.score ?? 0) < ($1.score ?? 0) }) ?? group.first,
                  group.contains(where: { NewsText.matches($0.title, keywords: keywords) }) else { continue }
            let why = sources.count >= minSources ? "Covered by \(sources.sorted().joined(separator: ", "))" : "\(topHN) points on Hacker News"
            events.append(AppEvent(id: "news.major:\(key)", ts: now, category: .newsMajor,
                                   title: "Major story: \(lead.title)", body: why, url: lead.url, scope: "news"))
        }
        return events
    }
}
