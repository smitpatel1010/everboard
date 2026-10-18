import EverboardCore
import SwiftUI

/// Every prompt Everboard sent to Claude, exactly as it left the Mac (after masking), and the reply.
struct AIActivityView: View {
    private var model: AppModel { .shared }
    @State private var entries: [AILogEntry] = []
    @State private var selection: Int64?
    @State private var detail: AILogEntry?
    @State private var filter = "all"
    @State private var confirmClear = false

    var filtered: [AILogEntry] {
        entries.filter { filter == "all" || (filter == "work") == $0.isWork }
    }

    var weekEntries: [AILogEntry] { entries.filter { $0.ts > Date().addingTimeInterval(-7 * 86400) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.config.aiLogDays == 0 {
                EmptyState(icon: "eye.slash", title: "Activity log is off",
                           message: "Turn it on in Settings → AI privacy to keep a local copy of every prompt sent to Claude.")
            } else if filtered.isEmpty {
                EmptyState(icon: "lock.shield", title: "Nothing sent yet",
                           message: "When a brief, summary or report runs, the exact text sent to Claude shows up here.")
            } else {
                HSplitView {
                    List(filtered, selection: $selection) { e in
                        LogRow(entry: e).tag(e.id)
                    }
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                    Group {
                        if let detail { LogDetail(entry: detail) } else { EmptyState(icon: "doc.text.magnifyingglass", title: "Select a call") }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("AI Activity")
        .task { await load() }
        .task(id: selection) {
            guard let selection else { detail = nil; return }
            detail = try? await model.store.aiLogEntry(id: selection)
        }
        .confirmationDialog("Delete the whole AI activity log?", isPresented: $confirmClear) {
            Button("Delete log", role: .destructive) {
                Task { try? await model.store.clearAILog(); await load() }
            }
        } message: { Text("Usage numbers in Settings → AI usage are kept.") }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What Claude sees").font(.title2.weight(.semibold))
                    Text("The exact text of every Claude call, after masking. Kept only on this Mac for \(model.config.aiLogDays) days.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.settingsTab = "privacy"; model.selection = .settings } label: { Label("Privacy settings", systemImage: "hand.raised") }
            }
            HStack(spacing: 10) {
                MiniStat(icon: model.config.aiWorkEnabled ? "checkmark.shield" : "xmark.shield",
                         tint: model.config.aiWorkEnabled ? .green : .orange, title: "Work data to Claude",
                         value: model.config.aiWorkEnabled ? "Allowed" : "Blocked")
                MiniStat(icon: "paperplane", tint: .blue, title: "Calls · 7 days", value: "\(weekEntries.count)")
                MiniStat(icon: "briefcase", tint: .purple, title: "With work data", value: "\(weekEntries.filter(\.isWork).count)")
                MiniStat(icon: "eye.slash", tint: .teal, title: "Items masked · 7 days", value: "\(weekEntries.map(\.redactionTotal).reduce(0, +))")
            }
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag("all")
                    Text("Work").tag("work")
                    Text("News").tag("news")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                Button("Clear log…", role: .destructive) { confirmClear = true }.disabled(entries.isEmpty)
            }
        }
        .padding()
    }

    func load() async {
        entries = (try? await model.store.aiLog()) ?? []
        if selection == nil || !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
    }

    /// Plain-language summary of what a feature includes, given today's settings.
    static func describe(_ feature: String, config: AppConfig) -> String {
        switch feature {
        case "work.brief":
            return "Titles, statuses and authors of your open MRs, review queue, team MRs, to-dos and pipelines; your assigned Jira issues; the last 24h of inbox events"
                + (config.aiSendJiraText ? "." : " (Jira comment text left out).")
        case "mr.summary":
            return "MR title, author, branches and description, "
                + (config.aiSendDiffs ? "plus the code diff (up to ~60 KB)." : "plus changed file names and line counts. No code.")
        case "jira.digest":
            return "Issue key, summary, status, priority and people, "
                + (config.aiSendJiraText ? "plus the description and up to 40 comments." : "with description and comment text withheld.")
        case "report.standup": return "Titles of MRs you merged or reviewed since the last workday, Jira issues you touched, and your open MRs."
        case "report.weekly": return "Titles of merged and open MRs for you and your reportees over 7 days, and Jira issues resolved."
        case "team.commentary": return "Per-person metric numbers only (merged, cycle time, size, open, reviews)."
        case "meeting.prep":
            return "Meeting title, time and attendees" + (config.aiSendMeetingNotes ? ", the invite notes" : "") + ", and titles of related MRs and issues."
        case "settings.test": return "A fixed test sentence."
        default: return feature.hasPrefix("news.") ? "Public headlines and your news preferences. No work data." : ""
        }
    }
}

private struct LogRow: View {
    let entry: AILogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.ok ? (entry.isWork ? "briefcase" : "globe") : "exclamationmark.triangle")
                .foregroundStyle(entry.ok ? (entry.isWork ? Color.purple : Color.blue) : Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(UsageSettings.featureName(entry.feature)).fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(entry.ts.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(entry.promptChars), countStyle: .file))")
                    if entry.redactionTotal > 0 {
                        Label("\(entry.redactionTotal)", systemImage: "eye.slash").foregroundStyle(.teal)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LogDetail: View {
    private var model: AppModel { .shared }
    let entry: AILogEntry
    @State private var tab = "sent"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(UsageSettings.featureName(entry.feature)).font(.title3.weight(.semibold))
                    if entry.isWork { StatusPill(text: "work data") } else { StatusPill(text: "no work data") }
                    if !entry.ok { StatusPill(text: "failed") }
                    Spacer()
                    Button { model.copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Text(AIActivityView.describe(entry.feature, config: model.config)).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    meta("clock", entry.ts.formatted(date: .abbreviated, time: .standard))
                    if !entry.model.isEmpty { meta("cpu", entry.model) }
                    meta("arrow.up", "\(UsageSettings.tokens(entry.inputTokens)) in")
                    meta("arrow.down", "\(UsageSettings.tokens(entry.outputTokens)) out")
                    meta("wrench.and.screwdriver", entry.tools.isEmpty ? "no tools" : entry.tools.joined(separator: ", "))
                }
                if entry.redactionTotal > 0 {
                    HStack(spacing: 6) {
                        Text("Masked before sending:").font(.caption).foregroundStyle(.secondary)
                        ForEach(entry.redactions.sorted { $0.key < $1.key }, id: \.key) { kind, n in
                            Text("\(n) \(kind)\(n == 1 ? "" : "s")").font(.caption.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.teal.opacity(0.15), in: Capsule()).foregroundStyle(.teal)
                        }
                    }
                }
                if let err = entry.error { Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                Picker("", selection: $tab) {
                    Text("Sent to Claude").tag("sent")
                    Text("Instructions").tag("system")
                    Text("Reply").tag("reply")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            .padding()
            Divider()
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    var text: String {
        switch tab {
        case "system": return entry.systemPrompt
        case "reply": return entry.response
        default: return entry.prompt
        }
    }

    func meta(_ icon: String, _ s: String) -> some View {
        Label(s, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct MiniStat: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
                .frame(width: 34, height: 34).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Settings → AI privacy

struct PrivacySettings: View {
    private var model: AppModel { .shared }
    @State private var terms = ""
    @State private var sample = "Ask priya.n@example.com: API_KEY=ab12cd34ef56 for Project Falcon"

    var body: some View {
        Form {
            Section {
                Toggle("Allow work features to send data to Claude", isOn: configBinding(model, \.aiWorkEnabled))
                Toggle("Include MR code diffs in summaries", isOn: configBinding(model, \.aiSendDiffs))
                    .disabled(!model.config.aiWorkEnabled)
                Toggle("Include Jira descriptions and comments", isOn: configBinding(model, \.aiSendJiraText))
                    .disabled(!model.config.aiWorkEnabled)
                Toggle("Include meeting invite notes in meeting prep", isOn: configBinding(model, \.aiSendMeetingNotes))
                    .disabled(!model.config.aiWorkEnabled)
            } header: { Text("Work data") } footer: {
                Text("Off = the work brief, MR summaries, Jira digests, standup, weekly report, team AI read and meeting prep are refused before anything is sent. News features never contain work data. With diffs off, summaries see file names and line counts only.")
            }

            Section {
                Toggle("Mask secrets (tokens, keys, passwords, private keys)", isOn: configBinding(model, \.aiRedactSecrets))
                Toggle("Mask email addresses", isOn: configBinding(model, \.aiRedactEmails))
                Toggle("Replace people's names with placeholders", isOn: configBinding(model, \.aiPseudonymizePeople))
                VStack(alignment: .leading) {
                    TextField("Words to always mask (comma-separated)", text: $terms)
                        .onSubmit { saveTerms() }
                    Text("Customer names, codenames, internal hostnames. Press Return to save.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Try it", text: $sample)
                    Text(preview).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: { Text("Masking (done on your Mac, before sending)") } footer: {
                Text("Names, emails and your words become placeholders like [PERSON-1]. Claude only ever sees the placeholder; Everboard puts the real name back into the reply on your Mac. Names come from your MRs, Jira issues, team list and comment authors. Secrets are removed for good.")
            }

            Section {
                Stepper(model.config.aiLogDays == 0 ? "Don't keep a log" : "Keep for \(model.config.aiLogDays) days",
                        value: configBinding(model, \.aiLogDays), in: 0...90)
                Button("Open AI Activity") { model.selection = .aiActivity }
            } header: { Text("Activity log") } footer: {
                Text("A local copy of each prompt and reply, so you can check exactly what was sent. Stored in Everboard's database on this Mac only.")
            }

            Section("Never sent") {
                Label("Your GitLab, Jira and GitHub tokens: they're removed from Claude's environment", systemImage: "key")
                Label("Files on your Mac: Claude runs in an empty folder with no file, shell or edit tools", systemImage: "folder")
                Label("Your MCP servers and Claude Code settings: runs use --strict-mcp-config", systemImage: "puzzlepiece.extension")
                Label("Anything automatically, except the scheduled work brief and weekly report", systemImage: "clock")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .onAppear { terms = model.config.aiMaskedTerms.joined(separator: ", ") }
    }

    var preview: String {
        var p = model.privacyPolicy
        p.terms = terms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return "→ " + Redactor.redact(sample, policy: p).text
    }

    func saveTerms() {
        model.updateConfig { $0.aiMaskedTerms = terms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }
}
