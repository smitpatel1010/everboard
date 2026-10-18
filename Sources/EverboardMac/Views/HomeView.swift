import EverboardCore
import SwiftUI

/// The landing page: today at a glance, what needs you, your team, Jira, meetings, the brief and the news.
/// Everything here is computed locally from data already fetched; nothing on this page calls Claude by itself.
struct HomeView: View {
    private var model: AppModel { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HomeHeader()
                KPIRow()
                HStack(alignment: .top, spacing: 18) {
                    mainColumn.frame(minWidth: 380, maxWidth: .infinity)
                    sideColumn.frame(width: 330)
                }
            }
            .padding(22)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Home")
    }

    var mainColumn: some View {
        VStack(spacing: 18) {
            NeedsYouCard()
            BriefCard()
            ActivityCard()
        }
    }

    var sideColumn: some View {
        VStack(spacing: 18) {
            TodayCard()
            TeamCard()
            JiraCard()
            NewsCard()
            AICard()
        }
    }
}

// MARK: - Building blocks

private struct HomeCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .accentColor
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.headline)
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.link).font(.callout)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

private struct QuietText: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}

/// Clickable row with a tinted icon, used by most cards.
private struct HomeRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var tag: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 26, height: 26).background(tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let tag {
                    Text(tag).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.14), in: Capsule()).foregroundStyle(tint).lineLimit(1)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(hover ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Header

private struct HomeHeader: View {
    private var model: AppModel { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting(ctx.date)).font(.system(size: 28, weight: .bold))
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.title3).opacity(0.9)
                    if !summary.isEmpty {
                        Text(summary).font(.callout.weight(.medium)).opacity(0.95).padding(.top, 4)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(model.health.keys.sorted(), id: \.self) { key in
                            let h = model.health[key]!
                            HStack(spacing: 5) {
                                Circle().fill(h.isHealthy ? Color.green : (h == .idle ? Color.white.opacity(0.6) : Color.orange)).frame(width: 7, height: 7)
                                Text(model.sourceName(key)).font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                            .help(h.label)
                        }
                    }
                    if let next = model.calendar.next {
                        Label(next.isNow ? "Now: \(next.title)" : "Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))",
                              systemImage: "calendar")
                            .font(.callout.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 0.24, green: 0.36, blue: 0.95), Color(red: 0.52, green: 0.30, blue: 0.90),
                                        Color(red: 0.85, green: 0.35, blue: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18))
        }
    }

    func greeting(_ now: Date) -> String {
        let h = Calendar.current.component(.hour, from: now)
        let part = h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        guard let first = model.myName?.split(separator: " ").first else { return part }
        return "\(part), \(first)"
    }

    /// "2 reviews waiting · 1 red pipeline on your MRs · 3 meetings today"
    var summary: String {
        var parts: [String] = []
        let reviews = model.items.reviewReady.count
        if reviews > 0 { parts.append("\(reviews) review\(reviews == 1 ? "" : "s") waiting") }
        let red = model.items.mine.filter { $0["pipelineStatus"] == "failed" }.count
        if red > 0 { parts.append("\(red) red pipeline\(red == 1 ? "" : "s") on your changes") }
        let meetings = model.calendar.today.filter { $0.end > Date() }.count
        if meetings > 0 { parts.append("\(meetings) meeting\(meetings == 1 ? "" : "s") left today") }
        if parts.isEmpty && model.hasCodeHost { return "Nothing urgent. A good day for deep work." }
        return parts.joined(separator: " · ")
    }
}

// MARK: - KPIs

private struct KPIRow: View {
    private var model: AppModel { .shared }

    var body: some View {
        let i = model.items
        let red = i.mine.filter { $0["pipelineStatus"] == "failed" }.count
        let ready = i.mine.filter(HomeLogic.readyToMerge).count
        let failed = i.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-86400) }.count
        let high = i.jiraAssigned.filter(HomeLogic.isHighPriority).count
        let oldestReview = i.reviewReady.compactMap(\.createdAt).min()
        HStack(spacing: 12) {
            KPITile(icon: "eye", tint: .blue, value: i.reviewReady.count, title: "To review",
                    detail: oldestReview.map { "oldest \(Dates.age($0))" } ?? "queue is clear") { model.selection = .mergeRequests }
            KPITile(icon: "arrow.triangle.pull", tint: .purple, value: i.mine.count, title: "My open " + (model.changesTitle == "Pull Requests" ? "PRs" : model.changesTitle == "MRs & PRs" ? "MRs & PRs" : "MRs"),
                    detail: "\(red) red · \(ready) ready") { model.selection = .mergeRequests }
            KPITile(icon: "xmark.octagon", tint: failed > 0 ? .red : .green, value: failed, title: "Failed pipelines",
                    detail: "last 24 hours") { model.selection = .pipelines }
            KPITile(icon: "checklist", tint: .orange, value: i.jiraAssigned.count, title: "Jira assigned",
                    detail: high > 0 ? "\(high) high priority" : "none high priority") { model.selection = .jira }
            KPITile(icon: "tray", tint: .teal, value: model.unread, title: "Unread", detail: "in your inbox") { model.selection = .inbox }
        }
    }
}

