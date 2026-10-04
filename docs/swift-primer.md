# Swift primer (using this codebase)

This primer is for someone who can program, say in Go, TypeScript or Python, but hasn't written Swift. Every example comes from Everboard, so you can open the file and see it in context.

## 1. The language in 10 minutes

### Values: `let` and `var`
```swift
let interval: TimeInterval = 60   // constant (like Go's const, but for any value)
var failures = 0                  // mutable; type inferred as Int
```

### Optionals: Swift's answer to nil
A type with `?` might be absent. The compiler forces you to handle the absent case.
```swift
public var url: String?                                       // FeedItem.swift

if let u = SafeURL.web(event.url) { NSWorkspace.shared.open(u) }   // unwrap if present
guard let gitlab else { throw HTTPError.notConfigured("…") }       // early exit if absent
let name = item["authorName"] ?? item.author ?? "?"                 // default value
item.updatedAt.map(Dates.iso)                                       // transform if present
```
Read `?` as "maybe" and `!` as "I promise it's there (crash if not)". Everboard avoids `!` almost everywhere.

### Structs vs classes
- **`struct`** is a value type: copied on assignment, like a Go struct. Most data types are structs: `FeedItem`, `AppConfig`, `Secrets`.
- **`class`** is a reference type, shared and mutable. It's used for long-lived objects with identity: `AppModel`, `Store`, `Notifier`.

```swift
public struct FeedItem: Codable, Hashable, Sendable, Identifiable { … }   // value
final class AppModel { … }                                                // reference
```

### Enums with associated values
These are much richer than Go constants: each case can carry data, and `switch` must handle every case.
```swift
public enum SourceHealth {            // DataSource.swift
    case ok(Date)
    case unreachable(String)
    case authFailed(String)
    …
}
switch error {
case HTTPError.unreachable: …
case HTTPError.rateLimited(let retry): delay = retry ?? delay   // pull out the payload
default: …
}
```

### Protocols: interfaces
```swift
public protocol DataSource: Sendable {        // Engine/DataSource.swift
    var id: String { get }
    func fetch(context: FetchContext) async throws -> [ScopeResult]
    func events(for change: ItemChange, config: AppConfig) -> [AppEvent]
}
public struct GitLabSource: DataSource { … }  // conforms by implementing them
```
Like Go interfaces, but conformance is declared explicitly (`: DataSource`). Protocols can also provide default implementations through `extension`.

### Extensions
These add methods to any type, including types you didn't write:
```swift
extension Array where Element == FeedItem {
    func sortedByUpdate() -> [FeedItem] { … }   // now every [FeedItem] has .sortedByUpdate()
}
```
Big types are split across files this way. `AppModel+Features.swift` extends `AppModel`.

### Closures
```swift
items.filter { $0.status == "failed" }               // $0 = first argument
events.map(\.id)                                     // key path as a function
Differ.diff(...) { source.events(for: $0, config: config) }   // trailing closure
```

### Errors
Functions that can fail are marked `throws`, and callers must use `try`:
```swift
func currentUser() async throws -> GitLabUser
do { let u = try await gl.currentUser() } catch { print(error) }
let maybe = try? await gl.currentUser()   // nil on error
```

### Codable: JSON for free
Conforming to `Codable` gives a type automatic JSON encoding and decoding. `CodingKeys` maps snake_case API fields:
```swift
public struct GitLabPipeline: Codable {
    public var projectId: Int
    enum CodingKeys: String, CodingKey { case projectId = "project_id" … }
}
let pipelines = try JSONDecoder().decode([GitLabPipeline].self, from: data)
```

### Access control
`public` means visible to other modules (the app and the CLI use `EverboardCore`). With no keyword, a declaration is `internal` (visible within its own module). `private` means visible only in that file or type. This is why structs that the app constructs need explicit `public init`s.

## 2. Concurrency: async/await and actors

```swift
let (data, response) = try await session.data(for: req)   // suspends; doesn't block a thread
```

- **`async` / `await`:** like JavaScript, but checked by the compiler.
- **Task groups** run work in parallel. News sources are fetched concurrently:
  ```swift
  await withTaskGroup(of: (String, Result<[Article], Error>).self) { group in
      for s in sources { group.addTask { … } }
      for await result in group { … }
  }
  ```
- **`actor`** is a class whose state can only be touched by one task at a time, so data races are impossible by construction. `Poller` is an actor.
- **`@MainActor`** marks code that must run on the UI thread. `AppModel` is `@MainActor`, so the UI can read it safely.
- **`Sendable`** means "safe to pass between concurrent tasks". Value types made of value types usually are.

