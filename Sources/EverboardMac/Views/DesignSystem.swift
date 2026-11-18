import AppKit
import EverboardCore
import SwiftUI

/// Visual language for the dashboard: quiet surfaces, hairline borders, dense keyboard-first lists,
/// one accent color, and a peek panel instead of modal detail windows.
enum Theme {
    static let accent = Color(red: 0.40, green: 0.36, blue: 0.96)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.64, green: 0.33, blue: 0.92)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.105, alpha: 1) : NSColor(white: 0.985, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.14, alpha: 1) : NSColor.white
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.085, alpha: 1) : NSColor(white: 0.955, alpha: 1)
    })
    static let hairline = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.045)
    static let selected = accent.opacity(0.14)
    static let radius: CGFloat = 10
}

// MARK: - Page chrome

/// Title row at the top of every screen: title, optional subtitle, trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
    }
}

/// Text tabs with counts, underlined when active (replaces segmented controls).
struct TabBar: View {
    struct Tab: Identifiable { let id: String; let title: String; var count: Int? = nil }
    let tabs: [Tab]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let active = tab.id == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = tab.id } } label: {
                    HStack(spacing: 6) {
                        Text(tab.title).fontWeight(active ? .semibold : .regular)
                        if let c = tab.count {
                            Text("\(c)").font(.caption.monospacedDigit().weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(active ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.07)))
                        }
                    }
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.primary.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Toolbar row under the page header: tabs on the left, filters and search on the right.
struct Toolbar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // One row when there's room; tabs above filters when the peek panel narrows the page.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                HStack(spacing: 10) { leading() }.fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 8) { trailing() }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { leading() }.fixedSize()
                HStack(spacing: 8) { trailing() }.fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Small chip-style toggle ("Drafts", "Unread", "Show done").
struct ChipToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").font(.caption)
                Text(title).font(.callout)
            }
            .foregroundStyle(isOn ? Theme.accent : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().stroke(isOn ? Theme.accent.opacity(0.5) : Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius + 2).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).stroke(Theme.hairline))
    }
}

/// Round status glyph used at the start of list rows.
struct StatusGlyph: View {
    let status: String?
    var icon: String?

    var body: some View {
        let color = status.map { StatusPill.color(for: $0) } ?? .secondary
        ZStack {
            Circle().fill(color.opacity(0.14))
            Image(systemName: icon ?? Self.symbol(status)).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
        }
        .frame(width: 22, height: 22)
    }

    static func symbol(_ status: String?) -> String {
        switch status?.lowercased() ?? "" {
        case "failed", "canceled", "cancelled", "blocked": return "xmark"
        case "success", "passed", "done", "closed", "resolved", "mergeable": return "checkmark"
        case "running", "pending", "in progress", "in review", "preparing": return "circle.dotted"
        case "draft", "manual", "skipped": return "pencil"
        default: return "circle.fill"
        }
    }
}

/// Initials avatar for people.
struct Avatar: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(abs(name.hashValue % 360)) / 360
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.75)))
            .help(name)
    }
}

// MARK: - Item lists

/// A keyboard-first list: click selects (and opens the peek panel), double-click opens, ↑/↓ or j/k move,
/// return opens the peek, ⌘↩ opens in the browser, esc closes the peek. Rows show quick actions on hover.
struct ItemList<Row: View>: View {
    struct Section: Identifiable {
        var id: String { title ?? "_" }
        var title: String?
        var items: [FeedItem]
    }

    let sections: [Section]
    @ViewBuilder var row: (FeedItem) -> Row
    private var peek: Peek { .shared }
    @FocusState private var focused: Bool

    init(_ items: [FeedItem], @ViewBuilder row: @escaping (FeedItem) -> Row) {
        sections = [Section(title: nil, items: items)]
        self.row = row
    }

    init(sections: [Section], @ViewBuilder row: @escaping (FeedItem) -> Row) {
        self.sections = sections.filter { !$0.items.isEmpty }
        self.row = row
    }

    var flat: [FeedItem] { sections.flatMap(\.items) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { item in
                                ItemListRow(item: item, selected: peek.itemID == item.id) { row(item) }
                                    .id(item.id)
                                    .onTapGesture(count: 2) { AppModel.shared.openItem(item) }
                                    .simultaneousGesture(TapGesture().onEnded { peek.show(item); focused = true })
                                    .contextMenu { ItemMenu(item: item) }
                            }
                        } header: {
                            if let title = section.title {
                                HStack {
                                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text("\(section.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                                .background(Theme.canvas)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.downArrow, .upArrow, "j", "k"]) { press in
                move(press.key == .downArrow || press.key == "j" ? 1 : -1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.command), let item = peek.item { AppModel.shared.openItem(item) }
                else if peek.item == nil, let first = flat.first { peek.show(first) }
                return .handled
            }
            .onKeyPress(.escape) {
                guard peek.item != nil else { return .ignored }
                peek.close()
                return .handled
            }
        }
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) {
        let items = flat
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == peek.itemID }.map { min(max($0 + delta, 0), items.count - 1) } ?? 0
        peek.show(items[i])
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(items[i].id) }
    }
}

/// Row chrome: hover and selection backgrounds, hover quick actions on the right.
struct ItemListRow<Content: View>: View {
    let item: FeedItem
    let selected: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            content()
            if hovering { QuickActions(item: item).padding(.leading, 8).transition(.opacity) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
    }
}

/// Two or three one-click actions that make sense for the item, shown on hover.
struct QuickActions: View {
    private var model: AppModel { .shared }
    let item: FeedItem

    var body: some View {
        HStack(spacing: 2) {
            if item.isCodeChange { button("sparkles", "Summarize with AI") { model.summarize(item) } }
            if let key = item.jiraKey { button("sparkles", "AI digest") { model.digest(jiraKey: key, title: item.title, url: item.url) } }
            if (item.kind == "pipeline" && ["failed", "canceled"].contains(item.status ?? "")) || (item.isCodeChange && item["pipelineStatus"] == "failed") {
                button("arrow.counterclockwise", "Retry pipeline") { model.retryPipeline(item) }
            }
            if let first = AgentCenter.shared.actions(for: item).first {
                button(first.icon, first.name) { AgentCenter.shared.request(first, item: item) }
            }
            if item.url != nil || item["path"] != nil { button("arrow.up.right", "Open") { model.openItem(item) } }
        }
    }

    func button(_ icon: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// What the peek panel shows: an item, or an event without a live item.
@MainActor @Observable
final class Peek {
    static let shared = Peek()
    var item: FeedItem?
    var event: AppEvent?

    var itemID: String? { item?.id ?? event.map { "event:\($0.id)" } }

    func show(_ item: FeedItem) { withAnimation(.snappy(duration: 0.2)) { self.item = item; event = nil } }
    func show(_ event: AppEvent) {
        withAnimation(.snappy(duration: 0.2)) {
            self.event = event
            item = AppModel.shared.item(withId: event.itemId)
        }
    }
    func close() { withAnimation(.snappy(duration: 0.2)) { item = nil; event = nil } }
}

/// Empty state in the new style.
struct EmptyHint: View {
    let icon: String
    let title: String
    var message: String = ""
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.1)).frame(width: 52, height: 52)
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.accent)
            }
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent).tint(Theme.accent).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
