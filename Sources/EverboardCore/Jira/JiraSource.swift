import Foundation

/// Polls Jira Cloud: issues assigned to me, configured filters, and new comments on issues I'm involved in.
public struct JiraSource: DataSource {
    public let id = "jira"
    public let displayName = "Jira"
    public let interval: TimeInterval
    let client: JiraClient

    /// Open issues assigned to me. Many workflows close or archive issues without setting a resolution,
    /// so the Done status category is excluded too (it covers "Closed", "Archive", "Done" and the like).
    public static let assignedJQL = "assignee = currentUser() AND resolution = Unresolved AND statusCategory != Done ORDER BY updated DESC"

    /// Recently finished issues assigned to me, for the Jira tab's "Show done" toggle. Kept in their own scope
    /// (not under the "jira.assigned" prefix) so they never reach Home, briefs or notifications.
    public static let doneJQL = "assignee = currentUser() AND (statusCategory = Done OR resolution is not EMPTY) AND updated >= -30d ORDER BY updated DESC"

    public enum Scope {
        public static let assigned = "jira.assigned"
        public static let done = "jira.done"
        public static let comments = "jira.comments"
        public static let filterPrefix = "jira.filter."
    }

    public init(client: JiraClient, interval: TimeInterval) {
        self.client = client
        self.interval = interval
    }

    public func fetch(context: FetchContext) async throws -> [ScopeResult] {
        let me = try await myself(context)
        var results: [ScopeResult] = []

        let assigned = try await client.search(Self.assignedJQL)
        results.append(ScopeResult(scope: Scope.assigned, mode: .replace, items: assigned.map { item($0, kind: "assigned") }))
        let done = try await client.search(Self.doneJQL, max: 50)
        results.append(ScopeResult(scope: Scope.done, mode: .replace, items: done.map { item($0, kind: "done") }))

        for f in context.config.jiraFilters {
            guard let jql = await filterJQL(f.id, context: context) else { continue }
            let issues = try await client.search("(\(JQL.stripOrderBy(jql))) ORDER BY updated DESC")
            results.append(ScopeResult(scope: Scope.filterPrefix + f.id, mode: .replace,
                                       items: issues.map { item($0, kind: "filter", filter: f) }))
        }

        results.append(ScopeResult(scope: Scope.comments, mode: .accumulate, items: try await recentComments(me: me, context: context)))
        return results
    }

    // MARK: Rules

