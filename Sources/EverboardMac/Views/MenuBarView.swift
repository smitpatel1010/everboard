import EverboardCore
import SwiftUI

/// The popover under the menu-bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(AppInfo.name).font(.headline)
                if model.unread > 0 {
                    Text("\(model.unread) unread").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh now")
                Button { model.showDashboard(.settings) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings")
            }
            HealthChips(compact: false)

            if let warning = attention { Label(warning, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }

            MeetingsSection()

            Divider()
            if model.events.isEmpty {
                Text("Nothing yet — updates show up here.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.events.prefix(8)) { e in
                        Button { model.open(e) } label: { EventRow(event: e, compact: true) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Divider()

            HStack(spacing: 8) {
                quickButton("Dashboard", "rectangle.grid.2x2") { model.showDashboard(.inbox) }
                quickButton("Work brief", "sun.max") { model.showDashboard(.workBrief) }
                quickButton("Reports", "doc.text") { model.showDashboard(.reports) }
                quickButton("World & Tech", "globe") { model.showDashboard(.worldBrief) }
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
            HStack {
                Button("Mark all read") { model.markAllRead() }.disabled(model.unread == 0)
                Button("Search ⌥Space") { CommandPalette.shared.show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 380)
    }

    var attention: String? {
        if !model.secrets.hasGitLab && !model.secrets.hasJira { return "Add your tokens in Settings → Accounts" }
        if let e = model.storeError { return e }
        return nil
    }

    func quickButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
    @Environment(AppModel.self) private var model

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
