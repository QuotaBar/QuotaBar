import Foundation

// MARK: - Last readings on disk, so a launch shows numbers at once

/// Where QuotaBar keeps what is not a preference: the last readings, the
/// usage archive, exchange rates. Created 0700 on first use.
public enum AppSupport {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Writes atomically and owner-only: these files name accounts.
    public static func write(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The last good reading per provider. openusage's stale-while-revalidate:
/// the panel opens on these at launch and the first refresh replaces them,
/// so a cold start never shows a column of spinners.
///
/// A reading is worded when it is taken — window names, plan details — so the
/// file remembers the language it was written in, and a launch in the other
/// language starts without it rather than showing the old wording.
public final class SnapshotCache: @unchecked Sendable {
    public static let shared = SnapshotCache()

    private struct File: Codable {
        var language: String
        var snapshots: [String: UsageSnapshot]
    }

    private let lock = NSLock()
    private let fileURL: URL
    private var snapshots: [String: UsageSnapshot]
    private var language: String

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? AppSupport.directory.appendingPathComponent("snapshots.json")
        self.fileURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url), let file = try? decoder.decode(File.self, from: data) {
            self.snapshots = file.snapshots
            self.language = file.language
        } else {
            // Nothing, or the earlier bare map with no language recorded:
            // which language that was is a guess, so it is not shown.
            self.snapshots = [:]
            self.language = Self.currentLanguage
        }
    }

    private static var currentLanguage: String { L10n.isChinese ? "zh" : "en" }

    public func snapshot(for id: ProviderID) -> UsageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard language == Self.currentLanguage else { return nil }
        return snapshots[id.rawValue]
    }

    public func store(_ snapshot: UsageSnapshot, for id: ProviderID) {
        write { snapshots in snapshots[id.rawValue] = snapshot }
    }

    public func remove(_ id: ProviderID) {
        write { snapshots in snapshots[id.rawValue] = nil }
    }

    private func write(_ change: (inout [String: UsageSnapshot]) -> Void) {
        lock.lock()
        let current = Self.currentLanguage
        // Readings in the other language are no use to this one.
        if language != current {
            snapshots = [:]
            language = current
        }
        change(&snapshots)
        let file = File(language: language, snapshots: snapshots)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(file) { AppSupport.write(data, to: fileURL) }
    }
}
