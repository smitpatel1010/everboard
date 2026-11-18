import Foundation

/// How a shell command ended.
public enum ShellOutcome: String, Codable, Sendable {
    case succeeded, failed, cancelled, timedOut
}

public struct ShellResult: Sendable {
    public var outcome: ShellOutcome
    public var exitCode: Int32?
    /// stdout and stderr interleaved, capped at `ShellCommand.outputLimit`.
    public var output: String
    /// stdout alone, for commands whose output is parsed (custom sources).
    public var stdout: Data
}

#if os(macOS)
/// Runs one user-configured command line through `/bin/zsh -c`, streaming its output.
/// Used by agent actions and command sources. The command is the user's own (from their config); values that
/// come from feed data are only ever passed as environment variables, never spliced into the command text.
public final class ShellCommand: @unchecked Sendable {
    public static let outputLimit = 400_000

    public let command: String
    public let workingDirectory: URL
    public let environment: [String: String]
    public let timeout: TimeInterval

    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init(command: String, workingDirectory: URL? = nil, environment: [String: String] = [:], timeout: TimeInterval = 600) {
        self.command = command
        self.workingDirectory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.environment = environment
        self.timeout = timeout
    }

    /// The environment every command gets: ours minus Everboard's tokens, a PATH that finds Homebrew and
    /// `~/.local/bin` tools when launched from Finder, plus `extra`.
    public static func environment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where Secrets.isSensitiveEnvKey(key) { env.removeValue(forKey: key) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        env.merge(extra) { _, new in new }
        return env
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// Runs to completion. `onOutput` receives chunks as they arrive (on a background queue).
    public func run(onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.runSync(onOutput: onOutput)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func runSync(onOutput: (@Sendable (String) -> Void)?) throws -> ShellResult {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment(extra: environment)
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = OutputBuffer(limit: Self.outputLimit)
        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if let text = buffer.append(chunk, isStdout: isStdout) { onOutput?(text) }
                }
                group.leave()
            }
        }

        do {
            lock.lock()
            let early = cancelled
            lock.unlock()
            if early { throw CancellationError() }
            try process.run()
        } catch {
            // Unblock the readers: nothing else will ever close these.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }
        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        let code = process.terminationStatus
        let outcome: ShellOutcome = wasCancelled ? .cancelled : timedOut ? .timedOut : code == 0 ? .succeeded : .failed
        return ShellResult(outcome: outcome, exitCode: timedOut || wasCancelled ? nil : code, output: buffer.text, stdout: buffer.stdout)
    }
}

/// Collects output from two reader threads.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var combined = ""
    private var out = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    /// Returns the decoded chunk to stream, or nil once the cap is reached.
    func append(_ data: Data, isStdout: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if isStdout && out.count < limit * 4 { out.append(data) }
        guard !truncated else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if combined.count + text.count > limit {
            truncated = true
            let note = "\n[output truncated]\n"
            combined += note
            return note
        }
        combined += text
        return text
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return combined }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
}
#endif
