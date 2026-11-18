import EverboardCore
import SwiftUI

// MARK: - Merge requests

struct MergeRequestsView: View {
    private var model: AppModel { .shared }
    @State private var tab = "review"
    @State private var search = ""
    @State private var selection: String?

    func list(_ tab: String) -> [FeedItem] {
        switch tab {
        case "mine": return model.items.mine
        case "assigned": return model.items.assigned
        case "reportees": return model.items.reportees
        case "todos": return model.items.todos
        default: return model.config.mrShowDraftReviews ? model.items.review : model.items.reviewReady
        }
    }

    var items: [FeedItem] { list(tab).filter { $0.matches(search) } }
    var selected: FeedItem? { selection.flatMap { id in list(tab).first { $0.id == id } } }

    var hiddenDrafts: Int { model.items.review.count - model.items.reviewReady.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Review requested (\(list("review").count))").tag("review")
                    Text("Mine (\(model.items.mine.count))").tag("mine")
                    Text("Assigned (\(model.items.assigned.count))").tag("assigned")
                    Text("Reportees (\(model.items.reportees.count))").tag("reportees")
                    Text("To-dos (\(model.items.todos.count))").tag("todos")
                }
                .pickerStyle(.segmented)
                if tab == "review" {
                    Toggle("Drafts\(hiddenDrafts > 0 ? " (\(hiddenDrafts))" : "")", isOn: configBinding(model, \.mrShowDraftReviews))
                        .toggleStyle(.checkbox).fixedSize()
                        .help("Also list drafts where your review is requested. They don't count toward your review queue.")
                }
                ListSearchField(text: $search)
            }
            .padding(10)
            Divider()
            if items.isEmpty {
                EmptyState(icon: "arrow.triangle.pull", title: search.isEmpty ? "Nothing here" : "No matches", message: search.isEmpty ? emptyMessage : "")
            } else if tab == "reportees" {
                List(selection: $selection) {
                    ForEach(groupedByAuthor, id: \.0) { author, mrs in
                        Section("\(author) · \(mrs.count) open") {
                            ForEach(mrs) { MRRow(item: $0, showAuthor: false).tag($0.id) }
                        }
                    }
                }
                .itemContextMenu(lookup)
            } else if tab == "todos" {
                List(items, selection: $selection) { TodoRow(item: $0).tag($0.id) }
                    .itemContextMenu(lookup)
            } else {
                List(items, selection: $selection) { MRRow(item: $0, showAuthor: tab != "mine").tag($0.id) }
                    .itemContextMenu(lookup)
            }
        }
        .itemInspector(selected) { selection = nil }
        .onChange(of: tab) { selection = nil }
        .navigationTitle(model.changesTitle)
    }

    func lookup(_ id: String) -> FeedItem? { list(tab).first { $0.id == id } }

    var emptyMessage: String {
        if !model.hasCodeHost { return "Add a GitLab or GitHub account to your secrets file (Settings → Accounts)." }
        if tab == "reportees" && model.config.reportees.isEmpty { return "Add your reportees' emails in Settings → Team." }
        return ""
    }

    var groupedByAuthor: [(String, [FeedItem])] {
        Dictionary(grouping: items) { $0["authorName"] ?? $0.author ?? "?" }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
}

/// One MR/PR in a list. Selection shows the inspector; right-click and double-click come from the list.
struct MRRow: View {
    private var model: AppModel { .shared }
    let item: FeedItem
    var showAuthor = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item["draft"] == "1" { StatusPill(text: "draft") }
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    if showAuthor, let a = item["authorName"] { Text("· \(a)").font(.caption).foregroundStyle(.secondary) }
                    if let notes = item["notes"], notes != "0" {
                        Label(notes, systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary)
                    }
                    if let approved = item["approvedBy"] {
                        Label(approved, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green).lineLimit(1)
                    }
                    if let keys = item["jiraKeys"] { Text(keys).font(.caption).foregroundStyle(.blue).lineLimit(1) }
                }
                if stale {
                    Label("Open \(Dates.age(item.createdAt)) — may be stuck", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let p = item["pipelineStatus"] { StatusPill(text: p) }
                if let m = item["mergeStatus"], m != "mergeable" { Text(m.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(.secondary) }
                AgeText(date: item.updatedAt)
            }
        }
        .padding(.vertical, 3)
        .statusAccent(item["pipelineStatus"])
    }

    /// Reportee/review MRs open > 3 days, or red for > 1 day.
    var stale: Bool {
        guard item.kind != "mr.mine" else { return false }
        let age = Date().timeIntervalSince(item.createdAt ?? Date())
        return age > 3 * 86400 || (item["pipelineStatus"] == "failed" && age > 86400)
    }
}

