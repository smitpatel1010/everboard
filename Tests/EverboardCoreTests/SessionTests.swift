import Foundation
import Testing
@testable import EverboardCore
import GRDB

/// Hook payloads in the shapes Claude Code (2.1) and Cursor (3.x) send. If a tool changes its payloads,
/// update these first: they are the contract the adapters are written against.
enum HookFixtures {
    static func claude(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["session_id": "abc-123", "transcript_path": "/tmp/t.jsonl", "cwd": "/work/acme/web-app",
                                "permission_mode": "default", "hook_event_name": event]
        p.merge(extra) { $1 }
        return p
    }

    static func cursor(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["conversation_id": "conv-9", "generation_id": "gen-1", "hook_event_name": event,
                                "workspace_roots": ["/work/acme/design-system"], "cursor_version": "3.31.0"]
        p.merge(extra) { $1 }
        return p
    }
}

@Suite struct SessionHookTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ payloads: [[String: Any]], tool: String = "claude-code") -> AgentSession? {
        var s: AgentSession?
        for (i, p) in payloads.enumerated() {
            s = SessionHooks.apply(p, tool: tool, to: s, context: .init(now: t0.addingTimeInterval(Double(i))))
        }
        return s
    }

    @Test func claudeTurnWithApprovalThenQuestion() throws {
        let f = HookFixtures.self
        var s = try #require(run([
            f.claude("SessionStart", ["source": "startup"]),
            f.claude("UserPromptSubmit", ["prompt": "Fix the flaky\ncheckout test"]),
        ]))
        #expect(s.state == .working)
        #expect(s.title == "Fix the flaky checkout test")
        #expect(s.resumeCommand == "cd /work/acme/web-app && claude --resume abc-123")

        s = try #require(SessionHooks.apply(f.claude("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "git push origin main"]]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(10))))
        #expect(s.activity == "Running `git push origin main`")
        s = try #require(SessionHooks.apply(f.claude("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "git push origin main"]]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(11))))
        #expect(s.state == .needsApproval)
        #expect(s.detail == "Allow running `git push origin main`")

        // A parallel call starting doesn't clear the open prompt; the approved call finishing does.
        s = try #require(SessionHooks.apply(f.claude("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/a/b/Checkout.swift"]]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(12))))
        #expect(s.state == .needsApproval)
        s = try #require(SessionHooks.apply(f.claude("PostToolUse", ["tool_name": "Bash"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(20))))
        #expect(s.state == .working)

        s = try #require(SessionHooks.apply(f.claude("Stop", ["last_assistant_message": "Pushed.\n\n```\nok\n```\n\nShould I open the merge request too?"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(30))))
        #expect(s.state == .needsReply)
        #expect(s.detail == "Should I open the merge request too?")
        #expect(s.activity == nil)
    }

    @Test func claudeStopWithoutQuestionIsDone() throws {
        let s = try #require(run([
            HookFixtures.claude("UserPromptSubmit", ["prompt": "rename it"]),
            HookFixtures.claude("Stop", ["last_assistant_message": "## Done\nRenamed `Foo` to `Bar` in 3 files."]),
        ]))
        #expect(s.state == .done)
        #expect(s.detail == "Done")
        #expect(SessionHooks.summary(of: "I wrote it in [docs/plan.md](docs/plan.md) and **pushed** nothing.")
                == "I wrote it in docs/plan.md and pushed nothing.")
    }

    @Test func claudeAskUserQuestionAndPlanApproval() throws {
        var s = try #require(run([
            HookFixtures.claude("UserPromptSubmit", ["prompt": "plan it"]),
            HookFixtures.claude("PreToolUse", ["tool_name": "AskUserQuestion",
                                               "tool_input": ["questions": [["question": "Which database?", "options": []]]]]),
        ]))
        #expect(s.state == .needsReply)
        #expect(s.detail == "Which database?")
        s = try #require(SessionHooks.apply(HookFixtures.claude("PreToolUse", ["tool_name": "ExitPlanMode", "tool_input": [:]]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(5))))
        #expect(s.state == .needsApproval)
        #expect(s.detail == "Approve the plan")
    }

    @Test func claudeNotificationsAndFailures() throws {
        var s = try #require(run([
            HookFixtures.claude("UserPromptSubmit", ["prompt": "go"]),
            HookFixtures.claude("Notification", ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"]),
        ]))
        #expect(s.state == .needsApproval)
        #expect(s.detail == "Claude needs your permission to use Bash")
        s = try #require(SessionHooks.apply(HookFixtures.claude("StopFailure", ["error": "rate_limit"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(9))))
        #expect(s.state == .error)
        #expect(s.detail == "rate_limit")
        s = try #require(SessionHooks.apply(HookFixtures.claude("SessionEnd", ["reason": "exit"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(10))))
        #expect(s.state == .ended)

        // Idle notification after a finished turn changes nothing; older versions without a type still work.
        let done = try #require(run([HookFixtures.claude("Stop", ["last_assistant_message": "All set."]),
                                     HookFixtures.claude("Notification", ["message": "Claude is waiting for your input"])]))
        #expect(done.state == .done)
        let old = try #require(run([HookFixtures.claude("UserPromptSubmit", ["prompt": "x"]),
                                    HookFixtures.claude("Notification", ["message": "Claude needs your permission to use Edit"])]))
        #expect(old.state == .needsApproval)
    }

    @Test func todoWriteShowsCurrentStep() throws {
        let s = try #require(run([
            HookFixtures.claude("UserPromptSubmit", ["prompt": "x"]),
            HookFixtures.claude("PreToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": [
                ["content": "Write tests", "status": "completed", "activeForm": "Writing tests"],
                ["content": "Fix the parser", "status": "in_progress", "activeForm": "Fixing the parser"],
            ]]]),
        ]))
        #expect(s.activity == "Fixing the parser")
    }

    @Test func cursorTurn() throws {
        let f = HookFixtures.self
        var s = try #require(run([
            f.cursor("beforeSubmitPrompt", ["prompt": "add dark mode tokens"]),
            f.cursor("beforeShellExecution", ["command": "npm run build:tokens", "cwd": "/work/acme/design-system"]),
        ], tool: "cursor"))
        #expect(s.tool == "cursor")
        #expect(s.state == .working)
        #expect(s.activity == "Running `npm run build:tokens`")
        #expect(s.openURL == "cursor://file/work/acme/design-system")
        #expect(s.pendingSince != nil)
        #expect(!SessionRules.mayNeedApproval(s, now: t0.addingTimeInterval(5)))
        #expect(SessionRules.mayNeedApproval(s, now: t0.addingTimeInterval(60)))

        s = try #require(SessionHooks.apply(f.cursor("afterShellExecution", ["command": "npm run build:tokens", "output": "ok"]),
                                            tool: "cursor", to: s, context: .init(now: t0.addingTimeInterval(61))))
        #expect(s.pendingSince == nil)
        #expect(s.activity == "Ran `npm run build:tokens`")
        s = try #require(SessionHooks.apply(f.cursor("afterAgentResponse", ["text": "Added the tokens. Want me to update the docs as well?"]),
                                            tool: "cursor", to: s, context: .init(now: t0.addingTimeInterval(62))))
        s = try #require(SessionHooks.apply(f.cursor("stop", ["status": "completed", "loop_count": 0]),
                                            tool: "cursor", to: s, context: .init(now: t0.addingTimeInterval(63))))
        #expect(s.state == .needsReply)
        #expect(s.detail == "Added the tokens. Want me to update the docs as well?")

        let aborted = try #require(run([f.cursor("beforeSubmitPrompt", ["prompt": "x"]), f.cursor("stop", ["status": "aborted"])], tool: "cursor"))
        #expect(aborted.state == .done)
        let failed = try #require(run([f.cursor("beforeSubmitPrompt", ["prompt": "x"]), f.cursor("stop", ["status": "error"])], tool: "cursor"))
        #expect(failed.state == .error)
    }

    @Test func cursorRunningClaudeCodeHookIsFiledUnderCursor() {
        // Cursor also runs hooks from ~/.claude/settings.json; its payloads still carry conversation_id.
        let p = HookFixtures.cursor("UserPromptSubmit", ["prompt": "hi"])
        #expect(SessionHooks.tool(for: p, declared: "claude-code") == "cursor")
        #expect(SessionHooks.HookEvent("UserPromptSubmit") == .prompt)
        #expect(SessionHooks.HookEvent("preToolUse") == SessionHooks.HookEvent("PreToolUse"))
    }

    @Test func noSessionIdIsIgnored() {
        #expect(SessionHooks.apply(["hook_event_name": "Stop"], tool: "claude-code", to: nil, context: .init()) == nil)
    }

    @Test func describesToolCalls() {
        #expect(SessionHooks.describe(tool: "Bash", input: ["command": "yarn test", "description": "Run unit tests"]) == "Run unit tests")
        #expect(SessionHooks.describe(tool: "Edit", input: ["file_path": "/x/y/Select.swift"]) == "Editing Select.swift")
        #expect(SessionHooks.describe(tool: "Grep", input: ["pattern": "TODO"]) == "Searching for TODO")
        #expect(SessionHooks.describe(tool: "WebFetch", input: ["url": "https://docs.example.com/a"]) == "Reading docs.example.com")
        #expect(SessionHooks.describe(tool: "mcp__tracker__get_issue", input: [:]) == "Using tracker: get issue")
        #expect(SessionHooks.describe(tool: "Frobnicate", input: [:]) == "Using Frobnicate")
    }

    @Test func questionDetection() {
        #expect(SessionHooks.question(in: "Done.\n\nShould I continue?") == "Should I continue?")
        #expect(SessionHooks.question(in: "Done. Let me know if you want the tests updated.") != nil)
        #expect(SessionHooks.question(in: "**Want me to open the MR?**") == "Want me to open the MR?")
        #expect(SessionHooks.question(in: "Why did it fail?\nThe cache was stale.\nFixed it.\nAll tests pass.") == nil)
        #expect(SessionHooks.question(in: "Here:\n```\nwhat?\n```\nDone.") == nil)
        #expect(SessionHooks.question(in: "") == nil)
    }
}

