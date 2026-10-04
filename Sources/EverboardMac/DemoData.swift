import AppKit
import EverboardCore
import SwiftUI

/// `--demo` fills an in-memory store with sample work data (so the UI can be previewed without tokens);
/// `--snapshot <dir>` renders each dashboard screen to PNG. Both are developer aids.
@MainActor
enum DemoData {
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }

    static var snapshotDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }

    static func seed(_ store: Store) async {
        let now = Date()
        func mr(_ iid: Int, _ title: String, kind: String, author: String, name: String, pipeline: String, hoursOld: Double,
                draft: Bool = false, approved: String? = nil, merge: String = "mergeable") -> FeedItem {
            var attrs = ["projectId": "42", "projectPath": "acme/payments-api", "iid": String(iid), "authorName": name,
                         "pipelineStatus": pipeline, "pipelineId": String(9000 + iid), "pipelineUrl": "https://gitlab.example/p/\(iid)",
                         "mergeStatus": merge, "notes": String(iid % 7), "sourceBranch": "feature/PAY-\(1200 + iid)-work"]
            if draft { attrs["draft"] = "1" }
            if let approved { attrs["approvedBy"] = approved }
            attrs["jiraKeys"] = "PAY-\(1200 + iid)"
            return FeedItem(id: "gitlab.mr:42:\(iid)", source: "gitlab", kind: "mr.\(kind)", title: title,
                            subtitle: "acme/payments-api !\(iid)", url: "https://gitlab.example/mr/\(iid)", status: pipeline,
                            author: author, createdAt: now.addingTimeInterval(-hoursOld * 3600),
                            updatedAt: now.addingTimeInterval(-hoursOld * 900), attrs: attrs)
        }
        let mine = [mr(311, "Add retry budget to payment workers", kind: "mine", author: "me", name: "You", pipeline: "failed", hoursOld: 20),
                    mr(318, "Bump GRPC deps and regenerate stubs", kind: "mine", author: "me", name: "You", pipeline: "success", hoursOld: 4, approved: "Priya N")]
        let review = [mr(305, "Cache tenant config in Redis", kind: "review", author: "priya", name: "Priya N", pipeline: "success", hoursOld: 30),
                      mr(320, "Fix pagination off-by-one in export API", kind: "review", author: "rahul", name: "Rahul S", pipeline: "running", hoursOld: 2)]
        let reportees = [mr(290, "Migrate alert rules to v2 schema", kind: "reportee", author: "asha", name: "Asha K", pipeline: "failed", hoursOld: 96, merge: "ci_must_pass"),
                         mr(321, "Dashboard widget for SLA breaches", kind: "reportee", author: "asha", name: "Asha K", pipeline: "success", hoursOld: 1, draft: true),
                         mr(316, "Remove dead feature flags", kind: "reportee", author: "vik", name: "Vikram P", pipeline: "success", hoursOld: 26, approved: "You")]
        let pipelines = (0..<6).map { i in
            FeedItem(id: "gitlab.pipeline:\(8000 + i)", source: "gitlab", kind: "pipeline",
                     title: ["acme/payments-api · feature/PAY-1311", "acme/ledger · main", "acme/payments-api · feature/PAY-1318"][i % 3],
                     subtitle: "#\(5000 + i) push", url: "https://gitlab.example/pl/\(i)", status: ["failed", "success", "running", "success", "canceled", "success"][i],
                     updatedAt: now.addingTimeInterval(-Double(i) * 5400), attrs: ["pipelineId": String(8000 + i)])
        }
        func issue(_ key: String, _ title: String, _ status: String, _ prio: String, _ assignee: String, _ hours: Double) -> FeedItem {
            FeedItem(id: "jira.issue:\(key)", source: "jira", kind: "issue.assigned", title: title, subtitle: key,
                     url: "https://example.atlassian.net/browse/\(key)", status: status, updatedAt: now.addingTimeInterval(-hours * 3600),
                     attrs: ["key": key, "priority": prio, "assignee": assignee, "filterId": "10042"])
        }
        let assigned = [issue("PAY-1311", "Payment workers exhaust retries during upstream outage", "In Progress", "High", "You", 3),
                        issue("PAY-1290", "Plan v2 alert schema rollout", "To Do", "Medium", "You", 30)]
        let sprint = assigned + [issue("PAY-1305", "Tenant config cache invalidation", "In Review", "Medium", "Priya N", 5),
                                 issue("PAY-1321", "SLA breach widget", "To Do", "Low", "Asha K", 1)]
        do {
            try await store.apply(ScopeResult(scope: GitLabSource.Scope.mine, mode: .replace, items: mine), events: [])
            try await store.apply(ScopeResult(scope: GitLabSource.Scope.review, mode: .replace, items: review), events: [])
            try await store.apply(ScopeResult(scope: GitLabSource.Scope.reportees, mode: .replace, items: reportees), events: [])
            try await store.apply(ScopeResult(scope: GitLabSource.Scope.pipelinesPrefix + "p42", mode: .accumulate, items: pipelines), events: [])
            try await store.apply(ScopeResult(scope: JiraSource.Scope.assigned, mode: .replace, items: assigned), events: [])
            try await store.apply(ScopeResult(scope: JiraSource.Scope.filterPrefix + "10042", mode: .replace, items: sprint), events: [])
            let events = [
                AppEvent(id: "d1", ts: now.addingTimeInterval(-600), category: .pipelineFailedMR, title: "Pipeline failed: Add retry budget to payment workers", body: "acme/payments-api · feature/PAY-1311"),
                AppEvent(id: "d2", ts: now.addingTimeInterval(-1800), category: .reporteeNewMR, title: "Asha K opened an MR", body: "Dashboard widget for SLA breaches\nacme/payments-api", itemId: "gitlab.mr:42:321"),
                AppEvent(id: "d3", ts: now.addingTimeInterval(-3600), category: .jiraMention, title: "Priya N mentioned you on PAY-1305", body: "Can you confirm the TTL we agreed on?"),
                AppEvent(id: "d4", ts: now.addingTimeInterval(-7200), category: .jiraFilterStatus, title: "PAY-1305: In Progress → In Review", body: "Tenant config cache invalidation\nSprint board", read: true),
                AppEvent(id: "d5", ts: now.addingTimeInterval(-9000), category: .todoReview, title: "Rahul S requested your review", body: "Fix pagination off-by-one in export API"),
                AppEvent(id: "d6", ts: now.addingTimeInterval(-30000), category: .newsMajor, title: "Major story: Google DeepMind announces Gemini 4 Argon", body: "Covered by Google DeepMind, Hacker News, The Verge", read: true),
            ]
            for e in events { try await store.insert(event: e) }
            await store.cache("brief.work.latest", """
            ## Needs you today
            - **Fix the red pipeline on acme/payments-api!311** — retry-budget tests fail since this morning; it blocks PAY-1311 (High).
            - **Review acme/payments-api!305** from Priya — waiting 30h, pipeline green, small diff.
            - Reply to Priya on **PAY-1305** (she asked about the cache TTL).
            ## Your team
            - **Asha K** — !290 (v2 alert schema) has been red for 4 days; worth a nudge or pairing.
            - **Vikram P** — !316 approved by you, ready to merge.
            ## FYI
            - Rahul's !320 pipeline is still running.
            """)
            await store.setValue("brief.work.at", Dates.iso(now.addingTimeInterval(-3 * 3600)))
            let health = TeamHealth(generatedAt: now, days: 7, people: [
                PersonMetrics(username: "asha", name: "Asha K", merged: 3, medianCycleHours: 96, medianSize: 42, open: 2, oldestOpenDays: 4, openRed: 1, reviewsGiven: 2),
                PersonMetrics(username: "rahul", name: "Rahul S", merged: 6, medianCycleHours: 18, medianSize: 9, open: 1, oldestOpenDays: 0.2, openRed: 0, reviewsGiven: 7),
                PersonMetrics(username: "vik", name: "Vikram P", merged: 4, medianCycleHours: 30, medianSize: 12, open: 1, oldestOpenDays: 1.1, openRed: 0, reviewsGiven: 3),
            ], commentary: "## Highlights\n- **Rahul** shipped 6 small MRs with an 18h cycle time and did the most reviews.\n## Watch\n- **Asha**: her MRs are large (42 files) and slow (4 days). Ask whether !290 can be split.\n## Team trend\n- Healthy review culture; one long-running migration.")
            await store.cache("team.health.latest", String(decoding: try JSONEncoder.everboard.encode(health), as: UTF8.self))
            await store.cache("report.standup.latest", "## Yesterday\n- Merged **acme/ledger!301**: backoff for the queue consumer\n- Reviewed !305 (Priya) and !316 (Vikram)\n## Today\n- Fix the red pipeline on **!311** (PAY-1311)\n- Plan the v2 alert schema rollout (PAY-1290)\n## Blockers\n- None")
            await store.setValue("report.standup.at", Dates.iso(now.addingTimeInterval(-1800)))
            for (n, (feature, i, o, cost)) in [("news.brief", 21000, 2400, 0.31), ("work.brief", 6000, 900, 0.06), ("mr.summary", 15000, 700, 0.09),
                                          ("report.standup", 2500, 400, 0.02), ("news.ask", 18000, 600, 0.14)].enumerated() {
                var u = ClaudeUsage(); u.model = "claude-sonnet"; u.inputTokens = i; u.outputTokens = o; u.cacheReadTokens = i / 2; u.durationMs = 24000
                await store.recordUsage(feature: feature, usage: u, costUSD: cost, ok: true, now: now.addingTimeInterval(-Double(n * 3) * 86400))
            }
            // Reuse the real World & Tech brief if one exists.
            if let real = try? Store() {
                if let brief = try? await real.latestBrief() { try await store.saveBrief(brief) }
                if let arts = try? await real.articles(since: now.addingTimeInterval(-36 * 3600)) { try await store.insertArticles(arts) }
            }
        } catch {
            Log.info("demo seed failed: \(error)")
        }
    }

    static func snapshot(model: AppModel, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DashboardView().environment(model))
        // Light + opaque so offscreen captures don't lose text over translucent materials.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.orderFront(nil)
        let screens: [(String, SidebarItem)] = [("inbox", .inbox), ("mrs", .mergeRequests), ("pipelines", .pipelines),
                                                ("jira", .jira), ("workbrief", .workBrief), ("reports", .reports), ("world", .worldBrief), ("settings", .settings)]
        for (name, item) in screens + [("usage", .settings)] {
            model.settingsTab = name == "usage" ? "usage" : "general"
            model.selection = item
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            save(window.contentView!, to: dir.appendingPathComponent("\(name).png"))
        }
        let menu = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 380, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MenuBarView().environment(model))
        menu.contentView = host
        menu.appearance = NSAppearance(named: .aqua)
        menu.setContentSize(host.fittingSize)
        menu.orderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        save(host, to: dir.appendingPathComponent("menubar.png"))
        ToastCenter.shared.show(.init(title: "Pipeline failed: Add retry budget to payment workers", body: "acme/payments-api · feature/PAY-1311",
                                      actionTitle: "Summarize with AI", onClick: {}, onAction: {}))
        Log.info("snapshots written to \(dir.path)")
        NSApp.terminate(nil)
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
