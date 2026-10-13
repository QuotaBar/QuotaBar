import Foundation

// MARK: - Machine-readable limits, for the CLI and the local API

/// The limits other tools read, after openusage's `/v1/limits`: providers,
/// their windows with used and left percentages, resets and pace. Never a
/// credential, and no account names either.
public enum LimitsJSON {
    public static func make(
        providers: [(id: ProviderID, snapshot: UsageSnapshot?, error: String?)],
        now: Date = Date()) -> Data
    {
        let iso = ISO8601DateFormatter()
        let snapshots = Dictionary(providers.compactMap { item in item.snapshot.map { (item.id, $0) } }, uniquingKeysWith: { _, last in last })
        let projection = XSubscriptionGrouping.project(snapshots, presentProviders: Set(providers.map(\.id)))
        var seen = Set<ProviderID>()
        let shown = providers.compactMap { item -> (id: ProviderID, snapshot: UsageSnapshot?, error: String?)? in
            let owner = projection.owner(for: item.id)
            guard seen.insert(owner).inserted else { return nil }
            let source = projection.authoritativeProviders[owner] ?? owner
            let error = providers.first { $0.id == source }?.error
            return (owner, projection.snapshots[owner], error)
        }
        let body: [String: Any] = [
            "version": 1,
            "generatedAt": iso.string(from: now),
            "providers": shown.map { item -> [String: Any] in
                var provider: [String: Any] = ["id": item.id.rawValue, "name": item.snapshot?.displayName(for: item.id) ?? item.id.displayName]
                if let snapshot = item.snapshot {
                    provider["plan"] = snapshot.planName ?? NSNull()
                    if let edition = snapshot.edition { provider["edition"] = edition }
                    if let source = snapshot.source { provider["source"] = source }
                    if let info = snapshot.xSubscription {
                        provider["plan"] = info.tierLabel
                        provider["sharedWith"] = info.memberProviders.map(\.rawValue)
                        if let sheet = snapshot.balance {
                            provider["balances"] = sheet.balances.map { ["currency": $0.currency, "total": $0.total] as [String: Any] }
                        }
                    }
                    provider["fetchedAt"] = iso.string(from: snapshot.fetchedAt)
                    provider["stale"] = now.timeIntervalSince(snapshot.fetchedAt) > 15 * 60
                    provider["windows"] = snapshot.windows.map { window -> [String: Any] in
                        var entry: [String: Any] = ["id": window.id, "title": window.title]
                        if let used = window.usedPercent {
                            entry["usedPercent"] = snapshot.xSubscription == nil ? (used * 10).rounded() / 10 : used
                            entry["leftPercent"] = snapshot.xSubscription == nil ? ((100 - used) * 10).rounded() / 10 : 100 - used
                        }
                        if let resetsAt = window.resetsAt { entry["resetsAt"] = iso.string(from: resetsAt) }
                        if let seconds = window.windowSeconds { entry["windowSeconds"] = seconds }
                        if let scope = window.scope { entry["scope"] = scope }
                        if let detail = window.detail { entry["detail"] = detail }
                        if let pace = window.pace(now: now), let verdict = pace.verdict {
                            var paceEntry: [String: Any] = [
                                "verdict": verdict.rawValue,
                                "projectedPercentAtReset": (pace.projectedPercent * 10).rounded() / 10,
                            ]
                            if let runOut = pace.runOutSeconds {
                                paceEntry["runsOutAt"] = iso.string(from: now.addingTimeInterval(runOut))
                            }
                            entry["pace"] = paceEntry
                        }
                        return entry
                    }
                }
                if let error = item.error { provider["error"] = error }
                return provider
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