@Suite struct SessionStoreTests {
    func tempDir() -> SessionDirectory {
        SessionDirectory(url: FileManager.default.temporaryDirectory.appendingPathComponent("evb-sessions-\(UUID().uuidString)"))
    }

    @Test func roundTripAndLenientDecoding() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        try dir.update(tool: "claude-code", sessionId: "a/b") { _ in
            var s = AgentSession(tool: "claude-code", sessionId: "a/b", state: .working)
            s.title = "x"
            return s
        }
        let file = dir.fileURL(tool: "claude-code", sessionId: "a/b")
        #expect(file.lastPathComponent == "claude-code-a_b.json")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // Another tool writing a minimal file by hand, with an unknown state and epoch-second dates.
        let manual = #"{"tool":"my-agent","sessionId":"42","state":"thinking","updatedAt":1800000000,"title":"Hand-written"}"#
        try Data(manual.utf8).write(to: dir.url.appendingPathComponent("my-agent-42.json"))
        try Data("not json".utf8).write(to: dir.url.appendingPathComponent("broken.json"))

        let all = dir.loadAll().sorted { $0.tool < $1.tool }
        #expect(all.count == 2)
        #expect(all[0].title == "x")
        #expect(all[1].state == .working)
        #expect(all[1].toolName == "My Agent")
        #expect(all[1].updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func hookRunnerWritesFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.cursor("beforeSubmitPrompt", ["prompt": "hello"]))
        SessionHookRunner.run(input: payload, declaredTool: "claude-code", environment: [:], directory: dir)
        SessionHookRunner.run(input: Data("garbage".utf8), declaredTool: "claude-code", environment: [:], directory: dir)
        let all = dir.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.id == "cursor:conv-9")
        #expect(all.first?.prompt == "hello")
    }

    @Test func transcriptTitle() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [#"{"type":"user","message":{"content":"hi"}}"#,
                     #"{"type":"agent-name","agentName":"Old name","sessionId":"s"}"#,
                     #"{"type":"assistant","message":{"content":"hello"}}"#,
                     #"{"type":"agent-name","agentName":"Checkout flake","sessionId":"s"}"#]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        #expect(SessionHookRunner.transcriptTitle(at: url.path) == "Checkout flake")
        #expect(SessionHookRunner.transcriptTitle(at: "/nonexistent") == nil)
    }

    @Test func prune() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let now = Date()
        var ended = AgentSession(tool: "x", sessionId: "1", state: .ended, now: now.addingTimeInterval(-2 * 86400))
        ended.updatedAt = now.addingTimeInterval(-2 * 86400)
        try dir.write(ended)
        try dir.write(AgentSession(tool: "x", sessionId: "2", state: .done, now: now))
        #expect(dir.prune(now: now) == 1)
        #expect(dir.loadAll().map(\.sessionId) == ["2"])
    }
}

