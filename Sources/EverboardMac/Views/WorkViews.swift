import EverboardCore
import SwiftUI

// MARK: - Merge requests

struct MergeRequestsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "review"

    var items: [FeedItem] {
        switch tab {
        case "mine": return model.items.mine
        case "assigned": return model.items.assigned
        case "reportees": return model.items.reportees
        case "todos": return model.items.todos
        default: return model.items.review
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Review requested (\(model.items.review.count))").tag("review")
                Text("Mine (\(model.items.mine.count))").tag("mine")
                Text("Assigned (\(model.items.assigned.count))").tag("assigned")
                Text("Reportees (\(model.items.reportees.count))").tag("reportees")
                Text("To-dos (\(model.items.todos.count))").tag("todos")
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            if items.isEmpty {
                EmptyState(icon: "arrow.triangle.pull", title: "Nothing here", message: emptyMessage)
            } else if tab == "reportees" {
                List {
                    ForEach(groupedByAuthor, id: \.0) { author, mrs in
                        Section("\(author) · \(mrs.count) open") {
                            ForEach(mrs) { MRRow(item: $0, showAuthor: false) }
                        }
                    }
                }
            } else if tab == "todos" {
                List(items) { TodoRow(item: $0) }
            } else {
                List(items) { MRRow(item: $0, showAuthor: tab != "mine") }
            }
        }
        .navigationTitle("Merge Requests")
    }

    var emptyMessage: String {
        if !model.secrets.hasGitLab { return "Add GITLAB_URL and GITLAB_TOKEN in Settings → Accounts." }
        if tab == "reportees" && model.config.reportees.isEmpty { return "Add your reportees' emails in Settings → Team." }
        return ""
    }

    var groupedByAuthor: [(String, [FeedItem])] {
        Dictionary(grouping: items) { $0["authorName"] ?? $0.author ?? "?" }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 }
    }
}

struct MRRow: View {
    @Environment(AppModel.self) private var model
    let item: FeedItem
    var showAuthor = true
    @State private var confirmApprove = false
    @State private var commenting = false

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
                    ForEach(jiraKeys, id: \.self) { key in
                        Button(key) { model.digest(jiraKey: key, url: jiraURL(key)) }
                            .buttonStyle(.link).font(.caption).help("AI digest of \(key)")
                    }
                }
                if stale {
                    Label("Open \(Dates.age(item.createdAt)) — may be stuck", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let p = item["pipelineStatus"] {
                    Button { model.open(item["pipelineUrl"]) } label: { StatusPill(text: p) }.buttonStyle(.plain).help("Open pipeline")
                }
                if let m = item["mergeStatus"], m != "mergeable" { Text(m.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(.secondary) }
                AgeText(date: item.updatedAt)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item.url) }
        .confirmationDialog("Approve \(item.subtitle)?", isPresented: $confirmApprove) {
            Button("Approve") { model.approve(item) }
        } message: { Text(item.title) }
        .sheet(isPresented: $commenting) {
            CommentSheet(title: "Comment on \(item.subtitle)") { model.commentOnMR(item, text: $0) }
        }
        .contextMenu {
            Button("Open in browser") { model.open(item.url) }
            Button("Summarize with AI") { model.summarize(item) }
            if let p = item["pipelineUrl"] { Button("Open pipeline") { model.open(p) } }
            Divider()
            if item.kind != "mr.mine" { Button("Approve…") { confirmApprove = true } }
            if item["pipelineStatus"] == "failed" { Button("Retry pipeline") { model.retryPipeline(item) } }
            Button("Comment…") { commenting = true }
            Divider()
            Button(model.config.isMuted(item.id) ? "Unmute" : "Mute notifications for this MR") {
                if model.config.isMuted(item.id) { model.unmute(itemId: item.id) } else { model.mute(itemId: item.id, for: nil) }
            }
        }
    }

    var jiraKeys: [String] { item["jiraKeys"]?.split(separator: ",").map(String.init) ?? [] }
    func jiraURL(_ key: String) -> String? { model.secrets.jiraBaseURL.map { $0.absoluteString + "/browse/" + key } }

    /// Reportee/review MRs open > 3 days, or red for > 1 day.
    var stale: Bool {
        guard item.kind != "mr.mine" else { return false }
        let age = Date().timeIntervalSince(item.createdAt ?? Date())
        return age > 3 * 86400 || (item["pipelineStatus"] == "failed" && age > 86400)
    }
}

struct TodoRow: View {
    @Environment(AppModel.self) private var model
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(item.url) }
        .contextMenu {
            Button("Open in browser") { model.open(item.url) }
            Button("Mark done") { model.markTodoDone(item) }
        }
    }
}

