import AppKit
import EverboardCore
import SwiftUI

/// Folder picker shared by the settings below.
@MainActor
func chooseFolder(message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    // Store with ~ so the config file doesn't carry your home path around.
    let home = NSHomeDirectory()
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
}

// MARK: - Agents

struct AgentSettings: View {
    private var model: AppModel { .shared }
    @State private var editing: AgentAction?
    @State private var newProject = ""

    var body: some View {
        Form {
            Section {
                ForEach(model.config.agentActions) { a in
                    HStack(alignment: .top) {
                        Image(systemName: a.icon).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                            Text(a.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            Text("On: " + a.targets.map(\.label).joined(separator: ", ") + (a.confirm ? "" : " · runs without asking"))
                                .font(.caption2).foregroundStyle(.tertiary)
                            let unknown = AgentTemplate.unknown(in: a.command)
                            if !unknown.isEmpty {
                                Label("Unknown: " + unknown.map { "{\($0)}" }.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = a }.buttonStyle(.borderless)
                        Button(role: .destructive) { model.updateConfig { $0.agentActions.removeAll { $0.id == a.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add action…") { editing = AgentAction(name: "", command: "") }
                    Menu("Add an example") {
                        ForEach(AgentAction.examples) { ex in
                            Button(ex.name) {
                                var copy = ex
                                copy.id = UUID().uuidString
                                model.updateConfig { $0.agentActions.append(copy) }
                            }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Your own CLI commands, run on an MR, PR, pipeline, issue or feed item from its right-click menu. Everboard asks first (unless you turn that off), shows the output and keeps a history. It never posts anything; copying or commenting is always your click.")
            }

            Section("Placeholders") {
                Text("Values are passed safely as environment variables (EVERBOARD_URL, …), so titles can't inject shell code. Write them anywhere in the command, quoted or not.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(AgentTemplate.placeholders, id: \.name) { p in
                        GridRow {
                            Text("{\(p.name)}").font(.caption.monospaced())
                            Text(p.help).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                ForEach(model.config.repoPaths.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).font(.body.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(model.config.repoPaths[key] ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.updateConfig { $0.repoPaths[key] = nil } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("group/project, owner/repo or just the repo name", text: $newProject)
                    Button("Choose folder…") {
                        guard let path = chooseFolder(message: "Choose the local checkout of \(newProject)") else { return }
                        let key = newProject.trimmingCharacters(in: .whitespaces)
                        model.updateConfig { $0.repoPaths[key] = path }
                        newProject = ""
                    }
                    .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Local repositories — fill {repoPath} so an agent can run inside your checkout")
            }

            Section("History") {
                Stepper("Keep agent run history for \(model.config.agentRunDays) days", value: configBinding(model, \.agentRunDays), in: 1...365)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { action in
            AgentActionEditor(action: action) { saved in
                model.updateConfig { c in
                    if let i = c.agentActions.firstIndex(where: { $0.id == saved.id }) { c.agentActions[i] = saved } else { c.agentActions.append(saved) }
                }
            }
        }
    }
}

private struct AgentActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: AgentAction
    let save: (AgentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.name.isEmpty ? "New agent action" : action.name).font(.headline)
            Form {
                TextField("Name", text: $action.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $action.command).font(.body.monospaced()).frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    let unknown = AgentTemplate.unknown(in: action.command)
                    if !unknown.isEmpty {
                        Label("Unknown placeholder: " + unknown.map { "{\($0)}" }.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Text("Show on")
                    ForEach(AgentTarget.allCases, id: \.self) { t in
                        Toggle(t.label, isOn: Binding(get: { action.targets.contains(t) }, set: { on in
                            if on { action.targets.append(t) } else { action.targets.removeAll { $0 == t } }
                        })).toggleStyle(.checkbox)
                    }
                }
                TextField("Working folder (optional, e.g. {repoPath} or ~/code/app)", text: $action.workingDirectory)
                Stepper("Time limit: \(Int(action.timeoutMinutes)) min", value: $action.timeoutMinutes, in: 1...240)
                Toggle("Show the command and ask before running", isOn: $action.confirm)
                TextField("Icon (SF Symbol name)", text: $action.icon)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(action); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(action.name.trimmingCharacters(in: .whitespaces).isEmpty || action.command.trimmingCharacters(in: .whitespaces).isEmpty
                              || action.targets.isEmpty)
            }
        }
        .padding()
        .frame(width: 640, height: 560)
    }
}

// MARK: - Sources

struct SourceSettings: View {
    private var model: AppModel { .shared }
    @State private var editing: CustomSourceConfig?

    var body: some View {
        Form {
            Section {
                ForEach(model.config.customSources) { s in
                    HStack(alignment: .top) {
                        Image(systemName: s.kind == .folder ? "folder" : "terminal").frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name + (s.enabled ? "" : " (off)"))
                            Text(s.kind == .folder ? s.folder + (s.tag.isEmpty ? "" : " · #\(s.tag)") : s.command)
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                            if let h = model.health[s.sourceID] {
                                Text(h.label).font(.caption2).foregroundStyle(h.isHealthy ? Color.secondary : Color.orange)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = s }.buttonStyle(.borderless)
                        Button(role: .destructive) { model.updateConfig { $0.customSources.removeAll { $0.id == s.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add command source…") { editing = CustomSourceConfig(id: "", name: "", kind: .command) }
                    Button("Add folder source…") { editing = CustomSourceConfig(id: "", name: "", kind: .folder, notifyNew: false) }
                }
            } header: {
                Text("Feeds without code. A command source runs your script on a timer and reads the JSON it prints; a folder source lists the markdown notes in a folder. Each shows up under Feeds in the sidebar and can notify on new items or status changes. The JSON format is in docs/extending.md.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { s in
            SourceEditor(source: s, isNew: s.id.isEmpty) { saved in
                model.updateConfig { c in
                    if let i = c.customSources.firstIndex(where: { $0.id == saved.id }) { c.customSources[i] = saved } else { c.customSources.append(saved) }
                }
            }
        }
    }
}

private struct SourceEditor: View {
    private var model: AppModel { .shared }
    @Environment(\.dismiss) private var dismiss
    @State var source: CustomSourceConfig
    let isNew: Bool
    let save: (CustomSourceConfig) -> Void
    @State private var testResult: String?
    @State private var testing = false

    init(source: CustomSourceConfig, isNew: Bool, save: @escaping (CustomSourceConfig) -> Void) {
        _source = State(initialValue: source)
        self.isNew = isNew
        self.save = save
    }

    var idTaken: Bool { isNew && model.config.customSources.contains { $0.id == CustomSourceConfig.slug(source.name) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New \(source.kind == .folder ? "folder" : "command") source" : source.name).font(.headline)
            Form {
                TextField("Name", text: $source.name)
                if source.kind == .command {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command (runs in zsh from your home folder; must print JSON)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $source.command).font(.body.monospaced()).frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    }
                } else {
                    HStack {
                        TextField("Folder", text: $source.folder)
                        Button("Choose…") { if let p = chooseFolder(message: "Choose a folder of markdown notes") { source.folder = p } }
                    }
                    TextField("Only notes tagged (optional, without #)", text: $source.tag)
                }
                Stepper("Check every \(Int(source.intervalMinutes)) min", value: $source.intervalMinutes, in: 1...1440)
                Toggle("Notify on new items", isOn: $source.notifyNew)
                Toggle("Notify on status changes", isOn: $source.notifyStatus)
                Toggle("Enabled", isOn: $source.enabled)
                if idTaken { Label("A source with this name already exists", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("Test") { test() }.disabled(testing || !filled)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var s = source
                    if isNew { s.id = CustomSourceConfig.slug(s.name) }
                    save(s)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!filled || source.name.trimmingCharacters(in: .whitespaces).isEmpty || idTaken)
            }
        }
        .padding()
        .frame(width: 600, height: 520)
    }

    var filled: Bool { source.kind == .command ? !source.command.isEmpty : !source.folder.isEmpty }

    func test() {
        testing = true
        testResult = nil
        var s = source
        if s.id.isEmpty { s.id = CustomSourceConfig.slug(s.name.isEmpty ? "test" : s.name) }
        let config = model.config
        let store = model.store
        Task {
            defer { testing = false }
            let source: DataSource = s.kind == .folder ? FolderSource(config: s) : CommandSource(config: s)
            do {
                let results = try await source.fetch(context: StoreFetchContext(store: store, config: config))
                let items = results.flatMap(\.items)
                testResult = "OK: \(items.count) item\(items.count == 1 ? "" : "s")" + (items.first.map { ", e.g. “\($0.title)”" } ?? "")
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

// MARK: - Brain

struct BrainSettingsView: View {
    private var model: AppModel { .shared }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Folder (e.g. your Obsidian vault)", text: configBinding(model, \.brain.folder))
                    Button("Choose…") { if let p = chooseFolder(message: "Choose your notes folder") { model.updateConfig { $0.brain.folder = p } } }
                    if model.brain != nil { Button("Open") { model.revealBrainFolder() } }
                }
            } header: {
                Text("Optional. Everboard writes markdown notes (frontmatter, [[links]]) into this folder. It only replaces its own marked sections inside notes you also edit, and never deletes or overwrites your writing.")
            }
            Section("Write") {
                Toggle("Work brief, standup and team digest into the day's note", isOn: configBinding(model, \.brain.writeDaily))
                Toggle("1:1 prep into each person's note", isOn: configBinding(model, \.brain.writePeople))
                Toggle("Weekly report draft into the week's note", isOn: configBinding(model, \.brain.writeWeekly))
                Toggle("Every agent run as its own note, linked from the day's note", isOn: configBinding(model, \.brain.writeAgentRuns))
            }
            Section("Read") {
                Toggle("Use my notes as AI context (person notes for 1:1 prep)", isOn: configBinding(model, \.brain.readForAI))
                Text("Sends the text you wrote in that person's note to Claude, masked per AI privacy. Everboard's own sections are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                TextField("Daily notes folder", text: configBinding(model, \.brain.dailyFolder))
                TextField("Daily note name format", text: configBinding(model, \.brain.dailyNameFormat))
                TextField("People folder", text: configBinding(model, \.brain.peopleFolder))
                TextField("Weekly notes folder", text: configBinding(model, \.brain.weeklyFolder))
                TextField("Agent runs folder", text: configBinding(model, \.brain.agentsFolder))
            }
        }
        .formStyle(.grouped)
        .disabled(DemoData.isDemo)
    }
}

// MARK: - Voice

struct VoiceSettings: View {
    private var model: AppModel { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("⌥⇧Space opens the Assistant and starts listening", isOn: Binding(get: { model.config.voiceHotkey }, set: { on in
                    model.updateConfig { $0.voiceHotkey = on }
                    if on { CommandPalette.shared.registerVoice() } else { CommandPalette.shared.unregisterVoice() }
                }))
                Toggle("Read replies aloud", isOn: configBinding(model, \.voiceSpeakReplies))
            } header: {
                Text("Talk to your agents from the Assistant screen, the mic in the menu bar, or the hotkey. Speak, then press the mic again (or pause) to send.")
            }
            Section {
                Toggle("Recognise speech on this Mac only", isOn: configBinding(model, \.voiceOnDeviceOnly))
                Text(VoiceInput.supportsOnDevice
                     ? "This Mac supports on-device recognition: your audio never leaves it."
                     : "This Mac can't recognise your language on-device. Turn this off to use Apple's speech service, or type instead.")
                    .font(.caption).foregroundStyle(VoiceInput.supportsOnDevice ? Color.secondary : Color.orange)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Voice uses Apple's built-in speech recognition and voices (Settings → General picks the voice). The text of your request then goes to your claude CLI, masked per AI privacy, to work out what to do. No other model is used.")
            }
        }
        .formStyle(.grouped)
    }
}
