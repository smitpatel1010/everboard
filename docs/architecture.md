# How it works

## The pieces

```
everboard/
├── Package.swift                 ← build manifest (like package.json / go.mod)
├── Sources/
│   ├── EverboardCore/            ← all logic; no UI code, could be reused by an iPhone app
│   │   ├── Config/               AppConfig (settings JSON), Secrets (secrets.env)
│   │   ├── Engine/               FeedItem, AppEvent, Differ, Store (SQLite), Poller
│   │   ├── GitLab/               REST + GraphQL client, GitLabSource
│   │   ├── Jira/                 REST v3 client, JiraSource, ADF helpers
│   │   ├── AI/                   ClaudeCLIRunner, WorkAssistant, Reports, Usage
│   │   ├── News/                 feed parsing, fetchers, clustering, brief, follow/ask
│   │   └── Util/                 HTTP, dates, HTML→text, JSON, log
│   ├── EverboardMac/             ← the macOS app: SwiftUI views + system integration
│   │   ├── EverboardApp.swift    entry point, menu bar, dashboard window
│   │   ├── AppModel*.swift       the single source of truth the UI observes
│   │   ├── Notifier, ToastCenter notifications (system + fallback banners)
│   │   ├── CalendarService, Speech, CommandPalette, SystemEvents
│   │   └── Views/                one file per screen
│   └── everboard-cli/            ← debug/setup command-line tool
├── Tests/EverboardCoreTests/     ← unit tests (Swift Testing)
├── Resources/                    Info.plist, AppIcon.icns
└── scripts/                      build-app.sh, make-icon.swift
```

**The rule:** `EverboardCore` never imports AppKit or SwiftUI. Everything that talks to the outside world or makes decisions lives there and is unit-tested. `EverboardMac` handles display and macOS integration only.

## One poll, end to end

What happens when one of your pipelines turns red:

1. **The `Poller`** (`Engine/Poller.swift`) is an `actor` that runs one loop per source. Every `interval` seconds (60 for GitLab) it calls `source.fetch(context:)`.

2. **`GitLabSource.fetch`** (`GitLab/GitLabSource.swift`) makes:
   - one GraphQL query for your authored, review-requested and assigned MRs, each with its `headPipeline`
   - one GraphQL query for all reportees' open MRs
   - `GET /todos`
   - `GET /projects/:id/pipelines?username=you` for each project you're active in

   It returns `[ScopeResult]`: named lists of normalised `FeedItem`s, such as `gitlab.mr.mine` and `gitlab.pipelines.p42`.

3. **`Engine.process`** loads the previous state of each scope from the `Store`: which items were present, which were ever seen, and whether the scope has synced before. It then calls the pure function **`Differ.diff`**, which pairs each new item with its old version as an `ItemChange`.

4. **Rules.** For each change the differ calls `source.events(for:config:)`. `GitLabSource` checks whether `pipelineStatus` is now `failed` when it wasn't before for that pipeline id. If so, it emits an `AppEvent` with the deterministic id `pipeline.failed:<pipelineId>`.

5. **`Store.apply`** upserts the items and inserts events with `INSERT OR IGNORE`. A deterministic id means the same failure seen through two paths (your MR, and "pipelines I triggered") is stored once. `apply` returns only the events that are truly new.

6. **The poller calls back into `AppModel.handle`** (main thread). That updates source health, reloads lists from the store, and calls `deliver(events)`.

7. **`deliver`** filters out disabled categories and muted items. It then either notifies now (urgent, not in a meeting) or holds the event for the next digest (`flushHeldIfDue`, checked every minute).

8. **`Notifier`** posts a native notification. If that isn't permitted, it falls back to a `ToastCenter` banner. Clicking it goes through `Notifier.route`, which opens the URL, summarizes, shows a digest, or mutes.

9. **SwiftUI** re-renders automatically, because `AppModel` is `@Observable` and its `items` / `events` / `unread` changed.