@Suite struct SessionRuleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ state: AgentSession.State, id: String = "s", since: TimeInterval = 0) -> AgentSession {
        var s = AgentSession(tool: "claude-code", sessionId: id, state: state, now: now.addingTimeInterval(-since))
        s.title = "Checkout flake"
        s.detail = "Should I push?"
        return s
    }

    @Test func eventsOnTransitions() {
        let working = session(.working)
        var waiting = working
        waiting.set(.needsReply, at: now.addingTimeInterval(5))
        let events = SessionRules.events(old: [working.id: working], new: [waiting], now: now)
        #expect(events.count == 1)
        #expect(events[0].category == .sessionNeedsReply)
        #expect(events[0].title == "Claude Code is waiting for you")
        #expect(events[0].body == "Checkout flake\nShould I push?")
        #expect(events[0].itemId == "session:claude-code:s")
        // Same state again: nothing. Deterministic id per change.
        #expect(SessionRules.events(old: [waiting.id: waiting], new: [waiting], now: now).isEmpty)
        #expect(events[0].id == SessionRules.event(for: waiting)?.id)
    }

    @Test func doneOnlyAfterWorkingAndNewSessionsOnlyWhenRecent() {
        let idle = session(.idle)
        var done = idle
        done.set(.done, at: now)
        #expect(SessionRules.events(old: [idle.id: idle], new: [done], now: now).isEmpty)
        #expect(SessionRules.events(old: [:], new: [session(.needsApproval, since: 30)], now: now).count == 1)
        #expect(SessionRules.events(old: [:], new: [session(.needsApproval, since: 3600)], now: now).isEmpty)
        #expect(SessionRules.events(old: [:], new: [session(.working)], now: now).isEmpty)
    }

    @Test func deadProcess() {
        var working = session(.working)
        working.pid = 999_999
        #expect(SessionRules.refresh(working, now: now, isAlive: { _ in false }).state == .ended)
        #expect(SessionRules.refresh(working, now: now, isAlive: { _ in true }).state == .working)
        var waiting = session(.needsReply)
        waiting.pid = 999_999
        #expect(SessionRules.refresh(waiting, now: now, isAlive: { _ in false }).state == .needsReply)
        #expect(SessionRules.refresh(waiting, now: now.addingTimeInterval(13 * 3600), isAlive: { _ in false }).state == .ended)
    }

    @Test func sortsNeedsYouFirst() {
        let list = SessionRules.sorted([session(.done, id: "a"), session(.working, id: "b"), session(.needsApproval, id: "c")])
        #expect(list.map(\.sessionId) == ["c", "b", "a"])
    }
}

@Suite struct HookInstallerTests {
    let bin = "/opt/everboard/bin/everboard-hook"

    @Test func claudeInstallKeepsOtherHooksAndIsIdempotent() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/opt/guard.sh"]]]]],
        ]
        #expect(HookInstaller.status(of: existing, target: .claudeCode, binary: bin) == .notInstalled)
        let once = HookInstaller.installing(into: existing, target: .claudeCode, binary: bin)
        let twice = HookInstaller.installing(into: once, target: .claudeCode, binary: bin)
        #expect(HookInstaller.status(of: twice, target: .claudeCode, binary: bin) == .installed)
        #expect(twice["model"] as? String == "opus")
        let pre = try #require((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] as? String == "Bash")
        #expect(((pre[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "\(bin) claude-code")

        // Moving the binary makes it outdated; reinstalling replaces, not duplicates.
        #expect(HookInstaller.status(of: twice, target: .claudeCode, binary: "/elsewhere/everboard-hook") == .outdated)

        let removed = HookInstaller.removing(from: twice, target: .claudeCode)
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(hooks.keys.sorted() == ["PreToolUse"])
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
    }

    @Test func claudeGroupSharedWithAnotherHookKeepsTheOther() throws {
        let shared: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/opt/notify.sh"],
                                                                     ["type": "command", "command": "\(bin) claude-code"]]]]]]
        let removed = HookInstaller.removing(from: shared, target: .claudeCode)
        let stop = try #require((removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect((stop[0]["hooks"] as? [[String: Any]])?.map { $0["command"] as? String } == ["/opt/notify.sh"])
    }

    @Test func cursorInstall() throws {
        let existing: [String: Any] = ["version": 1, "hooks": ["beforeShellExecution": [["command": "/opt/other-hook"]]]]
        let installed = HookInstaller.installing(into: existing, target: .cursor, binary: bin)
        #expect(HookInstaller.status(of: installed, target: .cursor, binary: bin) == .installed)
        let shell = try #require((installed["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]])
        #expect(shell.map { $0["command"] as? String } == ["/opt/other-hook", "\(bin) cursor"])
        let fresh = HookInstaller.installing(into: [:], target: .cursor, binary: bin)
        #expect(fresh["version"] as? Int == 1)
    }

    @Test func filesBackupAndRejectInvalidJSON() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("evb-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)

        try HookInstaller.install(target: .claudeCode, binary: bin, environment: [:], home: home.path)
        #expect(HookInstaller.status(target: .claudeCode, binary: bin, environment: [:], home: home.path) == .installed)
        let backup = try String(contentsOf: settings.appendingPathExtension("before-everboard"), encoding: .utf8)
        #expect(backup == #"{"theme":"dark"}"#)
        try HookInstaller.uninstall(target: .claudeCode, environment: [:], home: home.path)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        #expect(after?["theme"] as? String == "dark")
        #expect(HookInstaller.status(target: .claudeCode, binary: bin, environment: [:], home: home.path) == .notInstalled)

        try Data("{ broken".utf8).write(to: settings)
        #expect(throws: HookInstaller.InstallError.self) {
            try HookInstaller.install(target: .claudeCode, binary: bin, environment: [:], home: home.path)
        }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ broken")
    }

    @Test func paths() {
        #expect(SessionPaths.directory(environment: [:], home: "/h").path == "/h/.local/state/everboard/sessions")
        #expect(SessionPaths.directory(environment: ["XDG_STATE_HOME": "/s"], home: "/h").path == "/s/everboard/sessions")
        #expect(SessionPaths.directory(environment: ["EVERBOARD_SESSIONS_DIR": "/x"], home: "/h").path == "/x")
        #expect(SessionPaths.hookBinary(environment: [:], home: "/h").path == "/h/.local/share/everboard/bin/everboard-hook")
        #expect(HookInstaller.Target.claudeCode.settingsURL(environment: ["CLAUDE_CONFIG_DIR": "/c"], home: "/h").path == "/c/settings.json")
    }
}

