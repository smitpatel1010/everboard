# Security

Everboard runs locally, with your own credentials, on a single-user Mac. There's no Everboard server: network traffic goes only to your GitLab, your Jira, the news sources, and, through the `claude` CLI, Anthropic.

## Assets and where they live

| Asset | Location | Protection |
|---|---|---|
| GitLab / Jira / GitHub tokens | `<project>/secrets.env` | git-ignored (`secrets*`, `*.env`, only `secrets.env.example` is committed); permissions forced to `600` on load; never logged or shown in the UI (Settings shows "•••• set") |
| Work data (MR titles, issue summaries, comments, AI outputs) | `~/Library/Application Support/Everboard/everboard.sqlite` | Inside your user-only `~/Library`; use FileVault for encryption at rest |
| Web panel sessions (e.g. Jira SSO cookies) | WebKit's default data store for the app | Same as Safari's per-app storage |
| Logs | `~/Library/Logs/Everboard.log` | Status lines only: no tokens, no item contents beyond titles in event lines |

## Safeguards in the code

| Risk | Mitigation | Where |
|---|---|---|
| Tokens sent over plain HTTP | `GITLAB_URL` / `JIRA_URL` must be `https://` (except localhost); anything else is ignored with a warning | `Secrets.swift`, `SafeURL.isSecureEndpoint` |
| Leaking secrets via git | `.gitignore` excludes `secrets*` and `*.env`; the template contains no values | `.gitignore` |
| Opening dangerous links from untrusted data (RSS, API fields, AI output) | Only `http`/`https` links are ever opened (`file://`, `javascript:` and app schemes are refused), including links inside rendered AI markdown | `SafeURL.web`, `AppModel.open`, `MarkdownView` |
| Prompt injection via articles, diffs or comments | Every run carries a system instruction to treat content as data. Work features run with **no tools at all**. Tools are restricted to `WebSearch`/`WebFetch` by a hard allowlist, so Bash, Edit, Write and Read can't be granted. News prompts contain no work data, so an injected fetch has nothing sensitive to leak. | `ClaudeCLIRunner.permittedTools` |
| `claude` subprocess reading tokens | Token environment variables are removed from the child's environment; there's no shell (arguments are passed as an array, the prompt via stdin); it runs in an empty scratch directory with no MCP servers | `ClaudeCLIRunner.runSync` |
| SQL injection | All queries are parameterised; `LIKE` patterns are escaped | `Store.swift` |
| Accidental write actions | GitLab actions need the `api` scope (`read_api` can only read); Approve asks for confirmation; comments are sent only after you click Post | `AppModel+Features.swift` |
| Notification or banner spoofing | Banners render plain text only (no HTML) | `ToastCenter`, `Notifier` |
| Global hotkey as a keylogger | The Carbon `RegisterEventHotKey` API receives only its own ⌥Space combo and needs no Accessibility permission | `CommandPalette.swift` |
| Hanging or runaway AI calls | 60–420 s timeout per call; usage is recorded for every call | `ClaudeCLIRunner`, `RecordingClaudeRunner` |

Tests cover the URL scheme allowlist, HTTPS enforcement, automatic `chmod 600`, and the tool allowlist (`Tests/EverboardCoreTests/ParsingTests.swift`).

## Known limits and recommendations

- **Data sent to Anthropic.** AI features send work content (MR diffs, Jira text, titles) to Claude through your `claude` account. Check that this is allowed where you work, or simply don't use those buttons. Nothing is sent automatically except the scheduled work brief and weekly report, and you can disable both in Settings.
- **Unsigned builds** (ad-hoc) run without the hardened runtime. Create the "Everboard Local" certificate ([Build & deploy](build-and-deploy.md#signing)); the script then signs with `--options runtime`.
- **The secrets file is plaintext**, like most CLI tools' configuration. Don't sync the project folder to shared drives, and don't zip and share it with `secrets.env` inside. Keychain storage is a possible future improvement.
- **Web panels** are a normal browser: only add sites you trust.
- **The token scope is your call.** `read_api` is safest; `api` enables the in-app actions.

## Reporting

This is a personal open-source project. Open an issue for non-sensitive problems; for anything sensitive, contact the maintainer privately rather than filing a public issue.