## 3. SwiftUI: declarative UI

A view is a struct with a `body` that *describes* the UI for the current state. When the state changes, SwiftUI recomputes `body` and updates the screen. You never mutate views directly.

```swift
struct EventRow: View {                       // Views/MenuBarView.swift
    let event: AppEvent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)      // SF Symbols icon
            VStack(alignment: .leading) {
                Text(event.title).fontWeight(event.read ? .regular : .semibold)
                Text(event.body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```
- Layout comes from **stacks**: `HStack`, `VStack` and `ZStack`.
- **Modifiers** chain onto a view and each returns a new view: `.font`, `.padding`, `.background`, `.onTapGesture`.
- `some View` means "some specific view type; the compiler knows which".

### State and data flow
| Tool | Used for | Example |
|---|---|---|
| `@State` | Private state owned by one view | `@State private var query = ""` (CommandPalette) |
| `@Binding` / `$x` | Passing writable access to a child | `TextField("…", text: $query)` |
| `@Observable` class | Shared app model; views re-render when the properties they read change | `AppModel` |
| `@Environment` | Getting a shared object anywhere in the view tree | `@Environment(AppModel.self) private var model` |
| `@AppStorage` | A small preference stored in UserDefaults | `@AppStorage("news.tab")` (WorldBriefView) |

The flow in Everboard:
1. The poller updates the store.
2. `AppModel` reloads `items` and `events`.
3. Every view that read those properties re-renders.

That's the whole "framework" you need to follow.

### Scenes and AppKit
- `EverboardApp.swift` declares the app with `@main` and a `MenuBarExtra` scene, which is the icon and popover.
- The dashboard is an AppKit `NSWindow` hosting SwiftUI (`NSHostingView`). That lets notifications open it from anywhere.
- AppKit is the older macOS UI framework. Everboard uses it where SwiftUI has no equivalent: panels, the activation policy, opening URLs.

### Lists, tables, sheets
```swift
List(items) { MRRow(item: $0) }                              // scrolling list
Table(sorted) { TableColumn("Status") { StatusPill(text: $0.status ?? "?") } }
.sheet(item: $model.aiPanel) { AIPanelSheet(panel: $0) }     // modal shown when non-nil
.contextMenu { Button("Approve…") { … } }                    // right-click menu
```

## 4. Swift Package Manager (SwiftPM)

`Package.swift` is the build file, written in Swift itself:
```swift
products: [ .executable(name: "Everboard", targets: ["EverboardMac"]), … ],
dependencies: [ .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0") ],
targets: [ .target(name: "EverboardCore", dependencies: [ .product(name: "GRDB", package: "GRDB.swift") ]), … ]
```
- A **target** is a module, i.e. a folder under `Sources/`. A **product** is what gets built (an app binary, the CLI).
- `Package.resolved` pins exact dependency versions, like `go.sum` or a lockfile.

| Command | Does |
|---|---|
| `swift build` | Compile (debug) into `.build/` |
| `swift build -c release` | Optimised build |
| `swift run everboard-cli check` | Build and run the CLI |
| `swift test` | Run tests (Everboard needs extra flags without full Xcode, so use `make test`) |

## 5. Tests (Swift Testing)
```swift
@Test func pipelineTurningRedNotifiesOnce() async throws {       // EngineTests.swift
    let store = try Store.inMemory()
    …
    #expect(first.map(\.id) == ["pipeline.failed:100"])
}
```
`@Test` marks a test, and `#expect` asserts. On failure it prints both sides of the expression. Run everything with `make test`.

## 6. Reading order for this codebase

1. `Engine/FeedItem.swift` and `Engine/DataSource.swift`: the vocabulary
2. `Engine/Differ.swift`: about 30 lines, the heart of change detection
3. `GitLab/GitLabSource.swift`: a real source and its rules
4. `Engine/Poller.swift`: the loop
5. `EverboardMac/AppModel.swift`: how results reach the UI
6. `Views/DashboardView.swift`: how screens are put together
7. `Tests/EngineTests.swift`: the behaviour, spelled out as examples

## 7. Where to learn more
- *The Swift Programming Language* (free, docs.swift.org): the "A Swift Tour" chapter covers everything above.
- Apple's SwiftUI tutorials: developer.apple.com/tutorials/swiftui
- Hacking with Swift (hackingwithswift.com): practical, searchable answers.
