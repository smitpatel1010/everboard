import Foundation
import Testing
@testable import EverboardCore

/// Returns a canned structured reply and records the request.
private final class FakeClaude: ClaudeRunning, @unchecked Sendable {
    var reply: JSONValue
    var lastRequest: ClaudeRequest?
    init(_ reply: JSONValue) { self.reply = reply }
    func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        lastRequest = request
        return ClaudeResponse(text: "", structured: reply)
    }
}

@Suite struct AssistantTests {
    let mr = FeedItem(id: "gitlab.mr:7:12", source: "gitlab", kind: "mr.review", title: "Fix retries", subtitle: "acme/app !12",
                      url: "https://example.com/12", attrs: ["projectPath": "acme/app", "iid": "12"])
    let issue = FeedItem(id: "jira.issue:PAY-1", source: "jira", kind: "issue.assigned", title: "Plan", subtitle: "PAY-1", attrs: ["key": "PAY-1"])
    let review = AgentAction(id: "review", name: "Deep review", command: "claude -p {url}", targets: [.change])

    var context: AssistantContext {
        AssistantContext(items: [mr, issue], actions: [review], people: ["Asha K"], screens: AssistantPlanner.screens)
    }

    /// The model picks actions from their descriptions; an undescribed one gets guessed at (e.g. "work_brief" taken
    /// to mean "open the brief").
    @Test func promptDescribesEveryAction() {
        for a in AssistantIntent.Action.allCases {
            #expect(AssistantPlanner.system.contains("- \(a.rawValue):") || AssistantPlanner.system.contains(" \(a.rawValue): "),
                    "\(a.rawValue) isn't described")
        }
    }

    @Test func navigationIsLocal() {
        #expect(AssistantPlanner.localIntent("Open inbox.")?.screen == "inbox")
        #expect(AssistantPlanner.localIntent("show me my PRs")?.screen == "merge requests")
        #expect(AssistantPlanner.localIntent("show radar")?.screen == "team radar")
        #expect(AssistantPlanner.localIntent("refresh")?.action == .refresh)
        #expect(AssistantPlanner.localIntent("why did my pipeline fail") == nil)
    }

    @Test func confirmations() {
        #expect(AssistantPlanner.confirmation("Yes.") == true)
        #expect(AssistantPlanner.confirmation("go ahead") == true)
        #expect(AssistantPlanner.confirmation("Cancel") == false)
        #expect(AssistantPlanner.confirmation("yes and also open jira") == nil)
    }

    @Test func modelChoiceIsCheckedAgainstRealData() {
        let ok = AssistantPlanner.validate(AssistantIntent(action: .runAgent, item: mr.id, agent: "review", reply: "Running"), context: context)
        #expect(ok.action == .runAgent && ok.item == mr.id && ok.agent == "review")
        // Made-up item, or an action that doesn't apply to the item, becomes a clarifying question.
        #expect(AssistantPlanner.validate(AssistantIntent(action: .runAgent, item: "nope", agent: "review", reply: ""), context: context).action == .answer)
        #expect(AssistantPlanner.validate(AssistantIntent(action: .runAgent, item: issue.id, agent: "review", reply: ""), context: context).action == .answer)
        #expect(AssistantPlanner.validate(AssistantIntent(action: .summarize, item: issue.id, reply: ""), context: context).action == .answer)
        #expect(AssistantPlanner.validate(AssistantIntent(action: .show, screen: "Nowhere", reply: ""), context: context).action == .answer)
        #expect(AssistantPlanner.validate(AssistantIntent(action: .oneOnOne, person: "asha k", reply: ""), context: context).action == .oneOnOne)
        #expect(AssistantPlanner.validate(AssistantIntent(action: .oneOnOne, person: "Bob", reply: ""), context: context).action == .answer)
    }

    @Test func plansThroughClaudeWithTheDashboardInThePrompt() async throws {
        let fake = FakeClaude(.object(["action": .string("run_agent"), "item": .string(mr.id), "agent": .string("review"),
                                       "reply": .string("Run deep review on acme/app !12?")]))
        let intent = try await AssistantPlanner(claude: fake).plan("deep review the retries MR", context: context)
        #expect(intent.action == .runAgent && intent.item == mr.id)
        let req = try #require(fake.lastRequest)
        #expect(req.feature == "assistant.command")
        #expect(req.jsonSchema != nil && req.tools.isEmpty)
        #expect(req.prompt.contains("id=\(mr.id)") && req.prompt.contains("id=review | Deep review"))
        #expect(req.people == ["Asha K"])
    }

    @Test func chatsKeepOnlyRecentMemoryAndPersist() async throws {
        var chat = AssistantChat()
        for i in 1...7 {
            chat.messages.append(.init(role: .user, text: "q\(i)", spoken: i == 7))
            chat.messages.append(.init(role: .assistant, text: "a\(i)"))
        }
        chat.messages.append(.init(role: .user, text: "unanswered"))
        #expect(chat.exchanges.count == AssistantChat.memory)
        #expect(chat.exchanges.first?.user == "q4" && chat.exchanges.last?.reply == "a7")

        let prompt = AssistantPlanner.prompt("next", context: context, history: chat.exchanges)
        #expect(!prompt.contains("q3") && prompt.contains("q4"))

        #expect(AssistantChat.title(from: "  short  ") == "short")
        #expect(AssistantChat.title(from: String(repeating: "x", count: 80)).count == 48)

        let store = try Store.inMemory()
        chat.title = "First"
        try await store.saveChat(chat)
        var second = AssistantChat(title: "Second", createdAt: Date().addingTimeInterval(60))
        second.updatedAt = Date().addingTimeInterval(60)
        try await store.saveChat(second)
        #expect(try await store.chats().map(\.title) == ["Second", "First"])
        #expect(try await store.chats().last?.messages.last?.text == "unanswered")
        #expect(try await store.chats().last?.messages[12].spoken == true)
        try await store.deleteChat(id: second.id)
        #expect(try await store.chats().map(\.title) == ["First"])
    }
}
