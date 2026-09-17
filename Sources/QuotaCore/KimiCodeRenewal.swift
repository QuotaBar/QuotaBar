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

    public init(
        codeHome: URL,
        legacyHome: URL,
        send: @escaping HTTPSend,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = KimiCodeEnvironment.realSleep,
        lockWait: TimeInterval = 15,
        lockRetry: TimeInterval = KimiCodeLock.retryInterval,
        touchInterval: TimeInterval = KimiCodeLock.touchInterval,
        appVersion: String? = nil,
        renewal: KimiCodeRenewal = .shared)
    {
        self.codeHome = codeHome
        self.legacyHome = legacyHome
        self.send = send
        self.now = now
        self.sleep = sleep
        self.lockWait = lockWait
        self.lockRetry = lockRetry
        self.touchInterval = touchInterval
        self.appVersion = appVersion ?? KimiCodeIdentity.appVersion
        self.renewal = renewal
    }

    public static var live: KimiCodeEnvironment {
        KimiCodeEnvironment(codeHome: LocalCredentials.kimiCodeHome, legacyHome: LocalCredentials.kimiLegacyHome, send: HTTP.live)
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
///    tries for a network or server failure.
/// 5. Save what comes back at once, in Kimi Code's own format: the refresh
///    token has already been rotated on the server.
///
/// A refused renewal (401, 403, `invalid_grant`) is looked at again 100 ms
/// later, in case Kimi Code renewed first; otherwise it means signing in
/// again. Unlike Kimi Code, QuotaBar then writes nothing — no signed-out
/// marker — and leaves the file for Kimi Code to judge. Nothing is ever
/// written without the lock, over a file that is missing or signed out, or
/// for hosts other than Kimi Code's own.
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

    public init() {}

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
        let file = context.credentialsFile
        guard case let .token(before) = KimiCodeTokenFile.read(file), !before.isRevoked else {
            throw Failure.signInAgain
        }
        if let token = Self.usable(before, rejected: rejected, now: env.now()) {
            return Outcome(accessToken: token, renewedHere: false)
        }
        try checkRenewable(before, now: env.now())

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
                directory: context.lockDirectory, now: env.now(), sighting: &sighting, touchInterval: env.touchInterval)
            {
                held = lock
                break
            }
            // Kimi Code is renewing: once it has saved, its token will do.
            if case let .token(current) = KimiCodeTokenFile.read(file), !current.isRevoked,
               current.refreshToken != before.refreshToken,
               let token = Self.usable(current, rejected: rejected, now: env.now())
            {
                return Outcome(accessToken: token, renewedHere: false)
            }
            guard env.now() < deadline else { throw Failure.busy }
            await env.sleep(env.lockRetry)
        }
        guard let lock = held else { throw Failure.busy }
        defer { lock.release() }

        guard case let .token(current) = KimiCodeTokenFile.read(file), !current.isRevoked else {
            // Signed out while waiting; a file removed by signing out stays removed.
            throw Failure.signInAgain
        }
        if let token = Self.usable(current, rejected: rejected, now: env.now()) {
            return Outcome(accessToken: token, renewedHere: false)
        }
        try checkRenewable(current, now: env.now())
        guard !lock.isCompromised else { throw Failure.busy }

        return try await post(context, token: current, environment: env)
    }

    private func post(_ context: Context, token current: KimiCodeTokenFile, environment env: KimiCodeEnvironment) async throws -> Outcome {
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
            let last = attempt == attempts - 1
            let response: HTTPResponse
            do {
                response = try await env.send("POST", url, headers, body, 30)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? L10n.t("network error", "网络错误")
                if last { break }
                await env.sleep(pow(2, Double(attempt)))
                continue
            }
            let payload = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
            if response.status == 200, payload["access_token"] is String {
                guard let renewed = Self.token(from: payload, now: env.now()) else {
                    throw Failure.unavailable(L10n.t("unexpected reply from \(url.host ?? "")", "\(url.host ?? "")返回的数据无法识别"))
                }
                save(renewed, to: context.credentialsFile)
                return Outcome(accessToken: renewed.accessToken, renewedHere: true)
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
            await env.sleep(pow(2, Double(attempt)))
        }
        throw Failure.unavailable(failure)
    }

    /// Written even if the lock was lost while the request was out, as Kimi
    /// Code does: the server has rotated the refresh token, and the one on
    /// disk is dead either way. Not over a file that went missing or was
    /// signed out meanwhile — that sign-in was ended on purpose. A failed
    /// save still hands back the new access token; the quota can be read.
    private func save(_ renewed: RenewedToken, to file: URL) {
        guard case let .token(latest) = KimiCodeTokenFile.read(file), !latest.isRevoked else { return }
        let text = KimiCodeTokenFile.render(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken,
            expiresAt: renewed.expiresAt,
            scope: renewed.scope,
            tokenType: renewed.tokenType,
            expiresIn: renewed.expiresIn,
            keeping: latest)
        try? KimiCodeTokenFile.write(text, to: file)
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
