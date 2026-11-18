import Foundation
import Testing
@testable import EverboardCore

private struct ScriptedRunner: ClaudeRunning {
    var error: Error?
    func run(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        if let error { throw error }
        return ClaudeResponse(text: "ok")
    }
}

private actor Outcomes {
    var seen: [String] = []
    func add(_ e: Error?) { seen.append(e.map { "\($0)" } ?? "ok") }
}

/// A stand-in `claude` executable that prints `output` and exits.
private func fakeCLI(_ output: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("everboard-fake-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("claude").path
    try "#!/bin/sh\ncat >/dev/null\ncat <<'EOF'\n\(output)\nEOF\n".write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

@Suite struct ClaudeSchedulingTests {
    @Test func recognisesLoggedOutMessages() {
        #expect(ClaudeError.isAuthFailure("Failed to authenticate: OAuth session expired and could not be refreshed"))
        #expect(ClaudeError.isAuthFailure("Invalid API key · Please run /login"))
        #expect(ClaudeError.isAuthFailure("Not logged in"))
        #expect(!ClaudeError.isAuthFailure("Request timed out"))
        #expect(!ClaudeError.isAuthFailure("Overloaded"))
        #expect(ClaudeError.notLoggedIn("x").localizedDescription.contains("claude auth login"))
    }

    @Test func cliAuthFailureBecomesNotLoggedIn() async throws {
        let exe = try fakeCLI(#"{"is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#)
        do {
            _ = try await ClaudeCLIRunner(executable: exe).run(ClaudeRequest(prompt: "hi"))
            Issue.record("expected an error")
        } catch ClaudeError.notLoggedIn(let m) {
            #expect(m.contains("OAuth session expired"))
        }

        let other = try fakeCLI(#"{"is_error":true,"result":"Overloaded"}"#)
        await #expect(throws: ClaudeError.self) { try await ClaudeCLIRunner(executable: other).run(ClaudeRequest(prompt: "hi")) }
        do { _ = try await ClaudeCLIRunner(executable: other).run(ClaudeRequest(prompt: "hi")) } catch ClaudeError.failed {} catch {
            Issue.record("non-auth errors stay .failed, got \(error)")
        }
    }

    @Test func readsAuthStatus() async throws {
        #expect(ClaudeCLIRunner.parseLoggedIn(Data(#"{"loggedIn": false, "authMethod": "none"}"#.utf8)) == false)
        #expect(ClaudeCLIRunner.parseLoggedIn(Data(#"{"loggedIn": true}"#.utf8)) == true)
        #expect(ClaudeCLIRunner.parseLoggedIn(Data("Logged in as someone".utf8)) == nil)
        #expect(await ClaudeCLIRunner(executable: try fakeCLI(#"{"loggedIn": true}"#)).isLoggedIn() == true)
        #expect(await ClaudeCLIRunner(executable: "/nonexistent/claude").isLoggedIn() == nil)
    }

    @Test func failingJobBacksOffInsteadOfRunningEveryMinute() {
        var b = RetryBackoff(base: 5 * 60, cap: 60 * 60)
        let due = Date(timeIntervalSince1970: 1_000_000)
        var runs: [Int] = []
        // Six hours of one-minute ticks with the job failing every time.
        for minute in 0..<360 {
            let now = due.addingTimeInterval(Double(minute) * 60)
            if b.allows("brief.work", due: due, now: now) {
                b.recordAttempt("brief.work", due: due, now: now)
                runs.append(minute)
            }
        }
        #expect(runs.prefix(5) == [0, 5, 15, 35, 75])
        #expect(runs.count < 12)
        #expect(zip(runs, runs.dropFirst()).allSatisfy { $1 - $0 <= 60 })
        // The next day's due time starts fresh; other jobs are independent.
        #expect(b.allows("brief.work", due: due.addingTimeInterval(86_400), now: due.addingTimeInterval(86_400)))
        #expect(b.allows("news.brief", due: due, now: due.addingTimeInterval(60)))
    }

    @Test func reportsEachOutcome() async {
        let outcomes = Outcomes()
        let ok = OutcomeReportingClaudeRunner(base: ScriptedRunner()) { await outcomes.add($0) }
        let bad = OutcomeReportingClaudeRunner(base: ScriptedRunner(error: ClaudeError.notLoggedIn("expired"))) { await outcomes.add($0) }
        _ = try? await ok.run(ClaudeRequest(prompt: "a"))
        await #expect(throws: ClaudeError.self) { try await bad.run(ClaudeRequest(prompt: "b")) }
        let seen = await outcomes.seen
        #expect(seen.count == 2 && seen[0] == "ok" && seen[1].contains("notLoggedIn"))
    }
}
