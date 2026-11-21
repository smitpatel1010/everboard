# Working on Everboard

Instructions for anyone changing this repository, people and coding agents alike. `CLAUDE.md` imports this file; Cursor reads it directly.

## What Everboard is

An open-source macOS menu bar app (MIT) that anyone can run against their own GitLab, GitHub, Jira, calendar, news feeds and coding agents. It is not built for one person, team or company. Every change has to make sense for a stranger who installs it tomorrow.

## Rules that always apply

1. **Generic, not personal.** No organisation names, internal hostnames, teammates, project keys, personal paths or emails in code, tests, docs, demo data or comments. Hosts, accounts and tokens come from `secrets.env` or the environment; preferences come from `config.json` (`AppConfig`). If a feature only makes sense for one setup, make it configurable or leave it out.
2. **Placeholder data only** in tests, demo data, fixtures and docs: `example.com`, `gitlab.example`, `acme`, `PROJ-123`, made-up names. Screenshots come from `--demo`.
3. **Optional and quiet by default.** A feature that needs an account, a CLI or a change to the user's other tools stays off until the user turns it on, and says what it needs in its empty state. Never edit files outside Everboard's own folders (for example another tool's settings) without an explicit user action, and keep a way to undo it.
4. **`EverboardCore` never imports AppKit or SwiftUI.** Logic, parsing, rules and file formats live in Core with tests in `Tests/EverboardCoreTests`. `EverboardMac` only displays and integrates with macOS.
5. **Config stays backward compatible.** New `AppConfig` fields get a default, a `CodingKeys` case and one lenient line in `init(from:)` (see `docs/extending.md` → Add a setting). Old config files must keep loading.
6. **Follow the existing patterns** before inventing new ones: `DataSource` for polled feeds, deterministic `AppEvent` ids, `EventCategory` for anything that notifies, `Brain` for writing notes, `ShellCommand` for processes. `docs/architecture.md` and `docs/extending.md` describe them.
7. **Privacy.** Data stays on the machine unless the user asked for an AI feature, and AI calls go through `ClaudeCLIRunner` and the privacy filters in `AI/Privacy.swift`. Files that may hold prompts or work content are written owner-only (0600).
8. **No layout loops.** In dashboard pages use `ItemList` or `ScrollView` + `LazyVStack`, not AppKit-backed `List`, `Table` or `HSplitView`.

## Commands

```bash
make build                                   # debug build
make test                                    # unit tests (Swift Testing)
make leakcheck                               # secrets / personal details scan of what would be committed
scripts/check-core.sh                        # EverboardCore has no UI imports
make app && open build/Everboard.app --args --demo     # run with made-up data
build/Everboard.app/Contents/MacOS/Everboard --demo --snapshot /tmp/shots   # render every screen to PNG
tail -f ~/Library/Logs/Everboard.log         # app log
```

`scripts/agent-guard.sh` runs the leak check and the Core check whenever a coding agent runs `git commit` in this repo, and blocks the commit if either fails (wired in `.claude/settings.json` and `.cursor/hooks.json`).

## Area notes

- **Agent sessions** (`Sources/EverboardCore/Sessions`, `Sources/everboard-hook`): `everboard-hook` runs on every tool call of every agent, so it must stay fast and always exit 0. It prints nothing except a permission decision the user gave from Everboard; the only place it may wait is a held permission prompt (`SessionApprovals`), and only while the app says the user is away. Payload shapes for each tool live as fixtures in `Tests/EverboardCoreTests/SessionTests.swift`; change those first when a tool changes its hooks. Only list hook event names a tool actually knows in `HookInstaller`, since unknown names can make its settings file invalid. Details in `docs/agent-sessions.md`.

## Before you call a change done

Follow `.claude/skills/verify-everboard-change/SKILL.md`. In short: tests pass, leakcheck is clean, Core has no UI imports, docs in `docs/` match the new behaviour, and any UI change was looked at in `--demo` in light and dark mode.

## Commits

One line, conventional prefix, written like a person would: `feat: show coding agent sessions`, `fix: keep focus in the palette`. No body unless it's needed.
