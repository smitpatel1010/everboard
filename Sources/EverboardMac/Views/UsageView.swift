import Charts
import EverboardCore
import SwiftUI

/// Settings → AI usage: tokens and estimated cost of every `claude` call Everboard makes.
struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var range = 30
    @State private var total = UsageTotals(key: "total")
    @State private var today = UsageTotals(key: "today")
    @State private var byFeature: [UsageTotals] = []
    @State private var byDay: [UsageTotals] = []
    @State private var byModel: [UsageTotals] = []

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    StatTile(title: "Today", value: Self.tokens(today.totalTokens), detail: "\(today.runs) runs · \(Self.money(today.costUSD))")
                    StatTile(title: "Last \(range) days", value: Self.tokens(total.totalTokens), detail: "\(total.runs) runs · \(Self.money(total.costUSD))")
                    StatTile(title: "Output tokens", value: Self.tokens(total.outputTokens), detail: "input \(Self.tokens(total.inputTokens))")
                    StatTile(title: "Cache reads", value: Self.tokens(total.cacheReadTokens), detail: "\(total.webSearches) web searches")
                }
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Cost is the API-equivalent estimate that the claude CLI reports. On a Claude subscription you aren't billed per token — use it to see which features consume the most.")
            }

            Section("Tokens per day") {
                if byDay.isEmpty {
                    Text("No Claude calls recorded yet.").foregroundStyle(.secondary)
                } else {
                    Chart(byDay) { d in
                        BarMark(x: .value("Day", Self.day(d.key), unit: .day), y: .value("Tokens", d.totalTokens))
                            .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartXScale(domain: Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(range - 1) * 86400))...Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)))
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: range <= 7 ? 1 : range <= 30 ? 5 : 15)) { _ in
                        AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Self.tokens(n)) } } } }
                    .frame(height: 180)
                }
            }

            Section("By feature") {
                UsageTable(rows: byFeature, label: Self.featureName)
            }
            Section("By model") {
                UsageTable(rows: byModel, label: { $0.isEmpty ? "unknown" : $0 })
            }
        }
        .formStyle(.grouped)
        .task(id: range) { await load() }
    }

    func load() async {
        let since = Date().addingTimeInterval(-Double(range) * 86400)
        total = (try? await model.store.usageTotal(since: since)) ?? UsageTotals(key: "total")
        today = (try? await model.store.usageTotal(since: Calendar.current.startOfDay(for: Date()))) ?? UsageTotals(key: "today")
        byFeature = (try? await model.store.usage(since: since, groupBy: "feature")) ?? []
        byDay = (try? await model.store.usage(since: since, groupBy: "day")) ?? []
        byModel = (try? await model.store.usage(since: since, groupBy: "model")) ?? []
    }

    static func featureName(_ key: String) -> String {
        [
            "work.brief": "Work brief", "mr.summary": "MR summary", "jira.digest": "Jira digest",
            "news.brief": "World & Tech brief", "news.deeper": "Go deeper", "news.preferences": "Learning from feedback",
            "news.ask": "Ask the news", "report.standup": "Daily standup", "report.weekly": "Weekly report",
            "team.commentary": "Team health AI read", "meeting.prep": "Meeting prep", "settings.test": "Test claude",
        ][key] ?? key
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func money(_ x: Double) -> String { String(format: "$%.2f", x) }

    static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? Date()
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageTable: View {
    let rows: [UsageTotals]
    let label: (String) -> String

    var body: some View {
        if rows.isEmpty {
            Text("Nothing yet.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(["", "Runs", "Input", "Output", "Cache read", "Cache write", "Est. cost", "Avg time"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows) { r in
                    GridRow {
                        Text(label(r.key)).lineLimit(1)
                        Text("\(r.runs)" + (r.failures > 0 ? " (\(r.failures) failed)" : "")).monospacedDigit()
                        Text(UsageSettings.tokens(r.inputTokens)).monospacedDigit()
                        Text(UsageSettings.tokens(r.outputTokens)).monospacedDigit()
                        Text(UsageSettings.tokens(r.cacheReadTokens)).monospacedDigit()
                        Text(UsageSettings.tokens(r.cacheCreationTokens)).monospacedDigit()
                        Text(UsageSettings.money(r.costUSD)).monospacedDigit()
                        Text(String(format: "%.0fs", r.avgSeconds)).monospacedDigit()
                    }
                }
            }
        }
    }
}
