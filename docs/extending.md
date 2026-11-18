# Extending Everboard

## Add a code host (e.g. Bitbucket, Gitea)

GitLab and GitHub share one model, so a new host plugs into every screen, rule and AI feature at once:

1. **Add a `CodeHostKind` case** in `CodeHost/CodeHost.swift` (display name, env prefix, default URL). `Secrets` then picks up `<PREFIX>_URL`, `<PREFIX>_TOKEN`, `<PREFIX>_ORGS` and named accounts automatically.
2. **Write a client** that conforms to `CodeHostClient` (current user, details and diffs for summaries, approve/comment/retry, search, report queries).
3. **Write a source** that fills the `CodeScope` lists (`account.scope(.mine)`, `.review`, `.assigned`, `.reportees`, `.todos`, `.pipelines`) with `FeedItem`s using the shared attrs: `account`, `projectPath`, `iid`, `pipelineStatus`, `pipelineId`, `pipelineUrl`, `approvedBy`, `mergeStatus`, `action`. Return `CodeHostRules.events(for:account:)` from `events(for:config:)`. See `GitHub/GitHubSource.swift`.
4. **Map statuses** onto the GitLab vocabulary (`success`, `failed`, `running`, `pending`, `canceled`) so pills and rules work unchanged.
5. **Wire it** in `CodeHosts.client(for:)` and `CodeHosts.source(for:interval:)`. The compiler points to the remaining `switch`es.

## Add a data source (e.g. Linear, a personal feed)

1. **Write a client** in `Sources/EverboardCore/<Name>/`, using `HTTPClient` for the requests.
2. **Implement `DataSource`:**
   ```swift
   public struct MySource: DataSource {
       public let id = "mysource"
       public let displayName = "My Source"
       public let interval: TimeInterval = 300

       public func fetch(context: FetchContext) async throws -> [ScopeResult] {
           let items: [FeedItem] = try await client.list().map { x in
               FeedItem(id: "mysource:\(x.id)", source: id, kind: "thing", title: x.title,
                        url: x.url, status: x.state, updatedAt: x.updated, attrs: ["owner": x.owner])
           }
           return [ScopeResult(scope: "mysource.things", mode: .replace, items: items)]
       }

       public func events(for change: ItemChange, config: AppConfig) -> [AppEvent] {
           guard !change.everSeen else { return [] }          // only brand-new items
           return [AppEvent(id: "mysource.new:\(change.new.id)", category: .myNewThing,
                            title: "New: \(change.new.title)", body: "", url: change.new.url)]
       }
   }
   ```
   - Make event ids **deterministic**, so repeats are deduplicated.
   - Use `.replace` for full lists and `.accumulate` for incremental ones.
   - For state between polls, use `context.value` / `context.setValue`.
3. **Add an `EventCategory` case** in `Engine/FeedItem.swift`, with its label and source. The compiler will then point you to the `switch`es that need the new case: icons in `MenuBarView.swift`, routing in `Notifier.swift`.
4. **Register the source** in `AppModel.configureSources()`, usually guarded by a secret being present (add the key to `Secrets.Key`).
5. **Show it.** Load the items in `AppModel.reloadData()` into `ItemsSnapshot`, add a view in `Views/`, and add a `SidebarItem` case plus a sidebar `Label` in `DashboardView`.
6. **Test the rules.** Copy the pattern in `Tests/EverboardCoreTests/EngineTests.swift`: an in-memory store, one baseline run, then a run that should produce an event.

## Add a feed without code

**Settings → Sources** turns any script or folder into a feed. Nothing to compile.

### Command source

Everboard runs the command through `zsh -c` from your home folder, on the interval you set (timeout 2 minutes), and parses what it prints:

```json
{
  "mode": "replace",
  "items": [
    {
      "id": "deploy-481",
      "title": "Deploy web to production",
      "url": "https://deploys.example/481",
      "subtitle": "web",
      "status": "running",
      "author": "release-bot",
      "createdAt": "2026-11-18T09:12:00Z",
      "updatedAt": 1795000000,
      "attrs": { "env": "prod", "sha": "4f2a9c1" }
    }
  ]
}
```

