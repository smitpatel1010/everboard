import EverboardCore
import SwiftUI

/// The personal World & Tech brief with per-story feedback that tunes future briefs.
struct WorldBriefView: View {
    private var model: AppModel { .shared }
    @AppStorage("news.tab") private var tab: NewsTab = .all
    @AppStorage("news.mode") private var mode: Mode = .brief
    @State private var note = ""
    @State private var sentNote = false
    @State private var question = ""

    enum Mode: String { case brief, live, following }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("World & Tech", subtitle: subtitle) {
                if model.newsRunning || model.preferencesUpdating { ProgressView().controlSize(.small) }
                if let b = model.newsBrief { SpeakButton(id: "brief.news", text: spokenBrief(b)) }
                Button { model.settingsTab = "news"; model.showDashboard(.settings) } label: { Label("Preferences", systemImage: "slider.horizontal.3") }
                Button(model.newsBrief == nil ? "Generate now" : "Refresh") { model.generateNewsBrief() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(model.newsRunning)
            }
            Toolbar {
                TabBar(tabs: [.init(id: Mode.brief.rawValue, title: "Brief"), .init(id: Mode.live.rawValue, title: "Live feed"),
                              .init(id: Mode.following.rawValue, title: "Following", count: model.followed.count)],
                       selection: Binding(get: { mode.rawValue }, set: { mode = Mode(rawValue: $0) ?? .brief }))
            } trailing: {
                if mode != .following {
                    TabBar(tabs: NewsTab.allCases.map { .init(id: $0.rawValue, title: $0.title, count: count($0)) },
                           selection: Binding(get: { tab.rawValue }, set: { tab = NewsTab(rawValue: $0) ?? .all }))
                }
            }
            switch mode {
            case .brief: briefContent
            case .live: liveContent
            case .following: FollowingView()
            }
        }
        .task { await model.reloadArticles() }
    }

    var subtitle: String {
        if let s = model.newsStatus { return s }
        if let b = model.newsBrief { return "\(b.createdAt.formatted(date: .abbreviated, time: .shortened)) · next at \(nextRun)" }
        return "Runs daily at \(model.config.newsBriefTimes.joined(separator: " and "))"
    }

    func count(_ t: NewsTab) -> Int? {
        switch mode {
        case .brief:
            guard let b = model.newsBrief else { return nil }
            return b.sections.filter { t.includes(briefSection: $0.name) }.reduce(0) { $0 + $1.stories.count }
        case .live:
            return model.latestArticles.filter { t.includes($0.section) }.count
        case .following:
            return nil
        }
    }

    var askBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            TextField("Ask about today's news… “what's new in local LLMs this week?”", text: $question)
                .textFieldStyle(.plain).font(.system(size: 14))
                .onSubmit(ask)
            if model.askRunning { ProgressView().controlSize(.small) }
            Button("Ask", action: ask).buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || model.askRunning)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.ask(q)
        question = ""
    }

    // MARK: Brief

    @ViewBuilder var briefContent: some View {
        if let brief = model.newsBrief {
            let sections = brief.sections.filter { tab.includes(briefSection: $0.name) && !$0.stories.isEmpty }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    askBar
                    if tab == .all {
                        HStack(alignment: .top, spacing: 14) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.accentGradient).frame(width: 4)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("TODAY").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).tracking(1)
                                Text(brief.headline).font(.system(size: 22, weight: .semibold, design: .serif))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("Nothing in this topic for this brief. Try the Live feed.").foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            if tab == .all || sections.count > 1 {
                                HStack(spacing: 8) {
                                    Text(section.name).font(.title3.weight(.semibold))
                                    Text("\(section.stories.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07)))
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                                ForEach(section.stories) { StoryCard(story: $0) }
                            }
                        }
                    }
                    feedbackBox
                    Text("\(brief.candidateCount) articles considered" + (brief.costUSD.map { String(format: " · $%.2f", $0) } ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else if model.newsRunning {
            EmptyHint(icon: "globe", title: "Writing your first brief…", message: model.newsStatus ?? "")
        } else {
            EmptyHint(icon: "globe", title: "No brief yet",
                      message: "World, AI and your-stack news, ranked for you. Rate stories and it learns what you like.",
                      action: ("Generate now", { model.generateNewsBrief() }))
        }
    }

    // MARK: Live feed

    @ViewBuilder var liveContent: some View {
        let articles = model.latestArticles.filter { tab.includes($0.section) }
        if articles.isEmpty {
            EmptyHint(icon: "dot.radiowaves.left.and.right", title: "No articles yet",
                      message: "News is collected every \(Int(model.config.newsInterval / 60)) minutes. Refresh collects now.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedByTime(articles), id: \.0) { label, items in
                        Section {
                            ForEach(items) { ArticleRow(article: $0, showSection: tab == .all) }
                        } header: {
                            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4).background(Theme.canvas)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
    }

    func groupedByTime(_ articles: [Article]) -> [(String, [Article])] {
        let now = Date()
        var out: [(String, [Article])] = []
        for a in articles {
            let age = now.timeIntervalSince(a.publishedAt ?? a.fetchedAt)
            let label = age < 3 * 3600 ? "Last 3 hours" : age < 12 * 3600 ? "Earlier today" : "Yesterday & older"
            if out.last?.0 == label { out[out.count - 1].1.append(a) } else { out.append((label, [a])) }
        }
        return out
    }

    /// The brief as a script: headline, then each story's title and summary, respecting the current tab.
    func spokenBrief(_ b: NewsBrief) -> String {
        var lines = [b.headline]
        for section in b.sections where tab.includes(briefSection: section.name) && !section.stories.isEmpty {
            lines.append("# \(section.name)")
            for s in section.stories { lines.append("\(s.title). \(s.summary)") }
        }
        return lines.joined(separator: "\n")
    }

    var nextRun: String {
        let now = Date()
        let times = model.config.newsBriefTimes.sorted()
        return times.first { t in
            let p = t.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, let d = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: now) else { return false }
            return d > now
        } ?? (times.first.map { "\($0) tomorrow" } ?? "—")
    }

    var feedbackBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell it what you want").font(.headline)
            Text("e.g. “skip crypto”, “more on local LLMs and Swift”, “shorter world section”. Claude rewrites your preferences right away.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Feedback for future briefs", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button("Send", action: send).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if sentNote {
                Label(model.preferencesUpdating ? "Updating your preferences…" : "Preferences updated — applies to the next brief.",
                      systemImage: model.preferencesUpdating ? "hourglass" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    func send() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.feedback(nil, .note, note: text)
        note = ""
        sentNote = true
    }
}

struct StoryCard: View {
    private var model: AppModel { .shared }
    let story: NewsBrief.Story
    @State private var hovering = false

    var vote: NewsFeedback.Vote? { model.newsVotes[story.key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                importance
                if !story.sources.isEmpty {
                    Text(story.sources.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.isFollowing(story) { Image(systemName: "binoculars.fill").font(.caption).foregroundStyle(Theme.accent).help("Following") }
            }
            Button { if let u = story.urls.first { model.open(u) } } label: {
                Text(story.title).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            Text(story.summary).font(.callout).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            if !story.whyItMatters.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb").font(.caption).foregroundStyle(.orange)
                    Text(story.whyItMatters).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if !story.topics.isEmpty {
                HStack(spacing: 6) {
                    ForEach(story.topics, id: \.self) { topic in
                        Menu {
                            Button("More about “\(topic)”") { model.feedback(story, .more, topic: topic) }
                            Button("Less about “\(topic)”") { model.feedback(story, .less, topic: topic) }
                        } label: { Text("#" + topic).font(.caption) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.1)))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                iconButton(vote == .up ? "hand.thumbsup.fill" : "hand.thumbsup", "More like this", active: vote == .up) { model.feedback(story, .up) }
                iconButton(vote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown", "Fewer like this", active: vote == .down) { model.feedback(story, .down) }
                Spacer()
                Button { model.goDeeper(story) } label: { Label("Go deeper", systemImage: "sparkles") }
                Button { model.toggleFollow(story) } label: {
                    Label(model.isFollowing(story) ? "Following" : "Follow", systemImage: model.isFollowing(story) ? "binoculars.fill" : "binoculars")
                }
                .help("Get notified when this story develops")
                if story.urls.count > 1 {
                    Menu {
                        ForEach(story.urls, id: \.self) { u in Button(URL(string: u)?.host ?? u) { model.open(u) } }
                    } label: { Label("\(story.urls.count) sources", systemImage: "link") }
                    .menuStyle(.borderlessButton).fixedSize()
                } else if let first = story.urls.first {
                    Button { model.open(first) } label: { Label("Read", systemImage: "arrow.up.right") }
                }
            }
            .buttonStyle(.borderless).font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovering ? Theme.accent.opacity(0.45) : Theme.hairline))
        .opacity(vote == .down ? 0.55 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    func iconButton(_ icon: String, _ help: String, active: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.05)))
                .foregroundStyle(active ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain).help(help)
    }

    var importance: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule().fill(i < story.importance ? Color.orange : Color.secondary.opacity(0.2)).frame(width: 8, height: 4)
            }
        }
        .help("Importance \(story.importance)/5")
    }
}

/// Tabs shared by the Brief and the Live feed.
enum NewsTab: String, CaseIterable, Identifiable {
    case all, world, ai, tech, stack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .world: return "World"
        case .ai: return "AI"
        case .tech: return "Tech"
        case .stack: return "Your stack"
        }
    }

    func includes(_ section: NewsSection) -> Bool {
        switch self {
        case .all: return true
        case .world: return section == .world
        case .ai: return section == .ai
        case .tech: return section == .tech
        case .stack: return section == .stack
        }
    }

    /// Brief sections are named by Claude: World, AI, Your tech, Worth a look.
    func includes(briefSection name: String) -> Bool {
        switch self {
        case .all: return true
        case .world: return name == "World"
        case .ai: return name == "AI"
        case .tech: return name == "Worth a look"
        case .stack: return name == "Your tech"
        }
    }
}

