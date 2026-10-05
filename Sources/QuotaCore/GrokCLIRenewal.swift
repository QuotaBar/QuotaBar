import Foundation

/// The grok CLI's sign-in lasts six hours, and only the CLI renews it — when
/// it runs. Left alone longer, the Grok card said the session had expired.
/// So once the token has run out, QuotaBar runs `grok models`: listing the
/// models costs nothing, and the CLI renews an expired token before it asks
/// anything (checked on 1.0.46: its pre-request refresh runs at start-up,
/// under the CLI's own `auth.json.lock`, before the command returns).
public enum GrokCLIRenewal {
    public typealias Outcome = CLIRenewal.Outcome

    /// `defaults read bar.quota.QuotaBar grokRenewalLastAttempt`
    static let defaultsKey = "grokRenewalLastAttempt"
    private static let gate = CLIRenewal.Gate(key: defaultsKey)

    public static var lastAttempt: (at: Date, outcome: String)? {
        CLIRenewal.lastAttempt(defaultsKey)
    }

    /// Renews the CLI's sign-in when its token has run out (or is about to).
    public static func renewIfExpired(now: Date = .now) async -> Outcome {
        guard let auth = LocalCredentials.grokAuth(), let expiry = auth.expiresAt,
              expiry <= now.addingTimeInterval(60)
        else { return .notNeeded }
        let expired = auth.accessToken
        return await gate.run(now: now) {
            await renew(replacing: expired)
        }
    }

    /// `--grok-renewal`: the launch, whether or not the token needs it. The
    /// CLI leaves a good token as it is, so this only shows it running.
    public static func trial() async -> Outcome {
        await renew(replacing: LocalCredentials.grokAuth()?.accessToken)
    }

    private static func renew(replacing token: String?) async -> Outcome {
        guard let binary = grokBinary() else { return .noCLI }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(binary, replacing: token))
            }
        }
    }

    private static func run(_ binary: URL, replacing token: String?) -> Outcome {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["models"]
        process.currentDirectoryURL = CLIRenewal.workingDirectory("grok-renewal")
        // The CLI's own home and sign-in, not one a parent shell pointed at.
        process.environment = ProcessInfo.processInfo.environment.filter { key, _ in !key.hasPrefix("GROK_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            return .failed("The grok CLI did not finish in time.")
        }
        guard let fresh = LocalCredentials.grokAuth() else { return .failed("The grok CLI signed out.") }
        let good = (fresh.expiresAt ?? .distantFuture) > Date().addingTimeInterval(60)
        if fresh.accessToken != token, good { return .renewed }
        // Still the token it had, and still good: there was nothing to renew.
        return good ? .notNeeded : .failed("The grok CLI did not renew its sign-in.")
    }

    static func grokBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        CLIRenewal.firstExecutable([
            home.appendingPathComponent(".grok/bin/grok"),
            home.appendingPathComponent(".local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ])
    }
}
