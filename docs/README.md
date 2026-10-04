# Everboard docs

New here? Read them in this order:

1. **[Getting started](getting-started.md):** install, set up tokens, first run.
2. **[Features guide](features.md):** everything the app does, screen by screen.
3. **[How it works](architecture.md):** the big picture, from an API response to a notification.
4. **[Swift primer](swift-primer.md):** enough Swift, SwiftUI and SwiftPM to read and change this code, even if you've never written Swift.
5. **[Build & deploy](build-and-deploy.md):** what `make install` actually does and how the app lives on your Mac.

Reference:
- **[AI & token usage](ai-and-usage.md):** every Claude call, what it sends, how usage is tracked.
- **[Security](security.md):** the threat model, the safeguards, and where data lives.
- **[Extending](extending.md):** recipes for adding sources, screens, settings and tests.
- **[Troubleshooting](troubleshooting.md)**

## The 30-second mental model

```
          every 60–120 s                     on change
GitLab ─┐                ┌──────────┐   ┌───────────┐   ┌──────────────┐
Jira  ──┼─► DataSource ─►│  Differ  │──►│   Store   │──►│ Notifications│
News  ──┘   (fetch)      │ old→new  │   │ (SQLite)  │   │  + Inbox     │
                          └──────────┘   └─────┬─────┘   └──────────────┘
                                               │
                                     SwiftUI reads it ──► menu bar, dashboard
                                               │
                                   claude -p ◄─┘  briefs, summaries, reports
```

Each **source** fetches a list of items. The **differ** compares that list with the previous snapshot and turns changes into **events**. The **store** saves everything, and the **UI** and **notifier** read from the store. AI features build a prompt from stored data and run the local `claude` CLI.
