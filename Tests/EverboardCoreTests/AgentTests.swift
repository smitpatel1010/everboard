import Foundation
import Testing
@testable import EverboardCore

private func change(title: String = "Fix retries", attrs extra: [String: String] = [:]) -> FeedItem {
    var attrs = ["account": "gitlab", "projectId": "7", "projectPath": "acme/payments-api", "iid": "12", "authorName": "Asha",
                 "sourceBranch": "feature/x", "targetBranch": "main", "jiraKeys": "PAY-1, PAY-2"]
    attrs.merge(extra) { _, new in new }
    return FeedItem(id: "gitlab.mr:7:12", source: "gitlab", kind: "mr.review", title: title, subtitle: "acme/payments-api !12",
                    url: "https://gitlab.example/acme/payments-api/-/merge_requests/12", attrs: attrs)
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("everboard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct AgentTemplateTests {
    @Test func scansPlaceholdersAndFlagsTypos() {
        let t = #"claude -p "/deep-review {url}" --repo {projectPath} {url} {nope} {not a placeholder} ${HOME}"#
        #expect(AgentTemplate.used(in: t) == ["url", "projectPath", "nope"])
        #expect(AgentTemplate.unknown(in: t) == ["nope"])
    }

    @Test func valuesFromAChange() {
        let v = AgentTemplate.values(for: change(), repoPaths: ["payments-api": "~/code/payments-api"])
        #expect(v["url"]?.hasSuffix("/12") == true)
        #expect(v["iid"] == "12")
        #expect(v["ref"] == "acme/payments-api!12")
        #expect(v["jiraKey"] == "PAY-1")
        #expect(v["kind"] == "change")
        #expect(v["repoPath"] == NSHomeDirectory() + "/code/payments-api")
        #expect(v["pipelineId"] == nil)
    }

    @Test func repoPathPrefersExactProjectPath() {
        let map = ["acme/payments-api": "/a", "payments-api": "/b"]
        #expect(AgentTemplate.repoPath(for: "acme/payments-api", in: map) == "/a")
        #expect(AgentTemplate.repoPath(for: "other/payments-api", in: map) == "/b")
        #expect(AgentTemplate.repoPath(for: "acme/web", in: map) == nil)
    }

    @Test func placeholdersBecomeQuotedEnvReferences() {
        #expect(AgentTemplate.shellCommand("open {url}") == #"open "${EVERBOARD_URL}""#)
        #expect(AgentTemplate.shellCommand(#"claude -p "/review {url} now""#) == #"claude -p "/review ${EVERBOARD_URL} now""#)
        #expect(AgentTemplate.shellCommand("echo 'x {title} y'") == #"echo 'x '"${EVERBOARD_TITLE}"' y'"#)
        #expect(AgentTemplate.shellCommand(#"echo "a \" {iid}""#) == #"echo "a \" ${EVERBOARD_IID}""#)
        #expect(AgentTemplate.shellCommand("echo {unknown}") == "echo {unknown}")
        #expect(AgentTemplate.preview(#"claude -p "/review {url}""#, values: ["url": "https://x/1"]) == #"claude -p "/review https://x/1""#)
    }

    @Test func hostileTitleIsPassedAsTextNotRun() async throws {
        let dir = try tempDir()
        let marker = dir.appendingPathComponent("pwned").path
        let evil = "$(touch \(marker)) `touch \(marker)` \"; touch \(marker); echo \" ' ; touch \(marker)"
        let action = AgentAction(name: "echo", command: #"printf '%s|' {title} "{title}" '{title}'"#, targets: [.change], confirm: false)
        let plan = AgentRunner.plan(action, item: change(title: evil), repoPaths: [:], scratch: dir)
        #expect(plan.runnable)
        let run = await AgentExecution(plan: plan).run(store: nil) { _ in }
        #expect(run.status == .succeeded)
        #expect(run.output == "\(evil)|\(evil)|\(evil)|")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func planReportsProblems() throws {
        let dir = try tempDir()
        let item = change()
        let typo = AgentRunner.plan(AgentAction(name: "x", command: "echo {urll}"), item: item, repoPaths: [:], scratch: dir)
        #expect(typo.problems.first?.contains("{urll}") == true)
        let noRepo = AgentRunner.plan(AgentAction(name: "x", command: "echo hi", workingDirectory: "{repoPath}"), item: item, repoPaths: [:], scratch: dir)
        #expect(noRepo.problems.first?.contains("{repoPath}") == true)
        let noPipeline = AgentRunner.plan(AgentAction(name: "x", command: "echo {pipelineId}"), item: item, repoPaths: [:], scratch: dir)
        #expect(!noPipeline.runnable)
        let gone = AgentRunner.plan(AgentAction(name: "x", command: "echo", workingDirectory: dir.appendingPathComponent("missing").path),
                                    item: item, repoPaths: [:], scratch: dir)
        #expect(gone.problems.first?.hasPrefix("Folder not found") == true)
        let ok = AgentRunner.plan(AgentAction(name: "x", command: "pwd", workingDirectory: "{repoPath}"), item: item,
                                  repoPaths: ["acme/payments-api": dir.path], scratch: dir)
        #expect(ok.runnable)
        #expect(ok.workingDirectory.path == dir.path)
    }

    @Test func targetsMatchItemKinds() {
        let action = AgentAction(name: "x", command: "true", targets: [.pipeline, .issue])
        #expect(!action.applies(to: change()))
        #expect(action.applies(to: FeedItem(id: "p", source: "github", kind: "pipeline", title: "ci")))
        #expect(action.applies(to: FeedItem(id: "j", source: "jira", kind: "issue.assigned", title: "t")))
        #expect(AgentTarget.of(FeedItem(id: "c", source: "custom", kind: "pipeline", title: "t")) == .custom)
    }
}

@Suite struct ShellCommandTests {
    @Test func exitCodeAndOutput() async throws {
        let r = try await ShellCommand(command: "echo out; echo err >&2; exit 3").run()
        #expect(r.outcome == .failed)
        #expect(r.exitCode == 3)
        #expect(r.output.contains("out") && r.output.contains("err"))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "out\n")
    }

    @Test func timesOut() async throws {
        let r = try await ShellCommand(command: "sleep 5", timeout: 0.3).run()
        #expect(r.outcome == .timedOut)
    }

    @Test func cancels() async throws {
        let cmd = ShellCommand(command: "sleep 5")
        Task { try? await Task.sleep(nanoseconds: 300_000_000); cmd.cancel() }
        let r = try await cmd.run()
        #expect(r.outcome == .cancelled)
    }

    @Test func everboardTokensAreNotPassedOn() {
        setenv("GITLAB_TOKEN", "should-not-leak", 1)
        defer { unsetenv("GITLAB_TOKEN") }
        let env = ShellCommand.environment(extra: ["EVERBOARD_URL": "u"])
        #expect(env["GITLAB_TOKEN"] == nil)
        #expect(env["EVERBOARD_URL"] == "u")
    }
}

@Suite struct AgentRunStoreTests {
    @Test func roundTripAndHousekeeping() async throws {
        let store = try Store.inMemory()
        let old = Date().addingTimeInterval(-40 * 86400)
        var run = AgentRun(ts: old, actionId: "a", actionName: "Review", itemId: "i", itemTitle: "T", itemRef: "acme/app!1",
                           itemUrl: "https://x", command: "claude -p …", workingDirectory: "/tmp", output: "")
        try await store.saveAgentRun(run)
        let running = AgentRun(actionId: "b", actionName: "Plan", itemId: "j", itemTitle: "U", itemRef: "PAY-1", itemUrl: nil,
                                command: "x", workingDirectory: "/tmp")
        try await store.saveAgentRun(running)
        run.output = "findings"
        run.status = .succeeded
        try await store.saveAgentRun(run)

        let list = try await store.agentRuns()
        #expect(list.map(\.id) == [running.id, run.id])
        #expect(list.allSatisfy { $0.output.isEmpty })            // list leaves output out
        #expect(try await store.agentRun(id: run.id)?.output == "findings")
        #expect(try await store.agentRuns(itemId: "j").count == 1)

        try await store.closeInterruptedAgentRuns()
        #expect(try await store.agentRun(id: running.id)?.status == .cancelled)

        try await store.prune(agentRunDays: 30)
        #expect(try await store.agentRuns().map(\.id) == [running.id])
    }
}
