import Darwin
import Foundation

// MARK: - What the Kimi Code source runs on

/// The file system, network and clock the Kimi Code sign-in is read and
/// renewed with. `live` is this Mac; tests pass throwaway directories, a
/// scripted `send` and a clock of their own.
public struct KimiCodeEnvironment: Sendable {
    public var codeHome: URL
    public var legacyHome: URL
    public var send: HTTPSend
    public var now: @Sendable () -> Date
    /// The clock that stops while the Mac sleeps, as a lock holder's timer
    /// does: what a stale lock's second look is timed by.
    public var uptime: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// How long a refresh waits for a renewal Kimi Code is in the middle of.
    /// Kimi Code itself waits a minute; a background refresh has less
    /// patience, and trying again at the next refresh costs nothing.
    public var lockWait: TimeInterval
    public var lockRetry: TimeInterval
    public var touchInterval: TimeInterval
    /// For the User-Agent and `X-Msh-Version`.
    public var appVersion: String
    public var renewal: KimiCodeRenewal
    /// Whether a read may renew the sign-in at all. Only the running app
    /// may (`KimiCodeRenewal.allowInThisProcess`): a one-off command can be
    /// timed out or killed with its request out, losing a refresh token the
    /// server has already rotated, so it only reads.
    public var mayRenew: Bool
    /// The last reading kept on disk, which tells a pasted credential's
    /// edition before this run of the app has asked.
    public var lastReading: @Sendable () -> UsageSnapshot?

    public init(
        codeHome: URL,
        legacyHome: URL,
        send: @escaping HTTPSend,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = KimiCodeEnvironment.realSleep,
        lockWait: TimeInterval = 15,
        lockRetry: TimeInterval = KimiCodeLock.retryInterval,
        touchInterval: TimeInterval = KimiCodeLock.touchInterval,
        appVersion: String? = nil,
        renewal: KimiCodeRenewal = .shared,
        mayRenew: Bool = true,
        lastReading: @escaping @Sendable () -> UsageSnapshot? = { nil })
    {
        self.codeHome = codeHome
        self.legacyHome = legacyHome
        self.send = send
        self.now = now
        self.uptime = uptime
        self.sleep = sleep
        self.lockWait = lockWait
        self.lockRetry = lockRetry
        self.touchInterval = touchInterval
        self.appVersion = appVersion ?? KimiCodeIdentity.appVersion
        self.renewal = renewal
        self.mayRenew = mayRenew
        self.lastReading = lastReading
    }

    public static var live: KimiCodeEnvironment {
        KimiCodeEnvironment(
            codeHome: LocalCredentials.kimiCodeHome,
            legacyHome: LocalCredentials.kimiLegacyHome,
            send: HTTP.live,
            mayRenew: KimiCodeRenewal.isAllowedInThisProcess,
            lastReading: { SnapshotCache.shared.snapshot(for: .kimi) })
    }

    public static let realSleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Whether QuotaBar may renew a sign-in

public enum KimiCodeRenewability: Sendable {
    case renewable(KimiCodeRenewal.Context)
    case readOnly(Reason)

    public enum Reason: Sendable, Equatable {
        /// The older Python CLI's file in `~/.kimi`: a separate sign-in that
        /// Kimi Code no longer uses, with a lock of its own.
        case olderCLI
        /// No refresh token, or one that has run out.
        case cannotRenew
        /// Not the sign-in `~/.kimi-code/config.toml` says Kimi Code uses,
        /// or one for hosts QuotaBar does not know.
        case notInUse
        /// Kimi Code has not given this Mac its device id yet.
        case noDeviceID
    }

    public var isRenewable: Bool {
        if case .renewable = self { return true }
        return false
    }
}

// MARK: - Renewing

/// Renews the Kimi Code sign-in the way Kimi Code does (`OAuthManager` in
/// its `packages/oauth`), so the two can take turns on one refresh token:
///
/// 1. Read the credential file. Nothing to do when it no longer needs
///    renewing — someone else renewed it.
/// 2. Take Kimi Code's lock (`KimiCodeLock`), watching the file while
///    waiting: a renewal that lands meanwhile ends the wait.
/// 3. Read the file again under the lock, and stop if the work is done.
/// 4. `POST {oauthHost}/api/oauth/token` with the refresh token, three
///    tries for a network or server failure — a try after the first only
///    while the lock is still QuotaBar's.
/// 5. Save what comes back at once, in Kimi Code's own format: the refresh
///    token has already been rotated on the server. A save that fails is
///    kept in memory and made before anything else is sent.
///
/// A refused renewal (401, 403, `invalid_grant`) is looked at again 100 ms
/// later, in case Kimi Code renewed first; otherwise it means signing in
/// again. Unlike Kimi Code, QuotaBar then writes nothing — no signed-out
/// marker — and leaves the file for Kimi Code to judge. Nothing is ever
/// written without the lock, over a file that was removed or holds another
/// live sign-in, or for hosts other than Kimi Code's own.
///
/// Only the running app renews (`allowInThisProcess`), and quitting waits
/// for a request that is out (`stop`, `waitForRequests`).
public final class KimiCodeRenewal: @unchecked Sendable {
    public static let shared = KimiCodeRenewal()

