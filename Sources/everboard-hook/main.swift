import EverboardCore
import Foundation

// Called by coding agents' hooks with the event JSON on stdin: `everboard-hook <tool>`.
// Updates that session's status file for Everboard and always exits 0. It prints nothing, except a
// permission decision when you answered a prompt from Everboard (only if you turned that on).

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--version" {
    print(AppInfo.version)
    exit(0)
}
let tool = args.first ?? "claude-code"
let input = FileHandle.standardInput.readDataToEndOfFile()
if let output = SessionHookRunner.run(input: input, declaredTool: tool) { print(output) }
exit(0)
