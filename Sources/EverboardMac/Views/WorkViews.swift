import EverboardCore
import SwiftUI

// MARK: - Work brief

struct WorkBriefView: View {
    private var model: AppModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Work brief", subtitle: model.workBrief?.at.map { "Written \($0.formatted(date: .abbreviated, time: .shortened))" }
                       ?? "Runs at \(model.config.workBriefTime)\(model.config.workBriefWeekdaysOnly ? " on weekdays" : "")") {
                if model.workBriefRunning { ProgressView().controlSize(.small) }
                if let text = model.workBrief?.text {
                    SpeakButton(id: "brief.work", text: text)
                    Button { model.copyToClipboard(text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                Button(model.workBrief == nil ? "Generate" : "Regenerate") { model.generateWorkBrief() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(model.workBriefRunning)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading) {
                    if let err = model.workBriefError {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if let text = model.workBrief?.text {
                        Card { MarkdownView(text: text) }
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
