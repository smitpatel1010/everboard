# Troubleshooting

Start with the log: `tail -50 ~/Library/Logs/Everboard.log`, then `swift run everboard-cli check`.

| Symptom | Cause / fix |
|---|---|
| **The app "doesn't open"** | Look for the grid icon in the menu bar; launching the app again shows the dashboard. On a notched MacBook with many menu-bar icons, the icon may be hidden behind the notch; use ⌥Space → "Open dashboard". |
| **"GitLab unreachable — VPN?"** | Your self-hosted GitLab is only reachable on VPN. Connect, and the app recovers within a minute (it also refreshes on network change). |
| **"auth failed (401/403)"** | The token is expired or has the wrong scope. Jira: check that `JIRA_EMAIL` matches the token's account, and that your organisation allows API tokens. Fix `secrets.env`, then Settings → Accounts → Reload secrets. |
| **GitLab/GitHub/Jira shows "not configured"** | A value is missing, or the URL isn't `https://`. Check the warnings under Settings → Accounts. GitHub tracking also needs `GITHUB_URL`, not just `GITHUB_TOKEN`. |
| **GitHub To-dos tab is empty** | Fine-grained tokens can't read notifications. Use a classic token with the `notifications` scope. |
| **An account is missing** | Named accounts need `<HOST>_<NAME>_TOKEN` (letters and digits only in the name), e.g. `GITLAB_WORK_TOKEN`. Run `swift run everboard-cli check` to list what was found. |
| **Reportee not resolved** | Hosts only match *public* emails for normal tokens. Type their GitLab username and/or GitHub login in Settings → Team. |
| **No system notifications, only banners** | The build is unsigned. Create the "Everboard Local" certificate ([Build & deploy → Signing](build-and-deploy.md#signing)), run `make install` again, and allow notifications. |
| **Notifications come late** | Batching is on. Check Settings → Notifications → urgent categories and the digest interval, and whether you were in a busy meeting. The menu shows "N batched — show now". |
| **No meetings shown** | Allow Calendar access (System Settings → Privacy & Security → Calendars), and add your work account in Internet Accounts. |
| **⌥Space does nothing** | Another app took the shortcut (the log says "palette hotkey failed"). Free it up in that app, or turn the palette off in Settings → General. |
| **AI buttons fail: "claude CLI not found"** | Install Claude Code, run `claude` once to sign in, or set the path in Settings → General. Use **Test claude** to verify. |
| **AI call timed out** | Big diffs or web search can be slow. Retry, or set a faster model (e.g. `sonnet`). |
| **News brief is empty or off-topic** | Run `swift run everboard-cli news sources --check`. Tune Settings → News → preferences, or send feedback from the brief. |
| **Moved the project folder and secrets stopped loading** | The secrets path is compiled in. Run `make install` again from the new location. |
| **Start fresh** | Quit, then delete `~/Library/Application Support/Everboard/everboard.sqlite`. Settings live in `config.json` next to it. |