struct TodoRow: View {
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subtitle).font(.body.weight(.medium))
                Text(item.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let body = item["body"], !body.isEmpty, body != item.title {
                    Text(body).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                if let p = item["projectPath"] { Text(p).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            AgeText(date: item.createdAt)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Pipelines

struct PipelinesView: View {
    private var model: AppModel { .shared }
    @State private var filter = "all"
    @State private var search = ""
    @State private var selection: String?

    var sorted: [FeedItem] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let recentFailed = model.items.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > dayAgo }
        let rest = model.items.pipelines.filter { !recentFailed.contains($0) }
        return recentFailed + rest
    }

    var items: [FeedItem] {
        sorted.filter { p in
            let s = p.status ?? ""
            let keep = switch filter {
            case "failed": ["failed", "canceled"].contains(s)
            case "running": ["running", "pending", "created", "preparing", "waiting_for_resource", "queued", "in_progress"].contains(s)
            default: true
            }
            return keep && p.matches(search)
        }
    }

    func count(_ f: String) -> Int { sorted.filter { ["failed", "canceled"].contains($0.status ?? "") }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("All (\(sorted.count))").tag("all")
                    Text("Failed (\(count("failed")))").tag("failed")
                    Text("Running").tag("running")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
                ListSearchField(text: $search, prompt: "Filter by project, branch, status")
            }
            .padding(10)
            Divider()
            if items.isEmpty {
                EmptyState(icon: "gearshape.2", title: sorted.isEmpty ? "No recent pipelines" : "No matches",
                           message: sorted.isEmpty ? "Pipelines and GitHub Actions runs you trigger in projects you're active in (last 7 days) show up here, failed first." : "")
            } else {
                List(items, selection: $selection) { PipelineRow(item: $0).tag($0.id) }
                .itemContextMenu { id in sorted.first { $0.id == id } }
            }
        }
        .itemInspector(selection.flatMap { id in sorted.first { $0.id == id } }) { selection = nil }
        .navigationTitle("Pipelines")
    }
}

struct PipelineRow: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let t = item["trigger"] { Text("· \(t)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if item.status == "failed" || item.status == "canceled" {
                Button { model.retryPipeline(item) } label: { Label("Retry", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(text: item.status ?? "?")
                AgeText(date: item.updatedAt)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .statusAccent(item.status)
    }
}

struct IssueRow: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item["key"] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let p = item["priority"] { Text("· \(p)").font(.caption).foregroundStyle(StatusPill.color(for: p) == .red ? .red : .secondary) }
                    if let a = item["assignee"] { Text("· \(a)").font(.caption).foregroundStyle(.secondary) }
                    if let d = item["due"] { Label(d, systemImage: "calendar").font(.caption).foregroundStyle(.orange) }
                }
            }
            Spacer()
            Button { model.digest(jiraKey: item["key"] ?? "", title: item.title, url: item.url) } label: { Image(systemName: "sparkles") }
                .buttonStyle(.borderless).help("AI digest")
            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(text: item.status ?? "?")
                AgeText(date: item.updatedAt)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .statusAccent(item["statusCategory"] == "done" ? "done" : item["priority"].flatMap { ["highest", "high", "blocker", "critical"].contains($0.lowercased()) ? "failed" : nil })
    }
}

// MARK: - Jira

struct JiraView: View {
    private var model: AppModel { .shared }
    @State private var tab = "assigned"
    @State private var search = ""
    @State private var selection: String?

    func items(_ tab: String) -> [FeedItem] {
        let showDone = model.config.jiraShowDone
        if tab == "assigned" {
            guard showDone else { return model.items.jiraAssigned }
            let open = Set(model.items.jiraAssigned.map(\.id))
            return (model.items.jiraAssigned + model.items.jiraDone.filter { !open.contains($0.id) }).sortedByUpdate()
        }
        let all = model.items.jiraFilters[tab] ?? []
        return showDone ? all : all.filter { $0["statusCategory"] != "done" }
    }

    var items: [FeedItem] { items(tab).filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Assigned to me (\(items("assigned").count))").tag("assigned")
                    ForEach(model.config.jiraFilters) { f in
                        Text("\(f.name) (\(items(f.id).count))").tag(f.id)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show done", isOn: configBinding(model, \.jiraShowDone))
                    .toggleStyle(.checkbox).fixedSize()
                    .help("Also list done issues: ones assigned to you that finished in the last 30 days, and done issues in your filters.")
                ListSearchField(text: $search)
            }
            .padding(10)
            Divider()
            if items.isEmpty {
                EmptyState(icon: "checklist", title: search.isEmpty ? "No issues" : "No matches",
                           message: !search.isEmpty ? "" : model.secrets.hasJira ? (model.config.jiraFilters.isEmpty ? "Add saved filters in Settings → Jira." : "")
                               : "Add JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN in Settings → Accounts.")
            } else {
                List(items, selection: $selection) { IssueRow(item: $0).tag($0.id) }
                .itemContextMenu { id in items(tab).first { $0.id == id } }
            }
        }
        .itemInspector(selection.flatMap { id in items(tab).first { $0.id == id } }) { selection = nil }
        .onChange(of: tab) { selection = nil }
        .navigationTitle("Jira")
    }
}

// MARK: - Work brief

struct WorkBriefView: View {
    private var model: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Work brief").font(.title2.weight(.semibold))
                    if let at = model.workBrief?.at {
                        Text("Generated \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Runs automatically at \(model.config.workBriefTime)\(model.config.workBriefWeekdaysOnly ? " on weekdays" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.workBriefRunning { ProgressView().controlSize(.small) }
                if let text = model.workBrief?.text { SpeakButton(id: "brief.work", text: text) }
                Button(model.workBrief == nil ? "Generate" : "Regenerate") { model.generateWorkBrief() }
                    .disabled(model.workBriefRunning)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading) {
                    if let err = model.workBriefError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if let text = model.workBrief?.text {
                        MarkdownView(text: text)
                    } else if !model.workBriefRunning {
                        EmptyState(icon: "sun.max", title: "No brief yet",
                                   message: "Claude reads your MRs/PRs, pipelines, reportees' work and Jira issues and tells you what needs you today.")
                    } else {
                        Text("Claude is reading your dashboard…").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Work Brief")
    }
}

struct CommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let send: (String) -> Void
    @State private var text: String

    init(title: String, initial: String = "", send: @escaping (String) -> Void) {
        self.title = title
        self.send = send
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Post") { send(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