- A bare array of items works too.
- `id` and `title` are required; items without them are skipped. Item ids become `custom.<source id>:<id>`, so keep them **stable** between runs, otherwise every poll looks like new items.
- `mode`: `replace` (default) means the output is the complete current list; `accumulate` means only new or changed items, kept until they age out.
- Dates are ISO 8601 strings or Unix seconds (milliseconds work too). `attrs` values are turned into strings.
- A non-zero exit, a timeout or output that isn't JSON shows as an error on the source's health chip; the previous items stay.
- Events: a new item fires *New item in a custom feed*, and a changed `status` fires *Status change in a custom feed*. Both use deterministic ids, so repeats don't notify twice.
- The command gets `EVERBOARD_SOURCE` (the source id) and not your Everboard tokens.

A tiny example that lists open GitHub issues with the `gh` CLI:

```sh
gh issue list --repo owner/repo --json number,title,url,state,updatedAt \
  | jq '[.[] | {id: (.number|tostring), title, url, status: .state, updatedAt}]'
```

### Folder source

Lists `*.md` files in a folder and its subfolders (hidden folders such as `.obsidian` are skipped, up to 500 files). Frontmatter becomes `attrs`; `title`, `status`, `url` and `author`/`owner` fill the matching fields. Set a tag to only include notes tagged with it. The item id is the note's path relative to the folder, so renaming a note makes it a new item.

### In code

Both are ordinary `DataSource`s (`Custom/CustomSource.swift`) built by `CustomSources.sources(_:)` from `AppConfig.customSources`, so they follow every rule above: deterministic ids, one `replace` scope per source, events from `ItemChange`.

## Add an agent action

Agent actions are config, not code: **Settings → Agents**, or `agentActions` in `config.json`:

```json
{
  "name": "Claude: review this change",
  "command": "claude -p \"/deep-review {url}\"",
  "targets": ["change"],
  "workingDirectory": "{repoPath}",
  "timeoutMinutes": 15,
  "confirm": true,
  "icon": "sparkles"
}
```

- `targets`: `change` (MRs/PRs), `pipeline`, `issue` (Jira), `todo`, `custom` (feed items).
- Placeholders are listed in `AgentTemplate.placeholders`. To add one, give it a value in `AgentTemplate.values(for:)` and a line in that list; the safe quoting is automatic.
- `AgentRunner.plan` resolves an action against an item and reports problems (an unknown placeholder, a value the item doesn't have, a missing folder) before anything runs.

## Write to the brain folder

`Brain` (`Brain/Brain.swift`) is the only writer. Use `upsertBlock` (or the `writeDailySection` / `writePersonSection` / `writeWeeklySection` helpers) to set an Everboard-owned section in a note the user may also edit, and `createNote` for new files; it never overwrites. From the app, call `model.writeToBrain("what") { try $0.… }`, which does nothing when no folder is set and turns failures into a toast.

## Add a setting

1. Add a property with a default to `AppConfig`.
2. Add it to `CodingKeys`, and add one line in `init(from:)`. This lenient decoding keeps old config files working.
3. Use `configBinding(model, \.yourSetting)` in a `SettingsView` tab.

## Add an AI feature

1. Build the prompt from store data, in Core (see `ReportService` or `WorkAssistant`).
2. Call `claude.run(ClaudeRequest(prompt:…, feature: "my.feature"))`. The `feature` label is what appears in the usage dashboard; add a friendly name in `UsageSettings.featureName`.
3. Give it tools only if it needs the web, and only `WebSearch`/`WebFetch`; the runner drops anything else.
4. Cache results with `store.cache(key, text)` when the input hasn't changed.
5. In the UI, show the result with `AIPanel` (a sheet) or a dedicated view using `MarkdownView`.

## Add a news source

Settings → News → Sources accepts any RSS or Atom URL. For a code default, add it to `NewsSource.defaults`. Then check it with `swift run everboard-cli news sources --check`.

## Workflow tips

- Run `open build/Everboard.app --args --demo` to iterate on UI with sample data.
- Use `--snapshot <dir>` to render all screens to PNG and review them quickly (add `--appearance dark` for dark mode). It also renders narrow-window versions.
- Use `--demo --resize-test` to step every screen through narrow and wide window sizes, with and without the peek panel. It logs each step, so a layout loop shows up as the last step logged before a crash. `EVERBOARD_RESIZE_ONLY=<screen>` limits it to one screen.
- Avoid AppKit-backed `List`, `Table` and `HSplitView` in dashboard pages: inside the flexible window layout they can loop on constraints while the window resizes. Use `ItemList` or a `ScrollView` + `LazyVStack`.
- The log is the fastest debugger: `tail -f ~/Library/Logs/Everboard.log`.
- Keep `EverboardCore` free of AppKit and SwiftUI imports. That keeps it testable and reusable by a possible iPhone app.
