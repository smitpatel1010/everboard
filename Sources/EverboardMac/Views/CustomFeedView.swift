import AppKit
import EverboardCore
import SwiftUI

/// Items from one custom source (Settings → Sources): a command's JSON or a folder of markdown notes.
struct CustomFeedView: View {
    private var model: AppModel { .shared }
    let source: CustomSourceConfig
    @State private var search = ""

    var items: [FeedItem] {
        let all = model.items.custom[source.id] ?? []
        guard !search.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.subtitle) \($0.status ?? "") \($0.author ?? "")".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source.kind == .folder ? source.folder : source.command, systemImage: source.kind == .folder ? "folder" : "terminal")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
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
                List(items) { CustomItemRow(item: $0) }
            }
        }
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button(item["path"] != nil && item.url == nil ? "Open note" : "Open") { open() }.disabled(item.url == nil && item["path"] == nil)
            if let path = item["path"] { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            AgentActionItems(item: item)
            Divider()
            Button(model.config.isMuted(item.id) ? "Unmute" : "Mute notifications for this item") {
                if model.config.isMuted(item.id) { model.unmute(itemId: item.id) } else { model.mute(itemId: item.id, for: nil) }
            }
        }
    }

    /// Web links open in the browser; folder notes open in their default app (e.g. Obsidian).
    func open() {
        if item.url != nil { model.open(item.url); return }
        if let path = item["path"], let source = model.config.customSources.first(where: { $0.id == item["feed"] }),
           source.kind == .folder {
            let root = URL(fileURLWithPath: (source.folder as NSString).expandingTildeInPath).standardizedFileURL.path
            let file = URL(fileURLWithPath: path).standardizedFileURL
            if file.path.hasPrefix(root + "/") { NSWorkspace.shared.open(file) }
        }
    }
}
