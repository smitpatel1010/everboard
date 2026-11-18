import EverboardCore
import SwiftUI

/// Team & Reports → Radar: per-person load, review waits, aging/red MRs and Jira movement, from data already polled.
struct TeamRadarView: View {
    private var model: AppModel { .shared }
    private var desk: TeamDesk { .shared }
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Team radar").font(.title2.weight(.semibold))
                    Text(desk.radar.map { "Updated \($0.generatedAt.formatted(date: .omitted, time: .shortened)) · aging = open > \(Int($0.agingDays)) days" }
                         ?? "Who's loaded, who's waiting on review, what's stuck. Computed locally; no AI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let text = desk.digest() {
                    Button { model.copyToClipboard(text) } label: { Label("Copy digest", systemImage: "doc.on.doc") }
                    if model.brain != nil {
                        Button { desk.saveDigestToBrain() } label: { Label("Save to today's note", systemImage: "square.and.arrow.down") }
                    }
                }
                Button("Refresh") { Task { await desk.refreshRadar() } }
            }
            .padding()
            Divider()
            if model.config.reportees.isEmpty {
                EmptyState(icon: "person.3", title: "No reportees", message: "Add your team in Settings → Team.")
            } else if let radar = desk.radar {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                ForEach(["Person", "Open", "Reviewing", "Waiting for review", "Aging", "Red", "Jira moved", ""], id: \.self) {
                                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(radar.people) { p in
                                GridRow {
                                    Button {
                                        if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) }
                                    } label: {
                                        Label(p.name, systemImage: expanded.contains(p.id) ? "chevron.down" : "chevron.right").fontWeight(.medium)
                                    }.buttonStyle(.plain)
                                    Text("\(p.open.count)").monospacedDigit()
                                    metric("\(p.reviewing.count)", warn: p.reviewing.count >= 5)
                                    metric(p.medianReviewWaitHours.map { "~" + hours($0) } ?? "—", warn: (p.medianReviewWaitHours ?? 0) > 24)
                                    metric("\(p.aging.count)", warn: !p.aging.isEmpty)
                                    metric("\(p.red.count)", warn: !p.red.isEmpty)
                                    Text(p.jiraMoved.isEmpty ? "—" : "\(p.jiraMoved.count) (\(p.jiraDone) done)").monospacedDigit()
                                    Button("1:1 prep") {
                                        model.reportsTab = "oneonone"
                                        OneOnOneView.selected = p.id
                                    }.buttonStyle(.link)
                                }
                                if expanded.contains(p.id) {
                                    GridRow {
                                        PersonDetail(load: p).gridCellColumns(8)
                                    }
                                }
                            }
                        }
                        Text("Orange = worth a look: red pipelines, open longer than the aging threshold, ready MRs/PRs waiting over a day without approval, or 5+ reviews queued. Jira movement only covers issues in your assigned list and filters.")
                            .font(.caption).foregroundStyle(.tertiary)
                        if let text = desk.digest() {
                            Divider()
                            Label("Digest", systemImage: "text.alignleft").font(.headline)
                            MarkdownView(text: text)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyState(icon: "dot.radiowaves.left.and.right", title: "Loading…")
            }
        }
        .task { await desk.refreshRadar() }
        .onChange(of: model.items.reportees.count) { Task { await desk.refreshRadar() } }
    }

    func metric(_ text: String, warn: Bool) -> some View {
        Text(text).monospacedDigit().foregroundStyle(warn ? Color.orange : Color.primary)
    }

    func hours(_ h: Double) -> String { h < 48 ? String(format: "%.0fh", h) : String(format: "%.1fd", h / 24) }
}

private struct PersonDetail: View {
    private var model: AppModel { .shared }
    let load: PersonLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(load.open) { i in
                HStack(spacing: 6) {
                    if i["pipelineStatus"] == "failed" { StatusPill(text: "failed") }
                    if i["draft"] == "1" { StatusPill(text: "draft") }
                    Button("\(i.subtitle) \(i.title)") { model.open(i.url) }.buttonStyle(.link).lineLimit(1)
                    Text("· \(Dates.age(i.createdAt))").font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu { AgentActionItems(item: i) }
            }
            if !load.reviewing.isEmpty {
                Text("Reviewing").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(load.reviewing) { i in
                    Button("\(i.subtitle) \(i.title)") { model.open(i.url) }.buttonStyle(.link).lineLimit(1)
                }
            }
            if !load.jiraMoved.isEmpty {
                Text("Jira").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(load.jiraMoved) { i in
                    HStack(spacing: 6) {
                        StatusPill(text: i.status ?? "?")
                        Button("\(i["key"] ?? "") \(i.title)") { model.open(i.url) }.buttonStyle(.link).lineLimit(1)
                    }
                }
            }
        }
        .padding(.leading, 22)
        .padding(.bottom, 6)
    }
}

/// Team & Reports → 1:1 prep: an AI draft per person from their recent work (and your notes, if allowed).
struct OneOnOneView: View {
    private var model: AppModel { .shared }
    private var desk: TeamDesk { .shared }
    /// Set by the radar's "1:1 prep" link.
    @MainActor static var selected: String?
    @State private var person: String = ""

    var current: Reportee? { model.config.reportees.first { $0.id == person } ?? model.config.reportees.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Person", selection: $person) {
                    ForEach(model.config.reportees) { r in Text(r.name ?? r.username ?? r.email).tag(r.id) }
                }
                .frame(maxWidth: 260)
                if let r = current, let at = desk.prep[r.id]?.at {
                    Text("Drafted \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let r = current {
                    if desk.prepRunning.contains(r.id) { ProgressView().controlSize(.small) }
                    if let text = desk.prep[r.id]?.text {
                        Button { model.copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    Button(desk.prep[r.id] == nil ? "Draft prep" : "Redraft") { desk.generatePrep(r) }
                        .disabled(desk.prepRunning.contains(r.id) || !model.hasCodeHost)
                }
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let r = current {
                        if let err = desk.prepError[r.id] {
                            Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        }
                        if let text = desk.prep[r.id]?.text {
                            MarkdownView(text: text)
                        } else if desk.prepRunning.contains(r.id) {
                            Text("Claude is reading \(r.name ?? "their") recent work…").foregroundStyle(.secondary)
                        } else {
                            EmptyState(icon: "person.2", title: "No prep yet", message: hint)
                        }
                    } else {
                        EmptyState(icon: "person.3", title: "No reportees", message: "Add your team in Settings → Team.")
                    }
                }
                .padding()
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            if let s = Self.selected { person = s; Self.selected = nil } else if person.isEmpty { person = model.config.reportees.first?.id ?? "" }
            await desk.loadPreps()
        }
    }

    var hint: String {
        var h = "Wins, work in flight, where you can help and questions to ask, from the last two weeks of MRs/PRs, reviews and Jira."
        if model.config.brain.readForAI && model.brain != nil { h += " Your own note about them is included as context." }
        if model.brain != nil && model.config.brain.writePeople { h += " The draft is also saved to their note in your brain folder." }
        return h + " A private draft; nothing is sent to them."
    }
}