private struct KPITile: View {
    let icon: String
    let tint: Color
    let value: Int
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 30, height: 30).background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
                }
                Text("\(value)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hover ? tint.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.6)))
            .shadow(color: .black.opacity(hover ? 0.08 : 0.04), radius: hover ? 10 : 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Needs you

enum HomeLogic {
    static func readyToMerge(_ i: FeedItem) -> Bool {
        i["approvedBy"] != nil && i["draft"] != "1" && (i["mergeStatus"] ?? "mergeable") == "mergeable" && i["pipelineStatus"] != "failed"
            && i["pipelineStatus"] != "running"
    }

    static func isHighPriority(_ i: FeedItem) -> Bool {
        ["highest", "high", "blocker", "critical"].contains((i["priority"] ?? "").lowercased()) && i["statusCategory"] != "done"
    }

    static func dueSoon(_ i: FeedItem, now: Date = Date()) -> Bool {
        guard let due = i["due"], i["statusCategory"] != "done" else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: due) else { return false }
        return d < now.addingTimeInterval(2 * 86400)
    }

    static func isStuck(_ i: FeedItem, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(i.createdAt ?? now)
        return i["draft"] != "1" && (age > 3 * 86400 || (i["pipelineStatus"] == "failed" && age > 86400))
    }

    static let priorityRank = ["blocker": 0, "highest": 0, "critical": 0, "high": 1, "medium": 2, "low": 3, "lowest": 4]
}

private struct NeedsYouCard: View {
    private var model: AppModel { .shared }

    struct Focus: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
        let tag: String
        let url: String?
        var item: FeedItem?
        var event: AppEvent?
    }

    var focus: [Focus] {
        let i = model.items
        var out: [Focus] = []
        for mr in i.mine where mr["pipelineStatus"] == "failed" {
            out.append(Focus(id: "red." + mr.id, icon: "xmark.octagon.fill", tint: .red, title: mr.title,
                             detail: "\(mr.subtitle) · pipeline failed", tag: "Fix pipeline", url: mr["pipelineUrl"] ?? mr.url, item: mr))
        }
        for mr in i.reviewReady.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
            out.append(Focus(id: "rev." + mr.id, icon: "eye.fill", tint: .blue, title: mr.title,
                             detail: "\(mr["authorName"] ?? mr.author ?? "?") · waiting \(Dates.age(mr.createdAt))", tag: "Review", url: mr.url, item: mr))
        }
        for e in model.events where !e.read && [.todoMention, .jiraMention].contains(e.category) {
            out.append(Focus(id: "men." + e.id, icon: "at", tint: .pink, title: e.title,
                             detail: e.body.replacingOccurrences(of: "\n", with: " · "), tag: "Mention", url: e.url, event: e))
        }
        for issue in i.jiraAssigned where HomeLogic.isHighPriority(issue) || HomeLogic.dueSoon(issue) {
            let due = HomeLogic.dueSoon(issue)
            out.append(Focus(id: "jira." + issue.id, icon: due ? "calendar.badge.exclamationmark" : "flame.fill", tint: .orange,
                             title: issue.title, detail: "\(issue["key"] ?? "") · \(issue.status ?? "")" + (issue["due"].map { " · due \($0)" } ?? ""),
                             tag: due ? "Due soon" : issue["priority"] ?? "High", url: issue.url, item: issue))
        }
        for mr in i.mine where HomeLogic.readyToMerge(mr) {
            out.append(Focus(id: "ready." + mr.id, icon: "checkmark.seal.fill", tint: .green, title: mr.title,
                             detail: "\(mr.subtitle) · approved by \(mr["approvedBy"] ?? "")", tag: "Ready to merge", url: mr.url, item: mr))
        }
        return out
    }

    var body: some View {
        let list = focus
        HomeCard(title: "Needs you", icon: "bolt.fill", tint: .orange,
                 actionTitle: list.count > 8 ? "All \(list.count)" : nil, action: { model.selection = .mergeRequests }) {
            if list.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    QuietText(text: model.hasCodeHost || model.secrets.hasJira
                              ? "You're all caught up: no red pipelines, reviews, mentions or urgent Jira issues."
                              : "Connect GitLab, GitHub or Jira in Settings → Accounts to see what needs you.")
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(list.prefix(8)) { f in
                        HomeRow(icon: f.icon, tint: f.tint, title: f.title, detail: f.detail, tag: f.tag) {
                            if let e = f.event { model.open(e) } else { model.open(f.url) }
                        }
                        .contextMenu { menu(f) }
                    }
                }
            }
        }
    }

    @ViewBuilder func menu(_ f: Focus) -> some View {
        Button("Open in browser") { model.open(f.url) }
        if let item = f.item, item.isCodeChange { Button("Summarize with AI") { model.summarize(item) } }
        if let item = f.item, item.source == "jira", let key = item["key"] {
            Button("AI digest of \(key)") { model.digest(jiraKey: key, title: item.title, url: item.url) }
        }
    }
}