**Baseline.** The first time a scope is seen, the differ runs with `baseline: true`. State is recorded but no events are created, which is why you don't get 50 notifications on first launch.

**Replace vs accumulate.**
- A `.replace` scope (e.g. "MRs waiting for my review") is the complete current list. Items missing from a fetch are marked not-present.
- An `.accumulate` scope (pipelines, comments) is incremental: items are upserted and pruned later by age.

**Errors.** Failures are classified as unreachable (VPN), auth, rate limit or other. The poller backs off exponentially (up to 15 minutes, or `Retry-After`). It refreshes immediately on wake from sleep and on network changes (`SystemEvents.swift`).

## Data model

| Type | Meaning |
|---|---|
| `FeedItem` | Any thing a source lists: MR, pipeline, issue, to-do, comment. It has common fields plus `attrs: [String: String]` for source-specific detail (`pipelineStatus`, `jiraKeys`…). |
| `ScopeResult` | One named list from one fetch, plus its mode (`replace` / `accumulate`) |
| `ItemChange` | `old` vs `new`, with `wasPresent` and `everSeen` flags |
| `AppEvent` | Something that happened. It shows in the Inbox and may notify. It has an `EventCategory`, which drives notification toggles and icons. |
| `AppConfig` | User settings, saved as JSON. Decoding is lenient, so new fields don't break old files. |
| `Secrets` | Tokens and URLs from `secrets.env`, with environment variables as a fallback |

SQLite tables (`Store.swift` migrations):
- `items`: snapshots per scope
- `events`: the inbox
- `kv`: cursors and caches
- `ai_cache`: AI results
- `articles`, `news_briefs`, `news_feedback`, `shown_stories`: news
- `followed_stories`, `followed_matches`: followed stories and their updates
- `ai_usage`: token usage

## Jira specifics

- Search uses `POST /rest/api/3/search/jql`, the paginated replacement for the retired `/search` endpoint.
- Filter JQL is fetched once an hour. Its `ORDER BY` is stripped, and the query is re-run ordered by `updated`.
- For comments, the app looks at issues you're involved in that were updated since the last poll (relative `-Nm`, so the user's Jira timezone doesn't matter), then fetches their latest comments. Mentions are detected by finding your `accountId` in the comment's ADF (Atlassian Document Format) tree.

## News pipeline

1. **Collect** (every 30 minutes, no AI):
   - fetch all enabled sources concurrently (RSS/Atom via `XMLParser`, Hacker News API, GitHub search)
   - normalise URLs (strip `utm_*`, `www`, fragments) to an id
   - **cluster** articles by title similarity (Jaccard ≥ 0.5 on significant words)
   - run the **major-story** heuristic
   - match **followed stories**
2. **Brief** (scheduled):
   - take up to about 150 unseen candidates, balanced across sections, plus your preferences file and recent feedback
   - send them to `claude -p` with a **JSON schema**, so the result is structured (sections → stories → article ids)
   - map article ids back to URLs
   - mark the articles as shown, so they don't repeat tomorrow
3. **Learn.** Feedback is stored. "Apply" asks Claude to rewrite `news-preferences.md` and return new alert keywords.

## The AI layer

`ClaudeCLIRunner` (`AI/Claude.swift`) runs `claude -p --output-format json --tools <allowlist>` with the prompt on stdin. It runs in an empty scratch directory with a cleaned environment, then parses `result`, `structured_output`, cost and token usage. `RecordingClaudeRunner` wraps it to log every call to `ai_usage`. See [AI & token usage](ai-and-usage.md).

## Threading in one paragraph

- UI state (`AppModel`, views) lives on the **main actor**.
- The `Poller` is an **actor**, so its state is safe from concurrent access.
- The `Store` uses GRDB's `DatabasePool`: one writer at a time, many concurrent readers.
- Network calls are `async` and never block the UI.
- `claude` runs in a background `Process`, with stdout and stderr drained concurrently.
