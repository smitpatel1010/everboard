import AppKit
import EverboardCore
import Foundation

// Reports, in-app actions, story following and "ask the news".
extension AppModel {
    var reports: ReportService {
        ReportService(store: store, claude: claude, gitlab: GitLabClient(secrets: secrets), jira: JiraClient(secrets: secrets))
    }

    func loadReportsAndFollows() async {
        teamHealth = await reports.latestTeamHealth()
        standup = await reports.latest("standup")
        weekly = await reports.latest("weekly")
        followed = (try? await store.followedStories()) ?? []
    }

    // MARK: Reports

    private func runReport(_ kind: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !reportRunning.contains(kind) else { return }
        reportRunning.insert(kind)
        reportError = nil
        Task {
            defer { reportRunning.remove(kind) }
            do { try await work() } catch {
                reportError = error.localizedDescription
                Log.info("\(kind) failed: \(error.localizedDescription)")
            }
        }
    }

    func generateStandup() {
        runReport("standup") { self.standup = (try await self.reports.standup(), Date()) }
    }

    func generateWeekly(notify: Bool = false) {
        runReport("weekly") {
            let text = try await self.reports.weeklyReport(reportees: self.config.reportees)
            self.weekly = (text, Date())
            if !self.config.reportees.isEmpty {
                self.teamHealth = try? await self.reports.teamHealth(reportees: self.config.reportees)
            }
            if notify {
                let e = AppEvent(id: "report.weekly:\(Dates.iso(Date()))", category: .reportReady,
                                 title: "Weekly report & team health are ready", body: String(text.prefix(140)), scope: "brief")
                if try await self.store.insert(event: e) { self.deliver([e]) }
                await self.reloadData()
            }
        }
    }

