import Foundation

/// Pure snapshot comparison. Kept free of storage so it's trivially testable.
public enum Differ {
    public struct Output: Sendable {
        public var changes: [ItemChange]
        public var events: [AppEvent]
    }

    /// - Parameters:
    ///   - previous: items stored for this scope (present or not), keyed by id.
    ///   - presentIDs: ids that were present in the last snapshot of this scope.
    ///   - seenIDs: ids ever seen in this scope.
    ///   - baseline: first sync of the scope — record state but emit no events.
    public static func diff(result: ScopeResult, previous: [String: FeedItem], presentIDs: Set<String>,
                            seenIDs: Set<String>, baseline: Bool,
                            rule: (ItemChange) -> [AppEvent]) -> Output {
        var changes: [ItemChange] = []
        var events: [AppEvent] = []
        var emitted = Set<String>()
        for item in result.items {
            let change = ItemChange(scope: result.scope, old: previous[item.id], new: item,
                                    wasPresent: presentIDs.contains(item.id), everSeen: seenIDs.contains(item.id))
            changes.append(change)
            guard !baseline else { continue }
            for e in rule(change) where emitted.insert(e.id).inserted {
                var e = e
                e.scope = e.scope ?? result.scope
                e.itemId = e.itemId ?? item.id
                events.append(e)
            }
        }
        return Output(changes: changes, events: events)
    }
}