    /// Kimi Code's public OAuth client, the one its sign-in was issued to.
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// A refused refresh token is not sent again for this long.
    static let refusalMemory: TimeInterval = 300

    public struct Context: Sendable {
        public let slot: KimiCodeSlot
        public let codeHome: URL
        public let deviceID: String

        public var credentialsFile: URL {
            codeHome.appendingPathComponent("credentials/\(slot.storageName).json")
        }

        /// proper-lockfile's target; the lock itself is this plus `.lock`.
        public var lockSentinel: URL {
            codeHome.appendingPathComponent("oauth/\(slot.storageName)")
        }

        public var lockDirectory: URL {
            codeHome.appendingPathComponent("oauth/\(slot.storageName).lock")
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Signed out, refused, or nothing left to renew with.
        case signInAgain
        /// Kimi Code held the lock for the whole wait.
        case busy
        /// The network, the server or its reply; the detail names no secret.
        case unavailable(String)
    }

    public struct Outcome: Sendable, Equatable {
        public let accessToken: String
        /// Renewed by this call, rather than found renewed.
        public let renewedHere: Bool
    }

    private let state = NSLock()
    private var tail: Task<Void, Never>?
    private var refused: [String: Date] = [:]
    /// Renewals the server granted that could not be saved, by credential
    /// file: the only copy of the rotated refresh token.
    private var unsaved: [String: Unsaved] = [:]
    /// Requests out whose reply may carry rotated tokens, and those replies
    /// until saved.
    private var requestsOut = 0
    private var stopping = false

    public init() {}

    private struct Unsaved {
        let renewed: RenewedToken
        /// The refresh token the renewal spent, still the one on disk.
        let replacing: String
    }

    // MARK: Which process renews

    private static let processLock = NSLock()
    nonisolated(unsafe) private static var allowedInProcess = false

    /// Renewing is for the menu-bar app, which runs on and can finish what it
    /// starts; called once, as it starts. Everything else in the process —
    /// `--json`, `--provider`, `--windows` — only reads the sign-in.
    public static func allowInThisProcess() {
        processLock.withLock { allowedInProcess = true }
    }

    public static var isAllowedInThisProcess: Bool {
        processLock.withLock { allowedInProcess }
    }

    // MARK: Quitting

    /// Starts nothing new from here on: no renewal, no further try.
    public func stop() {
        state.withLock { stopping = true }
    }

    /// A renewal request is out, or its reply not yet saved.
    public var hasRequestOut: Bool {
        state.withLock { requestsOut > 0 }
    }

