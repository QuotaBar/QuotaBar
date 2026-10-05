import Darwin
import Foundation

/// Claude Code's access token lasts eight hours, and only Claude Code renews
/// it — while it runs. Left alone longer than that, the card could read
/// nothing until `claude` was run again. So once the token has run out,
/// QuotaBar has Claude Code renew it, the way CodexBar does: start it in a
/// terminal of QuotaBar's own, in a folder of QuotaBar's own, ask for
/// `/status`, and watch the keychain item change.
///
/// Claude Code renews under its own lock and writes its own item. QuotaBar
/// never spends the refresh token, so the two can never race for it.
public enum ClaudeCodeRenewal {
    public enum Outcome: Sendable, Equatable {
        case renewed
        /// The token is still good.
        case notNeeded
        /// Tried within the last half hour.
        case coolingDown
        case noClaudeCode
        case failed(String)
    }

    /// One launch at a time, at most one every half hour: a renewal that
    /// does not take (signed out, offline) must not start Claude Code at
    /// every refresh.
    static let cooldown: TimeInterval = 30 * 60
    private static let gate = Gate()

    actor Gate {
        private var running: Task<Outcome, Never>?

        func run(now: Date, _ attempt: @escaping @Sendable () async -> Outcome) async -> Outcome {
            if let running { return await running.value }
            if let last = ClaudeCodeRenewal.lastAttempt, now.timeIntervalSince(last.at) < ClaudeCodeRenewal.cooldown {
                return .coolingDown
            }
            ClaudeCodeRenewal.record(at: now, outcome: "started")
            let task = Task { await attempt() }
            running = task
            let outcome = await task.value
            running = nil
            ClaudeCodeRenewal.record(at: now, outcome: "\(outcome)")
            return outcome
        }
    }

    /// The last launch, kept in the app's defaults: the half hour holds
    /// across a restart, and `defaults read bar.quota.QuotaBar
    /// claudeRenewalLastAttempt` says how the last one went.
    static let defaultsKey = "claudeRenewalLastAttempt"

    public static var lastAttempt: (at: Date, outcome: String)? {
        guard let entry = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let at = entry["at"] as? Date, let outcome = entry["outcome"] as? String
        else { return nil }
        return (at, outcome)
    }

    static func record(at date: Date, outcome: String) {
        UserDefaults.standard.set(["at": date, "outcome": outcome], forKey: defaultsKey)
    }

    /// Renews the card's sign-in when its token has run out (or is about to).
    public static func renewIfExpired(now: Date = .now) async -> Outcome {
        let lookup = LocalCredentials.readClaudeNow()
        guard lookup.state == .available, let expiry = lookup.expiresAt, expiry <= now.addingTimeInterval(60) else {
            return .notNeeded
        }
        let expired = lookup.token
        return await gate.run(now: now) {
            await renew(replacing: expired, force: false)
        }
    }

    /// `--claude-renewal`: the whole launch, whether or not the token needs
    /// it. Claude Code leaves a good token as it is, so this only shows the
    /// launch working.
    public static func trial() async -> Outcome {
        await renew(replacing: LocalCredentials.readClaudeNow().token, force: true)
    }

