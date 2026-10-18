import Foundation

/// Runs one fetch through the differ and store. Shared by the poller and `everboard-cli poll`.
public enum Engine {
    public static func process(source: DataSource, results: [ScopeResult], store: Store, config: AppConfig,
                               persist: Bool = true) async throws -> [AppEvent] {
        var newEvents: [AppEvent] = []
        for result in results {
            let state = try await store.scopeState(result.scope)
            let out = Differ.diff(result: result, previous: state.previous, presentIDs: state.present,
                                  seenIDs: state.seen, baseline: !state.synced) { source.events(for: $0, config: config) }
            if persist {
                newEvents += try await store.apply(result, events: out.events)
            } else {
                newEvents += out.events
            }
        }
        return newEvents
    }
}

public struct PollUpdate: Sendable {
    public var sourceId: String
    public var health: SourceHealth
    public var newEvents: [AppEvent]
}

/// Background polling loop per source with exponential backoff on errors.
public actor Poller {
    private let store: Store
    private var config: AppConfig
    private var sources: [String: DataSource] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    private var running: Set<String> = []
    private let onUpdate: @Sendable (PollUpdate) async -> Void

    public init(store: Store, config: AppConfig, onUpdate: @escaping @Sendable (PollUpdate) async -> Void) {
        self.store = store
        self.config = config
        self.onUpdate = onUpdate
    }

    /// Replace the set of sources (e.g. after settings or secrets change) and restart all loops.
    public func configure(sources newSources: [DataSource], config: AppConfig) {
        self.config = config
        loops.values.forEach { $0.cancel() }
        loops = [:]
        failures = [:]
        sources = Dictionary(uniqueKeysWithValues: newSources.map { ($0.id, $0) })
        for id in sources.keys { startLoop(id) }
    }

    public func updateConfig(_ config: AppConfig) { self.config = config }

    /// Poll now (all sources, or one) — used on wake, network change and the Refresh button.
    public func refreshNow(_ id: String? = nil) {
        for sid in id.map({ [$0] }) ?? Array(sources.keys) where sources[sid] != nil {
            failures[sid] = 0
            loops[sid]?.cancel()
            startLoop(sid)
        }
    }

    public func stop() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
    }

    private func startLoop(_ id: String) {
        loops[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce(id)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Returns seconds until the next poll.
    private func pollOnce(_ id: String) async -> TimeInterval {
        guard let source = sources[id] else { return 3600 }
        // A refresh can restart the loop while a fetch is still in flight; don't run two at once.
        guard running.insert(id).inserted else { return source.interval }
        defer { running.remove(id) }
        let cfg = config
        do {
            let results = try await source.fetch(context: StoreFetchContext(store: store, config: cfg))
            let events = try await Engine.process(source: source, results: results, store: store, config: cfg)
            failures[id] = 0
            await onUpdate(PollUpdate(sourceId: id, health: .ok(Date()), newEvents: events))
            return source.interval
        } catch is CancellationError {
            return source.interval
        } catch {
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            let health: SourceHealth
            var delay = min(source.interval * pow(2, Double(n - 1)), 900)
            switch error {
            case HTTPError.unreachable:
                // Self-hosted GitLab behind a VPN is the usual cause.
                health = .unreachable("\(source.displayName) unreachable" + (id.hasPrefix("gitlab") ? " — VPN?" : ""))
            case HTTPError.unauthorized(let code):
                health = .authFailed("\(source.displayName) auth failed (\(code)) — check token")
                delay = 900
            case HTTPError.rateLimited(let retry):
                health = .failing("\(source.displayName) rate limited")
                delay = retry ?? delay
            default:
                health = .failing("\(source.displayName): \(error.localizedDescription)")
            }
            await onUpdate(PollUpdate(sourceId: id, health: health, newEvents: []))
            return delay
        }
    }
}
