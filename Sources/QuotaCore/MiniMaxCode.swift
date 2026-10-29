import CryptoKit
import Darwin
import Foundation

// MARK: - MiniMax's two editions

public enum MiniMaxRegion: String, Sendable, CaseIterable {
    /// minimax.io, the Global edition.
    case en
    /// minimaxi.com, the China edition.
    case cn

    /// Where MiniMax Code's sign-in is renewed (`ACCOUNT_ORIGINS`).
    var accountOrigin: String {
        switch self {
        case .en: "https://account.minimax.io"
        case .cn: "https://account.minimax.cn"
        }
    }

    /// Where MiniMax Code reads the plan's remaining quota with that sign-in
    /// (`OPEN_PLATFORM_ORIGINS`).
    var platformOrigin: String {
        switch self {
        case .en: "https://platform.minimax.io"
        case .cn: "https://www.minimaxi.com"
        }
    }

    public var label: String {
        switch self {
        case .en: L10n.t("Global (minimax.io)", "国际版（minimax.io）")
        case .cn: L10n.t("China (minimaxi.com)", "国内版（minimaxi.com）")
        }
    }

    public var consoleURL: URL? {
        switch self {
        case .en: URL(string: "https://platform.minimax.io/user-center/payment/coding-plan")
        case .cn: URL(string: "https://platform.minimaxi.com/user-center/payment/coding-plan")
        }
    }
}

// MARK: - MiniMax Code's sign-in

/// The sign-in MiniMax Code (the desktop app, and its CLI tools) keeps in
/// `~/.minimax/auth/prod/<region>/mcode-public/`: the tokens in `auth.json`,
/// what state they are in in `auth-state.json`. The access token lasts an
/// hour; MiniMax Code renews it while it runs, and so does QuotaBar
/// (`MiniMaxCodeRenewal`), the same way.
public struct MiniMaxCodeSignIn: Sendable, Equatable {
    public let region: MiniMaxRegion
    public let accessToken: String
    public let expiresAt: Date
    /// `auth-state.json`'s `status`: authenticated, expired, refreshing.
    public let status: String
    public let generation: Int
    public let hasRefreshToken: Bool

    public func isExpired(now: Date = Date()) -> Bool { expiresAt <= now }

    /// Due for renewing: run out, or about to.
    public func isDue(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < MiniMaxCode.renewalMargin
    }
}

public enum MiniMaxCode {
    static let clientID = "mcode-public"
    static let scope = "agent.default"
    static let audience = "agent-backend"
    static let buildEnv = "prod"
    /// Renewed this long before it runs out, so a reading never goes out
    /// with a token that expires on the way.
    static let renewalMargin: TimeInterval = 120
    static let remainsPath = "/v1/api/openplatform/coding_plan/remains"