    private static func renew(replacing token: String?, force: Bool) async -> Outcome {
        guard let binary = claudeBinary() else { return .noClaudeCode }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Session(binary: binary).run(replacing: token, force: force))
            }
        }
    }

    // MARK: Finding Claude Code

    static func claudeBinary(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        var candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
        ]
        // The native installer's newest build is the binary itself.
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        if let newest = ((try? fm.contentsOfDirectory(atPath: versions.path)) ?? [])
            .max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        {
            candidates.append(versions.appendingPathComponent(newest))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func supportsSafeMode(_ binary: URL) -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("--safe-mode")
    }

    /// QuotaBar's own empty folder: the only one it ever tells Claude Code
    /// to trust.
    static var workingDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar/claude-renewal", isDirectory: true)
    }

    // MARK: The terminal

    /// What the screen asks of the trust dialog Claude Code shows in a folder
    /// it has not seen: `nil` when it is not up, Enter once the marker is on
    /// "Yes, I trust this folder", an arrow toward it before then. Pure.
    static func trustKeys(screen: String) -> String? {
        let flat = normalized(screen)
        guard flat.contains("yes,itrustthisfolder") else { return nil }
        // The last marker drawn is the one on screen.
        guard let marker = screen.range(of: "❯", options: .backwards) else { return nil }
        let after = normalized(String(screen[marker.upperBound...].prefix(80)))
        if after.hasPrefix("yes,itrust") { return "\r" }
        return "\u{1b}[B"
    }

    /// Escape sequences out, for reading what is drawn.
    static func plainText(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\x{1B}\[[0-9;?<>=]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}[()][A-Z0-9]|\x{1B}[=>]"#, with: "", options: .regularExpression)
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    /// One launch, start to finish, on a thread of its own.
    final class Session {
        let binary: URL
        private var primary: Int32 = -1
        private var process: Process?
        private var screen = ""

        init(binary: URL) {
            self.binary = binary
        }

        func run(replacing token: String?, force: Bool) -> Outcome {
            let directory = ClaudeCodeRenewal.workingDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { stop() }
            do { try start(in: directory) } catch { return .failed(error.localizedDescription) }

            let started = Date()
            let deadline = started.addingTimeInterval(25)
            var trustAnswers = 0
            var trustedAt: Date?
            var statusSent = false
            var lastKeychainLook = Date.distantPast
            while Date() < deadline {
                drain()
                guard process?.isRunning == true else {
                    return renewed(from: token) ? .renewed : .failed("Claude Code exited before renewing.")
                }
                if let keys = ClaudeCodeRenewal.trustKeys(screen: String(screen.suffix(1_500))) {
                    // A few steps at most; Enter only once the marker is on Yes.
                    guard trustAnswers < 6 else { return .failed("Claude Code's folder trust dialog did not answer.") }
                    send(keys)
                    trustAnswers += 1
                    if keys == "\r" {
                        trustedAt = Date()
                        screen = ""
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                // Ready to type once the screen has settled after start-up or the dialog.
                let readyAt = (trustedAt ?? started).addingTimeInterval(trustedAt == nil ? 4 : 3)
                // Never typed into the trust dialog: Enter there would pick its default, "No, exit".
                let dialogUp = trustedAt == nil && ClaudeCodeRenewal.normalized(String(screen.suffix(1_500))).contains("trustthisfolder")
                if !statusSent, !dialogUp, Date() >= readyAt {
                    send("/status\r")
                    statusSent = true
                }
                if !force, Date().timeIntervalSince(lastKeychainLook) >= 0.5 {
                    lastKeychainLook = Date()
                    if renewed(from: token) { return .renewed }
                }
                if force, statusSent, Date().timeIntervalSince(readyAt) > 4 {
                    return renewed(from: token) ? .renewed : .notNeeded
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return renewed(from: token) ? .renewed : .failed("Claude Code did not renew its sign-in in time.")
        }

        private func renewed(from token: String?) -> Bool {
            let now = LocalCredentials.readClaudeNow()
            guard now.state == .available, let fresh = now.token, fresh != token else { return false }
            return (now.expiresAt ?? .distantFuture) > Date()
        }

        private func start(in directory: URL) throws {
            var primaryFD: Int32 = -1
            var secondaryFD: Int32 = -1
            var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
                throw RenewalError("Could not open a terminal for Claude Code.")
            }
            _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)
            primary = primaryFD
            let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

            let process = Process()
            process.executableURL = binary
            // Safe mode leaves out hooks, MCP servers, plugins and the rest
            // of the owner's customizations; sign-in works as ever. An older
            // Claude Code without it still skips the MCP servers.
            var arguments = ["--strict-mcp-config", "--settings", #"{"remoteControlAtStartup":false}"#]
            if ClaudeCodeRenewal.supportsSafeMode(binary) { arguments.insert("--safe-mode", at: 0) }
            process.arguments = arguments
            process.currentDirectoryURL = directory
            // The card's sign-in is the default config dir's, read the way a
            // fresh Claude Code would: nothing from a session QuotaBar was
            // started in (a config dir, a parent session's markers, an API key).
            var environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !key.hasPrefix("CLAUDE") && !key.hasPrefix("ANTHROPIC_")
            }
            environment["TERM"] = "xterm-256color"
            environment["PWD"] = directory.path
            environment["PATH"] = (environment["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.standardInput = secondary
            process.standardOutput = secondary
            process.standardError = secondary
            try process.run()
            // Its own group, so stopping it stops whatever it started.
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            self.process = process
            try? secondary.close()
        }

        private func drain() {
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = read(primary, &buffer, buffer.count)
                guard count > 0 else { break }
                debugLog(Data(buffer[0..<count]))
                screen += ClaudeCodeRenewal.plainText(String(decoding: buffer[0..<count], as: UTF8.self))
            }
            if screen.count > 20_000 { screen = String(screen.suffix(10_000)) }
        }

        private func send(_ keys: String) {
            debugLog(Data("\n<<sent \(keys.debugDescription)>>\n".utf8))
            let bytes = Array(keys.utf8)
            _ = bytes.withUnsafeBufferPointer { write(primary, $0.baseAddress, $0.count) }
        }

        /// `QUOTABAR_RENEWAL_LOG=<file>`: the terminal as Claude Code drew
        /// it, and the keys sent, for when a renewal will not take.
        private func debugLog(_ data: Data) {
            guard let path = ProcessInfo.processInfo.environment["QUOTABAR_RENEWAL_LOG"] else { return }
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }

        private func stop() {
            if let process, process.isRunning {
                // Close the status panel, then quit the way a person would.
                send("\u{1b}")
                Thread.sleep(forTimeInterval: 0.3)
                send("\u{3}")
                Thread.sleep(forTimeInterval: 0.3)
                send("\u{3}")
                let quitBy = Date().addingTimeInterval(2)
                while process.isRunning, Date() < quitBy { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning {
                    kill(-process.processIdentifier, SIGTERM)
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { kill(-process.processIdentifier, SIGKILL) }
                }
            }
            if primary >= 0 { close(primary); primary = -1 }
        }
    }

    struct RenewalError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