@Suite struct SessionAnsweringTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func tempDir() -> SessionDirectory {
        SessionDirectory(url: FileManager.default.temporaryDirectory.appendingPathComponent("evb-ans-\(UUID().uuidString)"))
    }

    @Test func approvalIsRecordedAndClearedWhenAnswered() throws {
        var s = try #require(SessionHooks.apply(
            HookFixtures.claude("PermissionRequest", ["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "git push"]]),
            tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(s.state == .needsApproval)
        #expect(s.approval?.id == "toolu_1")
        #expect(s.approval?.summary == "Allow running `git push`")
        s = try #require(SessionHooks.apply(HookFixtures.claude("PostToolUse", ["tool_name": "Bash"]), tool: "claude-code", to: s,
                                            context: .init(now: t0.addingTimeInterval(1))))
        #expect(s.approval == nil)
    }

    @Test func questionKind() throws {
        let typed = try #require(SessionHooks.apply(HookFixtures.claude("Stop", ["last_assistant_message": "Ship it?"]),
                                                    tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(typed.questionIsChoice == false)
        let choice = try #require(SessionHooks.apply(HookFixtures.claude("PreToolUse", ["tool_name": "AskUserQuestion",
                                                                                         "tool_input": ["question": "A or B?"]]),
                                                     tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(choice.questionIsChoice == true)
        let resumed = try #require(SessionHooks.apply(HookFixtures.claude("UserPromptSubmit", ["prompt": "A"]),
                                                      tool: "claude-code", to: choice, context: .init(now: t0)))
        #expect(resumed.questionIsChoice == nil)
    }

    @Test func desktopDeepLinkOnlyForItsOwnSession() throws {
        let dir = tempDir()
        let records = FileManager.default.temporaryDirectory.appendingPathComponent("evb-desk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir.url); try? FileManager.default.removeItem(at: records) }
        let org = records.appendingPathComponent("acct/org")
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_1f2e","cliSessionId":"abc-123","title":"Checkout flake"}"#.utf8)
            .write(to: org.appendingPathComponent("local_1f2e.json"))
        let env = ["CLAUDE_CODE_HOST_SESSION_ID": "local_1f2e", "EVERBOARD_CLAUDE_DESKTOP_DIR": records.path]

        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.claude("UserPromptSubmit", ["prompt": "hi"]))
        SessionHookRunner.run(input: payload, declaredTool: "claude-code", environment: env, directory: dir)
        #expect(dir.loadAll().first?.openURL == "claude://code/continue?session=local_1f2e")

        // A run started from inside that desktop session inherits its id, but the record names another session.
        let child = try JSONSerialization.data(withJSONObject: HookFixtures.claude("UserPromptSubmit", ["session_id": "child-9", "prompt": "x"]))
        SessionHookRunner.run(input: child, declaredTool: "claude-code", environment: env, directory: dir)
        #expect(dir.loadAll().first { $0.sessionId == "child-9" }?.openURL == nil)

        // Looking up from the Claude Code id, as a click on an older session does.
        #expect(ClaudeDesktopSessions.hostSessionId(forCLISession: "abc-123", in: records) == "local_1f2e")
        #expect(ClaudeDesktopSessions.hostSessionId(forCLISession: "child-9", in: records) == nil)
        #expect(ClaudeDesktopSessions.confirms(hostId: "local_9999", runs: "abc-123", in: records) == nil)

        // Ids that aren't the desktop app's format are ignored.
        var s = AgentSession(tool: "claude-code", sessionId: "q")
        s.hostSessionId = "local_x\" onclick"
        SessionHooks.fillOpeners(&s)
        #expect(s.openURL == nil)
    }

    @Test func holdOnlyWhenAppIsRunningAndYouAreElsewhere() {
        let status = SessionApprovals.AppStatus(pid: 42, updatedAt: t0, frontmostApp: "com.example.browser",
                                                holdApprovals: true, holdSeconds: 60)
        let alive: (Int32) -> Bool = { _ in true }
        #expect(SessionApprovals.holdDuration(status: status, hostApp: "com.example.terminal", now: t0, isAlive: alive) == 60)
        var front = status
        front.frontmostApp = "com.example.terminal"
        #expect(SessionApprovals.holdDuration(status: front, hostApp: "com.example.terminal", now: t0, isAlive: alive) == nil)
        // Claude's desktop app shows its own prompt alongside the hook, so it's held even while in front.
        front.frontmostApp = "com.anthropic.claudefordesktop"
        #expect(SessionApprovals.holdDuration(status: front, hostApp: "com.anthropic.claudefordesktop", now: t0, isAlive: alive) == 60)
        var off = status
        off.holdApprovals = false
        #expect(SessionApprovals.holdDuration(status: off, hostApp: nil, now: t0, isAlive: alive) == nil)
        #expect(SessionApprovals.holdDuration(status: status, hostApp: nil, now: t0.addingTimeInterval(60), isAlive: alive) == nil)
        #expect(SessionApprovals.holdDuration(status: status, hostApp: nil, now: t0, isAlive: { _ in false }) == nil)
        #expect(SessionApprovals.holdDuration(status: nil, hostApp: nil, now: t0, isAlive: alive) == nil)
    }

    @Test func hookOutputShape() throws {
        let allow = try #require(JSONSerialization.jsonObject(with: Data(SessionApprovals.hookOutput(for: .init(behavior: .allow)).utf8)) as? [String: Any])
        let out = try #require(allow["hookSpecificOutput"] as? [String: Any])
        #expect(out["hookEventName"] as? String == "PermissionRequest")
        #expect((out["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = SessionApprovals.hookOutput(for: .init(behavior: .deny))
        #expect(deny.contains(#""behavior":"deny""#) && deny.contains("Denied from Everboard."))
    }

    @Test func runnerHoldsAndUsesTheAnswer() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        let me = ProcessInfo.processInfo.processIdentifier
        try SessionApprovals.writeStatus(.init(pid: me, updatedAt: Date(), frontmostApp: "com.example.browser",
                                               holdApprovals: true, holdSeconds: 5), in: dir.url)
        // The answer is already waiting, as if you clicked Allow the moment the prompt appeared.
        let pending = AgentSession(tool: "claude-code", sessionId: "abc-123")
        try SessionApprovals.writeAnswer(.init(behavior: .allow), for: pending, approvalId: "toolu_7", in: dir.url)
        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.claude("PermissionRequest", [
            "tool_name": "Bash", "tool_use_id": "toolu_7", "tool_input": ["command": "make test"]]))
        let started = Date()
        let output = SessionHookRunner.run(input: payload, declaredTool: "claude-code",
                                           environment: ["__CFBundleIdentifier": "com.example.terminal"], directory: dir)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(output?.contains(#""behavior":"allow""#) == true)
        let s = try #require(dir.loadAll().first)
        #expect(s.state == .working)
        #expect(s.approval == nil)
        #expect(s.activity == "Allowed from Everboard: running `make test`")

        // Looking at the agent's own app: no hold, no output.
        try SessionApprovals.writeStatus(.init(pid: me, updatedAt: Date(), frontmostApp: "com.example.terminal",
                                               holdApprovals: true, holdSeconds: 5), in: dir.url)
        let again = SessionHookRunner.run(input: payload, declaredTool: "claude-code",
                                          environment: ["__CFBundleIdentifier": "com.example.terminal"], directory: dir)
        #expect(again == nil)
        #expect(dir.loadAll().first?.approval?.holdUntil == nil)
        #expect(dir.loadAll().count == 1)   // the status file isn't a session
    }

    @Test func runnerHandsBackWhenNobodyAnswers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        try SessionApprovals.writeStatus(.init(pid: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(),
                                               frontmostApp: nil, holdApprovals: true, holdSeconds: 0.6), in: dir.url)
        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.claude("PermissionRequest", [
            "tool_name": "Bash", "tool_use_id": "toolu_8", "tool_input": ["command": "rm -rf build"]]))
        #expect(SessionHookRunner.run(input: payload, declaredTool: "claude-code", environment: [:], directory: dir) == nil)
        let s = try #require(dir.loadAll().first)
        #expect(s.state == .needsApproval)
        #expect(s.approval?.id == "toolu_8")
        #expect(s.approval?.holdUntil == nil)
    }

    static let askInput: [String: Any] = ["questions": [
        ["question": "Which snack?", "header": "Snack", "multiSelect": false,
         "options": [["label": "Chai", "description": "Hot"], ["label": "Mango", "description": ""]]],
        ["question": "Which toppings?", "header": "Toppings", "multiSelect": true,
         "options": [["label": "Salt"], ["label": "Chilli"]]],
    ]]

    @Test func questionsArriveAsQuestionsWithOptions() throws {
        let s = try #require(SessionHooks.apply(
            HookFixtures.claude("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_q", "tool_input": Self.askInput]),
            tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(s.state == .needsReply)
        #expect(s.detail == "Which snack?")
        let a = try #require(s.approval)
        #expect(a.isQuestion)
        #expect(a.questions?.map(\.question) == ["Which snack?", "Which toppings?"])
        #expect(a.questions?.first?.options.map(\.label) == ["Chai", "Mango"])
        #expect(a.questions?.first?.options.last?.description == nil)
        #expect(a.questions?.last?.multiSelect == true)
    }

    @Test func answersGoBackInTheToolsOwnFormat() throws {
        let s = try #require(SessionHooks.apply(
            HookFixtures.claude("PreToolUse", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_q", "tool_input": Self.askInput]),
            tool: "claude-code", to: nil, context: .init(now: t0)))
        let answer = SessionApprovals.Answer(behavior: .allow, answers: ["Which snack?": ["Chai"], "Which toppings?": ["Salt", "Chilli"]])
        let out = try #require(JSONSerialization.jsonObject(with: Data(SessionApprovals.hookOutput(for: answer, approval: s.approval).utf8)) as? [String: Any])
        let decision = try #require((out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let input = try #require(decision["updatedInput"] as? [String: Any])
        #expect((input["questions"] as? [Any])?.count == 2)          // the shown input goes back unchanged
        let answers = try #require(input["answers"] as? [String: Any])
        #expect(answers["Which snack?"] as? String == "Chai")
        #expect(answers["Which toppings?"] as? [String] == ["Salt", "Chilli"])
        // Skip declines without answers.
        let skip = SessionApprovals.hookOutput(for: .init(behavior: .deny, message: "Skipped"), approval: s.approval)
        #expect(skip.contains(#""behavior":"deny""#) && !skip.contains("updatedInput"))
    }

    @Test func runnerHoldsAQuestionAndSendsThePick() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        try SessionApprovals.writeStatus(.init(pid: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(),
                                               frontmostApp: "com.example.browser", holdApprovals: true, holdSeconds: 5), in: dir.url)
        try SessionApprovals.writeAnswer(.init(behavior: .allow, answers: ["Which snack?": ["Mango"], "Which toppings?": ["Salt"]]),
                                         for: AgentSession(tool: "claude-code", sessionId: "abc-123"), approvalId: "toolu_q", in: dir.url)
        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.claude("PermissionRequest", [
            "tool_name": "AskUserQuestion", "tool_use_id": "toolu_q", "tool_input": Self.askInput]))
        let output = try #require(SessionHookRunner.run(input: payload, declaredTool: "claude-code", environment: [:], directory: dir))
        #expect(output.contains(#""Which snack?":"Mango""#))
        let s = try #require(dir.loadAll().first)
        #expect(s.state == .working)
        #expect(s.activity?.hasPrefix("Answered from Everboard: ") == true)
    }

    @Test func permissionNotificationDoesNotTurnAQuestionIntoAnApproval() throws {
        var s = try #require(SessionHooks.apply(
            HookFixtures.claude("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_q", "tool_input": Self.askInput]),
            tool: "claude-code", to: nil, context: .init(now: t0)))
        s = try #require(SessionHooks.apply(HookFixtures.claude("Notification", [
            "message": "Claude needs your permission to use AskUserQuestion", "notification_type": "permission_prompt"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(1))))
        #expect(s.state == .needsReply)
        #expect(s.detail == "Which snack?")
        #expect(s.approval?.isQuestion == true)
        // Even when the notification comes first.
        let early = try #require(SessionHooks.apply(HookFixtures.claude("Notification", [
            "message": "Claude needs your permission to use AskUserQuestion", "notification_type": "permission_prompt"]),
                                                    tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(early.state == .needsReply)
        #expect(early.detail == "Answer a question")
    }

    @Test func sessionNameIsKeptApartFromPromptText() throws {
        let s = try #require(SessionHooks.apply(HookFixtures.claude("UserPromptSubmit", ["prompt": "secret plan"]),
                                                tool: "claude-code", to: nil, context: .init(now: t0, transcriptTitle: "Checkout flake")))
        #expect(s.name == "Checkout flake")
        let unnamed = try #require(SessionHooks.apply(HookFixtures.claude("UserPromptSubmit", ["prompt": "secret plan"]),
                                                      tool: "claude-code", to: nil, context: .init(now: t0)))
        #expect(unnamed.name == nil)
        #expect(unnamed.title == "secret plan")
    }

    @Test func apiErrorsClearOnceTheSessionMovesOn() throws {
        // Recorded by an older hook, without a kind.
        var s = AgentSession(tool: "claude-code", sessionId: "abc-123", state: .working, now: t0)
        s.notice = .init(id: "old", level: .error, text: "API error: Can't reach the API server", at: t0)
        let old = s.notice
        s = try #require(SessionHooks.apply(HookFixtures.claude("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/a/b.swift"]]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(60))))
        #expect(s.notice == nil)
        s = try #require(SessionHooks.apply(HookFixtures.claude("PostToolUse", ["tool_name": "Read"]), tool: "claude-code", to: s,
                                            context: .init(now: t0.addingTimeInterval(61), notice: old)))
        #expect(s.notice == nil)
    }

    @Test func apiErrorsClearWhenTheTurnEndsNormally() throws {
        let err = AgentSession.Notice(id: "n1", level: .error, text: "API error: Connection dropped", at: t0, kind: .api)
        var s = try #require(SessionHooks.apply(HookFixtures.claude("PostToolUse", ["tool_name": "Bash"]), tool: "claude-code", to: nil,
                                                context: .init(now: t0.addingTimeInterval(1), notice: err)))
        #expect(s.notice?.id == "n1")
        s = try #require(SessionHooks.apply(HookFixtures.claude("Stop", ["last_assistant_message": "All done."]), tool: "claude-code", to: s,
                                            context: .init(now: t0.addingTimeInterval(5), notice: err)))
        #expect(s.notice == nil)
        // The same entry is still at the end of the transcript; it doesn't come back.
        s = try #require(SessionHooks.apply(HookFixtures.claude("UserPromptSubmit", ["prompt": "next"]), tool: "claude-code", to: s,
                                            context: .init(now: t0.addingTimeInterval(9), notice: err)))
        #expect(s.notice == nil)
        // A failed hook stays: it's a setup problem to look at.
        let hook = AgentSession.Notice(id: "n2", level: .error, text: "Hook failed", at: t0.addingTimeInterval(10), kind: .hook)
        s = try #require(SessionHooks.apply(HookFixtures.claude("Stop", ["last_assistant_message": "Done."]), tool: "claude-code", to: s,
                                            context: .init(now: t0.addingTimeInterval(11), notice: hook)))
        #expect(s.notice?.id == "n2")
    }

    @Test func lateNotificationAfterAnAnsweredPromptIsIgnored() throws {
        var s = try #require(SessionHooks.apply(
            HookFixtures.claude("PermissionRequest", ["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "rm x"]]),
            tool: "claude-code", to: nil, context: .init(now: t0)))
        s = try #require(SessionHooks.apply(HookFixtures.claude("PermissionDenied", ["tool_name": "Bash", "tool_use_id": "toolu_1"]),
                                            tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(2))))
        #expect(s.state == .working)
        #expect(s.approvalResolvedAt != nil)
        let late = HookFixtures.claude("Notification", ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"])
        s = try #require(SessionHooks.apply(late, tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(8))))
        #expect(s.state == .working)
        // Much later, a permission notification is a new prompt again.
        s = try #require(SessionHooks.apply(late, tool: "claude-code", to: s, context: .init(now: t0.addingTimeInterval(300))))
        #expect(s.state == .needsApproval)
    }

    @Test func plansAreNeverHeld() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.url) }
        try SessionApprovals.writeStatus(.init(pid: ProcessInfo.processInfo.processIdentifier, updatedAt: Date(),
                                               frontmostApp: nil, holdApprovals: true, holdSeconds: 5), in: dir.url)
        let payload = try JSONSerialization.data(withJSONObject: HookFixtures.claude("PermissionRequest", [
            "tool_name": "ExitPlanMode", "tool_use_id": "toolu_p", "tool_input": ["plan": "1. do it"]]))
        let started = Date()
        #expect(SessionHookRunner.run(input: payload, declaredTool: "claude-code", environment: [:], directory: dir) == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(dir.loadAll().first?.approval?.holdUntil == nil)
    }

    @Test func installerGivesThePermissionHookTimeToWait() throws {
        let bin = "/opt/everboard-hook"
        let installed = HookInstaller.installing(into: [:], target: .claudeCode, binary: bin)
        let perm = try #require((installed["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        #expect(((perm[0]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) == 620)
        // An install from before this timeout existed shows as needing an update.
        var old = installed
        var hooks = old["hooks"] as! [String: Any]
        hooks["PermissionRequest"] = [["hooks": [["type": "command", "command": "\(bin) claude-code", "timeout": 10]]]]
        old["hooks"] = hooks
        #expect(HookInstaller.status(of: old, target: .claudeCode, binary: bin) == .outdated)
    }
}

