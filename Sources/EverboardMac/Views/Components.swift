import EverboardCore
import SwiftUI

/// Colored capsule for pipeline / Jira statuses.
struct StatusPill: View {
    let text: String
    var color: Color { Self.color(for: text) }

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    static func color(for status: String) -> Color {
        switch status.lowercased() {
        case "failed", "canceled", "cancelled", "blocked", "highest", "high": return .red
        case "success", "passed", "done", "closed", "resolved", "mergeable": return .green
        case "running", "pending", "in progress", "in review", "preparing", "waiting_for_resource": return .blue
        case "manual", "scheduled", "created", "skipped", "draft": return .secondary
        default: return .orange
        }
    }
}

extension View {
    /// A thin colored bar on the leading edge, so red and running items stand out while scanning a list.
    func statusAccent(_ status: String?) -> some View {
        padding(.leading, 8).overlay(alignment: .leading) {
            if let status, StatusPill.color(for: status) != .orange || ["failed"].contains(status) {
                Capsule().fill(StatusPill.color(for: status)).frame(width: 3).padding(.vertical, 2)
            }
        }
    }
}

/// Small source-health indicators ("GitLab · work unreachable — VPN?").
struct HealthChips: View {
    private var model: AppModel { .shared }
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.health.keys.sorted(), id: \.self) { key in
                let h = model.health[key]!
                HStack(spacing: 4) {
                    Circle().fill(Self.color(h)).frame(width: 7, height: 7)
                    // Healthy sources just need their name; problems carry their own message.
                    Text(compact || h.isHealthy || h == .idle ? model.sourceName(key) : h.label).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help("\(model.sourceName(key)): \(h.label)")
            }
        }
    }

    static func color(_ h: SourceHealth) -> Color {
        switch h {
        case .ok: return .green
        case .idle: return .gray
        case .unreachable: return .orange
        case .notConfigured: return .gray
        case .authFailed, .failing: return .red
        }
    }
}

private struct RefLinkerKey: EnvironmentKey {
    static let defaultValue = RefLinker()
}

extension EnvironmentValues {
    /// Makes MR refs and Jira keys in rendered markdown clickable.
    var refLinker: RefLinker {
        get { self[RefLinkerKey.self] }
        set { self[RefLinkerKey.self] = newValue }
    }
}

/// Tiny block-level markdown renderer (headings, bullets, numbered lists, paragraphs) with inline markdown.
struct MarkdownView: View {
    @Environment(\.refLinker) private var linker
    let text: String
    /// Show only the first N blocks (for previews on Home).
    var maxBlocks: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.prefix(maxBlocks ?? .max).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s).font(level <= 2 ? .title3.weight(.semibold) : .headline).padding(.top, 6)
                case .bullet(let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }.padding(.leading, CGFloat(indent) * 14)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                case .paragraph(let s):
                    inline(s)
                case .rule:
                    Divider()
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows, inline: inline).padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        // AI output is untrusted: only web links are clickable.
        .environment(\.openURL, OpenURLAction { url in
            if let safe = SafeURL.web(url.absoluteString) { NSWorkspace.shared.open(safe) }
            return .handled
        })
    }

    enum Block { case heading(Int, String), bullet(String, Int), numbered(String, String), paragraph(String), rule, table([String]?, [[String]]) }

    var blocks: [Block] {
        var out: [Block] = []
        let lines = linker.linkify(text).components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if let t = MarkdownTable.read(lines, from: i - 1) {
                out.append(.table(t.header, t.rows))
                i = t.next
                continue
            }
            if line == "---" || line == "***" { out.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let indent = (raw.prefix { $0 == " " }.count) / 2
                out.append(.bullet(String(line.dropFirst(2)), indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                out.append(.numbered(String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Sheet showing a Claude result with loading / error states.
struct AIPanelSheet: View {
    private var model: AppModel { .shared }
    let panel: AIPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(panel.title, systemImage: "sparkles").font(.headline)
                    Text(panel.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if let refresh = panel.refresh, panel.text != nil || panel.error != nil {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate")
                }
                if let text = panel.text {
                    Button { model.copyToClipboard(text) } label: { Image(systemName: "doc.on.doc") }.help("Copy (links included)")
                }
                if panel.url != nil {
                    Button { model.open(panel.url) } label: { Image(systemName: "safari") }.help("Open in browser")
                }
                Button("Done") { model.aiPanel = nil }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                Group {
                    if let error = panel.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if let text = panel.text {
                        MarkdownView(text: text)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Asking Claude… this can take up to a minute.").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 560)
    }
}

/// "3h" style age that refreshes itself.
struct AgeText: View {
    let date: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(Dates.age(date, now: ctx.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A markdown table: header row, hairline dividers, cells that wrap. Short columns keep their width;
/// long ones share the rest, so a "Who | MR | Nudge" table reads like a table, not a wall of pipes.
struct MarkdownTableView: View {
    let header: [String]?
    let rows: [[String]]
    let inline: (String) -> Text

    var columns: Int { max(header?.count ?? 0, rows.map(\.count).max() ?? 0) }

    /// Columns whose cells are all short enough to sit on one line.
    var narrow: Set<Int> {
        Set((0..<columns).filter { c in ([header ?? []] + rows).allSatisfy { c >= $0.count || plainLength($0[c]) <= 22 } })
    }

    var body: some View {
        let narrow = narrow
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
            if let header {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < header.count ? header[c] : "", column: c, narrow: narrow)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
                Divider().gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < row.count ? row[c] : "", column: c, narrow: narrow)
                            .fontWeight(c == 0 ? .medium : .regular)
                    }
                }
                .padding(.vertical, 7)
                if i < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    @ViewBuilder func cell(_ s: String, column: Int, narrow: Set<Int>) -> some View {
        if narrow.contains(column) {
            inline(s).fixedSize()
        } else {
            inline(s).fixedSize(horizontal: false, vertical: true).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Visible length, ignoring link targets and markdown symbols.
    func plainLength(_ s: String) -> Int {
        s.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
            .filter { !"[]*`_".contains($0) }.count
    }
}