// MARK: - Pipelines

struct PipelinesView: View {
    @Environment(AppModel.self) private var model

    var sorted: [FeedItem] {
        let dayAgo = Date().addingTimeInterval(-86400)
        let recentFailed = model.items.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > dayAgo }
        let rest = model.items.pipelines.filter { !recentFailed.contains($0) }
        return recentFailed + rest
    }

    var body: some View {
        Group {
            if sorted.isEmpty {
                EmptyState(icon: "gearshape.2", title: "No recent pipelines",
                           message: "Pipelines you trigger in projects you're active in (last 7 days) show up here, failed first.")
            } else {
                Table(sorted) {
                    TableColumn("Status") { StatusPill(text: $0.status ?? "?") }.width(90)
                    TableColumn("Project · ref") { Text($0.title).lineLimit(1) }
                    TableColumn("Pipeline") { Text($0.subtitle).foregroundStyle(.secondary) }.width(140)
                    TableColumn("Updated") { AgeText(date: $0.updatedAt) }.width(70)
                    TableColumn("") { p in
                        HStack(spacing: 6) {
                            if p.status == "failed" || p.status == "canceled" {
                                Button { model.retryPipeline(p) } label: { Image(systemName: "arrow.counterclockwise") }
                                    .buttonStyle(.borderless).help("Retry pipeline")
                            }
                            Button { model.open(p.url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless)
                        }
                    }.width(56)
                }
            }
        }
        .navigationTitle("Pipelines")
    }
}

// MARK: - Jira

struct JiraView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "assigned"

    var items: [FeedItem] { tab == "assigned" ? model.items.jiraAssigned : (model.items.jiraFilters[tab] ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Assigned to me (\(model.items.jiraAssigned.count))").tag("assigned")
                ForEach(model.config.jiraFilters) { f in
                    Text("\(f.name) (\(model.items.jiraFilters[f.id]?.count ?? 0))").tag(f.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            if items.isEmpty {
                EmptyState(icon: "checklist", title: "No issues",
                           message: model.secrets.hasJira ? (model.config.jiraFilters.isEmpty ? "Add saved filters in Settings → Jira." : "")
                               : "Add JIRA_URL, JIRA_EMAIL and JIRA_API_TOKEN in Settings → Accounts.")
            } else {
                Table(items) {
                    TableColumn("Key") { i in Text(i["key"] ?? "").font(.body.monospaced()) }.width(100)
                    TableColumn("Summary") { i in Text(i.title).lineLimit(2) }
                    TableColumn("Status") { i in StatusPill(text: i.status ?? "?") }.width(110)
                    TableColumn("Priority") { i in Text(i["priority"] ?? "").font(.caption) }.width(70)
                    TableColumn("Assignee") { i in Text(i["assignee"] ?? "—").font(.caption).lineLimit(1) }.width(120)
                    TableColumn("Updated") { i in AgeText(date: i.updatedAt) }.width(60)
                    TableColumn("") { i in
                        HStack(spacing: 6) {
                            JiraActionsMenu(item: i)
                            Button { model.digest(jiraKey: i["key"] ?? "", title: i.title, url: i.url) } label: { Image(systemName: "sparkles") }
                                .buttonStyle(.borderless).help("AI digest")
                            Button { model.open(i.url) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless).help("Open in Jira")
                        }
                    }.width(84)
                }
            }
        }
        .navigationTitle("Jira")
    }
}

// MARK: - Work brief

struct WorkBriefView: View {
    @Environment(AppModel.self) private var model

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
                                   message: "Claude reads your MRs, pipelines, reportees' work and Jira issues and tells you what needs you today.")
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

/// Move a Jira issue through its workflow, or comment on it.
struct JiraActionsMenu: View {
    @Environment(AppModel.self) private var model
    let item: FeedItem
    @State private var transitions: [JiraClient.Transition] = []
    @State private var commenting = false

    var body: some View {
        let key = item["key"] ?? ""
        Menu {
            if transitions.isEmpty { Text("Loading…") }
            ForEach(transitions) { t in
                Button("→ \(t.to?.name ?? t.name)") { model.transition(key, to: t) }
            }
            Divider()
            Button("Comment…") { commenting = true }
        } label: {
            Image(systemName: "arrow.right.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move / comment")
        .onHover { inside in
            if inside && transitions.isEmpty { Task { transitions = await model.jiraTransitions(key) } }
        }
        .sheet(isPresented: $commenting) {
            CommentSheet(title: "Comment on \(key)") { model.commentOnJira(key, text: $0) }
        }
    }
}

struct CommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let send: (String) -> Void
    @State private var text = ""

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