@Suite struct SessionNoticeTests {
    @Test func readsNoticesFromTranscriptLines() throws {
        let lines = [
            #"{"type":"assistant","message":{"content":"hi"}}"#,
            #"{"type":"system","subtype":"informational","content":"Compacted while you were away","level":"notice","timestamp":"2026-11-21T09:00:00Z","uuid":"u1"}"#,
            #"{"attachment":{"type":"hook_non_blocking_error","hookName":"PreToolUse:Bash","hookEvent":"PreToolUse","stderr":"Failed with non-blocking status code: sh: guard.sh: No such file or directory\nmore"},"timestamp":"2026-11-21T09:01:00Z","uuid":"u2"}"#,
            #"{"type":"assistant","message":{"content":"done"}}"#,
        ].joined(separator: "\n")
        let n = try #require(SessionNotices.latest(inLines: lines))
        #expect(n.id == "u2")
        #expect(n.level == .error)
        #expect(n.text == "Hook PreToolUse:Bash failed, so it didn't run: Failed with non-blocking status code: sh: guard.sh: No such file or directory")

        let api = #"{"type":"system","subtype":"api_error","level":"error","error":{"message":"Connection error.","formatted":"Connection dropped (ECONNRESET)"},"timestamp":"2026-11-21T09:02:00Z","uuid":"u3"}"#
        #expect(SessionNotices.latest(inLines: api)?.text == "API error: Connection dropped (ECONNRESET)")
        let info = try #require(SessionNotices.latest(inLines: lines.components(separatedBy: "\n").prefix(2).joined(separator: "\n")))
        #expect(info.level == .info)
        #expect(SessionNotices.latest(inLines: #"{"type":"user"}"#) == nil)
    }

