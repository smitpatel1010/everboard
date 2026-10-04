import EverboardCore
import SwiftUI

/// Team health metrics, daily standup and weekly report.
struct ReportsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.reportsTab) {
                    Text("Team health").tag("team")
                    Text("Daily standup").tag("standup")
                    Text("Weekly report").tag("weekly")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                if let err = model.reportError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(10)
            Divider()
            switch model.reportsTab {
            case "standup":
                ReportText(kind: "standup", title: "Daily standup", report: model.standup,
                           hint: "Yesterday / Today / Blockers from your merged and reviewed MRs, Jira activity and open work. Ready to paste into team chat.",
                           generate: model.generateStandup)
            case "weekly":
                ReportText(kind: "weekly", title: "Weekly report",
                           report: model.weekly,
                           hint: "What you and your reportees shipped this week, grouped by theme, plus risks — written for your manager. Auto-generates \(weekdayName(model.config.weeklyReportWeekday)) at \(model.config.weeklyReportTime).",
                           generate: { model.generateWeekly() })
            default:
                TeamHealthView()
            }
        }
        .navigationTitle("Team & Reports")
    }

    func weekdayName(_ d: Int) -> String { Calendar.current.weekdaySymbols[max(0, min(6, d - 1))] }
}

private struct ReportText: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let title: String
    let report: (text: String, at: Date?)?
    let hint: String
    let generate: () -> Void

    var running: Bool { model.reportRunning.contains(kind) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(report?.at.map { "Generated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? hint)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                if let text = report?.text {
                    SpeakButton(id: "report.\(kind)", text: text)
                    Button { model.copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Button(report == nil ? "Generate" : "Regenerate", action: generate).disabled(running || !model.secrets.hasGitLab)
            }
            .padding()
            Divider()
            ScrollView {
                Group {
                    if let text = report?.text {
                        MarkdownView(text: text)
                    } else if running {
                        Text("Claude is reading your GitLab and Jira activity…").foregroundStyle(.secondary)
                    } else {
                        EmptyState(icon: "doc.text", title: "Nothing yet",
                                   message: model.secrets.hasGitLab ? hint : "Add your GitLab token in Settings → Accounts first.")
                    }
                }
                .padding()
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct TeamHealthView: View {
    @Environment(AppModel.self) private var model

    var running: Bool { model.reportRunning.contains("team") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Team health").font(.title2.weight(.semibold))
                    Text(model.teamHealth.map { "Last \($0.days) days · updated \($0.generatedAt.formatted(date: .abbreviated, time: .shortened))" }
                         ?? "Per-reportee delivery metrics from GitLab")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refreshTeamHealth(withCommentary: false) }.disabled(running)
                Button { model.refreshTeamHealth(withCommentary: true) } label: { Label("Refresh + AI read", systemImage: "sparkles") }
                    .disabled(running)
            }
            .padding()
            Divider()
            if model.config.reportees.isEmpty {
                EmptyState(icon: "person.3", title: "No reportees", message: "Add your team in Settings → Team.")
            } else if let health = model.teamHealth, !health.people.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                ForEach(["Person", "Merged", "Median cycle", "Median size", "Open", "Oldest open", "Red open", "Reviews given"], id: \.self) {
                                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(health.people) { p in
                                GridRow {
                                    Text(p.name).fontWeight(.medium)
                                    Text("\(p.merged)").monospacedDigit()
                                    metric(p.medianCycleHours.map(formatHours), warn: (p.medianCycleHours ?? 0) > 72)
                                    metric(p.medianSize.map { String(format: "%.0f files", $0) }, warn: (p.medianSize ?? 0) > 30)
                                    Text("\(p.open)").monospacedDigit()
                                    metric(p.oldestOpenDays.map { String(format: "%.0fd", $0) }, warn: (p.oldestOpenDays ?? 0) > 5)
                                    metric(p.openRed > 0 ? "\(p.openRed)" : "0", warn: p.openRed > 0)
                                    Text("\(p.reviewsGiven)").monospacedDigit()
                                }
                            }
                        }
                        Text("Orange = worth a look: cycle > 3 days, MRs > 30 files, open > 5 days, or red pipelines. Numbers can't see vacations or design work — use them to start conversations.")
                            .font(.caption).foregroundStyle(.tertiary)
                        if let c = health.commentary {
                            Divider()
                            Label("AI read", systemImage: "sparkles").font(.headline)
                            MarkdownView(text: c)
                        }
                    }
                    .padding()
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyState(icon: "chart.bar", title: running ? "Crunching numbers…" : "No metrics yet",
                           message: "Refresh to compute merged MRs, cycle time, MR size, stuck MRs and reviews for each reportee.")
            }
        }
    }

    func metric(_ text: String?, warn: Bool) -> some View {
        Text(text ?? "—").monospacedDigit().foregroundStyle(warn ? Color.orange : Color.primary)
    }

    func formatHours(_ h: Double) -> String { h < 48 ? String(format: "%.0fh", h) : String(format: "%.1fd", h / 24) }
}

/// Play / pause the text aloud.
struct SpeakButton: View {
    @Environment(AppModel.self) private var model
    let id: String
    let text: String

    var body: some View {
        let speech = Speech.shared
        let active = speech.speakingID == id
        HStack(spacing: 4) {
            Button {
                speech.toggle(id: id, text: text, voice: model.config.speechVoice, rate: model.config.speechRate)
            } label: {
                Label(active ? (speech.paused ? "Resume" : "Pause") : "Listen",
                      systemImage: active ? (speech.paused ? "play.fill" : "pause.fill") : "speaker.wave.2")
            }
            if active {
                Button { speech.stop() } label: { Image(systemName: "stop.fill") }.help("Stop")
            }
        }
    }
}