    /// Returns once no renewal request is out and every reply is saved, or
    /// after `timeout` — a request gives up after 30 seconds by itself.
    public func waitForRequests(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while hasRequestOut, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func checkNotStopping() throws {
        if state.withLock({ stopping }) { throw Failure.unavailable(Self.quittingDetail) }
    }

    /// Counts a request as out, unless quitting has begun — in one step, so
    /// a quit either waits for the request or the request is never sent.
    private func sendingRequest() throws {
        try state.withLock {
            guard !stopping else { throw Failure.unavailable(Self.quittingDetail) }
            requestsOut += 1
        }
    }

    private func requestSettled() {
        state.withLock { requestsOut -= 1 }
    }

    private static var quittingDetail: String {
        L10n.t("QuotaBar is quitting", "QuotaBar 正在退出")
    }

    static var unsavedDetail: String {
        L10n.t("could not save the renewed sign-in to ~/.kimi-code", "无法把续期后的登录保存到 ~/.kimi-code")
    }

    /// For this Mac's `~/.kimi-code`.
    public static func renewability(of session: LocalCredentials.KimiCodeSession) -> KimiCodeRenewability {
        renewability(of: session, codeHome: LocalCredentials.kimiCodeHome, now: Date())
    }

    /// Whether the sign-in may be renewed from here, and with what.
    public static func renewability(
        of session: LocalCredentials.KimiCodeSession, codeHome: URL, now: Date) -> KimiCodeRenewability
    {
        guard let name = session.storageName, let slot = LocalCredentials.kimiCodeSlots[name] else {
            return .readOnly(.olderCLI)
        }
        guard session.canRenew(now: now) else { return .readOnly(.cannotRenew) }
        guard KimiCodeConfig.activeSlot(codeHome: codeHome)?.storageName == name else { return .readOnly(.notInUse) }
        guard let deviceID = KimiCodeIdentity.deviceID(codeHome: codeHome) else { return .readOnly(.noDeviceID) }
        return .renewable(Context(slot: slot, codeHome: codeHome, deviceID: deviceID))
    }

    /// An access token good for the next request. `rejected` is one the
    /// Code API just turned down, which is then renewed whatever its expiry
    /// says. One renewal at a time in this process; each reads the file
    /// afresh, so one queued behind another finds the work done.
    public func accessToken(
        _ context: Context, rejected: String? = nil, environment: KimiCodeEnvironment) async throws -> Outcome
    {
        let task: Task<Outcome, Error> = state.withLock {
            let previous = tail
            let task = Task { () async throws -> Outcome in
                _ = await previous?.value
                return try await self.renew(context, rejected: rejected, environment: environment)
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }

    // MARK: The steps

    private func renew(_ context: Context, rejected: String?, environment env: KimiCodeEnvironment) async throws -> Outcome {
        try checkNotStopping()
        let file = context.credentialsFile
        let pending = unsavedRenewal(for: file)
        // The refresh token on disk this renewal starts from.
        let known: String
        if let pending {
            // A renewal whose save failed: saving it comes first, and the
            // dead refresh token on disk is never sent.
            known = pending.replacing
        } else {
            guard case let .token(before) = KimiCodeTokenFile.read(file), !before.isRevoked else {
                throw Failure.signInAgain
            }
            if let token = Self.usable(before, rejected: rejected, now: env.now()) {
                return Outcome(accessToken: token, renewedHere: false)
            }
            try checkRenewable(before, now: env.now())
            known = before.refreshToken
        }

        do {
            try Self.prepareSentinel(context.lockSentinel)
        } catch {
            throw Failure.unavailable(L10n.t("could not prepare Kimi Code's renewal lock", "无法准备 Kimi Code 的续期锁"))
        }
        var held: KimiCodeLock?
        var sighting: KimiCodeLock.StaleSighting?
        let deadline = env.now().addingTimeInterval(env.lockWait)
        while held == nil {
            if case let .acquired(lock) = KimiCodeLock.attempt(
                directory: context.lockDirectory, now: env.now(), uptime: env.uptime(),
                sighting: &sighting, touchInterval: env.touchInterval)
            {
                held = lock
                break
            }
            // Kimi Code is renewing, or signed in anew: once it has saved,
            // its token will do.
            if case let .token(current) = KimiCodeTokenFile.read(file), !current.isRevoked,
               current.refreshToken != known,
               let token = Self.usable(current, rejected: rejected, now: env.now())
            {
                if pending != nil { forgetUnsaved(file) }
                return Outcome(accessToken: token, renewedHere: false)
            }
            guard env.now() < deadline else { throw Failure.busy }
            try checkNotStopping()
            await env.sleep(env.lockRetry)
        }
        guard let lock = held else { throw Failure.busy }
        defer { lock.release() }

        if let pending { try settle(pending, in: file) }

        guard case let .token(current) = KimiCodeTokenFile.read(file), !current.isRevoked else {
            // Signed out while waiting; a file removed by signing out stays removed.
            throw Failure.signInAgain
        }
        if let token = Self.usable(current, rejected: rejected, now: env.now()) {
            return Outcome(accessToken: token, renewedHere: false)
        }
        try checkRenewable(current, now: env.now())
        guard !lock.isCompromised else { throw Failure.busy }

        return try await post(context, token: current, lock: lock, environment: env)
    }

    private func post(
        _ context: Context, token current: KimiCodeTokenFile, lock: KimiCodeLock, environment env: KimiCodeEnvironment) async throws -> Outcome
    {
        let url = URL(string: "\(KimiCodeConfig.trimmedEndpoint(context.slot.oauthHost))/api/oauth/token")!
        var headers = KimiCodeIdentity.headers(deviceID: context.deviceID, appVersion: env.appVersion)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        headers["Accept"] = "application/json"
        let body = Data(Self.formBody([
            ("client_id", Self.clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", current.refreshToken),
        ]).utf8)

        let attempts = 3
        var failure = L10n.t("no reply", "没有回应")
        for attempt in 0..<attempts {
            if attempt > 0 {
                await env.sleep(pow(2, Double(attempt - 1)))
                // Another try is another renewal of the same refresh token:
                // only under a lock no one else can have taken meanwhile.
                guard !lock.isCompromised else { throw Failure.busy }
            }
            try sendingRequest()
            defer { requestSettled() }
            let last = attempt == attempts - 1
            let response: HTTPResponse
            do {
                response = try await env.send("POST", url, headers, body, 30)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? L10n.t("network error", "网络错误")
                if last { break }
                continue
            }
            let payload = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
            if response.status == 200, payload["access_token"] is String {
                guard let renewed = Self.token(from: payload, now: env.now()) else {
                    throw Failure.unavailable(L10n.t("unexpected reply from \(url.host ?? "")", "\(url.host ?? "")返回的数据无法识别"))
                }
                // Saved even if the lock was lost while the request was out,
                // as Kimi Code does: the refresh token on disk is dead either way.
                return try save(renewed, replacing: current.refreshToken, to: context.credentialsFile, now: env.now())
            }
            if response.status == 401 || response.status == 403 || payload["error"] as? String == "invalid_grant" {
                await env.sleep(0.1)
                if case let .token(after) = KimiCodeTokenFile.read(context.credentialsFile), !after.isRevoked,
                   after.refreshToken != current.refreshToken
                {
                    return Outcome(accessToken: after.accessToken, renewedHere: false)
                }
                remember(refused: current.refreshToken, now: env.now())
                throw Failure.signInAgain
            }
            failure = "HTTP \(response.status)"
            guard [429, 500, 502, 503, 504].contains(response.status), !last else { break }
        }
        throw Failure.unavailable(failure)
    }

    // MARK: Saving

    enum SaveDecision: Equatable {
        /// Written, keeping the keys of what is there.
        case write
        /// Left as it is.
        case leave
    }

    /// Whether a renewal that spent `replacing` may be written over what the
    /// file holds now, read under the lock.
    ///
    /// - **Removed**: signing out removes the file, and that stands.
    /// - **Another live sign-in**: someone signed in anew meanwhile (Kimi
    ///   Code saves a sign-in without the lock); theirs stands.
    /// - **The same refresh token**, as expected — or **Kimi Code's
    ///   signed-out marker**, which only a renewal racing this one can have
    ///   left there (its try with the same token was refused because this
    ///   one had spent it): written, since this renewal holds the live pair.
    ///   QuotaBar still never writes a marker of its own.
    /// - **Not a sign-in file at all**: Kimi Code reads it as missing and
    ///   would write over it too.
    static func saveDecision(_ latest: KimiCodeTokenFile.Read, replacing: String) -> SaveDecision {
        switch latest {
        case .missing:
            return .leave
        case .unreadable:
            return .write
        case let .token(token):
            return !token.isRevoked && token.refreshToken != replacing ? .leave : .write
        }
    }

    /// Saves a renewal the server has granted, tried twice. A save that
    /// still fails is kept for the next renewal to make first, and said.
    private func save(_ renewed: RenewedToken, replacing: String, to file: URL, now: Date) throws -> Outcome {
        let latest = KimiCodeTokenFile.read(file)
        guard Self.saveDecision(latest, replacing: replacing) == .write else {
            // Someone else's sign-in is on disk, and is the one to read with.
            if case let .token(theirs) = latest, let token = Self.usable(theirs, rejected: nil, now: now) {
                return Outcome(accessToken: token, renewedHere: false)
            }
            return Outcome(accessToken: renewed.accessToken, renewedHere: true)
        }
        guard (try? Self.write(renewed, over: latest, to: file)) != nil
            || (try? Self.write(renewed, over: KimiCodeTokenFile.read(file), to: file)) != nil
        else {
            state.withLock { unsaved[file.path] = Unsaved(renewed: renewed, replacing: replacing) }
            throw Failure.unavailable(Self.unsavedDetail)
        }
        return Outcome(accessToken: renewed.accessToken, renewedHere: true)
    }

    /// A renewal whose save failed earlier, made now under the lock — or
    /// dropped, when the file shows the sign-in ended or was replaced.
    private func settle(_ pending: Unsaved, in file: URL) throws {
        let latest = KimiCodeTokenFile.read(file)
        guard Self.saveDecision(latest, replacing: pending.replacing) == .write else {
            forgetUnsaved(file)
            return
        }
        guard (try? Self.write(pending.renewed, over: latest, to: file)) != nil else {
            throw Failure.unavailable(Self.unsavedDetail)
        }
        forgetUnsaved(file)
    }

    private static func write(_ renewed: RenewedToken, over latest: KimiCodeTokenFile.Read, to file: URL) throws {
        var keeping: KimiCodeTokenFile?
        if case let .token(token) = latest { keeping = token }
        let text = KimiCodeTokenFile.render(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken,
            expiresAt: renewed.expiresAt,
            scope: renewed.scope,
            tokenType: renewed.tokenType,
            expiresIn: renewed.expiresIn,
            keeping: keeping)
        try KimiCodeTokenFile.write(text, to: file)
    }

    private func unsavedRenewal(for file: URL) -> Unsaved? {
        state.withLock { unsaved[file.path] }
    }

    private func forgetUnsaved(_ file: URL) {
        state.withLock { _ = unsaved.removeValue(forKey: file.path) }
    }

    // MARK: Rules

    /// The token in the file, when it will do without renewing: not due, or
    /// — after a rejection — a different one from the one rejected.
    static func usable(_ token: KimiCodeTokenFile, rejected: String?, now: Date) -> String? {
        let remaining = token.expiresAt.map { $0.timeIntervalSince(now) }
        if let rejected {
            guard token.accessToken != rejected else { return nil }
            return (remaining ?? .infinity) > LocalCredentials.KimiCodeSession.expiryMargin ? token.accessToken : nil
        }
        return (remaining ?? .infinity) > LocalCredentials.KimiCodeSession.renewalMargin ? token.accessToken : nil
    }

    /// No request goes out without a refresh token that can still work.
    private func checkRenewable(_ token: KimiCodeTokenFile, now: Date) throws {
        guard !token.refreshToken.isEmpty else { throw Failure.signInAgain }
        if let expiry = token.refreshExpiresAt, expiry.timeIntervalSince(now) <= LocalCredentials.KimiCodeSession.expiryMargin {
            throw Failure.signInAgain
        }
        if wasRefused(token.refreshToken, now: now) { throw Failure.signInAgain }
    }

    private func remember(refused token: String, now: Date) {
        state.withLock {
            refused = refused.filter { $0.value > now }
            refused[KimiPastedCredential.fingerprint(token)] = now.addingTimeInterval(Self.refusalMemory)
        }
    }

    private func wasRefused(_ token: String, now: Date) -> Bool {
        state.withLock { (refused[KimiPastedCredential.fingerprint(token)] ?? .distantPast) > now }
    }

    /// proper-lockfile locks against a file that exists: Kimi Code creates
    /// it empty (`writeFile(target, "", {flag: "a"})`) and never writes to it.
    static func prepareSentinel(_ sentinel: URL) throws {
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(sentinel.path, O_WRONLY | O_CREAT | O_APPEND, 0o666)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
    }

    // MARK: The token endpoint

    struct RenewedToken: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
        let scope: String
        let tokenType: String
        let expiresIn: Double
    }

    /// Kimi Code's `tokenFromResponse`: both tokens non-empty, a positive
    /// `expires_in`; the expiry counted from now in whole seconds.
    static func token(from payload: [String: Any], now: Date) -> RenewedToken? {
        guard let access = payload["access_token"] as? String, !access.isEmpty,
              let refresh = payload["refresh_token"] as? String, !refresh.isEmpty
        else { return nil }
        let expiresIn: Double?
        switch payload["expires_in"] {
        case let number as NSNumber:
            expiresIn = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? 1 : 0) : number.doubleValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            expiresIn = trimmed.isEmpty ? 0 : Double(trimmed)
        default:
            expiresIn = nil
        }
        guard let expiresIn, expiresIn.isFinite, expiresIn > 0 else { return nil }
        return RenewedToken(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: (now.timeIntervalSince1970).rounded(.down) + expiresIn,
            scope: payload["scope"] as? String ?? "",
            tokenType: payload["token_type"] as? String ?? "Bearer",
            expiresIn: expiresIn)
    }

    /// `new URLSearchParams(pairs).toString()`: letters, digits and `*-._`
    /// as they are, space as `+`, every other byte percent-encoded.
    static func formBody(_ pairs: [(String, String)]) -> String {
        func encode(_ text: String) -> String {
            var out = ""
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "*"), UInt8(ascii: "-"),
                     UInt8(ascii: "."), UInt8(ascii: "_"):
                    out.unicodeScalars.append(Unicode.Scalar(byte))
                case UInt8(ascii: " "):
                    out += "+"
                default:
                    out += String(format: "%%%02X", byte)
                }
            }
            return out
        }
        return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
