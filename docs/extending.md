# Extending Everboard

## Add a data source (e.g. GitHub, Linear, a personal feed)

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
- Use `--snapshot <dir>` to render all screens to PNG and review them quickly.
- The log is the fastest debugger: `tail -f ~/Library/Logs/Everboard.log`.
- Keep `EverboardCore` free of AppKit and SwiftUI imports. That keeps it testable and reusable by a possible iPhone app.
