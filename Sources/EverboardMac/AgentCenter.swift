import AppKit
import EverboardCore
import Foundation
import Observation

/// Runs agent actions (Settings → Agents) on items: confirm, stream output, keep history, optionally save to the brain.
/// Nothing here posts to a code host or sends a message; the output only leaves the app if you copy or post it yourself.
@MainActor @Observable
final class AgentCenter {
    static let shared = AgentCenter()

    /// A run in progress (or just finished) with its live output.
    @MainActor @Observable
    final class Live: Identifiable {
        let id: String
        let execution: AgentExecution
        var record: AgentRun
        init(execution: AgentExecution) {
            id = execution.id
            self.execution = execution
            record = execution.initialRecord
        }
    }

    /// Shown in a sheet: a run's output, live or from history.
    struct Presented: Identifiable, Equatable {
        let id: String
    }

    var live: [String: Live] = [:]
    var history: [AgentRun] = []
    /// Waiting for "Run" in the confirm sheet.
    var pending: AgentPlan?
    var presented: Presented?
    /// Output of history runs opened in the sheet (the list query leaves it out).
    var loaded: [String: AgentRun] = [:]

    private var model: AppModel { .shared }

    func start() async {
        try? await model.store.closeInterruptedAgentRuns()
        await reloadHistory()
    }

    func reloadHistory() async {
        history = (try? await model.store.agentRuns(limit: 300)) ?? []
    }

    func actions(for item: FeedItem) -> [AgentAction] { model.config.agentActions.filter { $0.applies(to: item) } }

    func plan(_ action: AgentAction, item: FeedItem) -> AgentPlan {
        AgentRunner.plan(action, item: item, repoPaths: model.config.repoPaths)
    }

    /// Entry point from menus: confirm first unless the action opts out (and nothing is wrong with it).
    func request(_ action: AgentAction, item: FeedItem) {
        let p = plan(action, item: item)
        model.showDashboard()
        if action.confirm || !p.runnable {
            pending = p
        } else {
            run(p)
        }
    }

    func run(_ plan: AgentPlan) { _ = start(plan, present: true) }

    /// Runs without opening the output sheet (used by the Assistant). Returns the run id.
    func runInBackground(_ plan: AgentPlan) -> String? { start(plan, present: false) }

    private func start(_ plan: AgentPlan, present: Bool) -> String? {
        pending = nil
        guard plan.runnable else { return nil }
        let execution = AgentExecution(plan: plan)
        let entry = Live(execution: execution)
        live[entry.id] = entry
        if present {
            // Let the confirm sheet finish closing before the output sheet opens; macOS drops a sheet presented mid-dismissal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.presented = Presented(id: entry.id) }
        }
        Log.info("agent: running \(plan.action.name) on \(plan.itemRef)")
        let store = model.store
        Task {
            let final = await execution.run(store: store) { chunk in
                Task { @MainActor in AgentCenter.shared.append(chunk, to: entry.id) }
            }
            finish(entry.id, final)
        }
        Task { await reloadHistory() }
        return entry.id
    }

    private func append(_ chunk: String, to id: String) {
        live[id]?.record.output += chunk
    }

    private func finish(_ id: String, _ final: AgentRun) {
        var record = final
        if model.config.brain.writeAgentRuns, let brain = model.brain {
            model.writeToBrain("agent run") { b in
                record.notePath = try b.writeAgentRun(record)
            }
            if record.notePath != nil {
                Task {
                    try? await model.store.saveAgentRun(record)
                    let today = Calendar.current.startOfDay(for: Date())
                    let runs = (try? await model.store.agentRuns(since: today)) ?? []
                    model.writeToBrain("agent run index") { _ in try brain.writeAgentRunIndex(runs) }
                    await reloadHistory()
                }
            }
        }
        live[id]?.record = record
        loaded[id] = record
        Log.info("agent: \(record.actionName) on \(record.itemRef) → \(record.status.rawValue)")
        // A run started from a chat you're looking at reports there; no banner on top of it.
        let shownInChat = AssistantModel.shared.owns(id) && AssistantModel.shared.isLookingAtChat()
        AssistantModel.shared.runFinished(record)
        if presented?.id != id && !shownInChat {
            ToastCenter.shared.show(.init(title: "\(record.actionName): \(record.status.label)", body: record.itemRef, actionTitle: "Show",
                                          onClick: { [weak self] in self?.show(id) },
                                          onAction: { [weak self] in self?.show(id) }), duration: 8)
        }
        Task { await reloadHistory() }
    }

    func cancel(_ id: String) { live[id]?.execution.cancel() }

    func show(_ id: String) {
        model.showDashboard()
        presented = Presented(id: id)
    }

    /// The run to show: live first, then a loaded history entry (loading its output if needed).
    func record(_ id: String) -> AgentRun? {
        if let l = live[id] { return l.record }
        if let r = loaded[id] { return r }
        Task {
            if let r = try? await model.store.agentRun(id: id) { loaded[id] = r }
        }
        return history.first { $0.id == id }
    }

    func isRunning(_ id: String) -> Bool { live[id]?.record.status == .running }

    func delete(_ ids: [String]) {
        Task {
            try? await model.store.deleteAgentRuns(ids: ids)
            for id in ids { loaded[id] = nil; if !isRunning(id) { live[id] = nil } }
            await reloadHistory()
        }
    }

    func clearHistory() {
        Task {
            try? await model.store.deleteAgentRuns()
            loaded = [:]
            live = live.filter { $0.value.record.status == .running }
            await reloadHistory()
        }
    }

    /// Saves a finished run to the brain on demand (when automatic saving is off).
    func saveToBrain(_ id: String) {
        guard var r = record(id), r.status != .running else { return }
        model.writeToBrain("agent run") { r.notePath = try $0.writeAgentRun(r) }
        guard r.notePath != nil else { return }
        loaded[id] = r
        live[id]?.record = r
        Task {
            try? await model.store.saveAgentRun(r)
            await reloadHistory()
        }
    }

    /// The item a run was for, if it's still in the dashboard.
    func item(for run: AgentRun) -> FeedItem? { model.item(withId: run.itemId) }
}
