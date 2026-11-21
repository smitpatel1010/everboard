import AppKit
import EverboardCore
import Foundation

/// Finds an agent's tab in Terminal or iTerm2 by its tty, to bring it forward or type a reply into it.
/// Uses Apple Events, so macOS asks once for permission to control each terminal app.
enum TerminalBridge {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"

    static func supports(_ host: String?) -> Bool { host == terminal || host == iTerm }

    /// URL scheme that opens a folder's window in an editor whose built-in terminal runs the agent.
    static func editorScheme(_ host: String) -> String? {
        switch host {
        case "com.todesktop.230313mzl4w4u92": return "cursor"
        case "com.microsoft.VSCode": return "vscode"
        case "com.microsoft.VSCodeInsiders": return "vscode-insiders"
        case "com.vscodium": return "vscodium"
        case "com.exafunction.windsurf": return "windsurf"
        default: return nil
        }
    }

    /// Selects the tab and brings its window to the front. False if the tab wasn't found.
    @MainActor static func focus(tty: String, host: String) -> Bool {
        run(script(host: host, tty: tty, action: .focus)) == "found"
    }

    /// Types `text` into the tab and presses Return. Returns an error message, or nil on success.
    @MainActor static func type(_ text: String, tty: String, host: String) -> String? {
        switch run(script(host: host, tty: tty, action: .type(text))) {
        case "found": return nil
        case "missing": return "The session's terminal tab is closed."
        case let other: return other ?? "macOS didn't allow Everboard to control the terminal. Allow it in System Settings → Privacy & Security → Automation."
        }
    }

    enum Action { case focus, type(String) }

    static func script(host: String, tty: String, action: Action) -> String {
        let t = escape(tty)
        if host == iTerm {
            let act: String
            switch action {
            case .focus: act = "tell w to select\n tell t to select\n tell s to select\n activate"
            case .type(let text): act = "tell s to write text \"\(escape(oneLine(text)))\""
            }
            return """
            tell application id "\(iTerm)"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(t)" then
                      \(act)
                      return "found"
                    end if
                  end repeat
                end repeat
              end repeat
              return "missing"
            end tell
            """
        }
        let act: String
        switch action {
        case .focus: act = "set selected of t to true\n set index of w to 1\n activate"
        case .type(let text): act = "do script \"\(escape(oneLine(text)))\" in t"
        }
        return """
        tell application id "\(terminal)"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(t)" then
                \(act)
                return "found"
              end if
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    /// Runs AppleScript; returns its string result, or nil (logging why) when it failed.
    @MainActor private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.info("sessions: terminal script failed: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        return result?.stringValue
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Replies go in as one line: a newline would send the message early.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
