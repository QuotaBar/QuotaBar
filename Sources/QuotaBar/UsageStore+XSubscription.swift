import Foundation
import QuotaCore

@MainActor
extension UsageStore {
    /// Raw readings keep their own credentials, cache and refresh lifecycle.
    /// Every visible surface uses this same projection of verified shared seats.
    var subscriptionProjection: XSubscriptionGrouping.Projection {
        XSubscriptionGrouping.project(Dictionary(uniqueKeysWithValues: enabled.compactMap { id in
            states[id]?.snapshot.map { (id, reported[id] ?? $0) }
        }), presentProviders: Set(enabled))
    }

    func displayProvider(_ id: ProviderID) -> ProviderID {
        subscriptionProjection.owner(for: id)
    }

    func displayProviders(_ ids: [ProviderID]) -> [ProviderID] {
        let projection = subscriptionProjection
        var seen = Set<ProviderID>()
        return ids.compactMap { id in
            let owner = projection.owner(for: id)
            return seen.insert(owner).inserted ? owner : nil
        }
    }

    func displayPhase(for id: ProviderID) -> ProviderPhase? {
        let projection = subscriptionProjection
        let owner = projection.owner(for: id)
        guard let raw = projection.snapshots[owner] else { return states[owner] }
        let snapshot = raw.hiding(experience.hiddenWindows[owner.rawValue])
        let source = projection.authoritativeProviders[owner] ?? owner
        switch states[source] {
        case let .stale(_, error): return .stale(snapshot, error: error)
        default: return .loaded(snapshot)
        }
    }

    func displayName(for id: ProviderID) -> String {
        displayPhase(for: id)?.snapshot?.displayName(for: id) ?? id.displayName
    }
}