struct ArticleRow: View {
    private var model: AppModel { .shared }
    let article: Article
    var showSection = false
    @State private var hovering = false

    var vote: NewsFeedback.Vote? { model.newsVotes["article:" + article.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: article.source, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title).fontWeight(.medium).lineLimit(2)
                if !article.snippet.isEmpty {
                    Text(article.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(article.source).font(.caption).foregroundStyle(.secondary)
                    if showSection { Tag(text: article.section.title, color: .secondary) }
                    if let score = article.score {
                        Label("\(score)", systemImage: article.source == "GitHub trending" ? "star" : "arrow.up").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if hovering || vote != nil {
                HStack(spacing: 4) {
                    Button { model.feedback(article: article, .up) } label: { Image(systemName: vote == .up ? "hand.thumbsup.fill" : "hand.thumbsup") }
                    Button { model.feedback(article: article, .down) } label: { Image(systemName: vote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                    Button { model.open(article.url) } label: { Image(systemName: "arrow.up.right") }
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text(Dates.age(article.publishedAt ?? article.fetchedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover : .clear))
        .opacity(vote == .down ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(article.url) }
        .contextMenu {
            Button("Open") { model.open(article.url) }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(article.url, forType: .string)
            }
        }
    }
}

/// Stories you follow and the updates found for each.
struct FollowingView: View {
    private var model: AppModel { .shared }
    @State private var updates: [String: [StoryUpdate]] = [:]

    var body: some View {
        if model.followed.isEmpty {
            EmptyHint(icon: "binoculars", title: "Not following anything",
                      message: "Tap Follow on a story in the brief. Everboard watches new articles every 30 minutes and notifies you when it develops.")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(model.followed) { story in
                        let ups = updates[story.key] ?? []
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    Image(systemName: "binoculars.fill").foregroundStyle(Theme.accent)
                                    Text(story.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button("Unfollow") { model.unfollow(story.key) }.buttonStyle(.borderless).font(.caption)
                                }
                                if ups.isEmpty {
                                    Text("No updates yet. Watching since \(story.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(ups) { u in
                                    Button { model.open(u.url) } label: {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(u.title).lineLimit(2).multilineTextAlignment(.leading)
                                                Text(u.source).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(Dates.age(u.publishedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .task(id: model.followed.map(\.key)) {
                for s in model.followed { updates[s.key] = await model.updates(for: s.key) }
            }
        }
    }
}
