import Foundation

// MARK: - The Antigravity CLI

/// The quota as the Antigravity CLI (`agy`) reports it, for people who use
/// the CLI without the app: `agy -p /usage --output-format json`, the
/// non-interactive report Google added in agy 1.1.11. It sends no prompt and
/// spends nothing; it is run in an empty folder of its own, so no project's
/// settings or tools come with it. Starting agy takes a few seconds, so a
/// reading is kept for five minutes.
enum AntigravityCLI {
    static let maxAge: TimeInterval = 300

    static func executable() -> String? {
        ToolRunner.locate("agy")
    }

    private static let cache = Cache()

    /// The report, or nil when agy is missing, signed out, too old for the
    /// report, or does not answer within a minute and a half.
    static func read(now: Date = .now) async -> UsageSnapshot? {
        if let cached = cache.reading(now: now) { return cached }
        guard let agy = executable() else { return nil }
        let snapshot = await Task.detached { () -> UsageSnapshot? in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuotaBar-agy-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let result = ToolRunner.run(agy, ["-p", "/usage", "--output-format", "json"], timeout: 90, in: folder),
                  result.status == 0
            else { return nil }
            return try? parseReport(result.output)
        }.value
        if let snapshot { cache.store(snapshot, now: now) }
        return snapshot
    }

    /// `{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":
    /// "Gemini Models","buckets":[{"window":"weekly","remaining_fraction":0.86,
    /// "reset_time":"2026-09-17T18:40:27Z"},{"window":"5h",…}]},{"name":
    /// "Claude and GPT models",…}]}}}` — the same groups the app's own quota
    /// summary has, so the card reads the same whichever one answered.
    static func parseReport(_ data: Data) throws -> UsageSnapshot {
        struct Bucket: Decodable {
            let id: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let disabled: Bool?
        }
        struct Group: Decodable {
            let name: String?
            let buckets: [Bucket]?
        }
        struct Usage: Decodable { let groups: [Group]? }
        struct Command: Decodable {
            let name: String?
            let data: Usage?
        }
        struct Report: Decodable {
            let status: String?
            let command: Command?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report = try? decoder.decode(Report.self, from: data),
              report.status == "SUCCESS", report.command?.name == "usage"
        else { throw ProviderError.badResponse }
        var windows: [UsageWindow] = []
        for group in report.command?.data?.groups ?? [] {
            let scope = AntigravityLocal.groupName(group.name)
            let buckets = (group.buckets ?? []).compactMap { bucket -> (Int, Bucket)? in
                guard bucket.disabled != true, bucket.remainingFraction != nil,
                      let seconds = AntigravityLocal.windowSeconds(bucket.window ?? bucket.id)
                else { return nil }
                return (seconds, bucket)
            }
            for (seconds, bucket) in buckets.sorted(by: { $0.0 < $1.0 }) {
                let remaining = min(max(bucket.remainingFraction ?? 0, 0), 1)
                windows.append(UsageWindow(
                    title: "\(WindowTitle.forSeconds(seconds)) · \(scope)",
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: LocalCredentials.parseFlexibleISO(bucket.resetTime),
                    windowSeconds: seconds,
                    scope: scope))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows, source: "agy")
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (snapshot: UsageSnapshot, readAt: Date)?

        func reading(now: Date) -> UsageSnapshot? {
            lock.withLock {
                guard let last, now.timeIntervalSince(last.readAt) < AntigravityCLI.maxAge else { return nil }
                return last.snapshot
            }
        }

        func store(_ snapshot: UsageSnapshot, now: Date) {
            lock.withLock { last = (snapshot, now) }
        }
    }
}