// MARK: - Work brief

private struct BriefCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        HomeCard(title: "Work brief", icon: "sun.max.fill", tint: .yellow,
                 actionTitle: model.workBrief == nil ? nil : "Open", action: { model.selection = .workBrief }) {
            if let brief = model.workBrief {
                VStack(alignment: .leading, spacing: 8) {
                    if let at = brief.at {
                        Text("Written \(Dates.age(at)) ago by Claude").font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownView(text: brief.text, maxBlocks: 7)
                    HStack {
                        Spacer()
                        if model.workBriefRunning { ProgressView().controlSize(.small) }
                        Button("Regenerate") { model.generateWorkBrief() }.disabled(model.workBriefRunning || !model.config.aiWorkEnabled)
                    }
                }
            } else {
                HStack {
                    QuietText(text: model.config.aiWorkEnabled
                              ? "Claude reads your MRs/PRs, pipelines and Jira issues and tells you what matters today. Runs at \(model.config.workBriefTime)."
                              : "Work AI features are off in Settings → AI privacy.")
                    if model.workBriefRunning { ProgressView().controlSize(.small) }
                    Button("Generate") { model.generateWorkBrief() }.disabled(model.workBriefRunning || !model.config.aiWorkEnabled)
                }
            }
        }
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        HomeCard(title: "Latest activity", icon: "tray.full.fill", tint: .teal, actionTitle: "Open inbox", action: { model.selection = .inbox }) {
            if model.events.isEmpty {
                QuietText(text: "Pipeline failures, team MRs, review requests and Jira changes land here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(model.events.prefix(6)) { e in
                        EventRow(event: e, compact: true).onTapGesture { model.open(e) }
                        if e.id != model.events.prefix(6).last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }
}

// MARK: - Side column

private struct TodayCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        let meetings = model.calendar.today
        HomeCard(title: "Today", icon: "calendar", tint: .red) {
            if !model.config.calendarEnabled {
                QuietText(text: "Turn on macOS Calendar in Settings → General to see your meetings here.")
            } else if meetings.isEmpty {
                QuietText(text: model.calendar.access == .denied ? "Calendar access is off: allow Everboard in System Settings → Privacy & Security → Calendars."
                          : "No meetings today. Enjoy the focus time.")
            } else {
                VStack(spacing: 6) {
                    ForEach(meetings) { m in MeetingRow(meeting: m) }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    private var model: AppModel { .shared }
    let meeting: CalendarService.Meeting

    var body: some View {
        let past = meeting.end < Date()
        HStack(spacing: 10) {
            Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(meeting.isNow ? Color.green : past ? Color.secondary.opacity(0.4) : Color.accentColor).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).lineLimit(1).foregroundStyle(past ? .secondary : .primary)
                Text(meeting.isNow ? "Now · until \(meeting.end.formatted(date: .omitted, time: .shortened))"
                     : "\(Int(meeting.end.timeIntervalSince(meeting.start) / 60)) min" + (meeting.attendees.isEmpty ? "" : " · \(meeting.attendees.count) \(meeting.attendees.count == 1 ? "person" : "people")"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !past {
                Button { model.prepBrief(for: meeting) } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.borderless).help("Prep with AI").disabled(!model.config.aiWorkEnabled)
                if let url = meeting.joinURL {
                    Button("Join") { model.open(url.absoluteString) }.controlSize(.small)
                }
            }
        }
    }
}

private struct TeamCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        let byAuthor = Dictionary(grouping: model.items.reportees) { $0["authorName"] ?? $0.author ?? "?" }
        let stuck = model.items.reportees.filter { HomeLogic.isStuck($0) }
        HomeCard(title: "Team", icon: "person.3.fill", tint: .indigo, actionTitle: "Reports", action: { model.selection = .reports }) {
            if model.config.reportees.isEmpty {
                QuietText(text: "Add your reportees in Settings → Team to track their MRs here.")
            } else if byAuthor.isEmpty {
                QuietText(text: "No open MRs from your team.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(byAuthor.keys.sorted(), id: \.self) { name in
                        let mrs = byAuthor[name] ?? []
                        let stuckCount = mrs.filter { HomeLogic.isStuck($0) }.count
                        HStack(spacing: 8) {
                            Text(initials(name)).font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(color(for: name), in: Circle())
                            Text(name).lineLimit(1)
                            Spacer()
                            Text("\(mrs.count) open").font(.caption).foregroundStyle(.secondary)
                            if stuckCount > 0 { StatusPill(text: "\(stuckCount) stuck") }
                        }
                    }
                    if !stuck.isEmpty {
                        Divider()
                        ForEach(stuck.prefix(3)) { mr in
                            HomeRow(icon: "hourglass", tint: .orange, title: mr.title,
                                    detail: "\(mr["authorName"] ?? "") · \(mr["pipelineStatus"] == "failed" ? "red" : "open") \(Dates.age(mr.createdAt))") {
                                model.open(mr.url)
                            }
                            .contextMenu { Button("Summarize with AI") { model.summarize(mr) } }
                        }
                    }
                }
            }
        }
    }

    func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
    func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        return palette[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
    }
}

private struct JiraCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        let issues = model.items.jiraAssigned
        let byStatus = Dictionary(grouping: issues) { $0.status ?? "?" }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let top = issues.sorted {
            let a = HomeLogic.priorityRank[($0["priority"] ?? "").lowercased()] ?? 5, b = HomeLogic.priorityRank[($1["priority"] ?? "").lowercased()] ?? 5
            return a != b ? a < b : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        HomeCard(title: "Jira", icon: "checklist", tint: .blue, actionTitle: "All issues", action: { model.selection = .jira }) {
            if issues.isEmpty {
                QuietText(text: model.secrets.hasJira ? "Nothing assigned to you." : "Connect Jira in Settings → Accounts.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(byStatus.prefix(4), id: \.0) { status, n in StatusPill(text: "\(status) \(n)") }
                    }
                    ForEach(top.prefix(4)) { i in
                        HomeRow(icon: HomeLogic.isHighPriority(i) ? "flame.fill" : "circle.fill", tint: HomeLogic.isHighPriority(i) ? .orange : .blue,
                                title: i.title, detail: "\(i["key"] ?? "") · \(i.status ?? "") · \(i["priority"] ?? "")") { model.open(i.url) }
                            .contextMenu {
                                Button("AI digest") { model.digest(jiraKey: i["key"] ?? "", title: i.title, url: i.url) }
                            }
                    }
                }
            }
        }
    }
}

