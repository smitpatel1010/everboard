import EverboardCore
import Foundation

// Debug / setup CLI. Shares the app's database and config so what you see here is what the app sees.

let usage = """
everboard-cli — Everboard debug tool

  check                     Validate secrets, GitLab/GitHub/Jira tokens, reportees and filters
  reportees resolve         Resolve reportee emails to GitLab usernames and GitHub logins (saves config)
  reportees add <email>…    Add reportees by email (then run resolve)
  filters                   List your favourite Jira filters
  filters add <id>…         Watch Jira filters by id
  poll [--dry-run]          Run one poll of every account and print items and events
  brief                     Generate the work morning brief
  news sources [--check]    List news sources (and test each one)
  news collect              Fetch news into the database
  news brief [--no-gap]     Generate the World & Tech brief
  news prefs                Print the news preferences file
"""

let args = Array(CommandLine.arguments.dropFirst())
var config = AppConfig.load()
let secrets = Secrets.load()
let codeHosts = secrets.codeHostAccounts.map { CodeHosts.client(for: $0) }

@MainActor func out(_ s: String = "") { print(s) }
@MainActor func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
@MainActor func saveConfig() { do { try config.save() } catch { fail("Could not save config: \(error)") } }

@MainActor func check() async {
    out("Secrets: \(secrets.path.path)")
    secrets.warnings.forEach { out("  ⚠️  \($0)") }
    for key in [Secrets.Key.jiraURL, .jiraEmail, .jiraToken] {
        let v = secrets[key]
        out("  \(key.rawValue): " + (v == nil ? "—" : key.isSecret ? "set (\(v!.count) chars)" : v!))
    }
    out()
    if codeHosts.isEmpty { out("➖ No GitLab or GitHub account (GITLAB_URL + GITLAB_TOKEN, GITHUB_URL + GITHUB_TOKEN, or GITLAB_<NAME>_TOKEN …)") }
    for host in codeHosts {
        let a = host.account
        let orgs = a.orgs.isEmpty ? "" : " · orgs: \(a.orgs.joined(separator: ", "))"
        do {
            let me = try await host.currentUser()
            out("✅ \(a.displayName): \(me.name) (@\(me.username)) at \(a.webURL.absoluteString)\(orgs)")
        } catch { out("❌ \(a.displayName) at \(a.webURL.absoluteString): \(error.localizedDescription)") }
    }
    if let jira = JiraClient(secrets: secrets) {
        do {
            let me = try await jira.myself()
            out("✅ Jira: \(me.displayName ?? "?") (\(me.accountId))")
            let favs = try await jira.favouriteFilters()
            out("   Favourite filters: " + (favs.isEmpty ? "none" : favs.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")))
        } catch { out("❌ Jira: \(error.localizedDescription)") }
    } else { out("➖ Jira not configured (JIRA_URL + JIRA_EMAIL + JIRA_API_TOKEN)") }
    out()
    out("Reportees: " + (config.reportees.isEmpty ? "none" : config.reportees.map {
        "\($0.email) → GitLab \($0.username ?? "—"), GitHub \($0.githubUsername ?? "—")"
    }.joined(separator: ", ")))
    out("Watched filters: " + (config.jiraFilters.isEmpty ? "none" : config.jiraFilters.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")))
    let claude = config.expandedClaudePath
    out("claude: \(claude) " + (FileManager.default.isExecutableFile(atPath: claude) ? "✅" : "❌ not found"))
}

@MainActor func resolveReportees() async {
    if codeHosts.isEmpty { fail("No GitLab or GitHub account configured") }
    for i in config.reportees.indices {
        let email = config.reportees[i].email
        for kind in CodeHostKind.allCases where config.reportees[i].username(on: kind) == nil {
            var found: CodeHostUser?
            for host in codeHosts where host.account.kind == kind && found == nil {
                do { found = try await host.resolveUser(email: email) } catch { out("❌ \(email) on \(host.account.displayName): \(error.localizedDescription)") }
            }
            guard codeHosts.contains(where: { $0.account.kind == kind }) else { continue }
            if let u = found {
                if kind == .gitlab { config.reportees[i].username = u.username } else { config.reportees[i].githubUsername = u.username }
                if config.reportees[i].name == nil { config.reportees[i].name = u.name }
                out("✅ \(email) → \(kind.displayName) @\(u.username) (\(u.name))")
            } else {
                out("❓ \(email): not found on \(kind.displayName) — set it in Settings → Team")
            }
        }
    }
    saveConfig()
}

@MainActor func poll(dryRun: Bool) async throws {
    let store = dryRun ? try Store.inMemory() : try Store()
    var sources: [DataSource] = secrets.codeHostAccounts.map { CodeHosts.source(for: $0, interval: config.gitlabInterval) }
    if let jira = JiraClient(secrets: secrets) { sources.append(JiraSource(client: jira, interval: config.jiraInterval)) }
    if sources.isEmpty { fail("No GitLab, GitHub or Jira account is configured") }
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
        let assistant = WorkAssistant(store: store, claude: claudeRunner(), codeHosts: codeHosts, jira: JiraClient(secrets: secrets))
        out(try await assistant.morningBrief())
    case "news": try await newsCommand(Array(args.dropFirst()))
    default: out(usage)
    }
} catch {
    fail("Error: \(error.localizedDescription)")
}
