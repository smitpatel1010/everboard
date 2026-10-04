import EventKit
import EverboardCore
import Foundation
import Observation

/// Today's meetings from macOS Calendar (add your work account in System Settings → Internet Accounts).
@MainActor @Observable
final class CalendarService {
    struct Meeting: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let notes: String?
        let attendees: [String]
        let joinURL: URL?
        let isBusy: Bool
        let calendarName: String

        var isNow: Bool { start <= Date() && end > Date() }
    }

    enum Access { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var today: [Meeting] = []
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard access == .unknown else { reload(); return }
        store.requestFullAccessToEvents { granted, error in
            Task { @MainActor in
                self.access = granted ? .granted : .denied
                Log.info("calendar access granted=\(granted) \(error?.localizedDescription ?? "")")
                if granted { self.reload() }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard access == .granted else { return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        today = events
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map { e in
                Meeting(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "(no title)", start: e.startDate, end: e.endDate,
                        location: e.location, notes: e.notes,
                        attendees: (e.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                        joinURL: Self.joinURL(e), isBusy: e.availability != .free,
                        calendarName: e.calendar.title)
            }
            .sorted { $0.start < $1.start }
    }

    var next: Meeting? { today.first { $0.end > Date() } }
    var inMeeting: Bool { today.contains { $0.isNow && $0.isBusy } }

    /// Short label for the menu bar, e.g. "in 12m: Standup" (only within the next hour).
    var menuBarLabel: String? {
        guard let m = next else { return nil }
        if m.isNow { return "now: \(m.title.prefix(18))" }
        let mins = Int(m.start.timeIntervalSinceNow / 60)
        return mins <= 60 ? "in \(max(mins, 1))m: \(m.title.prefix(18))" : nil
    }

    /// Finds a Teams / Zoom / Meet / Webex link in the event's URL, location or notes.
    static func joinURL(_ e: EKEvent) -> URL? {
        let haystack = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(teams\.microsoft\.com|teams\.live\.com|zoom\.us|meet\.google\.com|webex\.com)[^\s<>"]*"#
        guard let r = haystack.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(haystack[r]))
    }
}
