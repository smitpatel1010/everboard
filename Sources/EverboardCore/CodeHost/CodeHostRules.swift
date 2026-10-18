import Foundation

/// Notification rules shared by GitLab and GitHub sources; both store the same attrs
/// (`pipelineStatus`, `pipelineId`, `action`, …) so one set of rules covers them.
public enum CodeHostRules {
    public static func events(for change: ItemChange, account: CodeHostAccount) -> [AppEvent] {
        let new = change.new
        let ci = account.kind == .gitlab ? "Pipeline" : "Checks"
        switch change.scope {
        case account.scope(.mine), account.scope(.review), account.scope(.assigned):
            // Head pipeline turned red (or a newly seen MR is already red).
            guard new["pipelineStatus"] == "failed", let pid = new["pipelineId"] else { return [] }
            if let old = change.old, old["pipelineId"] == pid, old["pipelineStatus"] == "failed" { return [] }
            return [AppEvent(id: account.eventID("pipeline.failed:\(pid)"), ts: new.updatedAt ?? Date(), category: .pipelineFailedMR,
                             title: "\(ci) failed: \(new.title)",
                             body: "\(new["projectPath"] ?? "") · \(new["sourceBranch"] ?? "")",
                             url: new["pipelineUrl"] ?? new.url)]

        case account.scope(.reportees):
            // Only changes created recently: avoids a burst when a reportee is first added to the list.
            guard !change.everSeen, let created = new.createdAt, created > Date().addingTimeInterval(-3 * 86400) else { return [] }
            return [AppEvent(id: "mr.new:\(new.id)", ts: created, category: .reporteeNewMR,
                             title: "\(new["authorName"] ?? new.author ?? "Reportee") opened \(account.kind == .gitlab ? "an MR" : "a PR")",
                             body: "\(new.title)\n\(new["projectPath"] ?? "")", url: new.url)]

        case account.scope(.todos):
            guard !change.everSeen else { return [] }
            let category: EventCategory
            switch new["action"] ?? "" {
            case "review_requested": category = .todoReview
            case "mentioned", "directly_addressed": category = .todoMention
            case "build_failed": return [] // covered by the pipeline rule with a better message
            default: category = .todoOther
            }
            return [AppEvent(id: "todo:\(new.id)", ts: new.createdAt ?? Date(), category: category,
                             title: new.subtitle, body: new.title, url: new.url)]

        default:
            guard change.scope.hasPrefix(account.scope(.pipelines)), new.status == "failed" else { return [] }
            if let old = change.old, old.status == "failed" { return [] }
            return [AppEvent(id: account.eventID("pipeline.failed:\(new["pipelineId"] ?? new.id)"), ts: new.updatedAt ?? Date(),
                             category: .pipelineFailedTriggered,
                             title: "Your \(account.kind == .gitlab ? "pipeline" : "workflow run") failed on \(new["ref"] ?? "?")",
                             body: new["projectPath"] ?? "", url: new.url)]
        }
    }
}

/// Settings → Pinned projects: plain paths ("group/project", "owner/repo") apply to every account that can see them;
/// a full URL ("https://github.com/owner/repo") pins it on the account with that host only.
public enum PinnedProjects {
    public static func paths(_ entries: [String], for account: CodeHostAccount) -> [String] {
        var out: [String] = []
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            var path = entry
            if let url = SafeURL.web(entry) {
                guard url.host?.lowercased() == account.webURL.host?.lowercased() else { continue }
                path = url.path
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            if !path.isEmpty, path.contains("/"), account.includes(path: path), !out.contains(path) { out.append(path) }
        }
        return out
    }

    /// A path that didn't resolve on an account is retried every 6 hours, not every poll.
    static func shouldLookUp(_ path: String, account: CodeHostAccount, context: FetchContext) async -> Bool {
        guard let missed = await context.value("\(account.id).pinned.miss.\(path)").flatMap(Dates.parseISO) else { return true }
        return Date().timeIntervalSince(missed) > 6 * 3600
    }

    static func recordMiss(_ path: String, account: CodeHostAccount, context: FetchContext) async {
        await context.setValue("\(account.id).pinned.miss.\(path)", Dates.iso(Date()))
    }
}
