import Foundation

/// Time-based corrections to session files, and the events a state change produces.
public enum SessionRules {
    /// A tool call that hasn't finished after this long may be waiting on an approval the tool doesn't report.
    public static let approvalGuessAfter: TimeInterval = 20
    /// A finished or waiting session whose process is gone is marked ended after this long without updates.
    public static let quietEndAfter: TimeInterval = 12 * 3600

    /// Applies what the hooks can't report: a process that went away without a session-end event.
    public static func refresh(_ s: AgentSession, now: Date = Date(), isAlive: (Int32) -> Bool = SessionProcess.isAlive) -> AgentSession {
        guard s.state != .ended, let pid = s.pid, pid > 0, !isAlive(pid) else { return s }
        var r = s
        switch s.state {
        case .idle, .working, .needsApproval:
            // Mid-turn with no process: closed or crashed.
            r.set(.ended, at: now)
            r.activity = nil
            r.pendingSince = nil
        case .needsReply, .done, .error:
            // Some hosts stop the process between turns; keep the result visible for a while.
            if now.timeIntervalSince(s.updatedAt) > quietEndAfter { r.set(.ended, at: now) }
        case .ended:
            break
        }
        return r
    }

    /// True when a tool call has been running long enough that it may be an unreported approval prompt.
    public static func mayNeedApproval(_ s: AgentSession, now: Date = Date()) -> Bool {
        guard s.state == .working, let since = s.pendingSince else { return false }
        return now.timeIntervalSince(since) >= approvalGuessAfter
    }

    /// Needs-you first, then by most recent update.
    public static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.updatedAt > $1.updatedAt
        }
    }

    /// Events for sessions whose state changed since `old`. A session seen for the first time only notifies
    /// if it needs you and changed recently, so opening the app doesn't replay old states.
    public static func events(old: [String: AgentSession], new: [AgentSession], now: Date = Date()) -> [AppEvent] {
        stateEvents(old: old, new: new, now: now) + noticeEvents(old: old, new: new, now: now)
    }

    /// A new error notice notifies once; informational ones only show on the row.
    static func noticeEvents(old: [String: AgentSession], new: [AgentSession], now: Date) -> [AppEvent] {
        new.compactMap { s in
            guard let n = s.notice, n.level == .error, n.id != old[s.id]?.notice?.id,
                  now.timeIntervalSince(n.at) < 300 else { return nil }
            return AppEvent(id: "session.notice:\(s.id):\(n.id)", ts: n.at, category: .sessionNotice,
                            title: "\(s.toolName) reported a problem",
                            body: [s.title ?? s.project, n.text].compactMap { $0 }.joined(separator: "\n"),
                            scope: "sessions", itemId: "session:\(s.id)")
        }
    }

    static func stateEvents(old: [String: AgentSession], new: [AgentSession], now: Date) -> [AppEvent] {
        new.compactMap { s in
            if let prev = old[s.id] {
                // A prompt Everboard holds becomes visible as soon as it's held, then again if it's handed back.
                let heldNow = s.approval?.holdUntil != nil && prev.approval?.id != s.approval?.id
                guard prev.state != s.state || prev.stateSince != s.stateSince || heldNow else { return nil }
                if s.state == .done && prev.state != .working { return nil }
            } else {
                guard s.state.needsYou || s.state == .error, now.timeIntervalSince(s.stateSince) < 120 else { return nil }
            }
            return event(for: s)
        }
    }

    public static func event(for s: AgentSession) -> AppEvent? {
        let category: EventCategory
        let headline: String
        switch s.state {
        case .needsApproval: category = .sessionNeedsApproval; headline = "\(s.toolName) needs your approval"
        case .needsReply: category = .sessionNeedsReply; headline = "\(s.toolName) is waiting for you"
        case .done: category = .sessionDone; headline = "\(s.toolName) finished"
        case .error: category = .sessionFailed; headline = "\(s.toolName) stopped with an error"
        case .idle, .working, .ended: return nil
        }
        let what = [s.title ?? s.project, s.detail].compactMap { $0 }.filter { !$0.isEmpty }
        let stamp = Int(s.stateSince.timeIntervalSince1970)
        return AppEvent(id: "session.\(s.state.rawValue):\(s.id):\(stamp)", ts: s.stateSince, category: category,
                        title: headline, body: what.joined(separator: "\n"), url: nil,
                        scope: "sessions", itemId: "session:\(s.id)")
    }
}

/// Process facts for the hook and the app. macOS only; elsewhere they report nothing.
public enum SessionProcess {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "timeout"]

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The agent's process: the first ancestor of the hook that isn't a shell wrapper.
    public static func agentPID(start: Int32 = getppid()) -> Int32? {
        #if os(macOS)
        var pid = start
        for _ in 0..<6 {
            guard pid > 1, let info = info(pid) else { return nil }
            if !shells.contains(info.name) { return pid }
            pid = info.parent
        }
        return nil
        #else
        return nil
        #endif
    }

    /// The process's controlling terminal, e.g. `/dev/ttys003`, or nil when it has none.
    public static func tty(_ pid: Int32) -> String? {
        #if os(macOS)
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kinfo.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.isEmpty || s == "??" ? nil : "/dev/\(s)"
        #else
        return nil
        #endif
    }

    #if os(macOS)
    static func info(_ pid: Int32) -> (name: String, parent: Int32)? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &kinfo.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return (name, kinfo.kp_eproc.e_ppid)
    }
    #endif
}
