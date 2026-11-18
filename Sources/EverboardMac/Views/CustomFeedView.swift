import AppKit
import EverboardCore
import SwiftUI

/// Items from one custom source (Settings → Sources): a command's JSON or a folder of markdown notes.
struct CustomFeedView: View {
    private var model: AppModel { .shared }
    let source: CustomSourceConfig
    @State private var search = ""
    @State private var selection: String?

    var all: [FeedItem] { model.items.custom[source.id] ?? [] }
    var items: [FeedItem] { all.filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source.kind == .folder ? source.folder : source.command, systemImage: source.kind == .folder ? "folder" : "terminal")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                ListSearchField(text: $search)
                Button { Task { await model.poller.refreshNow(source.sourceID) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh this feed now")
            }
            .padding(10)
            if let h = model.health[source.sourceID], !h.isHealthy, h != .idle {
                Label(h.label, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if items.isEmpty {
                EmptyState(icon: source.kind == .folder ? "folder" : "terminal", title: "Nothing here",
                           message: source.kind == .folder ? "No markdown notes found\(source.tag.isEmpty ? "" : " tagged #\(source.tag)")."
                               : "The command printed no items yet. See docs/extending.md for the JSON format.")
            } else {
                List(items, selection: $selection) { CustomItemRow(item: $0).tag($0.id) }
                    .itemContextMenu { id in all.first { $0.id == id } }
            }
        }
        .itemInspector(selection.flatMap { id in all.first { $0.id == id } }) { selection = nil }
        .navigationTitle(source.name)
    }
}

struct CustomItemRow: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    if let a = item.author { Text("· \(a)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let s = item.status { StatusPill(text: s) }
                AgeText(date: item.updatedAt ?? item.createdAt)
            }
        }
        .padding(.vertical, 3)
        .statusAccent(item.status)
    }
}
