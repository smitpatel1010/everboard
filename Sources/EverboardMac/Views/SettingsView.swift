import EverboardCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Text("General") }.tag("general")
            AccountsSettings().tabItem { Text("Accounts") }.tag("accounts")
            TeamSettings().tabItem { Text("Team") }.tag("team")
            JiraSettings().tabItem { Text("Jira") }.tag("jira")
            NotificationSettings().tabItem { Text("Notifications") }.tag("notifications")
            WebPanelSettings().tabItem { Text("Web panels") }.tag("web")
            NewsSettings().tabItem { Text("News") }.tag("news")
            UsageSettings().tabItem { Text("AI usage") }.tag("usage")
        }
        .padding()
        .navigationTitle("Settings")
    }
}

/// Binding into a config field that saves on change.
@MainActor
func configBinding<T>(_ model: AppModel, _ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
    Binding(get: { model.config[keyPath: keyPath] }, set: { v in model.updateConfig { $0[keyPath: keyPath] = v } })
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var claudeTest: String?
    @State private var loginError: String?
    @State private var launchAtLogin = SystemEvents.launchAtLoginEnabled
    @State private var pinned = ""

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = SystemEvents.setLaunchAtLogin(on)
                        model.updateConfig { $0.launchAtLogin = on }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Shortcuts & calendar") {
                Toggle("Command palette on ⌥Space", isOn: Binding(get: { model.config.paletteEnabled }, set: { on in
                    model.updateConfig { $0.paletteEnabled = on }
                    if on { CommandPalette.shared.register(model: model) } else { CommandPalette.shared.unregister() }
                }))
                Toggle("Show meetings from macOS Calendar", isOn: Binding(get: { model.config.calendarEnabled }, set: { on in
                    model.updateConfig { $0.calendarEnabled = on }
                    if on { model.calendar.start() }
                }))
                if model.config.calendarEnabled {
                    switch model.calendar.access {
                    case .denied:
                        Text("Calendar access denied — allow Everboard in System Settings → Privacy & Security → Calendars.")
                            .font(.caption).foregroundStyle(.orange)
                    case .granted where model.calendar.today.isEmpty:
                        Text("No meetings today. Work calendar missing? Add your Microsoft 365 / Exchange account in System Settings → Internet Accounts.")
                            .font(.caption).foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
            }
            Section("Read aloud") {
                Picker("Voice", selection: configBinding(model, \.speechVoice)) {
                    Text("Best available").tag("")
                    ForEach(Speech.englishVoices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))\(v.quality == .premium ? " · premium" : v.quality == .enhanced ? " · enhanced" : "")").tag(v.identifier)
                    }
                }
                Slider(value: configBinding(model, \.speechRate), in: 0.35...0.65) { Text("Speed") }
                Text("Download nicer voices in System Settings → Accessibility → Spoken Content → System voice → Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Weekly report & team health") {
                Toggle("Generate automatically", isOn: configBinding(model, \.weeklyReportEnabled))
                Picker("Day", selection: configBinding(model, \.weeklyReportWeekday)) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                TextField("Time (HH:mm)", text: configBinding(model, \.weeklyReportTime))
            }
            Section("Polling") {
                Stepper("GitLab every \(Int(model.config.gitlabInterval))s", value: configBinding(model, \.gitlabInterval), in: 30...900, step: 30)
                Stepper("Jira every \(Int(model.config.jiraInterval))s", value: configBinding(model, \.jiraInterval), in: 60...1800, step: 60)
                Stepper("News every \(Int(model.config.newsInterval / 60)) min", value: configBinding(model, \.newsInterval), in: 900...7200, step: 900)
                VStack(alignment: .leading) {
                    TextField("Pinned GitLab projects (comma-separated paths)", text: $pinned)
                        .onSubmit { model.updateConfig { $0.pinnedProjects = pinned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                    Text("Your pipelines in these projects are always watched, in addition to projects you've pushed to this week. Press Return to save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Work brief") {
                Toggle("Generate automatically", isOn: configBinding(model, \.workBriefEnabled))
                TextField("Time (HH:mm)", text: configBinding(model, \.workBriefTime))
                Toggle("Weekdays only", isOn: configBinding(model, \.workBriefWeekdaysOnly))
                Toggle("Auto-summarize new reportee MRs (uses Claude per MR)", isOn: configBinding(model, \.autoSummarizeReporteeMRs))
            }
            Section("Claude") {
                TextField("claude CLI path (blank = auto-detect)", text: configBinding(model, \.claudePath))
                Text("Using: \(model.config.expandedClaudePath)").font(.caption).foregroundStyle(.secondary)
                TextField("Model (blank = CLI default, e.g. sonnet, opus)", text: configBinding(model, \.claudeModel))
                HStack {
                    Button("Test claude") { testClaude() }
                    if let claudeTest { Text(claudeTest).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { pinned = model.config.pinnedProjects.joined(separator: ", ") }
    }

    func testClaude() {
        claudeTest = "Running…"
        Task {
            do {
                let r = try await model.claude.run(ClaudeRequest(prompt: "Reply with exactly: Everboard can talk to Claude.", timeout: 60, feature: "settings.test"))
                claudeTest = "✅ " + r.text
            } catch {
                claudeTest = "❌ " + error.localizedDescription
            }
        }
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var results: [String] = []
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Secrets file", value: model.secrets.path.path)
                HStack {
                    Button("Edit secrets file") { NSWorkspace.shared.open(model.secrets.path) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.secrets.path]) }
                    Button("Reload secrets") { model.reloadSecrets() }
                }
                ForEach(model.secrets.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            } header: {
                Text("Tokens live in a private dotenv file, never in this app's settings")
            }
            Section("Values") {
                ForEach(Secrets.Key.allCases, id: \.self) { key in
                    LabeledContent(key.rawValue) {
                        if let v = model.secrets[key] {
                            Text(key.isSecret ? "•••• set" : v).foregroundStyle(.secondary)
                        } else {
                            Text(key == .githubToken ? "optional" : "missing").foregroundStyle(key == .githubToken ? Color.secondary : Color.red)
                        }
                    }
                }
            }
            Section("Connection check") {
                Button(checking ? "Checking…" : "Check connections") { check() }.disabled(checking)
                ForEach(results, id: \.self) { Text($0).font(.callout) }
            }
        }
        .formStyle(.grouped)
    }

    func check() {
        checking = true
        results = []
        Task {
            defer { checking = false }
            if let gl = GitLabClient(secrets: model.secrets) {
                do { let u = try await gl.currentUser(); results.append("✅ GitLab: \(u.name) (@\(u.username))") }
                catch { results.append("❌ GitLab: \(error.localizedDescription)") }
            } else { results.append("➖ GitLab not configured") }
            if let jira = JiraClient(secrets: model.secrets) {
                do { let u = try await jira.myself(); results.append("✅ Jira: \(u.displayName ?? u.accountId)") }
                catch { results.append("❌ Jira: \(error.localizedDescription)") }
            } else { results.append("➖ Jira not configured") }
        }
    }
}

// MARK: - Team

struct TeamSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newEmails = ""
    @State private var resolving = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Emails (comma or newline separated)", text: $newEmails, axis: .vertical).lineLimit(1...4)
                    Button("Add") { add() }.disabled(newEmails.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Reportees — you get notified when they open an MR")
            }
            Section {
                if model.config.reportees.isEmpty {
                    Text("No reportees yet.").foregroundStyle(.secondary)
                }
                ForEach(model.config.reportees) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.email)
                            if let n = r.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        TextField("GitLab username", text: usernameBinding(r))
                            .frame(width: 180)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: r.username == nil ? "questionmark.circle" : "checkmark.circle.fill")
                            .foregroundStyle(r.username == nil ? .orange : .green)
                        Button(role: .destructive) { model.updateConfig { $0.reportees.removeAll { $0.id == r.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button(resolving ? "Resolving…" : "Resolve usernames from GitLab") { resolve() }
                        .disabled(resolving || !model.secrets.hasGitLab)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("GitLab only matches public emails for non-admin tokens; if a lookup fails, type the username.")
            }
        }
        .formStyle(.grouped)
    }

    func usernameBinding(_ r: Reportee) -> Binding<String> {
        Binding(get: { r.username ?? "" }, set: { v in
            model.updateConfig { c in
                if let i = c.reportees.firstIndex(where: { $0.id == r.id }) {
                    let t = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
                    c.reportees[i].username = t.isEmpty ? nil : t
                }
            }
        })
    }

    func add() {
        let emails = newEmails.components(separatedBy: CharacterSet(charactersIn: ",;\n "))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") }
        model.updateConfig { c in
            for e in emails where !c.reportees.contains(where: { $0.id == e.lowercased() }) { c.reportees.append(Reportee(email: e)) }
        }
        newEmails = ""
        if model.secrets.hasGitLab { resolve() }
    }

    func resolve() {
        guard let gl = GitLabClient(secrets: model.secrets) else { return }
        resolving = true
        Task {
            defer { resolving = false }
            var found = 0, missing = 0
            for r in model.config.reportees where r.username == nil {
                if let u = try? await gl.resolveUser(email: r.email) {
                    found += 1
                    model.updateConfig { c in
                        if let i = c.reportees.firstIndex(where: { $0.id == r.id }) {
                            c.reportees[i].username = u.username
                            c.reportees[i].name = u.name
                        }
                    }
                } else { missing += 1 }
            }
            status = "Resolved \(found)" + (missing > 0 ? ", \(missing) need a username typed in" : "")
        }
    }
}

// MARK: - Jira

struct JiraSettings: View {
    @Environment(AppModel.self) private var model
    @State private var favourites: [JiraFilter] = []
    @State private var loading = false
    @State private var error: String?
    @State private var filterId = ""

    var body: some View {
        Form {
            Section("Watched filters") {
                if model.config.jiraFilters.isEmpty { Text("None yet — pick from your favourites below or add by ID.").foregroundStyle(.secondary) }
                ForEach(model.config.jiraFilters) { f in
                    HStack {
                        Text(f.name)
                        Text(f.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("New issues", isOn: filterBinding(f.id, \.notifyNew)).toggleStyle(.checkbox)
                        Toggle("Status changes", isOn: filterBinding(f.id, \.notifyStatus)).toggleStyle(.checkbox)
                        Button(role: .destructive) { model.updateConfig { $0.jiraFilters.removeAll { $0.id == f.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Filter ID (from the filter URL ?filter=12345)", text: $filterId)
                    Button("Add") { add(id: filterId.trimmingCharacters(in: .whitespaces), name: nil) }.disabled(filterId.isEmpty)
                }
            }
            Section("Your favourite filters") {
                Button(loading ? "Loading…" : "Load favourites from Jira") { load() }.disabled(loading || !model.secrets.hasJira)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                ForEach(favourites) { f in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(f.jql ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if model.config.jiraFilters.contains(where: { $0.id == f.id }) {
                            Text("Watching").font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Watch") { add(id: f.id, name: f.name) }
                        }
                    }
                }
            }
            Section {
                Text("Jira dashboards (gadgets) can't be fetched through the API — add the dashboard URL under Web panels to see it inside Everboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func filterBinding(_ id: String, _ kp: WritableKeyPath<JiraFilterConfig, Bool>) -> Binding<Bool> {
        Binding(get: { model.config.jiraFilters.first { $0.id == id }?[keyPath: kp] ?? true },
                set: { v in model.updateConfig { c in if let i = c.jiraFilters.firstIndex(where: { $0.id == id }) { c.jiraFilters[i][keyPath: kp] = v } } })
    }

    func load() {
        guard let jira = JiraClient(secrets: model.secrets) else { return }
        loading = true
        Task {
            defer { loading = false }
            do { favourites = try await jira.favouriteFilters(); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    func add(id: String, name: String?) {
        guard !id.isEmpty, !model.config.jiraFilters.contains(where: { $0.id == id }) else { return }
        if let name {
            model.updateConfig { $0.jiraFilters.append(JiraFilterConfig(id: id, name: name)) }
            return
        }
        guard let jira = JiraClient(secrets: model.secrets) else { return }
        Task {
            do {
                let f = try await jira.filter(id: id)
                model.updateConfig { $0.jiraFilters.append(JiraFilterConfig(id: f.id, name: f.name)) }
                filterId = ""
            } catch { self.error = "Filter \(id): \(error.localizedDescription)" }
        }
    }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Notify me when…") {
                ForEach(EventCategory.allCases, id: \.self) { c in
                    Toggle(c.label, isOn: Binding(get: { model.config.isEnabled(c) },
                                                  set: { v in model.updateConfig { $0.notifications[c.rawValue] = v } }))
                }
                Text("Everything still lands in the Inbox; these only control banners. Per-filter Jira toggles live under Jira.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Batching & focus") {
                Toggle("Batch low-priority notifications into a digest", isOn: configBinding(model, \.batchLowPriority))
                Stepper("Digest every \(Int(model.config.batchIntervalMinutes)) min", value: configBinding(model, \.batchIntervalMinutes), in: 15...240, step: 15)
                    .disabled(!model.config.batchLowPriority)
                Toggle("Hold all notifications while I'm in a meeting (busy calendar event)", isOn: configBinding(model, \.quietDuringMeetings))
                Text("Urgent — always delivered right away (unless in a meeting):").font(.caption).foregroundStyle(.secondary)
                ForEach(EventCategory.allCases.filter { ![.workBriefReady, .newsBriefReady, .reportReady].contains($0) }, id: \.self) { c in
                    Toggle(c.label, isOn: Binding(get: { model.config.isUrgent(c) }, set: { on in
                        model.updateConfig { cfg in
                            cfg.urgentCategories.removeAll { $0 == c.rawValue }
                            if on { cfg.urgentCategories.append(c.rawValue) }
                        }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
            Section("Muted items") {
                let muted = model.config.mutedItems.filter { $0.value > Date() }
                if muted.isEmpty { Text("Nothing muted. Right-click an item or use the notification's “Mute” action.").foregroundStyle(.secondary) }
                ForEach(muted.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(model.item(withId: id)?.title ?? id).lineLimit(1)
                        Spacer()
                        let until = muted[id]!
                        Text(until == .distantFuture ? "forever" : "until \(until.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Unmute") { model.unmute(itemId: id) }
                    }
                }
            }
            Section {
                if model.notifier.authorized {
                    Label("System notifications are allowed", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label("macOS is blocking notifications for this build, so Everboard shows its own banners in the top-right corner. Sign the app with a local certificate (see README) to get real notifications.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                Button("Send a test notification") { model.notifier.sendTest() }
                Button("Open macOS notification settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Web panels

struct WebPanelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.config.webPanels) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(p.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) { model.updateConfig { $0.webPanels.removeAll { $0.id == p.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Name", text: $name).frame(width: 160)
                    TextField("https://…", text: $url)
                    Button("Add") {
                        model.updateConfig { $0.webPanels.append(WebPanel(name: name, url: url)) }
                        name = ""; url = ""
                    }.disabled(name.isEmpty || !url.hasPrefix("http"))
                }
            } header: {
                Text("Pages shown inside the dashboard — e.g. your Jira dashboards. Sign in once; the session is remembered.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - News

struct NewsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var prefs = ""
    @State private var prefsSaved = false
    @State private var keywords = ""
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newSection: NewsSection = .tech

    var body: some View {
        Form {
            Section("Schedule") {
                TextField("Morning brief (HH:mm)", text: Binding(
                    get: { model.config.newsBriefTimes.first ?? "08:30" },
                    set: { v in model.updateConfig { c in if c.newsBriefTimes.isEmpty { c.newsBriefTimes = [v] } else { c.newsBriefTimes[0] = v } } }))
                Toggle("Evening edition at 18:00", isOn: Binding(
                    get: { model.config.newsBriefTimes.count > 1 },
                    set: { on in model.updateConfig { c in c.newsBriefTimes = on ? [c.newsBriefTimes.first ?? "08:30", "18:00"] : [c.newsBriefTimes.first ?? "08:30"] } }))
                Toggle("Gap check — let Claude web-search for big stories the feeds missed", isOn: configBinding(model, \.newsGapCheck))
                TextField("Region of interest (optional, e.g. India)", text: configBinding(model, \.newsRegion))
            }
            Section("Major story alerts") {
                Toggle("Alert me instantly about major stories (no Claude call)", isOn: configBinding(model, \.newsMajorAlerts))
                TextField("Keywords", text: $keywords, axis: .vertical).lineLimit(1...3)
                    .onSubmit { model.updateConfig { $0.newsAlertKeywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                Text("A story alerts when it matches a keyword and is on 3+ sources within 3h or has 600+ points on Hacker News. Keywords are also refreshed from your feedback. Press Return to save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $prefs)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 220)
                HStack {
                    Button("Save preferences") {
                        try? model.news.savePreferences(prefs)
                        prefsSaved = true
                    }
                    Button(model.preferencesUpdating ? "Applying feedback…" : "Apply pending 👍/👎 feedback now") {
                        model.applyNewsFeedback()
                    }.disabled(model.preferencesUpdating)
                    if prefsSaved { Text("Saved").font(.caption).foregroundStyle(.green) }
                }
            } header: {
                Text("Your preferences — Claude reads this before every brief and rewrites it from your feedback")
            }
            Section("Sources") {
                ForEach(NewsSection.allCases, id: \.self) { section in
                    let sources = model.config.newsSources.filter { $0.section == section }
                    if !sources.isEmpty {
                        Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(sources) { s in
                            HStack {
                                Toggle(s.name, isOn: Binding(
                                    get: { s.enabled },
                                    set: { v in model.updateConfig { c in if let i = c.newsSources.firstIndex(where: { $0.id == s.id }) { c.newsSources[i].enabled = v } } }))
                                Spacer()
                                Text(URL(string: s.url)?.host ?? "").font(.caption).foregroundStyle(.tertiary)
                                Button(role: .destructive) { model.updateConfig { $0.newsSources.removeAll { $0.id == s.id } } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                HStack {
                    TextField("Name", text: $newName).frame(width: 140)
                    TextField("RSS/Atom URL", text: $newURL)
                    Picker("", selection: $newSection) {
                        ForEach(NewsSection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 110)
                    Button("Add") {
                        model.updateConfig { $0.newsSources.append(NewsSource(name: newName, url: newURL, section: newSection)) }
                        newName = ""; newURL = ""
                    }.disabled(newName.isEmpty || !newURL.hasPrefix("http"))
                }
                Button("Restore default sources") {
                    model.updateConfig { c in
                        for d in NewsSource.defaults where !c.newsSources.contains(where: { $0.id == d.id }) { c.newsSources.append(d) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            prefs = model.news.loadPreferences()
            keywords = model.config.newsAlertKeywords.joined(separator: ", ")
        }
    }
}