    public static var authHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".minimax/auth")
    }

    public static var appConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiniMax Agent/minimax-agent-config.json")
    }

    /// Who MiniMax Code is signed in as, by its settings (`sharedUser`):
    /// the address when it keeps one, and the name.
    static func configIdentity(config: URL) -> Identity {
        guard let root = readObject(config), let user = root["sharedUser"] as? [String: Any] else { return Identity() }
        return Identity(email: text(user["userMail"]), name: text(user["subUserName"]) ?? text(user["userName"]))
    }

    /// An account's address and the name it goes by; either may be missing —
    /// an account made with a phone number has no address at all.
    struct Identity: Equatable {
        var email: String?
        var name: String?
    }

    static func text(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func namespace(_ region: MiniMaxRegion, authHome: URL) -> URL {
        authHome.appendingPathComponent(buildEnv).appendingPathComponent(region.rawValue).appendingPathComponent(clientID)
    }

    /// The keychain-style service the record in `auth.json` is filed under;
    /// the key is `<service>\0<account>`.
    static func service(_ region: MiniMaxRegion) -> String {
        "com.minimax.mcode.oauth.\(buildEnv).\(region.rawValue)"
    }

    /// The sign-in on this Mac: of the two editions, the one signed in, or
    /// the later one when both are.
    public static func signIn(authHome: URL = authHome) -> MiniMaxCodeSignIn? {
        MiniMaxRegion.allCases
            .compactMap { files(region: $0, authHome: authHome)?.signIn }
            .max { $0.expiresAt < $1.expiresAt }
    }

    // MARK: The files

    /// `auth-state.json` and `auth.json` as read, kept whole so a renewal
    /// writes back everything it does not change.
    struct Files {
        let region: MiniMaxRegion
        let namespace: URL
        var state: [String: Any]
        var payload: [String: Any]
        let recordKey: String
        var record: [String: Any]

        var stateURL: URL { namespace.appendingPathComponent("auth-state.json") }
        var credentialURL: URL { namespace.appendingPathComponent("auth.json") }
        var journalURL: URL { namespace.appendingPathComponent("refresh/auth.json") }
        var lockSentinel: URL { namespace.appendingPathComponent("auth.lock") }
        var lockDirectory: URL { namespace.appendingPathComponent("auth.lock.lock") }

        var status: String { state["status"] as? String ?? "" }
        var stateGeneration: Int { (state["generation"] as? NSNumber)?.intValue ?? -1 }
        var recordGeneration: Int { (record["generation"] as? NSNumber)?.intValue ?? -2 }
        var accessToken: String { (record["accessToken"] as? String) ?? "" }
        var refreshToken: String { (record["refreshToken"] as? String) ?? "" }
        var expiresAt: Date {
            Date(timeIntervalSince1970: ((record["expiresAtMs"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        }

        /// Whether MiniMax Code would call this signed in: a state that holds
        /// a sign-in, and a record of the same generation. While a renewal is
        /// out the state is one generation ahead and the old token still
        /// serves until it runs out.
        var signIn: MiniMaxCodeSignIn? {
            guard !accessToken.isEmpty else { return nil }
            switch status {
            case "authenticated", "expired":
                guard stateGeneration == recordGeneration else { return nil }
            case "refreshing":
                guard stateGeneration > recordGeneration else { return nil }
            default:
                return nil
            }
            return MiniMaxCodeSignIn(
                region: region, accessToken: accessToken, expiresAt: expiresAt, status: status,
                generation: recordGeneration, hasRefreshToken: !refreshToken.isEmpty)
        }
    }

    static func files(region: MiniMaxRegion, authHome: URL) -> Files? {
        let namespace = namespace(region, authHome: authHome)
        guard let state = readObject(namespace.appendingPathComponent("auth-state.json")),
              let payload = readObject(namespace.appendingPathComponent("auth.json")),
              let records = payload["records"] as? [String: Any]
        else { return nil }
        let prefix = service(region) + "\u{0}"
        guard let (key, value) = records.first(where: { $0.key.hasPrefix(prefix) }),
              let record = value as? [String: Any]
        else { return nil }
        return Files(region: region, namespace: namespace, state: state, payload: payload, recordKey: key, record: record)
    }

    static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Writes as MiniMax Code's `atomicWritePrivateFile` does: a private
    /// file beside the target, synced, renamed over it — owner-only, since
    /// MiniMax Code refuses a credential file others can read.
    static func writePrivate(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        data.append(0x0A)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let temporary = "\(url.path).\(getpid()).\(UUID().uuidString.lowercased()).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard written, chmod(temporary, 0o600) == 0, rename(temporary, url.path) == 0 else {
            let failure = errno
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    // MARK: The plan's quota

    /// `coding_plan/remains`, on the edition's platform host with MiniMax
    /// Code's sign-in, or on api.minimax.io with an API key.
    public static func parseRemains(_ data: Data) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        let container = (root["data"] as? [String: Any]) ?? root
        let status = (root["base_resp"] as? [String: Any]) ?? (container["base_resp"] as? [String: Any])
        if let code = (status?["status_code"] as? NSNumber)?.intValue, code != 0 {
            // 1004: not signed in; 2049: an API key it does not know.
            if code == 1004 || code == 2049 { throw ProviderError.unauthorized }
            let message = (status?["status_msg"] as? String) ?? "\(code)"
            throw ProviderError.usageUnavailable(L10n.t(
                "MiniMax did not report the plan's quota (\(message)).",
                "MiniMax 没有返回套餐额度（\(message)）。"))
        }
        guard let items = (container["model_remains"] ?? container["modelRemains"]) as? [[String: Any]], !items.isEmpty else {
            throw ProviderError.noPlan(L10n.t(
                "Signed in, but this account has no MiniMax plan quota to read.",
                "已登录，但这个账号没有可读的 MiniMax 套餐额度。"))
        }
        // "general" is the plan's text quota, the one MiniMax Code shows;
        // other entries are per-model allowances (speech, video).
        let ordered = items.sorted { lhs, rhs in
            (Self.string(lhs, "model_name", "modelName") == "general" ? 0 : 1)
                < (Self.string(rhs, "model_name", "modelName") == "general" ? 0 : 1)
        }
        var windows: [UsageWindow] = []
        for item in ordered.prefix(3) {
            let name = Self.string(item, "model_name", "modelName") ?? "general"
            let scope = name == "general" ? nil : name
            let start = Self.number(item, "start_time", "startTime")
            let end = Self.number(item, "end_time", "endTime")
            let intervalSeconds = start.flatMap { start in end.map { Int(($0 - start) / 1000) } }.flatMap { $0 > 0 ? $0 : nil }
            if let window = Self.window(item, kind: "interval", seconds: intervalSeconds, reset: end, scope: scope) {
                windows.append(window)
            }
            if let window = Self.window(item, kind: "weekly", seconds: 604_800,
                                        reset: Self.number(item, "weekly_end_time", "weeklyEndTime"), scope: scope)
            {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            throw ProviderError.usageUnavailable(L10n.t(
                "MiniMax answered without any quota figures.", "MiniMax 的回复里没有额度数字。"))
        }
        return UsageSnapshot(windows: windows)
    }

    /// One window — `current_interval_*` or `current_weekly_*`. The
    /// `usage_count` is what is left, not what was used, as MiniMax Code
    /// itself reads it; status 3 is a window with no limit.
    static func window(_ item: [String: Any], kind: String, seconds: Int?, reset: Double?, scope: String?) -> UsageWindow? {
        let camel = kind == "interval" ? "Interval" : "Weekly"
        let total = number(item, "current_\(kind)_total_count", "current\(camel)TotalCount")
        let left = number(item, "current_\(kind)_usage_count", "current\(camel)UsageCount")
        let unlimited = number(item, "current_\(kind)_status", "current\(camel)Status") == 3
        let remainingPercent = number(item, "current_\(kind)_remaining_percent", "current\(camel)RemainingPercent")
            ?? total.flatMap { total in left.flatMap { total > 0 ? $0 / total * 100 : nil } }
        guard unlimited || remainingPercent != nil else { return nil }
        let base = seconds.map(WindowTitle.forSeconds) ?? (kind == "weekly" ? WindowTitle.forSeconds(604_800) : L10n.t("Quota", "额度"))
        return UsageWindow(
            title: scope.map { "\($0) · \(base)" } ?? base,
            usedPercent: unlimited ? 0 : remainingPercent.map { 100 - $0 },
            detail: unlimited
                ? L10n.t("Unlimited", "不限量")
                : total.flatMap { total in
                    guard total > 0, let left else { return nil }
                    return L10n.t("\(Int(left)) left of \(Int(total))", "剩余 \(Int(left)) / 共 \(Int(total))")
                },
            resetsAt: unlimited ? nil : Dates.parseEpoch(reset),
            windowSeconds: seconds,
            scope: scope)
    }

    static func string(_ item: [String: Any], _ keys: String...) -> String? {
        for key in keys { if let value = item[key] as? String, !value.isEmpty { return value } }
        return nil
    }

    static func number(_ item: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = item[key] as? NSNumber { return value.doubleValue }
            if let value = item[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    /// The plan's quota with MiniMax Code's sign-in, with the plan's name
    /// when the subscription endpoint gives it — asked at the same time, and
    /// never a reason for the reading to fail.
    static func fetchRemains(region: MiniMaxRegion, token: String, send: HTTPSend) async throws -> UsageSnapshot {
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        async let plan: String? = {
            guard let response = try? await send("GET", URL(string: region.platformOrigin + comboPath)!, headers, nil, 15),
                  (200...299).contains(response.status)
            else { return nil }
            return planName(response.data)
        }()
        let response = try await send("GET", URL(string: region.platformOrigin + remainsPath)!, headers, nil, 20)
        var snapshot = try parseRemains(response.requireOK().data)
        snapshot.planName = await plan
        return snapshot
    }

    /// The subscription and the plans on offer, as MiniMax Code's pricing
    /// page reads them.
    static let comboPath = "/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7"

    /// The plan's short name as MiniMax Code shows it ("Go", "Explore"):
    /// the current plan's card, else the offered plan of the subscribed
    /// type, else the subscription's full title ("Monthly M Plan Go").
    /// Nil without a current subscription.
    static func planName(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let body = (root["data"] as? [String: Any]) ?? root
        guard let subscription = body["current_subscribe"] as? [String: Any] else { return nil }
        let fullTitle = string(subscription, "current_subscribe_title")
        let type = number(subscription, "current_subscribe_combo_type")
        guard fullTitle != nil || type != nil else { return nil }
        func trimmed(_ value: String?) -> String? {
            value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let card = body["current_combo_card"] as? [String: Any],
           type == nil || number(card, "combo_type") == type,
           let title = trimmed(string(card, "title"))
        {
            return title
        }
        if let type, let offered = body["cycle_resource_packages"] as? [[String: Any]],
           let title = trimmed(offered.first { number($0, "combo_type") == type }.flatMap { string($0, "title") })
        {
            return title
        }
        return trimmed(fullTitle)
    }
}

// MARK: - What the MiniMax Code source runs on

/// The file system, network and clock MiniMax Code's sign-in is read and
/// renewed with; tests pass a throwaway directory and a scripted `send`.
public struct MiniMaxCodeEnvironment: Sendable {
    public var authHome: URL
    /// MiniMax Code's own settings, which name the account signed in.
    public var appConfig: URL
    /// What MiniMax Code signs its agent API with, read from the app.
    public var signing: @Sendable () -> MiniMaxSigning?
    public var accounts: MiniMaxAccountCache
    public var send: HTTPSend
    public var now: @Sendable () -> Date
    public var uptime: @Sendable () -> TimeInterval
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// How long a refresh waits for MiniMax Code to finish a renewal of its
    /// own. MiniMax Code waits about half a minute; a background refresh can
    /// try again at the next one.
    public var lockWait: TimeInterval
    public var lockRetry: TimeInterval
    public var touchInterval: TimeInterval
    /// Only the running app renews: a one-off command killed with its
    /// request out would leave MiniMax Code a renewal it cannot finish.
    public var mayRenew: Bool
    public var renewal: MiniMaxCodeRenewal

    public init(
        authHome: URL = MiniMaxCode.authHome,
        appConfig: URL = MiniMaxCode.appConfig,
        signing: @escaping @Sendable () -> MiniMaxSigning? = { MiniMaxSigningReader.installed() },
        accounts: MiniMaxAccountCache = .shared,
        send: @escaping HTTPSend = HTTP.live,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = KimiCodeEnvironment.realSleep,
        lockWait: TimeInterval = 10,
        lockRetry: TimeInterval = 0.25,
        touchInterval: TimeInterval = MiniMaxCodeRenewal.touchInterval,
        mayRenew: Bool = KimiCodeRenewal.isAllowedInThisProcess,
        renewal: MiniMaxCodeRenewal = .shared)
    {
        self.authHome = authHome
        self.appConfig = appConfig
        self.signing = signing
        self.accounts = accounts
        self.send = send
        self.now = now
        self.uptime = uptime
        self.sleep = sleep
        self.lockWait = lockWait
        self.lockRetry = lockRetry
        self.touchInterval = touchInterval
        self.mayRenew = mayRenew
        self.renewal = renewal
    }

    public static var live: MiniMaxCodeEnvironment { MiniMaxCodeEnvironment() }
}

// MARK: - Renewing

/// Renews MiniMax Code's sign-in the way MiniMax Code does (`MCodeOAuthCore`
/// in its auth package), so the two take turns on one refresh token, which
/// the server may replace on every renewal:
///
/// 1. Take MiniMax Code's lock: proper-lockfile on `auth.lock`, with
///    `stale: 30000` (`KimiCodeLock`, at MiniMax Code's timings).
/// 2. Read both files again. Nothing to do if the token is good — someone
///    renewed it meanwhile. A renewal of someone else's still open
///    (`refreshing`) is left for MiniMax Code to finish.
/// 3. Fence first: `auth-state.json` says `refreshing`, one generation up,
///    with this renewal's id and process, before the refresh token is spent.
/// 4. Ask for new tokens. If that fails, put the state back as it was
///    (`expired` once the old token has run out) and leave the decision to
///    MiniMax Code, which signs out on a refused refresh token.
/// 5. Commit as MiniMax Code does: the new record to `refresh/auth.json`
///    first, which lets MiniMax Code finish the commit should this process
///    die; then `auth.json`; then the state back to `authenticated`; then
///    the journal removed — checking before each step that the fence is
///    still this renewal's.
public final class MiniMaxCodeRenewal: @unchecked Sendable {
    public static let shared = MiniMaxCodeRenewal()

    /// proper-lockfile's `stale` as MiniMax Code sets it, and its `update`.
    public static let staleAfter: TimeInterval = 30
    public static let touchInterval: TimeInterval = 15
    /// A renewal that failed is not tried again for this long.
    static let failureCooldown: TimeInterval = 120

    public enum Failure: Error, Equatable {
        /// MiniMax Code is renewing, or holds the lock.
        case busy
        /// No sign-in to renew, or one the server turned down.
        case signInAgain
        /// The renewal did not go through (network, server); the next
        /// refresh tries again.
        case unavailable(String)
    }

    private let lock = NSLock()
    private var stopping = false
    private var requestsOut = 0
    private var lastFailure: [String: Date] = [:]
    /// Generations whose refresh token the server turned down.
    private var refused: [String: Int] = [:]
    private let gate = Gate()

    /// The pid and start MiniMax Code records as a renewal's owner: whether
    /// the owner is still alive tells MiniMax Code whether to wait for it.
    private static let startedAtMs = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))

    public init() {}

    actor Gate {
        private var running: [String: Task<Result<String, Error>, Never>] = [:]

        func run(_ key: String, _ body: @escaping @Sendable () async throws -> String) async throws -> String {
            if let task = running[key] { return try await task.value.get() }
            let task = Task { () -> Result<String, Error> in
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            running[key] = task
            let result = await task.value
            running[key] = nil
            return try result.get()
        }
    }

    // MARK: Quitting

    public func stop() {
        lock.withLock { stopping = true }
    }

    public var hasRequestOut: Bool {
        lock.withLock { requestsOut > 0 }
    }

    public func waitForRequests(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while hasRequestOut, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func checkNotStopping() throws {
        if lock.withLock({ stopping }) {
            throw Failure.unavailable(L10n.t("QuotaBar is quitting.", "QuotaBar 正在退出。"))
        }
    }

    private func sendingRequest() throws {
        try lock.withLock {
            if stopping { throw Failure.unavailable(L10n.t("QuotaBar is quitting.", "QuotaBar 正在退出。")) }
            requestsOut += 1
        }
    }

    private func requestDone() {
        lock.withLock { requestsOut -= 1 }
    }

    // MARK: Renewing

    /// A token good for a reading: the one on disk when someone renewed it
    /// meanwhile, else a new one. `rejected` is a token the quota endpoint
    /// just turned down, renewed even if it looks good.
    public func token(region: MiniMaxRegion, rejected: String? = nil, env: MiniMaxCodeEnvironment) async throws -> String {
        let key = MiniMaxCode.namespace(region, authHome: env.authHome).path
        return try await gate.run(key) { [self] in
            try await renew(region: region, key: key, rejected: rejected, env: env)
        }
    }

    private func renew(region: MiniMaxRegion, key: String, rejected: String?, env: MiniMaxCodeEnvironment) async throws -> String {
        try checkNotStopping()
        guard var files = MiniMaxCode.files(region: region, authHome: env.authHome) else { throw Failure.signInAgain }
        if let token = Self.usable(files, rejected: rejected, now: env.now()) { return token }
        // A refresh token the server turned down stays turned down: that is
        // signing in again, not trying later.
        if lock.withLock({ refused[key] }) == files.recordGeneration { throw Failure.signInAgain }
        if let last = lock.withLock({ lastFailure[key] }), env.now().timeIntervalSince(last) < Self.failureCooldown {
            throw Failure.unavailable(L10n.t(
                "Renewing MiniMax Code's sign-in failed a moment ago; trying again shortly.",
                "刚才续期 MiniMax Code 登录没有成功，稍后会再试。"))
        }

        // 1. MiniMax Code's lock.
        if !FileManager.default.fileExists(atPath: files.lockSentinel.path) {
            let fd = open(files.lockSentinel.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if fd >= 0 { close(fd) }
        }
        var held: KimiCodeLock?
        var sighting: KimiCodeLock.StaleSighting?
        let deadline = env.now().addingTimeInterval(env.lockWait)
        while held == nil {
            if case let .acquired(taken) = KimiCodeLock.attempt(
                directory: files.lockDirectory, now: env.now(), uptime: env.uptime(), sighting: &sighting,
                touchInterval: env.touchInterval, staleAfter: Self.staleAfter, secondLook: env.touchInterval + 1)
            {
                held = taken
                break
            }
            // MiniMax Code is renewing: once it has saved, its token will do.
            if let current = MiniMaxCode.files(region: region, authHome: env.authHome),
               let token = Self.usable(current, rejected: rejected, now: env.now())
            {
                return token
            }
            guard env.now() < deadline else { throw Failure.busy }
            try checkNotStopping()
            await env.sleep(env.lockRetry)
        }
        guard let held else { throw Failure.busy }
        defer { held.release() }

        // 2. Both files again, under the lock.
        guard let current = MiniMaxCode.files(region: region, authHome: env.authHome) else { throw Failure.signInAgain }
        files = current
        switch files.status {
        case "authenticated", "expired":
            guard files.stateGeneration == files.recordGeneration else { throw Failure.signInAgain }
        case "refreshing":
            if let token = Self.usable(files, rejected: rejected, now: env.now()) { return token }
            throw Failure.busy
        default:
            throw Failure.signInAgain
        }
        if let token = Self.usable(files, rejected: rejected, now: env.now()) { return token }
        guard !files.refreshToken.isEmpty else { throw Failure.signInAgain }
        if lock.withLock({ refused[key] }) == files.recordGeneration { throw Failure.signInAgain }

        // 3. The fence.
        let generation = max(files.stateGeneration, files.recordGeneration) + 1
        let transaction = UUID().uuidString.lowercased()
        let original = files.state
        var refreshing = original
        refreshing["status"] = "refreshing"
        refreshing["generation"] = generation
        refreshing["refresh"] = ["id": transaction, "owner": ["pid": Int(getpid()), "startedAtMs": Self.startedAtMs]]
        try sendingRequest()
        defer { requestDone() }
        do {
            try MiniMaxCode.writePrivate(refreshing, to: files.stateURL)
        } catch {
            throw Failure.unavailable(L10n.t("Could not write MiniMax Code's sign-in state.", "无法写入 MiniMax Code 的登录状态。"))
        }
        let isOurs = { () -> Bool in
            guard let state = MiniMaxCode.readObject(files.stateURL),
                  state["status"] as? String == "refreshing",
                  (state["generation"] as? NSNumber)?.intValue == generation,
                  (state["refresh"] as? [String: Any])?["id"] as? String == transaction
            else { return false }
            return true
        }

        // 4. The refresh.
        let grant: Grant
        do {
            grant = try await Self.refresh(region: region, refreshToken: files.refreshToken, env: env)
        } catch {
            // Put the state back as it was, the old token still good if it
            // is, and let MiniMax Code decide what a refusal means.
            var restored = original
            let stillGood = files.status == "authenticated" && files.expiresAt > env.now()
            restored["status"] = stillGood ? "authenticated" : "expired"
            if isOurs() { try? MiniMaxCode.writePrivate(restored, to: files.stateURL) }
            lock.withLock {
                lastFailure[key] = env.now()
                if case Failure.signInAgain = error { refused[key] = files.recordGeneration }
            }
            throw error
        }

        // 5. The commit.
        var record = files.record
        record["accessToken"] = grant.accessToken
        record["refreshToken"] = grant.refreshToken ?? files.refreshToken
        record["tokenType"] = "Bearer"
        record["scopes"] = grant.scopes
        record["audience"] = MiniMaxCode.audience
        record["clientId"] = MiniMaxCode.clientID
        record["expiresAtMs"] = Int64((env.now().timeIntervalSince1970 * 1000).rounded(.down)) + Int64(grant.expiresIn * 1000)
        record["generation"] = generation
        if let subject = grant.subject { record["subject"] = subject }
        if let accountID = grant.accountID { record["accountId"] = accountID }
        let journalKey = MiniMaxCode.service(region) + "\u{0}" + transaction
        do {
            try MiniMaxCode.writePrivate(["schemaVersion": 1, "records": [journalKey: record]], to: files.journalURL)
            guard isOurs() else { throw Failure.busy }
            var payload = MiniMaxCode.readObject(files.credentialURL) ?? files.payload
            var records = payload["records"] as? [String: Any] ?? [:]
            records[files.recordKey] = record
            payload["records"] = records
            try MiniMaxCode.writePrivate(payload, to: files.credentialURL)
            guard isOurs() else { throw Failure.busy }
            let authenticated: [String: Any] = [
                "schemaVersion": 2,
                "status": "authenticated",
                "storeKind": "file",
                "clientId": MiniMaxCode.clientID,
                "scopes": grant.scopes,
                "audience": MiniMaxCode.audience,
                "buildEnv": MiniMaxCode.buildEnv,
                "region": region.rawValue,
                "generation": generation,
                "expiresAtMs": record["expiresAtMs"]!,
            ]
            try MiniMaxCode.writePrivate(authenticated, to: files.stateURL)
            try? FileManager.default.removeItem(at: files.journalURL)
        } catch {
            // The journal, when written, lets MiniMax Code finish the commit.
            lock.withLock { lastFailure[key] = env.now() }
            throw Failure.unavailable(L10n.t(
                "Renewed MiniMax Code's sign-in, but could not save it; MiniMax Code will finish saving it.",
                "已续期 MiniMax Code 的登录，但没能保存，MiniMax Code 下次运行时会完成保存。"))
        }
        lock.withLock { lastFailure[key] = nil }
        return grant.accessToken
    }

    /// The token on disk, when it is good for a reading and is not the one
    /// just turned down.
    static func usable(_ files: MiniMaxCode.Files, rejected: String?, now: Date) -> String? {
        guard files.status == "authenticated" || files.status == "refreshing",
              !files.accessToken.isEmpty,
              files.accessToken != rejected,
              files.expiresAt.timeIntervalSince(now) >= MiniMaxCode.renewalMargin
        else { return nil }
        if files.status == "authenticated", files.stateGeneration != files.recordGeneration { return nil }
        return files.accessToken
    }

    // MARK: The token endpoint

    struct Grant {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let scopes: [String]
        let subject: String?
        let accountID: String?
    }

    /// `HttpOAuthClient.refreshToken`: a form post to the edition's account
    /// host, as MiniMax Code's public client.
    static func refresh(region: MiniMaxRegion, refreshToken: String, env: MiniMaxCodeEnvironment) async throws -> Grant {
        let url = URL(string: region.accountOrigin + "/oauth2/token")!
        let form = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", MiniMaxCode.clientID),
            ("scope", MiniMaxCode.scope),
            ("audience", MiniMaxCode.audience),
        ]
        let body = form.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
        let response: HTTPResponse
        do {
            response = try await env.send("POST", url, [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
            ], Data(body.utf8), 30)
        } catch {
            throw Failure.unavailable(L10n.t(
                "Could not reach MiniMax to renew the sign-in.", "连不上 MiniMax，暂时无法续期登录。"))
        }
        return try parseGrant(response)
    }

    static func parseGrant(_ response: HTTPResponse) throws -> Grant {
        let body = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
        let error = (body["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if error == "invalid_grant", response.status == 400 { throw Failure.signInAgain }
        guard (200...299).contains(response.status), error == nil,
              let access = (body["access_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
              (body["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = (body["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0
        else {
            throw Failure.unavailable(L10n.t(
                "MiniMax did not renew the sign-in (\(error ?? "HTTP \(response.status)")).",
                "MiniMax 没有续期登录（\(error ?? "HTTP \(response.status)")）。"))
        }
        let claims = LocalCredentials.jwtPayload(access)
        let scopes: [String] = {
            for value in [body["scope"], claims?["scope"], claims?["scp"]] {
                if let text = value as? String { return text.split(whereSeparator: \.isWhitespace).map(String.init) }
                if let list = value as? [String] { return list }
            }
            return []
        }()
        guard scopes.contains(MiniMaxCode.scope) else {
            throw Failure.unavailable(L10n.t(
                "MiniMax renewed the sign-in without the access MiniMax Code needs.",
                "MiniMax 续期后的登录缺少 MiniMax Code 需要的权限。"))
        }
        return Grant(
            accessToken: access,
            refreshToken: (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresIn: expiresIn,
            scopes: scopes,
            subject: claims?["sub"] as? String,
            accountID: claims?["account_id"] as? String)
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value).replacingOccurrences(of: "%20", with: "+")
    }
}

// MARK: - The account, from MiniMax Code's agent API

/// What MiniMax Code signs its agent API requests with (`MemoryQuotaTransport`
/// in its quota package): a salt for `x-signature` and a suffix for `yy`.
/// Read from the installed app, never kept in this source.
public struct MiniMaxSigning: Sendable, Equatable {
    let salt: String
    let suffix: String
}

public enum MiniMaxSigningReader {
    static let signaturePrefix = "'x-signature': md5(`${second}"
    static let signatureEnd = "${body}`)"
    static let yyPrefix = "yy: md5(`${encodeURIComponent(`${url.pathname}${url.search}`)}_${body || '{}'}${md5(String(now))}"
    static let yyEnd = "`)"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (stamp: String, signing: MiniMaxSigning?)?

    static var archives: [URL] {
        ["/Applications/MiniMax Code.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MiniMax Code.app").path]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("Contents/Resources/app.asar") }
    }

    /// The installed app's signing, kept while its archive stays the same.
    public static func installed() -> MiniMaxSigning? {
        for archive in archives {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path) else { continue }
            let stamp = "\(archive.path)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if let cached = lock.withLock({ cache }), cached.stamp == stamp { return cached.signing }
            let signing = (try? Data(contentsOf: archive, options: .alwaysMapped)).flatMap(signing(in:))
            lock.withLock { cache = (stamp, signing) }
            if signing != nil { return signing }
        }
        return nil
    }

    static func signing(in data: Data) -> MiniMaxSigning? {
        guard let salt = between(signaturePrefix, signatureEnd, in: data, maxLength: 80),
              let suffix = between(yyPrefix, yyEnd, in: data, maxLength: 40)
        else { return nil }
        return MiniMaxSigning(salt: salt, suffix: suffix)
    }

    /// The text between the first `prefix` and the `end` after it.
    private static func between(_ prefix: String, _ end: String, in data: Data, maxLength: Int) -> String? {
        guard let start = AntigravityClients.occurrences(of: prefix, in: data).first else { return nil }
        let from = start + prefix.utf8.count
        let window = data[from ..< min(data.count, from + maxLength + end.utf8.count)]
        guard let range = window.range(of: Data(end.utf8)), range.lowerBound > from else { return nil }
        return String(decoding: data[from ..< range.lowerBound], as: UTF8.self)
    }
}

extension MiniMaxCode {
    /// MiniMax Code's agent API (`MATRIX_ORIGINS`).
    static func agentOrigin(_ region: MiniMaxRegion) -> String {
        region == .cn ? "https://agent.minimax.cn" : "https://agent.minimax.io"
    }

    /// `/v1/api/user/info` as MiniMax Code asks it (`withUserIdentity`):
    /// the same query, signed the same way, with its sign-in.
    static func userInfoRequest(region: MiniMaxRegion, token: String, signing: MiniMaxSigning, now: Date)
        -> (url: URL, headers: [String: String])
    {
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let language = region == .cn ? "zh" : "en"
        let query = [
            ("device_platform", "web"), ("biz_id", "3"), ("app_id", "3001"), ("version_code", "22201"),
            ("unix", String(nowMs)), ("timezone_offset", String(TimeZone.current.secondsFromGMT(for: now))),
            ("sys_language", language), ("lang", language), ("device_id", "0"), ("user_id", "0"),
            ("client", "desktop"), ("region", region.rawValue), ("is_desktop", "1"),
        ].map { "\($0.0)=\(MiniMaxCodeRenewal.formEncode($0.1))" }.joined(separator: "&")
        let pathAndQuery = "/v1/api/user/info?" + query
        let second = nowMs / 1000
        return (URL(string: agentOrigin(region) + pathAndQuery)!, [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token)",
            "yy": md5(encodeURIComponent(pathAndQuery) + "_{}" + md5(String(nowMs)) + signing.suffix),
            "x-timestamp": String(second),
            "x-signature": md5("\(second)\(signing.salt)"),
        ])
    }

    /// The signed-in account as `/v1/api/user/info` names it, or nil — it
    /// only labels the card, so a failure is never the reading's.
    static func fetchIdentity(region: MiniMaxRegion, token: String, signing: MiniMaxSigning?, send: HTTPSend, now: Date) async -> Identity? {
        guard let signing else { return nil }
        let request = userInfoRequest(region: region, token: token, signing: signing, now: now)
        guard let response = try? await send("GET", request.url, request.headers, nil, 15),
              (200...299).contains(response.status)
        else { return nil }
        return userInfo(response.data)
    }

    /// `{"data":{"userInfo":{"email","name","subUserName",…}},"statusInfo":{"code":0}}`.
    static func userInfo(_ data: Data) -> Identity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let code = ((root["statusInfo"] as? [String: Any])?["code"] as? NSNumber)?.intValue, code != 0 { return nil }
        let body = (root["data"] as? [String: Any]) ?? root
        guard let user = (body["userInfo"] as? [String: Any]) ?? (body["user_info"] as? [String: Any]) else { return nil }
        let email = ["email", "mail", "userMail", "user_mail"].lazy.compactMap { text(user[$0]) }.first { $0.contains("@") }
        return Identity(email: email, name: text(user["name"]) ?? text(user["subUserName"]))
    }

    /// What goes under the card's name: an address — the server's, else the
    /// one MiniMax Code's settings keep — else the name the account goes by.
    /// Kept six hours, so a refresh does not ask each time.
    static func account(region: MiniMaxRegion, token: String, env: MiniMaxCodeEnvironment) async -> String? {
        if let cached = env.accounts.cached(region, now: env.now()) { return cached.value }
        let server = await fetchIdentity(region: region, token: token, signing: env.signing(), send: env.send, now: env.now())
        let settings = configIdentity(config: env.appConfig)
        let account = server?.email ?? settings.email ?? server?.name ?? settings.name
        env.accounts.store(account, for: region, now: env.now(), asked: server != nil)
        return account
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// JavaScript's `encodeURIComponent`.
    static func encodeURIComponent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

/// The account a card was last labelled with, per edition: six hours when
/// the server answered, half an hour when it did not.
public final class MiniMaxAccountCache: @unchecked Sendable {
    public static let shared = MiniMaxAccountCache()
    private let lock = NSLock()
    private var entries: [MiniMaxRegion: (value: String?, until: Date)] = [:]

    public init() {}

    func cached(_ region: MiniMaxRegion, now: Date) -> (value: String?, until: Date)? {
        lock.withLock {
            guard let entry = entries[region], entry.until > now else { return nil }
            return entry
        }
    }

    func store(_ value: String?, for region: MiniMaxRegion, now: Date, asked: Bool) {
        lock.withLock { entries[region] = (value, now.addingTimeInterval(asked ? 6 * 3600 : 1800)) }
    }
}
