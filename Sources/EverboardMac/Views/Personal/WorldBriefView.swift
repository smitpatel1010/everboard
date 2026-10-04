import EverboardCore
import SwiftUI

/// The personal World & Tech brief with per-story feedback that tunes future briefs.
struct WorldBriefView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("news.tab") private var tab: NewsTab = .all
    @AppStorage("news.mode") private var mode: Mode = .brief
    @State private var note = ""
    @State private var sentNote = false
    @State private var question = ""

    enum Mode: String { case brief, live, following }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            askBar
            switch mode {
            case .brief: briefContent
            case .live: liveContent
            case .following: FollowingView()
            }
        }
        .navigationTitle("World & Tech")
        .task { await model.reloadArticles() }
    }

    var tabBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text("Brief").tag(Mode.brief)
                Text("Live feed").tag(Mode.live)
                Text("Following \(model.followed.count)").tag(Mode.following)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .help("Brief: Claude's ranked picks. Live feed: everything collected in the last 36h.")
            Divider().frame(height: 18)
            if mode != .following { Picker("", selection: $tab) {
                ForEach(NewsTab.allCases) { t in
                    Text(count(t).map { "\(t.title) \($0)" } ?? t.title).tag(t)
                }
            }
            .pickerStyle(.segmented) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
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
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
            TextField("Ask about today's news — e.g. “what's new in local LLMs this week?”", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)
            Button("Ask", action: ask).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || model.askRunning)
        }
        .padding(.horizontal).padding(.vertical, 8)
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
                VStack(alignment: .leading, spacing: 22) {
                    if tab == .all {
                        Text(brief.headline).font(.title3).fixedSize(horizontal: false, vertical: true)
                    }
                    if sections.isEmpty {
                        Text("Nothing in this tab for this brief — try the Live feed.").foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            if tab == .all || sections.count > 1 {
                                Text(section.name.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).tracking(1)
                            }
                            ForEach(section.stories) { StoryCard(story: $0) }
                        }
                    }
                    feedbackBox
                    Text("\(brief.candidateCount) articles considered" + (brief.costUSD.map { String(format: " · $%.2f", $0) } ?? ""))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else if model.newsRunning {
            EmptyState(icon: "globe", title: "Writing your first brief…", message: model.newsStatus ?? "")
        } else {
            EmptyState(icon: "globe", title: "No brief yet",
                       message: "World, AI and your-stack news, ranked for you by Claude. Rate stories with 👍/👎 and it learns what you like.")
        }
    }

    // MARK: Live feed

    @ViewBuilder var liveContent: some View {
        let articles = model.latestArticles.filter { tab.includes($0.section) }
        if articles.isEmpty {
            EmptyState(icon: "dot.radiowaves.left.and.right", title: "No articles yet",
                       message: "News is collected every \(Int(model.config.newsInterval / 60)) minutes. Use Refresh brief to collect now.")
        } else {
            List {
                ForEach(groupedByTime(articles), id: \.0) { label, items in
                    Section(label) {
                        ForEach(items) { ArticleRow(article: $0, showSection: tab == .all) }
                    }
                }
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

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("World & Tech Brief").font(.title2.weight(.semibold))
                Group {
                    if let s = model.newsStatus { Text(s) }
                    else if let b = model.newsBrief { Text("\(b.createdAt.formatted(date: .abbreviated, time: .shortened)) · next at \(nextRun)") }
                    else { Text("Runs daily at \(model.config.newsBriefTimes.joined(separator: " and "))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.newsRunning || model.preferencesUpdating { ProgressView().controlSize(.small) }
            if let b = model.newsBrief { SpeakButton(id: "brief.news", text: spokenBrief(b)) }
            Button("Preferences…") { model.settingsTab = "news"; model.showDashboard(.settings) }
            Button(model.newsBrief == nil ? "Generate now" : "Refresh brief") { model.generateNewsBrief() }
                .disabled(model.newsRunning)
        }
        .padding()
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
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
    @Environment(AppModel.self) private var model
    let story: NewsBrief.Story

    var vote: NewsFeedback.Vote? { model.newsVotes[story.key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                importance
                Text(story.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text(story.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(story.whyItMatters).font(.callout).foregroundStyle(.secondary).italic().fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(story.topics, id: \.self) { topic in
                    Menu {
                        Button("More about “\(topic)”") { model.feedback(story, .more, topic: topic) }
                        Button("Less about “\(topic)”") { model.feedback(story, .less, topic: topic) }
                    } label: {
                        Text(topic).font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
                if !story.sources.isEmpty {
                    Text(story.sources.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            HStack(spacing: 14) {
                Button { model.feedback(story, .up) } label: {
                    Image(systemName: vote == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                }.help("More stories like this")
                Button { model.feedback(story, .down) } label: {
                    Image(systemName: vote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }.help("Fewer stories like this")
                Button { model.goDeeper(story) } label: { Label("Go deeper", systemImage: "sparkles") }
                Button { model.toggleFollow(story) } label: {
                    Label(model.isFollowing(story) ? "Following" : "Follow",
                          systemImage: model.isFollowing(story) ? "binoculars.fill" : "binoculars")
                }.help("Get notified when this story develops")
                if let first = story.urls.first {
                    Button { model.open(first) } label: { Label("Read", systemImage: "arrow.up.right.square") }
                }
                if story.urls.count > 1 {
                    Menu("\(story.urls.count - 1) more") {
                        ForEach(story.urls.dropFirst(), id: \.self) { u in Button(URL(string: u)?.host ?? u) { model.open(u) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .opacity(vote == .down ? 0.55 : 1)
    }

    var importance: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Circle().fill(i < story.importance ? Color.orange : Color.secondary.opacity(0.25)).frame(width: 5, height: 5)
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
    @Environment(AppModel.self) private var model
    let article: Article
    var showSection = false

    var vote: NewsFeedback.Vote? { model.newsVotes["article:" + article.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title).font(.body.weight(.medium)).lineLimit(2)
                if !article.snippet.isEmpty {
                    Text(article.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if showSection { StatusPill(text: article.section.title) }
                    Text(article.source).font(.caption).foregroundStyle(.secondary)
                    if let score = article.score {
                        Label("\(score)", systemImage: article.source == "GitHub trending" ? "star" : "arrow.up")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                AgeText(date: article.publishedAt ?? article.fetchedAt)
                HStack(spacing: 8) {
                    Button { model.feedback(article: article, .up) } label: {
                        Image(systemName: vote == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    Button { model.feedback(article: article, .down) } label: {
                        Image(systemName: vote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 3)
        .opacity(vote == .down ? 0.5 : 1)
        .contentShape(Rectangle())
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
    @Environment(AppModel.self) private var model
    @State private var updates: [String: [StoryUpdate]] = [:]

    var body: some View {
        if model.followed.isEmpty {
            EmptyState(icon: "binoculars", title: "Not following anything",
                       message: "Tap Follow on a story in the brief. Everboard watches new articles every 30 minutes and notifies you when it develops.")
        } else {
            List {
                ForEach(model.followed) { story in
                    Section {
                        let ups = updates[story.key] ?? []
                        if ups.isEmpty {
                            Text("No updates yet — watching since \(story.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(ups) { u in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.title).lineLimit(2)
                                    Text(u.source).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                AgeText(date: u.publishedAt)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.open(u.url) }
                            .contextMenu { Button("Open") { model.open(u.url) } }
                        }
                    } header: {
                        HStack {
                            Text(story.title).font(.headline)
                            Spacer()
                            Button("Unfollow") { model.unfollow(story.key) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            .task(id: model.followed.map(\.key)) {
                for s in model.followed { updates[s.key] = await model.updates(for: s.key) }
            }
        }
    }
}
