import Foundation

/// An agent action resolved against one item: what will run, where, and whether it can.
public struct AgentPlan: Sendable, Identifiable {
    public var id: String { "\(action.id)|\(item.id)" }
    public var action: AgentAction
    public var item: FeedItem
    public var values: [String: String]
    /// What's executed: placeholders replaced by quoted `$EVERBOARD_…` references.
    public var shellCommand: String
    /// What's shown to the user: placeholders replaced by the values.
    public var preview: String
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Problems that stop the run (unknown or unfillable placeholders, missing folder).
    public var problems: [String]

    public var runnable: Bool { problems.isEmpty }

    /// Short reference for history rows and note names.
    public var itemRef: String { values["ref"] ?? values["jiraKey"] ?? item.title }
}

public enum AgentRunner {
    /// Scratch folder for actions without a working directory, so a CLI agent doesn't pick up some random project.
    public static var scratchDirectory: URL {
        let dir = AppInfo.cacheDirectory.appendingPathComponent("agent-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func plan(_ action: AgentAction, item: FeedItem, repoPaths: [String: String], now: Date = Date(),
                            scratch: URL? = nil) -> AgentPlan {
        let values = AgentTemplate.values(for: item, repoPaths: repoPaths, now: now)
        var problems: [String] = []
        let unknown = AgentTemplate.unknown(in: action.command)
        if !unknown.isEmpty { problems.append("Unknown placeholder\(unknown.count > 1 ? "s" : "") " + unknown.map { "{\($0)}" }.joined(separator: ", ")) }
        let missing = AgentTemplate.missing(action.command + " " + action.workingDirectory, values: values)
        if !missing.isEmpty {
            problems.append("This item has no " + missing.map { "{\($0)}" }.joined(separator: ", ")
                            + (missing.contains("repoPath") ? " (map the project to a local folder in Settings → Agents)" : ""))
        }
        if action.command.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("The command is empty") }
        var dir = scratch ?? scratchDirectory
        if let wd = AgentTemplate.workingDirectory(action, values: values) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: wd, isDirectory: &isDir), isDir.boolValue {
                dir = URL(fileURLWithPath: wd, isDirectory: true)
            } else if missing.isEmpty {
                problems.append("Folder not found: \(wd)")
            }
        }
        return AgentPlan(action: action, item: item, values: values, shellCommand: AgentTemplate.shellCommand(action.command),
                         preview: AgentTemplate.preview(action.command, values: values),
                         environment: AgentTemplate.environment(values), workingDirectory: dir, problems: problems)
    }
}

#if os(macOS)
/// One running agent action. Persists itself to the store when it starts and when it ends.
public final class AgentExecution: @unchecked Sendable {
    public let plan: AgentPlan
    public let id: String
    private let shell: ShellCommand

    public init(plan: AgentPlan) {
        self.plan = plan
        id = UUID().uuidString
        shell = ShellCommand(command: plan.shellCommand, workingDirectory: plan.workingDirectory, environment: plan.environment,
                             timeout: max(plan.action.timeoutMinutes, 0.1) * 60)
    }

    public var initialRecord: AgentRun {
        AgentRun(id: id, actionId: plan.action.id, actionName: plan.action.name, itemId: plan.item.id, itemTitle: plan.item.title,
                 itemRef: plan.itemRef, itemUrl: plan.item.url, command: plan.preview, workingDirectory: plan.workingDirectory.path)
    }

    public func cancel() { shell.cancel() }

    /// Runs the command, streaming output to `onOutput`, and returns the finished record.
    public func run(store: Store?, onOutput: @escaping @Sendable (String) -> Void) async -> AgentRun {
        var record = initialRecord
        try? await store?.saveAgentRun(record)
        do {
            let result = try await shell.run(onOutput: onOutput)
            record.status = AgentRun.Status(result.outcome)
            record.exitCode = result.exitCode.map(Int.init)
            record.output = result.output
        } catch is CancellationError {
            record.status = .cancelled
        } catch {
            record.status = .failed
            record.output = "Couldn't start the command: \(error.localizedDescription)"
            onOutput(record.output)
        }
        record.finishedAt = Date()
        try? await store?.saveAgentRun(record)
        return record
    }
}
#endif
