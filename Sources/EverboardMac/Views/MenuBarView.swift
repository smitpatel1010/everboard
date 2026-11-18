import EverboardCore
import SwiftUI

/// The popover under the menu-bar icon: counts, the Assistant, meetings and the latest activity.
struct MenuBarView: View {
    private var model: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                askBar
                stats
                if let warning = attention {
                    Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                MeetingsSection()
                activity
            }
            .padding(14)
            footer
        }
        .frame(width: 380)
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.accentGradient).frame(width: 22, height: 22)
                .overlay(Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 0) {
                Text(AppInfo.name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(model.health.keys.sorted(), id: \.self) { key in
                        let h = model.health[key]!
                        HStack(spacing: 3) {
                            Circle().fill(HealthChips.color(h)).frame(width: 5, height: 5)
                            Text(model.sourceName(key)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .help(h.label)
                    }
                }
            }
            Spacer()
            iconButton("arrow.clockwise", "Refresh now") { model.refreshAll() }
            iconButton("macwindow", "Open dashboard") { model.showDashboard() }
            iconButton("gearshape", "Settings") { model.showDashboard(.settings) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var askBar: some View {
        Button { AssistantModel.shared.listenFromHotkey() } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(Theme.accentGradient))
                Text("Ask your agents").foregroundStyle(.primary)
                Spacer()
                Text("⌥⇧Space").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        let i = model.items
        let failed = i.pipelines.filter { $0.status == "failed" && ($0.updatedAt ?? .distantPast) > Date().addingTimeInterval(-86400) }.count
        return HStack(spacing: 8) {
            stat(i.reviewReady.count, "Reviews", .blue) { model.showDashboard(.mergeRequests) }
            stat(failed, "Failed", failed > 0 ? .red : .green) { model.showDashboard(.pipelines) }
            stat(i.jiraAssigned.count, "Jira", .orange) { model.showDashboard(.jira) }
            stat(model.unread, "Unread", .teal) { model.showDashboard(.inbox) }
        }
    }

    @ViewBuilder private var activity: some View {
        HStack {
            Text("Latest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if model.unread > 0 { Button("Mark all read") { model.markAllRead() }.buttonStyle(.borderless).font(.caption) }
        }
        if model.events.isEmpty {
            Text("Nothing yet. Updates show up here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
        } else {
            VStack(spacing: 2) {
                ForEach(model.events.prefix(6)) { e in
                    Button { model.open(e) } label: { EventRow(event: e, compact: true) }.buttonStyle(.plain)
                }
            }
        }
        if !model.heldEvents.isEmpty {
            Button("\(model.heldEvents.count) batched notifications — show now") {
                let batch = model.heldEvents
                model.heldEvents = []
                model.heldSince = nil
                model.notifier.postDigest(batch)
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.showDashboard(.workBrief) } label: { Label("Brief", systemImage: "sun.max") }
            Button { model.showDashboard(.reports) } label: { Label("Team", systemImage: "person.2") }
            Button { CommandPalette.shared.show() } label: { Label("Search", systemImage: "magnifyingglass") }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    var attention: String? {
        if !model.hasCodeHost && !model.secrets.hasJira { return "Add your tokens in Settings → Accounts" }
        if let e = model.storeError { return e }
        return nil
    }

    func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 24) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }

    func stat(_ value: Int, _ title: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(value > 0 ? tint : Color.secondary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EventRow: View {
    let event: AppEvent
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(compact ? .callout : .body).fontWeight(event.read ? .regular : .semibold).lineLimit(compact ? 1 : 2)
                Text(event.body.replacingOccurrences(of: "\n", with: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                AgeText(date: event.ts)
                if !event.read { Circle().fill(.blue).frame(width: 7, height: 7) }
            }
        }
        .padding(.vertical, compact ? 3 : 5)
        .padding(.horizontal, compact ? 4 : 0)
        .contentShape(Rectangle())
    }

    var icon: String {
        switch event.category {
        case .pipelineFailedMR, .pipelineFailedTriggered: return "xmark.octagon.fill"
        case .reporteeNewMR: return "arrow.triangle.pull"
        case .todoReview: return "eye"
        case .todoMention, .jiraMention: return "at"
        case .todoOther: return "checklist"
        case .jiraAssigned: return "person.crop.circle.badge.checkmark"
        case .jiraComment: return "text.bubble"
        case .jiraFilterNew: return "plus.circle"
        case .jiraFilterStatus: return "arrow.right.circle"
        case .workBriefReady: return "sun.max"
        case .newsBriefReady: return "globe"
        case .newsMajor: return "bolt.fill"
        case .newsFollow: return "binoculars"
        case .reportReady: return "doc.text"
        case .customNew: return "tray.and.arrow.down"
        case .customStatus: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch event.category {
        case .pipelineFailedMR, .pipelineFailedTriggered: return .red
        case .newsMajor, .newsFollow: return .orange
        case .jiraAssigned, .jiraComment, .jiraMention, .jiraFilterNew, .jiraFilterStatus: return .blue
        case .workBriefReady, .newsBriefReady, .reportReady: return .yellow
        default: return .purple
        }
    }
}

/// Today's upcoming meetings with join + prep buttons.
struct MeetingsSection: View {
    private var model: AppModel { .shared }

    var body: some View {
        let upcoming = model.calendar.today.filter { $0.end > Date() }.prefix(3)
        if model.config.calendarEnabled, !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(upcoming)) { m in
                    HStack(spacing: 6) {
                        Circle().fill(m.isNow ? Color.green : Color.blue).frame(width: 6, height: 6)
                        Text(m.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(m.title).font(.callout).lineLimit(1)
                        Spacer()
                        Button { model.prepBrief(for: m) } label: { Image(systemName: "sparkles") }
                            .buttonStyle(.borderless).help("Prep brief")
                        if let url = m.joinURL {
                            Button("Join") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
