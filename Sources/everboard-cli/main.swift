import EverboardCore
import Foundation

// Debug / setup CLI. Shares the app's database and config so what you see here is what the app sees.

let usage = """
everboard-cli — Everboard debug tool

  check                     Validate secrets, GitLab + Jira tokens, reportees and filters
  reportees resolve         Resolve reportee emails in config to GitLab usernames (saves config)
  reportees add <email>…    Add reportees by email (then run resolve)
  filters                   List your favourite Jira filters
  filters add <id>…         Watch Jira filters by id
  poll [--dry-run]          Run one GitLab + Jira poll and print items and events
  brief                     Generate the work morning brief
  news sources [--check]    List news sources (and test each one)
  news collect              Fetch news into the database
  news brief [--no-gap]     Generate the World & Tech brief
  news prefs                Print the news preferences file
"""

let args = Array(CommandLine.arguments.dropFirst())
var config = AppConfig.load()
let secrets = Secrets.load()

@MainActor func out(_ s: String = "") { print(s) }
@MainActor func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
@MainActor func saveConfig() { do { try config.save() } catch { fail("Could not save config: \(error)") } }

@MainActor func check() async {
    out("Secrets: \(secrets.path.path)")
    secrets.warnings.forEach { out("  ⚠️  \($0)") }
    for key in Secrets.Key.allCases {
        let v = secrets[key]
        out("  \(key.rawValue): " + (v == nil ? "—" : key.isSecret ? "set (\(v!.count) chars)" : v!))
    }
    out()
    if let gl = GitLabClient(secrets: secrets) {
        do {
            let me = try await gl.currentUser()
            out("✅ GitLab: \(me.name) (@\(me.username)) at \(gl.baseURL.absoluteString)")
        } catch { out("❌ GitLab: \(error.localizedDescription)") }
    } else { out("➖ GitLab not configured (GITLAB_URL + GITLAB_TOKEN)") }
    if let jira = JiraClient(secrets: secrets) {
        do {
            let me = try await jira.myself()
            out("✅ Jira: \(me.displayName ?? "?") (\(me.accountId))")
            let favs = try await jira.favouriteFilters()
            out("   Favourite filters: " + (favs.isEmpty ? "none" : favs.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")))
        } catch { out("❌ Jira: \(error.localizedDescription)") }
    } else { out("➖ Jira not configured (JIRA_URL + JIRA_EMAIL + JIRA_API_TOKEN)") }
    out()
    out("Reportees: " + (config.reportees.isEmpty ? "none" : config.reportees.map { "\($0.email) → \($0.username ?? "unresolved")" }.joined(separator: ", ")))
    out("Watched filters: " + (config.jiraFilters.isEmpty ? "none" : config.jiraFilters.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")))
    let claude = config.expandedClaudePath
    out("claude: \(claude) " + (FileManager.default.isExecutableFile(atPath: claude) ? "✅" : "❌ not found"))
}

@MainActor func resolveReportees() async {
    guard let gl = GitLabClient(secrets: secrets) else { fail("GitLab not configured") }
    for i in config.reportees.indices where config.reportees[i].username == nil {
        let email = config.reportees[i].email
        do {
            if let u = try await gl.resolveUser(email: email) {
                config.reportees[i].username = u.username
                config.reportees[i].name = u.name
                out("✅ \(email) → @\(u.username) (\(u.name))")
            } else {
                out("❓ \(email): not found — set the username in Settings")
            }
        } catch { out("❌ \(email): \(error.localizedDescription)") }
    }
    saveConfig()
}

@MainActor func poll(dryRun: Bool) async throws {
    let store = dryRun ? try Store.inMemory() : try Store()
    var sources: [DataSource] = []
    if let gl = GitLabClient(secrets: secrets) { sources.append(GitLabSource(client: gl, interval: config.gitlabInterval)) }
    if let jira = JiraClient(secrets: secrets) { sources.append(JiraSource(client: jira, interval: config.jiraInterval)) }
    if sources.isEmpty { fail("Neither GitLab nor Jira is configured") }
    for source in sources {
        out("== \(source.displayName)")
        do {
            let results = try await source.fetch(context: StoreFetchContext(store: store, config: config))
            for r in results {
                out("  \(r.scope): \(r.items.count) items")
                for i in r.items.prefix(5) { out("    · [\(i.status ?? "-")] \(i.title.prefix(90)) — \(i.subtitle)") }
            }
            let events = try await Engine.process(source: source, results: results, store: store, config: config)
            out("  events: \(events.count)" + (dryRun ? " (dry run: in-memory store, so this is a baseline)" : ""))
            for e in events { out("    🔔 \(e.title) — \(e.body.replacingOccurrences(of: "\n", with: " · "))") }
        } catch { out("  ❌ \(error.localizedDescription)") }
    }
}

@MainActor func claudeRunner() -> ClaudeRunning {
    let base = ClaudeCLIRunner(executable: config.expandedClaudePath, defaultModel: config.claudeModel)
    guard let store = try? Store() else { return base }
    return RecordingClaudeRunner(base: base, store: store)
}

@MainActor func newsCommand(_ rest: [String]) async throws {
    let store = try Store()
    let news = NewsService(store: store, claude: claudeRunner(), secrets: secrets)
    switch rest.first {
    case "sources":
        let check = rest.contains("--check")
        for s in config.newsSources {
            var line = "\(s.enabled ? "●" : "○") [\(s.section.title)] \(s.name) — \(s.url)"
            if check {
                do {
                    let a = try await NewsFetchers.fetch(s, secrets: secrets)
                    line += "  ✅ \(a.count) recent"
                } catch { line += "  ❌ \(error.localizedDescription.prefix(120))" }
            }
            out(line)
        }
    case "collect":
        let r = try await news.collect(config: config)
        out("New articles: \(r.newArticles.count)")
        for (name, err) in r.errors.sorted(by: { $0.key < $1.key }) { out("  ❌ \(name): \(err.prefix(120))") }
        for e in r.majorEvents { out("  🚨 \(e.title) (\(e.body))") }
    case "brief":
        if rest.contains("--no-gap") { config.newsGapCheck = false }
        out("Generating brief with claude… (can take a few minutes)")
        let b = try await news.generateBrief(config: config)
        out("\n\(b.headline)\n")
        for s in b.sections {
            out("## \(s.name)")
            for st in s.stories {
                out("- [\(st.importance)] \(st.title)\n    \(st.summary)\n    ↳ \(st.whyItMatters)\n    \(st.urls.first ?? "")")
            }
            out()
        }
        out("(\(b.candidateCount) candidates" + (b.costUSD.map { String(format: ", $%.3f", $0) } ?? "") + ")")
    case "prefs":
        out(news.loadPreferences())
    default:
        out(usage)
    }
}

do {
    switch args.first {
    case "check": await check()
    case "reportees":
        if args.dropFirst().first == "add" {
            for email in args.dropFirst(2) where !config.reportees.contains(where: { $0.id == email.lowercased() }) {
                config.reportees.append(Reportee(email: email))
            }
            saveConfig()
            out("Reportees: \(config.reportees.map(\.email).joined(separator: ", "))")
        } else {
            await resolveReportees()
        }
    case "filters":
        guard let jira = JiraClient(secrets: secrets) else { fail("Jira not configured") }
        if args.dropFirst().first == "add" {
            for id in args.dropFirst(2) where !config.jiraFilters.contains(where: { $0.id == id }) {
                let f = try await jira.filter(id: id)
                config.jiraFilters.append(JiraFilterConfig(id: f.id, name: f.name))
                out("Watching \(f.name) [\(f.id)]: \(f.jql ?? "")")
            }
            saveConfig()
        } else {
            for f in try await jira.favouriteFilters() { out("[\(f.id)] \(f.name)\n    \(f.jql ?? "")") }
        }
    case "poll": try await poll(dryRun: args.contains("--dry-run"))
    case "brief":
        let store = try Store()
        let assistant = WorkAssistant(store: store, claude: claudeRunner(), gitlab: GitLabClient(secrets: secrets), jira: JiraClient(secrets: secrets))
        out(try await assistant.morningBrief())
    case "news": try await newsCommand(Array(args.dropFirst()))
    default: out(usage)
    }
} catch {
    fail("Error: \(error.localizedDescription)")
}