    func refreshTeamHealth(withCommentary: Bool) {
        runReport("team") {
            var h = try await self.reports.teamHealth(reportees: self.config.reportees)
            self.teamHealth = h
            if withCommentary {
                h = try await self.reports.commentary(on: h)
                self.teamHealth = h
            }
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show(.init(title: "Copied to clipboard", body: "Paste it into Teams or an email.", actionTitle: nil, onClick: {}, onAction: nil), duration: 3)
    }

    // MARK: In-app actions (GitLab token needs the `api` scope)

    private func act(_ success: String, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                ToastCenter.shared.show(.init(title: success, body: "", actionTitle: nil, onClick: {}, onAction: nil), duration: 4)
                refreshAll()
            } catch HTTPError.unauthorized(let code) {
                ToastCenter.shared.show(.init(title: "Not allowed (HTTP \(code))",
                                              body: "For GitLab actions your token needs the `api` scope (read_api is read-only).",
                                              actionTitle: nil, onClick: {}, onAction: nil))
            } catch {
                ToastCenter.shared.show(.init(title: "Action failed", body: error.localizedDescription, actionTitle: nil, onClick: {}, onAction: nil))
            }
        }
    }

    func approve(_ item: FeedItem) {
        guard let gl = GitLabClient(secrets: secrets), let pid = item["projectId"], let iid = item["iid"] else { return }
        act("Approved \(item.subtitle)") { try await gl.approve(projectId: pid, iid: iid) }
    }

    func retryPipeline(_ item: FeedItem) {
        guard let gl = GitLabClient(secrets: secrets), let pid = item["projectId"],
              let pipeline = item["pipelineId"] else { return }
        act("Retrying pipeline #\(pipeline)") { try await gl.retryPipeline(projectId: pid, pipelineId: pipeline) }
    }

    func markTodoDone(_ item: FeedItem) {
        guard let gl = GitLabClient(secrets: secrets) else { return }
        let id = String(item.id.dropFirst("gitlab.todo:".count))
        act("To-do marked done") { try await gl.markTodoDone(id: id) }
    }

    func commentOnMR(_ item: FeedItem, text: String) {
        guard let gl = GitLabClient(secrets: secrets), let pid = item["projectId"], let iid = item["iid"], !text.isEmpty else { return }
        act("Comment posted on \(item.subtitle)") { try await gl.comment(projectId: pid, iid: iid, body: text) }
    }

    func jiraTransitions(_ key: String) async -> [JiraClient.Transition] {
        (try? await JiraClient(secrets: secrets)?.transitions(issueKey: key)) ?? []
    }

    func transition(_ key: String, to t: JiraClient.Transition) {
        guard let jira = JiraClient(secrets: secrets) else { return }
        act("\(key) → \(t.to?.name ?? t.name)") { try await jira.transition(issueKey: key, to: t.id) }
    }

    func commentOnJira(_ key: String, text: String) {
        guard let jira = JiraClient(secrets: secrets), !text.isEmpty else { return }
        act("Comment posted on \(key)") { try await jira.addComment(issueKey: key, text: text) }
    }

    // MARK: Follow a story / ask

    func isFollowing(_ story: NewsBrief.Story) -> Bool { followed.contains { $0.key == story.key } }

    func toggleFollow(_ story: NewsBrief.Story) {
        Task {
            if isFollowing(story) { try? await store.unfollow(story.key) } else { try? await store.follow(story) }
            followed = (try? await store.followedStories()) ?? []
        }
    }

    func unfollow(_ key: String) {
        Task {
            try? await store.unfollow(key)
            followed = (try? await store.followedStories()) ?? []
        }
    }

    func updates(for key: String) async -> [StoryUpdate] { (try? await store.updates(for: key)) ?? [] }

    func ask(_ question: String) {
        guard !question.isEmpty, !askRunning else { return }
        askRunning = true
        aiPanel = AIPanel(title: "Ask the news", subtitle: question)
        let panelID = aiPanel?.id
        let brief = newsBrief
        Task {
            defer { askRunning = false }
            do {
                let text = try await news.ask(question, brief: brief, webSearch: config.newsGapCheck)
                if aiPanel?.id == panelID { aiPanel?.text = text }
            } catch {
                if aiPanel?.id == panelID { aiPanel?.error = error.localizedDescription }
            }
        }
    }

    // MARK: Calendar

    func prepBrief(for meeting: CalendarService.Meeting) {
        showDashboard()
        aiPanel = AIPanel(title: "Meeting prep", subtitle: "\(meeting.title) · \(meeting.start.formatted(date: .omitted, time: .shortened))",
                          url: meeting.joinURL?.absoluteString)
        let panelID = aiPanel?.id
        // Related work: anything whose author/assignee appears among attendees, or whose key/title words appear in the meeting.
        let names = meeting.attendees.map { $0.lowercased() }
        let words = NewsText.tokens(meeting.title + " " + (meeting.notes ?? ""))
        let pool = items.mine + items.review + items.reportees + items.jiraAssigned + items.jiraFilters.values.flatMap { $0 }
        let related = pool.filter { i in
            let people = [i["authorName"], i["assignee"], i.author].compactMap { $0?.lowercased() }
            return people.contains { p in names.contains { $0.contains(p) || p.contains($0) } }
                || !NewsText.tokens(i.title).intersection(words).isEmpty
                || (i["key"].map { meeting.title.contains($0) || (meeting.notes ?? "").contains($0) } ?? false)
        }
        let prompt = """
        Prepare me for this meeting in under 200 words: ## Context (what it's likely about) ## Talking points (from the related work below) \
        ## Questions to ask. If nothing related is known, say so briefly and suggest generic prep.

        Meeting: \(meeting.title)
        When: \(meeting.start.formatted()) – \(meeting.end.formatted(date: .omitted, time: .shortened))
        Attendees: \(meeting.attendees.joined(separator: ", "))
        Notes: \(String((meeting.notes ?? "").prefix(3000)))

        Related work:
        \(related.prefix(25).map { "- \($0.subtitle): \($0.title) [\($0.status ?? "")] \($0["authorName"] ?? $0["assignee"] ?? "")" }.joined(separator: "\n"))
        """
        Task {
            do {
                let r = try await claude.run(ClaudeRequest(prompt: prompt, feature: "meeting.prep"))
                if aiPanel?.id == panelID { aiPanel?.text = r.text }
            } catch {
                if aiPanel?.id == panelID { aiPanel?.error = error.localizedDescription }
            }
        }
    }
}
