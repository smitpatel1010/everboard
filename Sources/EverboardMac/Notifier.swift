import AppKit
import EverboardCore
import UserNotifications

/// Posts macOS notifications for events and routes notification clicks / actions back to the model.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false

    enum Category: String {
        case mr = "EVB_MR", jira = "EVB_JIRA", plain = "EVB_PLAIN", approval = "EVB_APPROVAL"
    }
    enum Action: String {
        case summarize = "EVB_SUMMARIZE", digest = "EVB_DIGEST", markRead = "EVB_READ", mute = "EVB_MUTE"
        case allow = "EVB_ALLOW", deny = "EVB_DENY", answerHere = "EVB_ANSWER_HERE"
    }

    func setUp(model: AppModel) {
        self.model = model
        center.delegate = self
        let read = UNNotificationAction(identifier: Action.markRead.rawValue, title: "Mark read")
        let mute = UNNotificationAction(identifier: Action.mute.rawValue, title: "Mute this item")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.mr.rawValue, actions: [
                UNNotificationAction(identifier: Action.summarize.rawValue, title: "Summarize with AI", options: [.foreground]), read, mute,
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.jira.rawValue, actions: [
                UNNotificationAction(identifier: Action.digest.rawValue, title: "AI digest", options: [.foreground]), read, mute,
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.plain.rawValue, actions: [read, mute], intentIdentifiers: []),
            // A Claude Code permission prompt Everboard is holding: answer it from the notification.
            UNNotificationCategory(identifier: Category.approval.rawValue, actions: [
                UNNotificationAction(identifier: Action.allow.rawValue, title: "Allow"),
                UNNotificationAction(identifier: Action.deny.rawValue, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Log.info("notifications authorized=\(granted) \(error?.localizedDescription ?? "")")
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(_ events: [AppEvent]) {
        guard !events.isEmpty else { return }
        // Bursts (e.g. after the VPN reconnects) collapse into a summary after the first few.
        let individual = events.prefix(4)
        guard authorized else {
            // System notifications blocked (unsigned build) → in-app banners instead.
            for e in individual { toast(e) }
            if events.count > individual.count {
                ToastCenter.shared.show(.init(title: "\(events.count - individual.count) more updates",
                                              body: events.dropFirst(individual.count).prefix(3).map(\.title).joined(separator: "\n"),
                                              actionTitle: nil, onClick: { [weak self] in self?.model?.showDashboard(.inbox) }, onAction: nil))
            }
            return
        }
        for e in individual { postSystem(e) }
        if events.count > individual.count {
            let content = UNMutableNotificationContent()
            content.title = "\(events.count - individual.count) more updates"
            content.body = events.dropFirst(individual.count).prefix(4).map(\.title).joined(separator: "\n")
            content.categoryIdentifier = Category.plain.rawValue
            content.userInfo = ["openInbox": true]
            center.add(UNNotificationRequest(identifier: "evb.summary.\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    private func postSystem(_ e: AppEvent) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        content.body = e.body
        content.threadIdentifier = e.category.source
        content.sound = [.pipelineFailedMR, .pipelineFailedTriggered, .todoReview, .jiraMention, .newsMajor,
                         .sessionNeedsApproval, .sessionNeedsReply].contains(e.category) ? .default : nil
        var info: [String: Any] = ["eventId": e.id]
        info["url"] = e.url
        info["itemId"] = e.itemId
        switch e.category {
        case .reporteeNewMR, .todoReview:
            content.categoryIdentifier = Category.mr.rawValue
        case .jiraAssigned, .jiraComment, .jiraMention, .jiraFilterNew, .jiraFilterStatus:
            content.categoryIdentifier = Category.jira.rawValue
            info["jiraKey"] = Self.jiraKey(in: e)
        case .sessionNeedsApproval where Self.heldApproval(e):
            content.categoryIdentifier = Category.approval.rawValue
        default:
            content.categoryIdentifier = Category.plain.rawValue
        }
        if e.category == .workBriefReady { info["open"] = "workBrief" }
        if e.category == .newsBriefReady { info["open"] = "worldBrief" }
        if e.category == .reportReady { info["open"] = "reports" }
        if e.category.source == "sessions" { info["open"] = "session" }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: e.id, content: content, trigger: nil)) { error in
            if let error { Log.info("notification failed: \(error.localizedDescription)") }
        }
    }

    private func toast(_ e: AppEvent) {
        var info: [String: Any] = ["eventId": e.id]
        info["url"] = e.url
        info["itemId"] = e.itemId
        info["jiraKey"] = Self.jiraKey(in: e)
        if e.category == .workBriefReady { info["open"] = "workBrief" }
        if e.category == .newsBriefReady { info["open"] = "worldBrief" }
        if e.category == .reportReady { info["open"] = "reports" }
        if e.category.source == "sessions" { info["open"] = "session" }
        let action: (String, String)? = switch e.category {
        case .sessionNeedsApproval where Self.heldApproval(e): ("Allow", Action.allow.rawValue)
        case .sessionNeedsReply where Self.heldQuestion(e): ("Answer in Everboard", Action.answerHere.rawValue)
        case .reporteeNewMR, .todoReview: ("Summarize with AI", Action.summarize.rawValue)
        case .jiraAssigned, .jiraComment, .jiraMention, .jiraFilterNew, .jiraFilterStatus: ("AI digest", Action.digest.rawValue)
        default: nil
        }
        let snapshot = info
        ToastCenter.shared.show(.init(
            title: e.title, body: e.body, actionTitle: action?.0,
            onClick: { [weak self] in self?.route(action: UNNotificationDefaultActionIdentifier, info: snapshot) },
            onAction: action.map { a in { [weak self] in self?.route(action: a.1, info: snapshot) } }))
    }

    /// One summary notification for batched low-priority (or in-meeting) events.
    func postDigest(_ events: [AppEvent]) {
        guard !events.isEmpty else { return }
        if events.count <= 2 { post(events); return }
        let title = "\(events.count) updates while you were busy"
        let body = events.prefix(5).map(\.title).joined(separator: "\n")
        guard authorized else {
            ToastCenter.shared.show(.init(title: title, body: body, actionTitle: nil,
                                          onClick: { [weak self] in self?.model?.showDashboard(.inbox) }, onAction: nil), duration: 15)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Category.plain.rawValue
        content.userInfo = ["openInbox": true]
        center.add(UNNotificationRequest(identifier: "evb.digest.\(UUID().uuidString)", content: content, trigger: nil))
    }

    func sendTest() {
        post([AppEvent(id: "test:\(UUID().uuidString)", category: .pipelineFailedMR, title: "Everboard test notification",
                       body: authorized ? "System notifications are working ✅" : "In-app banner (system notifications are blocked for unsigned builds)",
                       url: nil)])
    }

    /// Handles a click or action button, from a system notification or an in-app banner.
    func route(action: String, info: [String: Any]) {
        guard let model else { return }
        let url = info["url"] as? String
        let itemId = info["itemId"] as? String
        if let eventId = info["eventId"] as? String { model.markRead([eventId]) }
        switch action {
        case Action.summarize.rawValue:
            if let item = model.item(withId: itemId) { model.summarize(item) } else { model.open(url) }
        case Action.digest.rawValue:
            if let key = info["jiraKey"] as? String { model.digest(jiraKey: key, url: url) } else { model.open(url) }
        case Action.mute.rawValue:
            model.mute(itemId: itemId, for: nil)
        case Action.answerHere.rawValue:
            model.showDashboard(.sessions)
        case Action.allow.rawValue, Action.deny.rawValue:
            if let s = SessionCenter.shared.session(itemId: itemId) {
                SessionCenter.shared.answer(s, allow: action == Action.allow.rawValue)
            }
        case Action.markRead.rawValue:
            break
        default:
            let open = info["open"] as? String
            if info["openInbox"] != nil { model.showDashboard(.inbox) }
            else if open == "workBrief" { model.showDashboard(.workBrief) }
            else if open == "worldBrief" { model.showDashboard(.worldBrief) }
            else if open == "reports" { model.reportsTab = "weekly"; model.showDashboard(.reports) }
            else if open == "session" {
                // The Sessions page is where a prompt can be answered; its rows jump to the session itself.
                model.showDashboard(.sessions)
            }
            else if url != nil { model.open(url) }
            else { model.showDashboard(.inbox) }
        }
    }

    /// The event is for a permission prompt that Everboard is still holding, so it can be answered from here.
    @MainActor static func heldApproval(_ e: AppEvent) -> Bool {
        guard let s = SessionCenter.shared.session(itemId: e.itemId) else { return false }
        return SessionCenter.shared.canAnswer(s) && s.approval?.isQuestion != true
    }

    /// A multiple-choice question Everboard is holding: its options are on the Sessions page.
    @MainActor static func heldQuestion(_ e: AppEvent) -> Bool {
        guard let s = SessionCenter.shared.session(itemId: e.itemId) else { return false }
        return SessionCenter.shared.canAnswer(s) && s.approval?.isQuestion == true
    }

    static func jiraKey(in e: AppEvent) -> String? {
        if let id = e.itemId, id.hasPrefix("jira.issue:") { return String(id.dropFirst("jira.issue:".count)) }
        return JiraKeys.find(in: [e.title]).first
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        // userInfo holds only plist types; re-box as Sendable strings for the hop to the main actor.
        var flat: [String: String] = [:]
        for (k, v) in info { if let k = k as? String { flat[k] = (v as? String) ?? ((v as? Bool) == true ? "true" : nil) } }
        let boxed = flat
        Task { @MainActor in
            self.route(action: action, info: boxed)
            completionHandler()
        }
    }
}
