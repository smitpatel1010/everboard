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

    /// Sample accounts so demo mode shows both hosts.
    static let accounts = [
        CodeHostAccount(kind: .gitlab, webURL: URL(string: "https://gitlab.example")!, token: ""),
        CodeHostAccount(kind: .github, webURL: URL(string: "https://github.com")!, token: "", orgs: ["acme-oss"]),
    ]

    /// Placeholder secrets: Settings and links show these instead of anything from your real secrets file.
    static let secrets = Secrets(values: ["JIRA_URL": "https://example.atlassian.net", "JIRA_EMAIL": "alex@example.com",
                                          "JIRA_API_TOKEN": "demo"],
                                 path: URL(fileURLWithPath: "/Users/you/.config/everboard/secrets.env"))  // placeholder; leakcheck:allow

    static var config: AppConfig {
        var c = AppConfig()
        c.reportees = [Reportee(email: "asha@example.com", username: "asha", githubUsername: "asha-k", name: "Asha K"),
                       Reportee(email: "vikram@example.com", username: "vik", name: "Vikram P")]
        c.jiraFilters = [JiraFilterConfig(id: "10042", name: "Sprint board")]
        c.pinnedProjects = ["acme/payments-api", "https://github.com/acme-oss/sdk-swift"]
        c.launchAtLogin = false
        return c
    }

    static func seed(_ store: Store) async {
        let now = Date()
        let gitlab = accounts[0], github = accounts[1]
        func mr(_ iid: Int, _ title: String, kind: String, author: String, name: String, pipeline: String, hoursOld: Double,
                draft: Bool = false, approved: String? = nil, merge: String = "mergeable") -> FeedItem {
            var attrs = ["account": "gitlab", "projectId": "42", "projectPath": "acme/payments-api", "iid": String(iid), "authorName": name,
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
                      mr(320, "Fix pagination off-by-one in export API", kind: "review", author: "rahul", name: "Rahul S", pipeline: "running", hoursOld: 2),
                      mr(323, "Spike: event-sourced ledger prototype", kind: "review", author: "vik", name: "Vikram P", pipeline: "success", hoursOld: 50, draft: true)]
        let reportees = [mr(290, "Migrate alert rules to v2 schema", kind: "reportee", author: "asha", name: "Asha K", pipeline: "failed", hoursOld: 96, merge: "ci_must_pass"),
                         mr(321, "Dashboard widget for SLA breaches", kind: "reportee", author: "asha", name: "Asha K", pipeline: "success", hoursOld: 1, draft: true),
                         mr(316, "Remove dead feature flags", kind: "reportee", author: "vik", name: "Vikram P", pipeline: "success", hoursOld: 26, approved: "You")]
        let pipelines = (0..<6).map { i in
            FeedItem(id: "gitlab.pipeline:\(8000 + i)", source: "gitlab", kind: "pipeline",
                     title: ["acme/payments-api · feature/PAY-1311", "acme/ledger · main", "acme/payments-api · feature/PAY-1318"][i % 3],
                     subtitle: "#\(5000 + i) push", url: "https://gitlab.example/pl/\(i)", status: ["failed", "success", "running", "success", "canceled", "success"][i],
                     updatedAt: now.addingTimeInterval(-Double(i) * 5400), attrs: ["account": "gitlab", "pipelineId": String(8000 + i)])
        }
        func pr(_ n: Int, _ title: String, kind: String, author: String, name: String, checks: String, hoursOld: Double) -> FeedItem {
            let repo = "acme-oss/sdk-swift"
            return FeedItem(id: "github.pr:\(repo):\(n)", source: "github", kind: "mr.\(kind)", title: title, subtitle: "\(repo) #\(n)",
                            url: "https://github.com/\(repo)/pull/\(n)", status: checks, author: author,
                            createdAt: now.addingTimeInterval(-hoursOld * 3600), updatedAt: now.addingTimeInterval(-hoursOld * 600),
                            attrs: ["account": "github", "projectId": repo, "projectPath": repo, "iid": String(n), "authorName": name,
                                    "pipelineStatus": checks, "pipelineId": "abc\(n)", "pipelineUrl": "https://github.com/\(repo)/pull/\(n)/checks",
                                    "mergeStatus": "mergeable", "notes": "2", "sourceBranch": "fix/retry-\(n)"])
        }
        let githubMine = [pr(87, "Expose retry budget in the Swift SDK", kind: "mine", author: "you", name: "You", checks: "success", hoursOld: 6)]
        let githubReview = [pr(91, "Add async sequence for webhooks", kind: "review", author: "lena", name: "Lena M", checks: "failed", hoursOld: 12)]
        let runs = [FeedItem(id: "github.run:777", source: "github", kind: "pipeline", title: "acme-oss/sdk-swift · fix/retry-87",
                             subtitle: "#212 CI (pull_request)", url: "https://github.com/acme-oss/sdk-swift/actions/runs/777", status: "success",
                             updatedAt: now.addingTimeInterval(-2400), attrs: ["account": "github", "pipelineId": "777", "projectPath": "acme-oss/sdk-swift"])]
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
            try await store.apply(ScopeResult(scope: gitlab.scope(.mine), mode: .replace, items: mine), events: [])
            try await store.apply(ScopeResult(scope: gitlab.scope(.review), mode: .replace, items: review), events: [])
            try await store.apply(ScopeResult(scope: gitlab.scope(.reportees), mode: .replace, items: reportees), events: [])
            try await store.apply(ScopeResult(scope: gitlab.scope(.pipelines) + "p42", mode: .accumulate, items: pipelines), events: [])
            try await store.apply(ScopeResult(scope: github.scope(.mine), mode: .replace, items: githubMine), events: [])
            try await store.apply(ScopeResult(scope: github.scope(.review), mode: .replace, items: githubReview), events: [])
            try await store.apply(ScopeResult(scope: github.scope(.pipelines) + "acme-oss/sdk-swift", mode: .accumulate, items: runs), events: [])
            try await store.apply(ScopeResult(scope: JiraSource.Scope.assigned, mode: .replace, items: assigned), events: [])
            var archived = issue("PAY-1244", "Retire v1 alert webhooks", "Archive", "Low", "You", 50)
            archived.attrs["statusCategory"] = "done"
            try await store.apply(ScopeResult(scope: JiraSource.Scope.done, mode: .replace, items: [archived]), events: [])
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
            await store.setValue("gitlab.me", #"{"id":1,"username":"you","name":"Alex Morgan"}"#)
            var masked = ClaudeRequest(prompt: """
            Summarize this merge request for me as the reviewer/manager. ...

            Title: Cache tenant config in Redis
            Author: [PERSON-1]
            Branch: feature/PAY-1305-cache → main
            Description:
            Adds a read-through cache. Connection: redis://[SECRET]@cache.internal:6379

            Diff (3 files):
            --- config/cache.yml → config/cache.yml
            +ttl_seconds: 300
            """, systemPrompt: "You are the user's work assistant inside their personal dashboard app. …", feature: "mr.summary")
            masked.redactions = ["person": 2, "secret": 1]
            var u = ClaudeUsage(); u.model = "claude-sonnet"; u.inputTokens = 15000; u.outputTokens = 700
            await store.logAICall(masked, response: ClaudeResponse(text: "## What it does\n- Adds a Redis read-through cache for tenant config (**Priya N**).",
                                                                   structured: nil, costUSD: 0.09, usage: u), error: nil, now: now.addingTimeInterval(-2400))
            await store.logAICall(ClaudeRequest(prompt: "Write my daily standup update …\n\nMerged since Fri:\n- acme/ledger!301: Backoff for the queue consumer",
                                                feature: "report.standup"),
                                  response: ClaudeResponse(text: "## Yesterday\n- Merged acme/ledger!301", structured: nil, costUSD: 0.02, usage: u),
                                  error: nil, now: now.addingTimeInterval(-1800))
            await store.logAICall(ClaudeRequest(prompt: "Here are ~150 headlines from the last day …", tools: ["WebSearch"], feature: "news.brief"),
                                  response: ClaudeResponse(text: "{…}", structured: nil, costUSD: 0.31, usage: u), error: nil,
                                  now: now.addingTimeInterval(-5 * 3600))
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

    static func seedCalendar(_ calendar: CalendarService) {
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        func meeting(_ title: String, _ start: Date, _ minutes: Double, _ people: [String], join: Bool = true) -> CalendarService.Meeting {
            .init(id: title, title: title, start: start, end: start.addingTimeInterval(minutes * 60), location: nil, notes: nil,
                  attendees: people, joinURL: join ? URL(string: "https://teams.microsoft.com/l/meetup-join/demo") : nil, isBusy: true,
                  calendarName: "Work")
        }
        let now = Date()
        calendar.seedDemo([
            meeting("Team standup", at(9, 30), 15, ["Priya N", "Rahul S", "Asha K", "Vikram P"]),
            meeting("1:1 with Asha", now.addingTimeInterval(25 * 60), 30, ["Asha K"]),
            meeting("Payments design review", now.addingTimeInterval(2.5 * 3600), 60, ["Priya N", "Rahul S", "Dana L"]),
            meeting("Focus: alert schema plan", now.addingTimeInterval(4.5 * 3600), 90, [], join: false),
        ].sorted { $0.start < $1.start })
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
        let screens: [(String, SidebarItem)] = [("inbox", .inbox), ("home", .home), ("aiactivity", .aiActivity), ("mrs", .mergeRequests), ("pipelines", .pipelines),
                                                ("jira", .jira), ("workbrief", .workBrief), ("reports", .reports), ("world", .worldBrief), ("settings", .settings)]
        for (name, item) in screens + [("usage", .settings), ("privacy", .settings), ("accounts", .settings), ("team", .settings)] {
            model.settingsTab = ["usage", "privacy", "accounts", "team"].contains(name) ? name : "general"
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
        for (name, query) in [("palette-empty", ""), ("palette-search", "pay"), ("palette-jira", "jira cache")] {
            let state = PaletteState(model: model, close: {})
            state.query = query
            let host = NSHostingView(rootView: PaletteView(state: state))
            let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: PaletteView.width, height: PaletteView.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.backgroundColor = .windowBackgroundColor
            win.contentView = host
            win.orderFront(nil)
            try? await Task.sleep(nanoseconds: 700_000_000)
            if name == "palette-search" { state.selection = 1; state.toggleActions(); try? await Task.sleep(nanoseconds: 400_000_000) }
            save(host, to: dir.appendingPathComponent("\(name).png"))
            win.orderOut(nil)
        }
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