    public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] {
        let new = change.new
        let key = new["key"] ?? ""
        switch change.scope {
        case Scope.assigned:
            guard !change.wasPresent else { return [] }
            return [AppEvent(id: "jira.assigned:\(key):\(new.updatedAt.map(Dates.iso) ?? "")", ts: new.updatedAt ?? Date(),
                             category: .jiraAssigned, title: "Assigned to you: \(key)",
                             body: new.title, url: new.url)]

        case Scope.comments:
            guard !change.everSeen, new["authorId"] != new["me"] else { return [] }
            let issue = "\(new["issueKey"] ?? "") \(new["issueSummary"] ?? "")"
            if new["mentionsMe"] == "1" {
                return [AppEvent(id: "jira.comment:\(new.id)", ts: new.createdAt ?? Date(), category: .jiraMention,
                                 title: "\(new.author ?? "Someone") mentioned you on \(new["issueKey"] ?? "")",
                                 body: "\(issue)\n\(new.title)", url: new.url)]
            }
            guard new["involvement"] == "assignee" || new["involvement"] == "reporter" else { return [] }
            return [AppEvent(id: "jira.comment:\(new.id)", ts: new.createdAt ?? Date(), category: .jiraComment,
                             title: "\(new.author ?? "Someone") commented on \(new["issueKey"] ?? "")",
                             body: "\(issue)\n\(new.title)", url: new.url)]

        default:
            guard change.scope.hasPrefix(Scope.filterPrefix) else { return [] }
            let filterId = String(change.scope.dropFirst(Scope.filterPrefix.count))
            let cfg = config.jiraFilters.first { $0.id == filterId }
            let filterName = cfg?.name ?? "filter"
            if !change.everSeen {
                return [AppEvent(id: "jira.filter.new:\(filterId):\(key)", ts: new.updatedAt ?? Date(), category: .jiraFilterNew,
                                 title: "New in \(filterName): \(key)", body: new.title, url: new.url,
                                 wantsNotification: cfg?.notifyNew ?? true)]
            }
            if let old = change.old, change.wasPresent, let from = old.status, let to = new.status, from != to {
                return [AppEvent(id: "jira.status:\(key):\(to):\(new.updatedAt.map(Dates.iso) ?? "")", ts: new.updatedAt ?? Date(),
                                 category: .jiraFilterStatus, title: "\(key): \(from) → \(to)",
                                 body: "\(new.title)\n\(filterName)", url: new.url,
                                 wantsNotification: cfg?.notifyStatus ?? true)]
            }
            return []
        }
    }

    // MARK: Helpers

    private func myself(_ context: FetchContext) async throws -> JiraUser {
        if let json = await context.value("jira.me"),
           let u = try? JSONDecoder().decode(JiraUser.self, from: Data(json.utf8)) { return u }
        let u = try await client.myself()
        await context.setValue("jira.me", String(decoding: try JSONEncoder().encode(u), as: UTF8.self))
        return u
    }

    /// Filter JQL, cached for an hour.
    private func filterJQL(_ id: String, context: FetchContext) async -> String? {
        let key = "jira.filterJQL.\(id)"
        let stampKey = key + ".at"
        let cached = await context.value(key)
        let stamp = await context.value(stampKey).flatMap(Dates.parseISO) ?? .distantPast
        if let cached, Date().timeIntervalSince(stamp) < 3600 { return cached }
        guard let jql = try? await client.filter(id: id).jql else { return cached }
        await context.setValue(key, jql)
        await context.setValue(stampKey, Dates.iso(Date()))
        return jql
    }

    /// New comments on issues where I'm assignee/reporter/watcher, updated since the last poll.
    private func recentComments(me: JiraUser, context: FetchContext) async throws -> [FeedItem] {
        let cursorKey = "jira.comments.cursor"
        let last = await context.value(cursorKey).flatMap(Dates.parseISO) ?? Date().addingTimeInterval(-3600)
        let started = Date()
        // Relative minutes avoid JQL's dependence on the user's Jira profile timezone.
        let minutes = max(5, Int(started.timeIntervalSince(last) / 60) + 3)
        let jql = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) AND updated >= -\(min(minutes, 60 * 24 * 3))m ORDER BY updated DESC"
        let issues = try await client.search(jql, max: 30)
        var items: [FeedItem] = []
        for issue in issues {
            guard let comments = try? await client.comments(issueKey: issue.key) else { continue }
            let involvement = issue.fields.assignee?.accountId == me.accountId ? "assignee"
                : issue.fields.reporter?.accountId == me.accountId ? "reporter" : "watcher"
            for c in comments {
                guard let created = c.created, created > last.addingTimeInterval(-300) else { continue }
                let text = ADF.plainText(c.body)
                var attrs = [
                    "issueKey": issue.key, "issueSummary": issue.fields.summary ?? "", "involvement": involvement,
                    "me": me.accountId, "mentionsMe": ADF.mentions(c.body, accountId: me.accountId) ? "1" : "0",
                ]
                attrs["authorId"] = c.author?.accountId
                items.append(FeedItem(id: "jira.comment:\(issue.key):\(c.id)", source: "jira", kind: "comment",
                                      title: String(text.prefix(280)), subtitle: "\(issue.key) · \(issue.fields.summary ?? "")",
                                      url: client.browseURL(issue.key) + "?focusedCommentId=\(c.id)",
                                      author: c.author?.displayName, createdAt: c.created, updatedAt: c.updated, attrs: attrs))
            }
        }
        await context.setValue(cursorKey, Dates.iso(started))
        return items
    }

    func item(_ issue: JiraIssue, kind: String, filter: JiraFilterConfig? = nil) -> FeedItem {
        let f = issue.fields
        var attrs = ["key": issue.key]
        attrs["priority"] = f.priority?.name
        attrs["type"] = f.issuetype?.name
        attrs["assignee"] = f.assignee?.displayName
        attrs["assigneeId"] = f.assignee?.accountId
        attrs["reporter"] = f.reporter?.displayName
        attrs["statusCategory"] = f.status?.statusCategory?.key
        attrs["due"] = f.duedate
        attrs["filterId"] = filter?.id
        return FeedItem(id: "jira.issue:\(issue.key)", source: "jira", kind: "issue.\(kind)",
                        title: f.summary ?? issue.key, subtitle: issue.key, url: client.browseURL(issue.key),
                        status: f.status?.name, author: f.reporter?.displayName,
                        createdAt: f.created, updatedAt: f.updated, attrs: attrs)
    }
}
