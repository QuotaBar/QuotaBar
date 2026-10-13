import AppKit
import Foundation
import QuotaCore

/// Reads only the two existing sign-ins, using the same providers as the app.
/// Its private cache models a restart without replacing any real account data.
@MainActor
enum XSubscriptionCheck {
    static func run(directory: String) {
        Task {
            let config = ConfigStore.shared
            var states: [ProviderID: ProviderPhase] = [:]
            await withTaskGroup(of: (ProviderID, ProviderPhase).self) { group in
                for id in [ProviderID.cursor, .grok] {
                    group.addTask {
                        do { return (id, .loaded(try await ProviderRegistry.make(id).fetch(config: config))) }
                        catch { return (id, .failed(error.localizedDescription)) }
                    }
                }
                for await (id, state) in group { states[id] = state }
            }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let cacheFile = url.appendingPathComponent("private-cache.json")
            let cache = SnapshotCache(fileURL: cacheFile)
            for (id, state) in states { if let snapshot = state.snapshot { cache.store(snapshot, for: id) } }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
            let restored = SnapshotCache(fileURL: cacheFile)
            for id in [ProviderID.cursor, .grok] {
                if let snapshot = restored.snapshot(for: id) { states[id] = .loaded(snapshot) }
            }
            let store = UsageStore.preview(enabled: [.cursor, .grok], states: states)
            let ids = store.displayProviders(store.enabled)
            let cloud = store.cloudReadings()
            let encoded = try? JSONEncoder().encode(cloud)
            let decoded = encoded.flatMap { try? JSONDecoder().decode(CloudReadings.self, from: $0) }
            let phone = MergedReadings(decoded.map { [$0] } ?? [])
            let projection = store.subscriptionProjection
            var result: [String: Any] = [
                "checkedAt": ISO8601DateFormatter().string(from: Date()),
                "rawProviders": states.keys.map(\.rawValue).sorted(),
                "macProviders": ids.map(\.rawValue),
                "phoneProvidersAfterReload": phone.items.map { $0.provider.rawValue },
                "sameVerifiedSeat": projection.aliases[.cursor] == .grok,
                "oldCursorSelectionResolves": phone.item(for: .cursor)?.provider == .grok,
                "errors": states.compactMapValues(\.errorMessage).map { ["provider": $0.key.rawValue, "message": $0.value] },
            ]
            if let snapshot = store.displayPhase(for: .grok)?.snapshot {
                result["name"] = snapshot.displayName(for: .grok)
                result["plan"] = snapshot.chipLabel
                result["windowCount"] = snapshot.windows.count
                result["usedPercent"] = snapshot.headlinePercent ?? NSNull() as Any
                result["usedCaption"] = snapshot.headlinePercent.map(QuotaFormat.percent) ?? "—"
                result["balances"] = snapshot.balance?.balances.map { ["currency": $0.currency, "total": $0.total] as [String: Any] } ?? []
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url.appendingPathComponent("verification.json"))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
