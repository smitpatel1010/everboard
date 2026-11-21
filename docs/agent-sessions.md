# Agent sessions

Everboard can show every coding agent session you have open (Claude Code in any terminal or app, Cursor chats, and any other tool that writes a session file) in one list: what each one is working on, and which ones are blocked on you.

## Set it up

1. **Settings → Agent sessions → Hooks → Install** next to Claude Code and/or Cursor.
2. Restart sessions that were already running (tools read their hook settings at start).

Or from the command line:

```bash
swift run everboard-cli sessions install claude-code
swift run everboard-cli sessions install cursor
swift run everboard-cli sessions            # list sessions and their state
swift run everboard-cli sessions hooks      # what's installed where
```

What installing does:

- Copies `everboard-hook`, a small binary from the app bundle, to `~/.local/share/everboard/bin/` (`$XDG_DATA_HOME` if set), so moving the app doesn't break your hooks. The app keeps that copy up to date.
- Adds one entry per event to `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) or `~/.cursor/hooks.json`. Your other hooks and settings stay as they were. The first install keeps a copy of the original file next to it, ending in `.before-everboard`.
- **Remove** takes Everboard's entries out again and leaves everything else.

The hook always exits 0 and runs in about 10 ms. It prints nothing, so it never blocks or changes what the agent does, with one opt-in exception: a permission decision when you answer a prompt from Everboard (see below).

## What you see

**Sessions** in the sidebar (under Agents) groups sessions into *Needs you*, *Working*, *Finished or idle* and, if you ask, *Ended*. Each row shows the session's name (or first prompt), what it is doing now or what it is waiting for, the project folder, the latest notice, and how long it has been in that state. Right-click to copy its resume command, open its folder, mute it or remove it.

**Clicking a session opens that exact session**, using the most specific way back the tool offers:

| Where the agent runs | What opens |
|---|---|
| Claude's desktop app | That session, through the app's `claude://code/continue?session=…` link |
| Terminal or iTerm2 | The tab running it, found by its terminal device (macOS asks once to let Everboard control the terminal) |
| A terminal inside Cursor, VS Code or Windsurf | The editor window for the session's folder |
| Cursor chat | The chat itself, in Cursor's Agents Window (`cursor://anysphere.cursor-deeplink/agent?id=<chat id>`). Cursor versions without that link get the window the chat belongs to instead: its `.code-workspace` file or folder, found in Cursor's own workspace records |
| Anything else | The app it runs in, or its folder |

Sessions waiting on you also show at the top of **Home → Needs you**, in the menu bar popover, and as a badge on the sidebar item.

| State | Meaning | Claude Code signal | Cursor signal |
|---|---|---|---|
| **Needs approval** | Blocked on a permission prompt | `PermissionRequest`, `Notification` (permission), or the plan tool | Not reported by Cursor (see below) |
| **Waiting for you** | Asked you something | The turn ends on a question, `AskUserQuestion`, or a question dialog | The turn ends on a question |
| **Working** | Running a turn; the line shows the current step | Prompt submitted, tool calls; the in-progress to-do item when there is one | Prompt submitted, tool calls, thinking |
| **Done** | The turn ended without a question | `Stop` | `stop` (completed or aborted) |
| **Error** | The turn failed | `StopFailure` | `stop` with an error |
| **Ended** | The session closed, or its process went away mid-turn | `SessionEnd`, or the process is gone | The process is gone |

"Ends on a question" means one of the last lines of the reply ends with `?` or asks something like "should I…", "want me to…" or "let me know if…". Code blocks are ignored.

**Cursor approvals.** Cursor's hooks report a tool call starting and finishing, but not an approval prompt. When a tool call has been running for more than 20 seconds the row says *may be waiting for your approval*. That can also be a slow command, so these don't send a notification.

**Cursor's records.** Chat names, pending questions and which window a chat is in come from Cursor's internal files, not a documented interface. If Cursor changes them, Everboard falls back to the hook data: the first prompt as the title, no question, and the first folder's window.

**Cursor and Claude Code hooks.** Cursor also runs hooks from `~/.claude/settings.json`. The hook tells the two apart by the payload, so a Cursor chat is never listed as a Claude Code session, even with both installed.

## Answer from Everboard

**Permission prompts and questions (Claude Code).** Turn on *Answer Claude Code permission prompts and questions from Everboard* in Settings → Agent sessions. Then a permission prompt shows **Allow** and **Deny**, and a multiple-choice question shows its options with **Submit** and **Skip**, on the session row, in the menu bar, and from the notification (which opens the Sessions page). Your answer goes back to Claude Code as if you had answered there.

Claude's desktop app shows its own prompt at the same time, so you can answer in either place. Claude Code in a terminal is different: there a held prompt waits for Everboard only while you're in another app, and the terminal asks once the time runs out (5 minutes by default). Plan approvals are never held, since a plan is meant to be read where it's shown.