    @Test func errorNoticesNotifyOnceInfoNever() {
        let now = Date()
        var s = AgentSession(tool: "claude-code", sessionId: "s", state: .working, now: now)
        s.title = "Checkout flake"
        let before = s
        s.notice = .init(id: "u2", level: .error, text: "Hook PreToolUse:Bash failed, so it didn't run", at: now)
        let events = SessionRules.events(old: [before.id: before], new: [s], now: now)
        #expect(events.map(\.category) == [.sessionNotice])
        #expect(events.first?.body == "Checkout flake\nHook PreToolUse:Bash failed, so it didn't run")
        #expect(SessionRules.events(old: [s.id: s], new: [s], now: now).isEmpty)
        var info = before
        info.notice = .init(id: "u1", level: .info, text: "Compacted", at: now)
        #expect(SessionRules.events(old: [before.id: before], new: [info], now: now).isEmpty)
        var old = before
        old.notice = .init(id: "u0", level: .error, text: "old", at: now.addingTimeInterval(-3600))
        #expect(SessionRules.events(old: [:], new: [old], now: now).isEmpty)
    }
}

@Suite struct SessionSafetyTests {
    @Test func onlyOpensAgentAndEditorLinks() {
        var s = AgentSession(tool: "other", sessionId: "s1")
        for ok in ["claude://code/continue?session=local_1", "cursor://anysphere.cursor-deeplink/agent?id=1", "vscode://file/tmp/x", "https://example.com/run/1"] {
            s.openURL = ok
            #expect(s.safeOpenURL != nil, "\(ok)")
        }
        for bad in ["file:///Applications/Calculator.app", "smb://files.example.com/share", "x-apple.systempreferences:com.apple.preference.security", "/tmp/x", "not a url", ""] {
            s.openURL = bad
            #expect(s.safeOpenURL == nil, "\(bad)")
        }
    }

