import Foundation

/// Paces scheduled Claude jobs. A job only stops being due once it succeeds, so without this a failing
/// job would rerun every scheduler tick (once a minute) for hours. Gaps double from `base` up to `cap`;
/// a new due time (the next day's brief, say) starts the count over.
public struct RetryBackoff: Sendable {
    struct Attempt: Sendable { var due: Date; var count: Int; var last: Date }

    public var base: TimeInterval
    public var cap: TimeInterval
    private var attempts: [String: Attempt] = [:]

    public init(base: TimeInterval = 5 * 60, cap: TimeInterval = 60 * 60) {
        self.base = base
        self.cap = cap
    }

    /// Wait after the n-th attempt of the same due time: base, 2×base, 4×base … capped.
    public func delay(afterAttempts n: Int) -> TimeInterval {
        min(base * pow(2, Double(max(n - 1, 0))), cap)
    }

    public func allows(_ key: String, due: Date, now: Date) -> Bool {
        guard let a = attempts[key], a.due == due else { return true }
        return now.timeIntervalSince(a.last) >= delay(afterAttempts: a.count)
    }

    public mutating func recordAttempt(_ key: String, due: Date, now: Date) {
        var a = attempts[key].flatMap { $0.due == due ? $0 : nil } ?? Attempt(due: due, count: 0, last: now)
        a.count += 1
        a.last = now
        attempts[key] = a
    }
}

/// Passes each call's outcome (nil on success) to `report`, so the app can notice a logged-out CLI and when it's fixed.
public struct OutcomeReportingClaudeRunner: ClaudeRunning {
    let base: ClaudeRunning
    let report: @Sendable (Error?) async -> Void

    public init(base: ClaudeRunning, report: @escaping @Sendable (Error?) async -> Void) {
        self.base = base
        self.report = report
    }

    public func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        do {
            let r = try await base.run(request)
            await report(nil)
            return r
        } catch {
            await report(error)
            throw error
        }
    }
}