private struct NewsCard: View {
    private var model: AppModel { .shared }

    var body: some View {
        HomeCard(title: "World & Tech", icon: "globe", tint: .green, actionTitle: "Read", action: { model.selection = .worldBrief }) {
            if let brief = model.newsBrief {
                VStack(alignment: .leading, spacing: 8) {
                    Text(brief.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    ForEach(brief.sections.flatMap(\.stories).sorted { $0.importance > $1.importance }.prefix(3)) { s in
                        HomeRow(icon: "newspaper.fill", tint: .green, title: s.title, detail: s.sources.prefix(2).joined(separator: ", ")) {
                            model.selection = .worldBrief
                        }
                    }
                }
            } else {
                QuietText(text: "Your personal news brief appears here after the first run.")
            }
        }
    }
}

/// Small transparency card: how much Claude was used today and a way to see exactly what was sent.
private struct AICard: View {
    private var model: AppModel { .shared }
    @State private var today = UsageTotals(key: "today")
    @State private var workCalls = 0

    var body: some View {
        HomeCard(title: "Claude today", icon: "lock.shield.fill", tint: .purple, actionTitle: "What was sent", action: { model.selection = .aiActivity }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    stat("\(today.runs)", "calls")
                    stat("\(workCalls)", "with work data")
                    stat(UsageSettings.tokens(today.totalTokens), "tokens")
                }
                Label(model.config.aiWorkEnabled ? "Work data allowed · masking: \(masking)" : "Work data blocked",
                      systemImage: model.config.aiWorkEnabled ? "checkmark.shield" : "xmark.shield")
                    .font(.caption).foregroundStyle(model.config.aiWorkEnabled ? Color.secondary : Color.orange)
            }
        }
        .task(id: model.events.first?.id) {
            let start = Calendar.current.startOfDay(for: Date())
            today = (try? await model.store.usageTotal(since: start)) ?? UsageTotals(key: "today")
            workCalls = ((try? await model.store.aiLog(since: start)) ?? []).filter(\.isWork).count
        }
    }

    var masking: String {
        let c = model.config
        let on = [c.aiRedactSecrets ? "secrets" : nil, c.aiRedactEmails ? "emails" : nil, c.aiPseudonymizePeople ? "names" : nil,
                  c.aiMaskedTerms.isEmpty ? nil : "\(c.aiMaskedTerms.count) terms"].compactMap { $0 }
        return on.isEmpty ? "off" : on.joined(separator: ", ")
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
