import Foundation

/// What Claude Code and the grok CLI have in common: a sign-in that runs out
/// after a few hours, renewed only by the CLI itself, when it runs. QuotaBar
/// has the CLI renew it rather than spending the refresh token itself, so
/// the two can never race for it (see `ClaudeCodeRenewal`, `GrokCLIRenewal`).
public enum CLIRenewal {
    public enum Outcome: Sendable, Equatable {
        case renewed
        /// The token is still good.
        case notNeeded
        /// Tried within the last half hour.
        case coolingDown
        /// The CLI is not installed where its installers put it.
        case noCLI
        case failed(String)
    }

    /// One launch at a time, at most one every half hour: a renewal that
    /// does not take (signed out, offline) must not start the CLI at every
    /// refresh.
    static let cooldown: TimeInterval = 30 * 60

    actor Gate {
        let key: String
        private var running: Task<Outcome, Never>?

        init(key: String) {
            self.key = key
        }

        func run(now: Date, _ attempt: @escaping @Sendable () async -> Outcome) async -> Outcome {
            if let running { return await running.value }
            if let last = CLIRenewal.lastAttempt(key), now.timeIntervalSince(last.at) < CLIRenewal.cooldown {
                return .coolingDown
            }
            CLIRenewal.record(key, at: now, outcome: "started")
            let task = Task { await attempt() }
            running = task
            let outcome = await task.value
            running = nil
            CLIRenewal.record(key, at: now, outcome: "\(outcome)")
            return outcome
        }
    }

    /// The last launch, kept in the app's defaults: the half hour holds
    /// across a restart, and `defaults read bar.quota.QuotaBar <key>` says
    /// how the last one went.
    public static func lastAttempt(_ key: String) -> (at: Date, outcome: String)? {
        guard let entry = UserDefaults.standard.dictionary(forKey: key),
              let at = entry["at"] as? Date, let outcome = entry["outcome"] as? String
        else { return nil }
        return (at, outcome)
    }

    static func record(_ key: String, at date: Date, outcome: String) {
        UserDefaults.standard.set(["at": date, "outcome": outcome], forKey: key)
    }

    static func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A folder of QuotaBar's own to start a CLI in.
    static func workingDirectory(_ name: String) -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
