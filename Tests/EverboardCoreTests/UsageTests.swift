import Foundation
import Testing
@testable import EverboardCore

private struct FakeRunner: ClaudeRunning {
    var fail = false
    func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        if fail { throw ClaudeError.failed("nope") }
        var u = ClaudeUsage()
        u.model = "claude-test"; u.inputTokens = 100; u.outputTokens = 50; u.cacheReadTokens = 1000; u.durationMs = 2000
        return ClaudeResponse(text: "ok", structured: nil, costUSD: 0.01, usage: u)
    }
}

@Suite struct UsageTests {
    @Test func parsesCLIOutput() throws {
        // Trimmed from a real `claude -p --output-format json` response.
        let json = #"{"duration_ms":3069,"total_cost_usd":0.015851,"usage":{"input_tokens":9,"cache_creation_input_tokens":7501,"cache_read_input_tokens":0,"output_tokens":168,"server_tool_use":{"web_search_requests":2}},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":9,"outputTokens":168,"cacheReadInputTokens":0,"cacheCreationInputTokens":7501}},"is_error":false,"result":"hi"}"#
        let u = ClaudeUsage.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(u.model == "claude-haiku-4-5-20251001")
        #expect(u.inputTokens == 9)
        #expect(u.outputTokens == 168)
        #expect(u.cacheCreationTokens == 7501)
        #expect(u.webSearches == 2)
        #expect(u.durationMs == 3069)
        #expect(u.totalTokens == 7678)
    }

    @Test func recordingRunnerAggregates() async throws {
        let store = try Store.inMemory()
        let ok = RecordingClaudeRunner(base: FakeRunner(), store: store)
        _ = try await ok.run(ClaudeRequest(prompt: "a", feature: "news.brief"))
        _ = try await ok.run(ClaudeRequest(prompt: "b", feature: "news.brief"))
        _ = try await ok.run(ClaudeRequest(prompt: "c", feature: "mr.summary"))
        let bad = RecordingClaudeRunner(base: FakeRunner(fail: true), store: store)
        await #expect(throws: ClaudeError.self) { try await bad.run(ClaudeRequest(prompt: "d", feature: "mr.summary")) }

        let since = Date().addingTimeInterval(-60)
        let byFeature = try await store.usage(since: since, groupBy: "feature")
        let news = try #require(byFeature.first { $0.key == "news.brief" })
        #expect(news.runs == 2)
        #expect(news.outputTokens == 100)
        #expect(abs(news.costUSD - 0.02) < 0.0001)
        #expect(byFeature.first { $0.key == "mr.summary" }?.failures == 1)
        let total = try await store.usageTotal(since: since)
        #expect(total.runs == 4)
        #expect(total.totalTokens == 3 * 1150)
        #expect(try await store.usage(since: since, groupBy: "day").count == 1)
    }
}