This works through Claude Code's `PermissionRequest` hook, which decides a prompt by printing a decision while it is running (for a question, the tool's input plus `answers`). Everboard writes a small status file the hook reads (`.everboard-app.json` in the sessions folder: whether it's running, which app is in front, the setting); without a fresh one, nothing is held. Answers can also come from a script: `everboard-cli sessions answer <session> allow|deny|<option>`.

Cursor's hooks have no permission event, so Cursor prompts are answered in Cursor.

**Cursor's questions.** Cursor asks multiple-choice questions with its `ask_question` tool, which fires no hook. Everboard reads Cursor's own chat records (`globalStorage/state.vscdb`) for a question that is still pending, marks the chat *Waiting for you* and shows the questions and options. Cursor has no way to take an answer from outside, so the button opens the chat in Cursor to answer there. The same records give the chat's name.

**Questions.** For a session in Terminal or iTerm2 that ended its turn with a question, the row has a reply box: Everboard types your answer into the session's tab and presses Return. Multiple-choice questions, and sessions in Claude's desktop app or Cursor, can't take text from outside, so the row offers to open the session instead.

## Notices

Claude Code records some things only in its transcript, never in a hook: a hook that failed or blocked an action, an API or connection error, or a note such as "compacted while you were away". Everboard reads the end of the transcript after each step and shows the latest notice on the session row. API errors clear once the turn finishes normally, since Claude Code retries them. Errors also notify you (Settings → Notifications → *reported a problem*); informational notes only show on the row.

## Notifications

Settings → Notifications has five toggles: *needs my approval*, *waiting for my reply*, *stopped with an error*, *reported a problem* and *finished its turn*. All but the last are on by default and are always sent right away, outside the digest, because the agent can't continue until you answer. Meeting quiet hours still apply. *Finished* is off by default; it fires after every turn.

Clicking a notification switches to that session. Right-click a session → *Mute notifications* to silence one busy session.

## Privacy

Session files hold the prompt (cut to 500 characters), the session name, the current step, a one-line summary of the last reply and the latest notice. They stay on your Mac, in `~/.local/state/everboard/sessions/` (`$XDG_STATE_HOME`, or `$EVERBOARD_SESSIONS_DIR`), readable only by you. Nothing is sent to Claude or anywhere else. **Hide prompt text** in settings shows the project name instead of prompts in the app.

Ended sessions are deleted after a day, and any session not updated for three days is deleted.

## Add another tool

Any tool can show up by writing one JSON file per session to the sessions folder. Name it `<tool>-<session id>.json`, write it atomically (write a temp file, then rename), and update it as the session changes:

```json
{
  "schema": 1,
  "tool": "my-agent",
  "sessionId": "3f2a9c",
  "state": "needs_approval",
  "title": "Retry failed payouts",
  "activity": "Running the payout tests",
  "detail": "Allow running `git push`",
  "cwd": "/path/to/project",
  "pid": 41235,
  "hostApp": "com.example.terminal",
  "resumeCommand": "my-agent resume 3f2a9c",
  "updatedAt": "2026-11-21T09:12:00Z",
  "stateSince": "2026-11-21T09:11:40Z"
}
```

- Required: `tool`, `sessionId`. Everything else is optional.
- `state`: `idle`, `working`, `needs_approval`, `needs_reply`, `done`, `error` or `ended`. Unknown values count as `working`.
- `detail`: the question, the approval needed, the error, or a summary of the last reply. `activity`: what it is doing now.
- `pid`: the agent's process. If it disappears mid-turn the session is shown as ended.
- `hostApp`: the bundle id of the app to bring forward on click; `tty` (e.g. `/dev/ttys003`) finds its Terminal or iTerm2 tab. `openURL` (a URL to open, tried first; only `claude:`, `cursor:`, `vscode:`, `vscode-insiders:`, `vscodium:`, `windsurf:`, `zed:` and `https:` links are opened, never `file:` ones) and `resumeCommand` (copied to the clipboard) are other ways back to the session.
- `notice`: `{"id", "level": "error"|"info", "text", "at"}`. A new error notice notifies once.
- Dates are ISO 8601 or Unix seconds. Set `stateSince` when the state changes; each change notifies once.

If your tool has hooks similar to Claude Code's, it may be simpler to call `everboard-hook <tool-name>` with the hook's JSON on stdin: payloads with `session_id` and `hook_event_name` (`UserPromptSubmit`, `PreToolUse`, `Stop`, …) are understood as they are.

## How it fits together

```
Claude Code / Cursor ──hook──► everboard-hook ──writes──► sessions/<tool>-<id>.json
                                                                   │ folder watch (instant)
                                                                   ▼    + re-check every 5 s
                                                SessionCenter (app) ── state changed? ──► Inbox + notification
```

- `EverboardCore/Sessions/SessionHooks.swift` maps each tool's events onto one state machine. It's pure and covered by `SessionTests.swift`, which holds payload fixtures for both tools. When a tool changes its payloads, update the fixtures first.
- `SessionDirectory.swift` reads and writes the files under a folder lock, because parallel tool calls fire hooks at the same time.
- `SessionRules.swift` handles what hooks can't report (a process that went away) and turns state changes into `AppEvent`s with deterministic ids.
- `HookInstaller.swift` edits the tools' settings files. `EverboardMac/SessionCenter.swift` watches the folder and drives the UI. Sessions skip the `Poller` because they change many times a second and never touch the network.
