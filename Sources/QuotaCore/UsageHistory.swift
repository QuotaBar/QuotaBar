import Foundation

// MARK: - Usage history (sparkline source)

public struct UsageReading: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var percent: Double

    public init(t: TimeInterval, percent: Double) {
        self.t = t
        self.percent = percent
    }
}

/// Append-only per-provider reading log persisted next to the config file.
/// Capped so the file stays tiny; powers the detail sparkline.
///
/// Stored keyed by the provider's raw value rather than by `ProviderID`:
/// `Codable` flattens a dictionary with a non-`String` key into an array,
/// which round-trips but produces an unreadable file.
public final class UsageHistoryStore: @unchecked Sendable {
    public static let shared = UsageHistoryStore()

    private static let cap = 400
    private let lock = NSLock()
    private var data: [String: [UsageReading]]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotabar/history.json")
        self.fileURL = url
        self.data = UsageHistoryStore.load(url)
    }

    /// Reads the current object format, falling back to the flat-array format
    /// written by earlier builds so existing trend lines are not lost.
    private static func load(_ url: URL) -> [String: [UsageReading]] {
        guard let raw = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        if let object = try? decoder.decode([String: [UsageReading]].self, from: raw) {
            return object
        }
        guard let legacy = try? JSONSerialization.jsonObject(with: raw) as? [Any] else { return [:] }
        var result: [String: [UsageReading]] = [:]
        for index in stride(from: 0, to: legacy.count - 1, by: 2) {
            guard let key = legacy[index] as? String,
                  let rows = legacy[index + 1] as? [[String: Any]] else { continue }
            result[key] = rows.compactMap { row in
                guard let t = row["t"] as? TimeInterval,
                      let percent = row["percent"] as? Double else { return nil }
                return UsageReading(t: t, percent: percent)
            }
        }
        return result
    }

    public func record(_ id: ProviderID, percent: Double, at date: Date = Date()) {
        lock.lock()
        var readings = data[id.rawValue] ?? []
        readings.append(UsageReading(t: date.timeIntervalSince1970, percent: percent))
        if readings.count > Self.cap {
            readings.removeFirst(readings.count - Self.cap)
        }
        data[id.rawValue] = readings
        let snapshot = data
        lock.unlock()
        save(snapshot)
    }

    public func readings(for id: ProviderID, limit: Int = 96) -> [UsageReading] {
        lock.lock(); defer { lock.unlock() }
        return Array((data[id.rawValue] ?? []).suffix(limit))
    }

    /// Forgets every provider's trend.
    public func clearAll() {
        lock.lock()
        data.removeAll()
        let snapshot = data
        lock.unlock()
        save(snapshot)
    }

    /// Forgets a provider's trend — used when its credential is replaced,
    /// since a new credential may well be a different account.
    public func clear(_ id: ProviderID) {
        lock.lock()
        data[id.rawValue] = nil
        let snapshot = data
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: [String: [UsageReading]]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(snapshot)
            try encoded.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path)
        } catch {
            // History is best-effort; never crash or spam over it.
        }
    }
}