    @Test func hookCommandQuotesTheBinaryPath() {
        #expect(HookInstaller.command(binary: "/opt/eb/everboard-hook", target: .cursor) == "/opt/eb/everboard-hook cursor")
        #expect(HookInstaller.command(binary: "/Volumes/My Disk/everboard-hook", target: .cursor) == "'/Volumes/My Disk/everboard-hook' cursor")
        #expect(HookInstaller.command(binary: "/tmp/$(id)/it's/everboard-hook", target: .claudeCode)
                == #"'/tmp/$(id)/it'\''s/everboard-hook' claude-code"#)
    }
}

@Suite struct CursorRecordTests {
    @Test func chatLinkOnlyForPlainIds() {
        #expect(CursorChats.chatLink(chatId: "1f0c2b6e-0000-4000-8000-000000000abc") == "cursor://anysphere.cursor-deeplink/agent?id=1f0c2b6e-0000-4000-8000-000000000abc")
        #expect(CursorChats.chatLink(chatId: "a&b=c") == nil)
        #expect(CursorChats.chatLink(chatId: "") == nil)
    }

    @Test func detectsChatLinkSupportFromTheAppsLinkHandler() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let dist = app.appendingPathComponent("Contents/Resources/app/extensions/cursor-deeplink/dist")
        #expect(!CursorChats.supportsChatLinks(app: app))
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try Data(#"handleUri(n){"/createchat"===n.path?a(n):"/settings"===n.path?b(n):0}"#.utf8).write(to: dist.appendingPathComponent("main.js"))
        #expect(!CursorChats.supportsChatLinks(app: app))
        try Data(#"handleUri(n){"/background-agent"===n.path||"/agent"===n.path?a(n):0}"#.utf8).write(to: dist.appendingPathComponent("main.js"))
        #expect(CursorChats.supportsChatLinks(app: app))
    }

    @Test func readsNameAndPendingQuestion() {
        let chat = #"{"composerId":"c1","name":"Question and answer session","status":"completed"}"#
        let pending = #"{"bubbleId":"b2","createdAt":"2026-11-21T08:20:04.429Z","toolFormerData":{"name":"ask_question","toolCallId":"call-1","additionalData":{"status":"pending"},"params":"{\"title\":\"Quick check-in\",\"questions\":[{\"id\":\"focus\",\"prompt\":\"What should we focus on?\",\"options\":[{\"id\":\"a\",\"label\":\"Docs layout\"},{\"id\":\"b\",\"label\":\"Design system\"}]}]}"}}"#
        let answered = #"{"bubbleId":"b1","toolFormerData":{"name":"ask_question","additionalData":{"status":"submitted"},"params":"{\"questions\":[{\"prompt\":\"Old?\",\"options\":[{\"label\":\"x\"}]}]}"}}"#
        let shell = #"{"bubbleId":"b3","toolFormerData":{"name":"run_terminal_cmd","additionalData":{"status":"pending"}}}"#
        let info = CursorChats.parse(chat: chat, toolCalls: [answered, pending, shell])
        #expect(info.name == "Question and answer session")
        #expect(info.pendingQuestion?.id == "call-1")
        #expect(info.pendingQuestion?.title == "Quick check-in")
        #expect(info.pendingQuestion?.questions.first?.question == "What should we focus on?")
        #expect(info.pendingQuestion?.questions.first?.options.map(\.label) == ["Docs layout", "Design system"])
        #expect(CursorChats.parse(chat: nil, toolCalls: [answered]).pendingQuestion == nil)
        #expect(CursorChats.parse(chat: "not json", toolCalls: ["{"]) == CursorChats.Info())
    }

    @Test func findsTheWindowAChatBelongsTo() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("evb-cursor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let code = root.appendingPathComponent("code")
        for repo in ["web-app", "design-system"] { try fm.createDirectory(at: code.appendingPathComponent(repo), withIntermediateDirectories: true) }
        let wsFile = root.appendingPathComponent("workspaces/acme.code-workspace")
        try fm.createDirectory(at: wsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          // two repos
          "folders": [ { "path": "../code/web-app" }, { "path": "../code/design-system" }, ],
        }
        """.utf8).write(to: wsFile)
        #expect(CursorWorkspaces.folders(inWorkspaceFile: wsFile).map { URL(fileURLWithPath: $0).lastPathComponent } == ["web-app", "design-system"])

        let storage = root.appendingPathComponent("workspaceStorage")
        let multi = storage.appendingPathComponent("aaa")
        let single = storage.appendingPathComponent("bbb")
        for d in [multi, single] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(#"{"workspace":"\#(wsFile.absoluteString)"}"#.utf8).write(to: multi.appendingPathComponent("workspace.json"))
        try Data(#"{"folder":"\#(code.appendingPathComponent("web-app").absoluteString)"}"#.utf8).write(to: single.appendingPathComponent("workspace.json"))
        for (dir, chats) in [(multi, #"{"allComposers":[{"composerId":"chat-1"}]}"#), (single, #"{"allComposers":[{"composerId":"chat-2"}]}"#)] {
            let db = try DatabaseQueue(path: dir.appendingPathComponent("state.vscdb").path)
            try db.write { db in
                try db.execute(sql: "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
                try db.execute(sql: "INSERT INTO ItemTable VALUES ('composer.composerData', ?)", arguments: [chats])
            }
        }
        #expect(CursorWorkspaces.workspace(forChat: "chat-1", storage: storage)?.lastPathComponent == "acme.code-workspace")
        #expect(CursorWorkspaces.workspace(forChat: "chat-2", storage: storage)?.lastPathComponent == "web-app")
        #expect(CursorWorkspaces.workspace(forChat: "chat-9", storage: storage) == nil)
        // From the folders alone: both repos → the workspace file; one repo alone isn't enough to pick it.
        let roots = [code.appendingPathComponent("web-app").path, code.appendingPathComponent("design-system").path]
        #expect(CursorWorkspaces.workspaceFile(forRoots: roots, storage: storage)?.lastPathComponent == "acme.code-workspace")
        #expect(CursorWorkspaces.workspaceFile(forRoots: [roots[0]], storage: storage) == nil)
    }
}
