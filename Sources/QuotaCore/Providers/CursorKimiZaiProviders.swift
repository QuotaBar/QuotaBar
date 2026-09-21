import Foundation

// MARK: - Cursor (browser session cookie → cursor.com/api/usage-summary)

public struct CursorProvider: QuotaProvider {
    public let id = ProviderID.cursor

    public func isConfigured(config: ConfigStore) -> Bool {
        // A manually pasted cookie wins so the user can override a stale local
        // session; otherwise fall back to the session Cursor.app established.
        config.credential(for: .cursor) != nil || LocalCredentials.cursorSession() != nil
    }

    /// The value for the WorkosCursorSessionToken cookie. A pasted credential
    /// is used verbatim; otherwise it is composed from Cursor.app's own
    /// signed-in session, which stores the token as `sub::JWT`.
    private func cookieHeader(_ config: ConfigStore) throws -> String {
        if let raw = config.credential(for: .cursor) {
            if raw.lowercased().contains("workoscursorsessiontoken=") {
                return raw
            }
            return "WorkosCursorSessionToken=\(raw)"
        }
        if let session = LocalCredentials.cursorSession() {
            // The composite carries "::" and the JWT's own characters, which
            // must be percent-encoded to survive the Cookie header.
            let encoded = session.sessionCookie.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? session.sessionCookie
            return "WorkosCursorSessionToken=\(encoded)"
        }
        throw ProviderError.notConfigured(hint: ProviderID.cursor.setupHint)
    }

    // MARK: Response shape

    struct Breakdown: Decodable {
        let included: Int?
        let bonus: Int?
        let total: Int?
    }

    struct Cents: Decodable {
        let used: Int?
        let limit: Int?
        let remaining: Int?
        let breakdown: Breakdown?
        /// Cursor's own figures. `limit` covers only the *included* allowance,
        /// so used/limit ignores bonus credit and reads 100% on an account
        /// that Cursor itself shows as half consumed.
        let totalPercentUsed: Double?
        let apiPercentUsed: Double?
        let autoPercentUsed: Double?
    }

    struct Individual: Decodable {
        let plan: Cents?
        let onDemand: Cents?
    }

    struct Summary: Decodable {
        let membershipType: String?
        let billingCycleEnd: String?
        let individualUsage: Individual?
    }

    struct Me: Decodable {
        let email: String?
    }

    /// Grok Bot's weekly included usage — "Sand" inside Cursor — from the
    /// dashboard endpoint the usage summary does not cover.
    struct SandUsage: Decodable {
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let usagePercent: Double?
        let hasAvailableUsage: Bool?
        let hasNonZeroIncludedLimit: Bool?
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let cookie = try cookieHeader(config)
        let headers = ["Accept": "application/json", "Cookie": cookie]

        let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
        let response = try await HTTP.get(summaryURL, headers: headers).requireOK()
        let summary = try response.json(Summary.self)

        let account = try? await HTTP.get(URL(string: "https://cursor.com/api/auth/me")!, headers: headers)
            .requireOK().json(Me.self)

        // Best effort, like the account: an account without Grok Bot, or a
        // stalled endpoint, must not cost the card its plan numbers.
        let sandURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
        var sandHeaders = headers
        sandHeaders["Origin"] = "https://cursor.com"
        let sand = try? await HTTP.post(sandURL, headers: sandHeaders).requireOK().json(SandUsage.self)

        return Self.snapshot(from: summary, account: account?.email, sand: sand)
    }

    /// Pure parse step, pinned by a recorded response.
    public static func parse(_ data: Data, account: String? = nil, sand: Data? = nil) throws -> UsageSnapshot {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw ProviderError.badResponse
        }
        let sandUsage = sand.flatMap { try? JSONDecoder().decode(SandUsage.self, from: $0) }
        return snapshot(from: summary, account: account, sand: sandUsage)
    }

    static func snapshot(from summary: Summary, account: String?, sand: SandUsage? = nil) -> UsageSnapshot {
        let cycleEnd = Dates.parseAny(summary.billingCycleEnd)
        var windows: [UsageWindow] = []
        if let plan = summary.individualUsage?.plan {
            windows.append(contentsOf: planWindows(plan, resetsAt: cycleEnd))
        }
        if let onDemand = summary.individualUsage?.onDemand, let limit = onDemand.limit, limit > 0 {
            let used = onDemand.used ?? 0
            windows.append(UsageWindow(
                title: L10n.t("On-demand", "按量付费"),
                usedPercent: Double(used) / Double(limit) * 100,
                detail: "\(QuotaFormat.dollars(cents: used)) / \(QuotaFormat.dollars(cents: limit))",
                resetsAt: cycleEnd))
        }
        if let sand, let window = grokBotWindow(sand) {
            windows.append(window)
        }
        return UsageSnapshot(
            planName: summary.membershipType?.capitalized,
            account: account,
            windows: windows)
    }

    /// Cursor reports the plan three ways, and `used / limit` is the one that
    /// lies: `limit` is the included allowance only, so an account holding
    /// bonus credit reads 100% while Cursor's own page says 54%. Prefer the
    /// percentages it publishes, and size the money against the real total.
    static func planWindows(_ plan: Cents, resetsAt: Date?) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let total = plan.breakdown?.total ?? plan.limit

        if let percent = plan.totalPercentUsed {
            var detail: String?
            if let total, total > 0 {
                // The absolute spend is not published; derive it from the
                // percentage, the only figure that accounts for bonus credit.
                let spent = Int((percent / 100 * Double(total)).rounded())
                detail = "\(QuotaFormat.dollars(cents: spent)) / \(QuotaFormat.dollars(cents: total))"
            }
            windows.append(UsageWindow(
                title: L10n.t("Monthly plan", "月度套餐"),
                usedPercent: percent,
                detail: detail,
                resetsAt: resetsAt))
        } else if let limit = plan.limit, limit > 0 {
            // Older shape, with no percentages to prefer.
            let used = plan.used ?? 0
            windows.append(UsageWindow(
                title: L10n.t("Monthly plan", "月度套餐"),
                usedPercent: Double(used) / Double(limit) * 100,
                detail: "\(QuotaFormat.dollars(cents: used)) / \(QuotaFormat.dollars(cents: limit))",
                resetsAt: resetsAt))
        }

        // Named-model usage runs down faster than the total and is usually the
        // binding constraint, so it gets its own row rather than being buried
        // inside the headline.
        if let api = plan.apiPercentUsed {
            windows.append(UsageWindow(
                title: L10n.t("Named models", "指定模型"),
                usedPercent: api,
                resetsAt: resetsAt,
                scope: L10n.t("Named models", "指定模型")))
        }
        return windows
    }

    /// Only accounts whose plan includes Grok Bot get the row: the endpoint
    /// answers for everyone, with `hasNonZeroIncludedLimit` false for the rest,
    /// and a 0% bar for an allowance that does not exist would be a lie.
    static func grokBotWindow(_ sand: SandUsage) -> UsageWindow? {
        guard sand.hasNonZeroIncludedLimit == true, let percent = sand.usagePercent else { return nil }
        let start = Dates.parseISO(sand.currentPeriodStart)
        let end = Dates.parseISO(sand.nextResetTimestampUtc)
        var seconds: Int?
        if let start, let end, end > start {
            seconds = Int(end.timeIntervalSince(start).rounded())
        }
        var window = UsageWindow(
            title: "Grok Bot",
            usedPercent: percent,
            resetsAt: end,
            windowSeconds: seconds,
            scope: "Grok Bot")
        window.extra = true
        return window
    }
}

// MARK: - Kimi Code (its own sign-in or an API key → coding/v1/usages, or a kimi-auth cookie → kimi.com / kimi.ai billing RPC)

public struct KimiProvider: QuotaProvider {
    public let id = ProviderID.kimi

    /// This Mac, or a test's throwaway directories and scripted network.
    let environment: KimiCodeEnvironment

    public init() {
        environment = .live
    }

    init(environment: KimiCodeEnvironment) {
        self.environment = environment
    }

    /// One card, three sources, decided on every refresh in this order:
    ///
    /// 1. **Something pasted in Settings.** Pasting is a deliberate override,
    ///    as for Cursor, Grok and OpenCode Go, and clearing it goes back to
    ///    the sign-in on this Mac. What it is follows from its shape
    ///    (`KimiPastedCredential`): a kimi-auth cookie — a bare JWT,
    ///    `kimi-auth=…`, a Cookie header — reads the billing gateway of
    ///    www.kimi.com, or of www.kimi.ai if kimi.com refuses it; a single
    ///    word is a Kimi Code API key, sent to the China edition's Code API
    ///    and to the Global one only if China refuses it. Once an edition has
    ///    answered, only that edition is asked.
    /// 2. **The Kimi Code sign-in on this Mac**, which the app and the `kimi`
    ///    CLI share, for whichever edition it signed in to. When its access
    ///    token is about to run out the running app renews it, under Kimi
    ///    Code's own lock (`KimiCodeRenewal`). The older Python CLI's file is
    ///    only read.
    /// 3. Neither: not configured.
    ///
    /// A sign-in whose access token has expired counts as configured while
    /// it can still be renewed; one that cannot does not.
    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .kimi) != nil || Self.localSession(environment) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let env = environment
        if let pasted = config.credential(for: .kimi) {
            let signedInLocally = Self.localSession(env) != nil
            switch KimiPastedCredential.classify(pasted) {
            case let .cookie(token):
                return try await Self.fetchCookie(token, signedInLocally: signedInLocally, env)
            case .cookieWithoutToken:
                throw ProviderError.sessionExpired(Self.cookieWithoutTokenHint)
            case .unrecognized:
                throw ProviderError.sessionExpired(Self.unrecognizedPasteHint)
            case let .apiKey(key):
                return try await Self.fetchAPIKey(key, signedInLocally: signedInLocally, env)
            }
        }
        return try await Self.fetchLocal(env)
    }

    static func localSession(_ env: KimiCodeEnvironment) -> LocalCredentials.KimiCodeSession? {
        LocalCredentials.kimiCodeSession(codeHome: env.codeHome, legacyHome: env.legacyHome, now: env.now())
    }

    /// For Settings: which source the next refresh uses and for which
    /// edition, and the console that goes with it.
    public func sourceInfo(config: ConfigStore) -> ProviderSourceInfo? {
        let env = environment
        let session = Self.localSession(env)
        if let pasted = config.credential(for: .kimi) {
            let note = session.map {
                L10n.t(
                    "Clear it to use the Kimi Code sign-in on this Mac (\($0.edition.label)).",
                    "清除后改用本机 Kimi Code 登录（\($0.edition.label)）。")
            }
            switch KimiPastedCredential.classify(pasted) {
            case let .cookie(token):
                return Self.pastedSource(.cookie, secret: token, note: note, env)
            case .cookieWithoutToken:
                return ProviderSourceInfo(
                    summary: L10n.t("A Cookie header with no kimi-auth cookie in it", "Cookie 头里没有 kimi-auth cookie"),
                    note: note)
            case .unrecognized:
                return ProviderSourceInfo(
                    summary: L10n.t("Neither a Kimi Code API key nor a kimi-auth cookie", "既不是 Kimi Code API Key，也不是 kimi-auth cookie"),
                    note: note)
            case let .apiKey(key):
                return Self.pastedSource(.apiKey, secret: key, note: note, env)
            }
        }
        guard let session else { return nil }
        let name = session.isLegacy
            ? L10n.t("Older Kimi CLI sign-in (~/.kimi)", "旧版 Kimi CLI 登录（~/.kimi）")
            : L10n.t("Kimi Code sign-in on this Mac", "Kimi Code 本机登录")
        var note: String?
        if case let .readOnly(reason) = KimiCodeRenewal.renewability(of: session, codeHome: env.codeHome, now: env.now()) {
            note = Self.readOnlyNote(reason)
        }
        return ProviderSourceInfo(
            summary: "\(name) · \(session.edition.longLabel)",
            note: note,
            consoleURL: session.edition.consoleURL)
    }

    /// "API key · Global (kimi.ai)": the edition this run of the app found,
    /// else the one the last reading kept on disk found with the same kind
    /// of credential, else not known yet.
    static func pastedSource(_ source: KimiSource, secret: String, note: String?, _ env: KimiCodeEnvironment) -> ProviderSourceInfo {
        let last = env.lastReading().flatMap { $0.source == source.rawValue ? $0.edition : nil }
        guard let edition = pastedEditions.edition(for: secret) ?? last.flatMap(KimiEdition.init(rawValue:)) else {
            return ProviderSourceInfo(
                summary: L10n.t("\(source.label) · edition found on the first refresh", "\(source.label) · 首次刷新后识别版本"),
                note: note)
        }
        return ProviderSourceInfo(
            summary: "\(source.label) · \(edition.longLabel)",
            note: note,
            consoleURL: edition.consoleURL)
    }

    // MARK: Kimi Code API key

    /// Which edition each pasted API key or cookie belongs to, by
    /// fingerprint, for this run of the app: only that edition is asked
    /// from then on, and Settings can say which. Never the secret itself,
    /// and never on disk.
    final class EditionMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var editions: [String: KimiEdition] = [:]

        func edition(for key: String) -> KimiEdition? {
            lock.withLock { editions[KimiPastedCredential.fingerprint(key)] }
        }

        func remember(_ edition: KimiEdition, for key: String) {
            lock.withLock { editions[KimiPastedCredential.fingerprint(key)] = edition }
        }

        /// The edition that answered before, alone: a key or cookie belongs
        /// to one edition, so a refusal there is final and the other is not
        /// asked. China, then Global, while none has answered.
        func order(for key: String) -> [KimiEdition] {
            edition(for: key).map { [$0] } ?? [.china, .global]
        }
    }

    static let pastedEditions = EditionMemo()

    /// `GET <edition>/usages` with the key as the Bearer — the endpoint
    /// Kimi Code's own sign-in reads, which takes API keys too. A key
    /// belongs to one edition and the other refuses it with a 401, so only
    /// a 401 moves on to the other edition. Any other answer — no plan, a
    /// rate limit, a server or network error — is that edition's, and the
    /// key goes no further.
    static func fetchAPIKey(_ key: String, signedInLocally: Bool, _ env: KimiCodeEnvironment) async throws -> UsageSnapshot {
        for edition in pastedEditions.order(for: key) {
            let response = try await env.send("GET", edition.usagesURL, [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
                "User-Agent": "QuotaBar",
            ], nil, 20)
            switch response.status {
            case 401:
                continue
            case 402, 403:
                // Recognised, with nothing to read: this edition is the key's.
                pastedEditions.remember(edition, for: key)
                throw ProviderError.noPlan(apiKeyNoPlanHint(edition))
            default:
                var snapshot = try parseCodeUsage(response.requireOK().data)
                snapshot.edition = edition.rawValue
                snapshot.source = KimiSource.apiKey.rawValue
                pastedEditions.remember(edition, for: key)
                return snapshot
            }
        }
        throw ProviderError.sessionExpired(rejectedAPIKeyHint(signedInLocally: signedInLocally))
    }

    static func apiKeyNoPlanHint(_ edition: KimiEdition) -> String {
        L10n.t(
            "Kimi Code \(edition.label) (\(edition.site)) accepted the API key, but this account has no Kimi Code plan to read.",
            "Kimi Code \(edition.label)（\(edition.site)）认可这个 API Key，但这个账号没有可读取的 Kimi Code 套餐。")
    }

    static func rejectedAPIKeyHint(signedInLocally: Bool) -> String {
        signedInLocally
            ? L10n.t(
                "Kimi rejected the API key pasted in Settings. Check it in the Kimi Code console of your edition (kimi.com or kimi.ai), or clear it to use the Kimi Code sign-in on this Mac.",
                "Kimi 拒绝了设置里粘贴的 API Key。请在你所用版本的 Kimi Code 控制台（kimi.com 或 kimi.ai）检查，或清除它以改用本机 Kimi Code 登录。")
            : L10n.t(
                "Kimi rejected the API key pasted in Settings. Check it in the Kimi Code console of your edition (kimi.com or kimi.ai), or paste a new one.",
                "Kimi 拒绝了设置里粘贴的 API Key。请在你所用版本的 Kimi Code 控制台（kimi.com 或 kimi.ai）检查，或粘贴新的 Key。")
    }

    // MARK: kimi-auth cookie

    /// The cookie reads the billing gateway of the site it came from:
    /// www.kimi.com, then www.kimi.ai when kimi.com refuses it. It is only
    /// ever sent to those two sites, never to a Code API host.
    static func fetchCookie(_ token: String, signedInLocally: Bool, _ env: KimiCodeEnvironment) async throws -> UsageSnapshot {
        for edition in pastedEditions.order(for: token) {
            do {
                var snapshot = try await fetchWeb(token: token, edition: edition, send: env.send)
                snapshot.edition = edition.rawValue
                snapshot.source = KimiSource.cookie.rawValue
                pastedEditions.remember(edition, for: token)
                return snapshot
            } catch ProviderError.unauthorized {
                continue
            }
        }
        // Signing in to Kimi Code again would change nothing while the
        // cookie is there, which is what `.unauthorized` suggests.
        throw ProviderError.sessionExpired(rejectedCookieHint(signedInLocally: signedInLocally))
    }

    static var cookieWithoutTokenHint: String {
        L10n.t(
            "The Cookie header pasted in Settings has no kimi-auth cookie in it. Paste the kimi-auth value from kimi.com or kimi.ai, or a Kimi Code API key.",
            "设置里粘贴的 Cookie 头里没有 kimi-auth cookie。请粘贴 kimi.com 或 kimi.ai 的 kimi-auth 值，或 Kimi Code API Key。")
    }

    static var unrecognizedPasteHint: String {
        L10n.t(
            "What is pasted in Settings for Kimi Code is neither a Kimi Code API key nor a kimi-auth cookie. Paste the key on its own, or the kimi-auth cookie's value.",
            "设置里为 Kimi Code 粘贴的内容既不是 Kimi Code API Key，也不是 kimi-auth cookie。请只粘贴 Key 本身，或 kimi-auth cookie 的值。")
    }

    // MARK: Kimi Code sign-in

    /// `GET <base>/usages` with the sign-in's access token — the call Kimi
    /// Code's own usage panel makes, and all it sends. The server allows no
    /// grace: a token a minute past its expiry gets a 401. So a token about
    /// to run out is renewed first, and a 401 on one that should still be
    /// good is answered with one renewal and one more try.
    static func fetchLocal(_ env: KimiCodeEnvironment) async throws -> UsageSnapshot {
        let now = env.now()
        guard let session = localSession(env) else {
            if !LocalCredentials.kimiCodeSessions(codeHome: env.codeHome, legacyHome: env.legacyHome).isEmpty {
                throw ProviderError.sessionExpired(signInAgainHint)
            }
            throw ProviderError.notConfigured(hint: ProviderID.kimi.setupHint)
        }
        let renewability = KimiCodeRenewal.renewability(of: session, codeHome: env.codeHome, now: now)
        var token = session.accessToken
        var renewed = false
        if session.isDueForRenewal(now: now) {
            if case let .renewable(context) = renewability, env.mayRenew {
                do {
                    token = try await renew(context, rejected: nil, env)
                    renewed = true
                } catch ProviderError.unavailable(_) where !session.isExpired(now: env.now()) {
                    // Kimi Code busy renewing, or the sign-in server away: the
                    // token still has a little while, enough for this one read.
                }
            } else if session.isExpired(now: now) {
                // Known without asking: no request goes out.
                throw renewability.isRenewable
                    ? ProviderError.unavailable(readOnlyRunHint)
                    : ProviderError.sessionExpired(expiredHint(renewability))
            }
        }
        var response = try await usages(session.usageURL, token: token, env)
        if response.status == 401, !renewed, env.mayRenew, case let .renewable(context) = renewability {
            token = try await renew(context, rejected: token, env)
            response = try await usages(session.usageURL, token: token, env)
        }
        switch response.status {
        case 401:
            if renewability.isRenewable, !env.mayRenew { throw ProviderError.unavailable(readOnlyRunHint) }
            throw ProviderError.sessionExpired(renewability.isRenewable ? rejectedSessionHint : expiredHint(renewability))
        case 402, 403:
            // Kimi Code's own panel offers the subscription page for these.
            throw ProviderError.noPlan(L10n.t(
                "Signed in to Kimi Code, but this account has no Kimi Code plan.",
                "已登录 Kimi Code，但这个账号没有订阅 Kimi Code 套餐。"))
        default:
            var snapshot = try parseCodeUsage(response.requireOK().data)
            snapshot.edition = session.edition.rawValue
            snapshot.source = (session.isLegacy ? KimiSource.legacySignIn : .signIn).rawValue
            return snapshot
        }
    }

    private static func usages(_ url: URL, token: String, _ env: KimiCodeEnvironment) async throws -> HTTPResponse {
        try await env.send("GET", url, [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
        ], nil, 20)
    }

    private static func renew(_ context: KimiCodeRenewal.Context, rejected: String?, _ env: KimiCodeEnvironment) async throws -> String {
        do {
            return try await env.renewal.accessToken(context, rejected: rejected, environment: env).accessToken
        } catch let failure as KimiCodeRenewal.Failure {
            switch failure {
            case .signInAgain: throw ProviderError.sessionExpired(signInAgainHint)
            case .busy: throw ProviderError.unavailable(renewalBusyHint)
            case let .unavailable(detail): throw ProviderError.unavailable(renewalFailedHint(detail))
            }
        }
    }

    /// The access token has run out and QuotaBar may not renew it, said
    /// with the reason and what brings it back.
    static func expiredHint(_ renewability: KimiCodeRenewability) -> String {
        guard case let .readOnly(reason) = renewability else { return rejectedSessionHint }
        switch reason {
        case .cannotRenew:
            return signInAgainHint
        case .olderCLI:
            return L10n.t(
                "The sign-in the older Kimi CLI saved in ~/.kimi has expired, and QuotaBar only reads that one. Sign in to the Kimi Code app or the current `kimi` CLI, and QuotaBar keeps that sign-in renewed.",
                "旧版 Kimi CLI 在 ~/.kimi 保存的登录已过期，QuotaBar 只读取、不续期这份登录。登录 Kimi Code 应用或新版 `kimi` CLI 后，QuotaBar 会让那份登录保持续期。")
        case .notInUse:
            return L10n.t(
                "The Kimi Code sign-in token on this Mac has expired. QuotaBar renews only the sign-in Kimi Code's settings (~/.kimi-code/config.toml) say is in use, and this is not it: use Kimi Code once, or sign in again.",
                "本机的 Kimi Code 登录令牌已过期。QuotaBar 只续期 Kimi Code 设置（~/.kimi-code/config.toml）里正在使用的登录，这份不是：用一次 Kimi Code，或重新登录。")
        case .noDeviceID:
            return L10n.t(
                "The Kimi Code sign-in token on this Mac has expired. Renewing it needs the device id Kimi Code creates when it first starts: open Kimi Code once and the quota shows again.",
                "本机的 Kimi Code 登录令牌已过期。续期需要 Kimi Code 首次启动时生成的设备 ID：打开一次 Kimi Code，额度就会重新显示。")
        }
    }

    /// For Settings, under the source: why this sign-in is left alone.
    static func readOnlyNote(_ reason: KimiCodeRenewability.Reason) -> String {
        switch reason {
        case .olderCLI:
            L10n.t("Read only: QuotaBar does not renew the older CLI's sign-in.", "只读：QuotaBar 不续期旧版 CLI 的登录。")
        case .cannotRenew:
            L10n.t("Can no longer be renewed: sign in again once it runs out.", "已无法续期，过期后需要重新登录。")
        case .notInUse:
            L10n.t("Read only: not the sign-in Kimi Code's settings say is in use.", "只读：不是 Kimi Code 设置里正在使用的登录。")
        case .noDeviceID:
            L10n.t("Read only until Kimi Code has created this Mac's device id.", "Kimi Code 还没有为本机生成设备 ID，暂时只读。")
        }
    }

    /// The access token has run out and nothing renews it — the refresh
    /// token ran out too, 30 days after Kimi Code was last used, or there is
    /// none, or the sign-in server refused it — so only signing in brings it back.
    static var signInAgainHint: String {
        L10n.t(
            "Kimi Code's sign-in on this Mac has ended and can no longer be renewed. Sign in again in the Kimi Code app or with `kimi`, or paste a Kimi Code API key or kimi-auth cookie in Settings.",
            "Kimi Code 在本机的登录已失效，无法再续期。请在 Kimi Code 应用里或用 `kimi` 重新登录，或在设置里粘贴 Kimi Code API Key 或 kimi-auth cookie。")
    }

    /// A one-off command (`--json`, `--provider`) found the token run out:
    /// renewing is left to the app, which can see a renewal through.
    static var readOnlyRunHint: String {
        L10n.t(
            "The Kimi Code sign-in token on this Mac has expired. The QuotaBar app renews it while it runs; a one-off command only reads it.",
            "本机的 Kimi Code 登录令牌已过期。QuotaBar 应用运行时会续期它；一次性命令只读取、不续期。")
    }

    /// Kimi Code held its lock for the whole wait: it is renewing itself.
    static var renewalBusyHint: String {
        L10n.t(
            "Kimi Code is renewing its sign-in right now; QuotaBar reads the quota again at the next refresh.",
            "Kimi Code 正在续期登录，QuotaBar 会在下次刷新时重新读取额度。")
    }

    static func renewalFailedHint(_ detail: String) -> String {
        L10n.t(
            "Couldn't renew the Kimi Code sign-in (\(detail)). QuotaBar tries again at the next refresh.",
            "无法续期 Kimi Code 登录（\(detail)），QuotaBar 会在下次刷新时重试。")
    }

    /// A pasted cookie comes first, so it has to go before the sign-in on
    /// this Mac can be used.
    static func rejectedCookieHint(signedInLocally: Bool) -> String {
        signedInLocally
            ? L10n.t(
                "Kimi turned down the kimi-auth cookie pasted in Settings, which is used before the Kimi Code sign-in on this Mac. Clear it in Settings to use that sign-in, or paste a fresh cookie.",
                "Kimi 拒绝了设置里粘贴的 kimi-auth cookie；有 cookie 时会先用它，而不是本机 Kimi Code 的登录。在设置里清除它即可改用本机登录，或粘贴新的 cookie。")
            : L10n.t(
                "Kimi turned down the kimi-auth cookie pasted in Settings. Paste a fresh one or a Kimi Code API key, or clear it and sign in to the Kimi Code app or CLI (`kimi`) instead.",
                "Kimi 拒绝了设置里粘贴的 kimi-auth cookie。请粘贴新的 cookie 或 Kimi Code API Key，或清除它，改为登录 Kimi Code 应用或 CLI（`kimi`）。")
    }

    /// Turned down even after a renewal.
    static var rejectedSessionHint: String {
        L10n.t(
            "Kimi turned down the Kimi Code sign-in on this Mac, even renewed. Sign in again in the Kimi Code app or with `kimi`.",
            "Kimi 拒绝了本机的 Kimi Code 登录，续期后仍然如此。请在 Kimi Code 应用里或用 `kimi` 重新登录。")
    }

    /// Pure. The live reply carries the same limits twice:
    ///
    ///     {"usage": {"limit": "100", "remaining": "100", "resetTime": "…"},
    ///      "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
    ///                  "detail": {"limit": "100", "remaining": "100", "resetTime": "…"}}],
    ///      "usages": {"limit_5h": {"used_ratio": 0, "reset_time": "…"},
    ///                 "limit_7d": {"used_ratio": 0, "reset_time": "…"}}}
    ///
    /// `usages` holds the ratio pools the Kimi Code desktop app reads, and
    /// they win wherever they are present and sane; `usage` (weekly) and
    /// `limits` are the older counts, used for any window no pool covers.
    /// Pools carry no counts, so their windows have no detail line. Following
    /// CodexBar (#3697), `limit_month_total` is the monthly window and
    /// `limit_month_code` — the Code share of that same pool — is left out.
    public static func parseCodeUsage(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        let pools = root["usages"] as? [String: Any] ?? [:]

        // The counts: `usage` is the week, each `limits[]` entry a window of
        // its own length. The first count per length is the one compared
        // with a pool below; any other stands alone.
        var counts: [Int: UsageWindow] = [:]
        var standalone: [UsageWindow] = []
        if let weekly = countWindow(root["usage"], title: WindowTitle.forSeconds(604_800), seconds: 604_800) {
            counts[604_800] = weekly
        }
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            let seconds = windowSeconds(entry["window"])
            let named = ["name", "title", "scope"].lazy.compactMap { entry[$0] as? String }.first { !$0.isEmpty }
            let title = seconds.map(WindowTitle.forSeconds) ?? named ?? L10n.t("Rate limit", "速率限制")
            guard let window = countWindow(entry["detail"] ?? entry, title: title, seconds: seconds) else { continue }
            if let seconds, counts[seconds] == nil {
                counts[seconds] = window
            } else {
                standalone.append(window)
            }
        }

        // Both forms can come in one reply and disagree: on 2026-09-19 the
        // pools said 0 for the 5-hour window while its count read 100 of
        // 100, and the week 0 against 21 of 100. So each window takes
        // whichever says more is used — a quota shown as untouched when it
        // is spent is the one mistake that costs the owner — with the count
        // preferred on a tie, since it also gives "used / limit".
        var windows: [UsageWindow] = []
        for (key, seconds) in [("limit_5h", 18_000), ("limit_7d", 604_800), ("limit_month_total", 2_592_000)] {
            let pool = ratioWindow(pools[key], seconds: seconds)
            if let window = fuller(pool, counts.removeValue(forKey: seconds)) { windows.append(window) }
        }
        windows += counts.sorted { $0.key < $1.key }.map(\.value)
        windows += standalone
        guard !windows.isEmpty else { throw ProviderError.badResponse }

        // Shortest first, as the other providers list them.
        let ordered = windows.enumerated()
            .sorted { ($0.element.windowSeconds ?? .max, $0.offset) < ($1.element.windowSeconds ?? .max, $1.offset) }
            .map(\.element)
        return UsageSnapshot(planName: planName(root["user"], version: root["version"]), windows: ordered)
    }

    /// The pool or the count for one window, whichever reports more used; the
    /// count on a tie. The one kept borrows the other's reset time if it has
    /// none.
    static func fuller(_ pool: UsageWindow?, _ count: UsageWindow?) -> UsageWindow? {
        guard let pool else { return count }
        guard let count else { return pool }
        let countWins = (count.usedPercent ?? -1) >= (pool.usedPercent ?? -1)
        var chosen = countWins ? count : pool
        if chosen.resetsAt == nil { chosen.resetsAt = (countWins ? pool : count).resetsAt }
        return chosen
    }

    /// `{"used_ratio": 0.42, "reset_time": "…"}`. A missing, negative or
    /// non-finite ratio gives nothing, so the older counts can stand in.
    static func ratioWindow(_ raw: Any?, seconds: Int) -> UsageWindow? {
        guard let pool = raw as? [String: Any],
              let ratio = QwenProvider.number(pool["used_ratio"]), ratio.isFinite, ratio >= 0
        else { return nil }
        return UsageWindow(
            title: WindowTitle.forSeconds(seconds),
            usedPercent: min(ratio, 1) * 100,
            resetsAt: date(pool["reset_time"]),
            windowSeconds: seconds)
    }

    /// `{"limit": "100", "used": "12", "remaining": "88", "resetTime": "…"}`,
    /// numbers as strings or not. `used` is taken as given — it may pass
    /// `limit` — and otherwise worked out from `remaining`. Infinite figures
    /// ("inf", "1e400") give nothing.
    static func countWindow(_ raw: Any?, title: String, seconds: Int?) -> UsageWindow? {
        guard let detail = raw as? [String: Any],
              let limit = QwenProvider.number(detail["limit"]), limit.isFinite, limit > 0
        else { return nil }
        let used: Double
        if let reported = QwenProvider.number(detail["used"]), reported.isFinite, reported >= 0 {
            used = reported
        } else if let remaining = QwenProvider.number(detail["remaining"]), remaining.isFinite,
                  remaining >= 0, remaining <= limit
        {
            used = limit - remaining
        } else {
            return nil
        }
        let reset = ["resetTime", "resetAt", "reset_time", "reset_at"].lazy.compactMap { date(detail[$0]) }.first
        return UsageWindow(
            title: title,
            usedPercent: used / limit * 100,
            detail: countDetail(used: used, limit: limit),
            resetsAt: reset,
            windowSeconds: seconds)
    }

    /// "12 / 100", or nothing when a figure is no whole number an `Int` holds.
    /// The counts come as int64 strings, and a plan with no cap may send
    /// int64's largest, which a `Double` rounds past `Int.max`: `Int(_:)`
    /// would stop the app there.
    static func countDetail(used: Double, limit: Double) -> String? {
        guard let used = Int(exactly: used.rounded(.towardZero)),
              let limit = Int(exactly: limit.rounded(.towardZero))
        else { return nil }
        return "\(used) / \(limit)"
    }

    /// `{"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}` in seconds.
    static func windowSeconds(_ raw: Any?) -> Int? {
        guard let window = raw as? [String: Any],
              let duration = QwenProvider.number(window["duration"]), duration > 0
        else { return nil }
        let unit: Double
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": unit = 60
        case "TIME_UNIT_HOUR": unit = 3_600
        case "TIME_UNIT_DAY": unit = 86_400
        case "TIME_UNIT_WEEK": unit = 604_800
        default: return nil
        }
        // Checked, not `Int(_:)`, for the same reason as `countDetail`.
        guard let seconds = Int(exactly: (duration * unit).rounded()), seconds > 0 else { return nil }
        return seconds
    }

    /// `{"membership": {"level": "LEVEL_INTERMEDIATE"}}`. The first goods
    /// version names its levels after tempos, as Kimi's plans are named
    /// (mapping after CodexBar); a later version shows the level as sent.
    static func planName(_ raw: Any?, version: Any?) -> String? {
        guard let user = raw as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let level = (membership["level"] as? String)?.trimmingCharacters(in: .whitespaces),
              !level.isEmpty, level != "LEVEL_UNSPECIFIED"
        else { return nil }
        let goods = version as? String
        if goods == nil || goods == "GOODS_VERSION_V1" {
            let tempos = [
                "LEVEL_FREE": "Adagio",
                "LEVEL_TRIAL": "Andante",
                "LEVEL_BASIC": "Moderato",
                "LEVEL_INTERMEDIATE": "Allegretto",
                "LEVEL_ADVANCED": "Allegro",
            ]
            if let tempo = tempos[level] { return tempo }
        }
        let words = level.replacingOccurrences(of: "LEVEL_", with: "").split(separator: "_")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// ISO 8601 with any number of fractional digits ("…33.809775Z"), or epoch.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, let parsed = LocalCredentials.parseFlexibleISO(text) { return parsed }
        return QwenProvider.number(value).flatMap(Dates.parseEpoch)
    }

    // MARK: kimi.com / kimi.ai billing gateway

    /// The Kimi Code console's own calls on www.kimi.com or www.kimi.ai,
    /// signed in by the kimi-auth cookie.
    static func fetchWeb(token: String, edition: KimiEdition, send: @escaping HTTPSend = HTTP.live) async throws -> UsageSnapshot {
        let site = "https://www.\(edition.site)"
        let headers = [
            "Authorization": "Bearer \(token)",
            "Cookie": "kimi-auth=\(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": site,
            "Referer": "\(site)/code/console",
            "connect-protocol-version": "1",
            "x-msh-platform": "web",
        ]

        struct Detail: Decodable {
            let limit: String?
            let used: String?
            let remaining: String?
            let resetTime: String?
            let resetAt: String?
        }
        struct Usage: Decodable {
            let scope: String?
            let detail: Detail?
        }
        struct UsagesBody: Decodable {
            let usages: [Usage]?
        }
        struct SubscriptionBalance: Decodable {
            let amountUsedRatio: Double?
            let expireTime: String?
        }
        struct RateLimit7d: Decodable {
            let ratio: Double?
            let resetTime: String?
        }
        struct StatsBody: Decodable {
            let subscriptionBalance: SubscriptionBalance?
            let ratelimitCode7d: RateLimit7d?
        }

        let usagesURL = URL(string: "\(site)/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
        let usages = try await send("POST", usagesURL, headers, Data("{}".utf8), 20).requireOK().json(UsagesBody.self)

        var windows: [UsageWindow] = []
        for usage in usages.usages ?? [] {
            guard let detail = usage.detail else { continue }
            let limit = Double(detail.limit ?? "").flatMap { $0.isFinite ? $0 : nil } ?? 0
            let used = Double(detail.used ?? "").flatMap { $0.isFinite ? $0 : nil } ?? 0
            let reset = Dates.parseAny(detail.resetTime) ?? Dates.parseAny(detail.resetAt)
            let percent: Double? = limit > 0 ? used / limit * 100 : nil
            windows.append(UsageWindow(
                title: usage.scope ?? L10n.t("Usage", "用量"),
                usedPercent: percent,
                detail: limit > 0 ? countDetail(used: used, limit: limit) : nil,
                resetsAt: reset))
        }

        let statsURL = URL(string: "\(site)/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!
        if let stats = try? await send("POST", statsURL, headers, Data("{}".utf8), 20).requireOK().json(StatsBody.self) {
            if let balance = stats.subscriptionBalance, let ratio = balance.amountUsedRatio {
                windows.append(UsageWindow(
                    title: L10n.t("Subscription balance", "订阅余额"),
                    usedPercent: ratio <= 1 ? ratio * 100 : ratio,
                    resetsAt: Dates.parseAny(balance.expireTime)))
            }
            if let weekly = stats.ratelimitCode7d, let ratio = weekly.ratio {
                windows.append(UsageWindow(
                    title: WindowTitle.forSeconds(604_800),
                    usedPercent: ratio <= 1 ? ratio * 100 : ratio,
                    resetsAt: Dates.parseAny(weekly.resetTime),
                    windowSeconds: 604_800))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - z.ai (API key → api.z.ai quota/limit)

public struct ZaiProvider: QuotaProvider {
    public let id = ProviderID.zai

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .zai) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: .zai) else {
            throw ProviderError.notConfigured(hint: ProviderID.zai.setupHint)
        }
        return try await Self.fetchQuota(host: "https://api.z.ai", key: key)
    }

    /// The GLM Coding Plan quota endpoint, on z.ai or on bigmodel.cn.
    static func fetchQuota(host: String, key: String) async throws -> UsageSnapshot {
        let url = URL(string: "\(host)/api/monitor/usage/quota/limit")!
        let response = try await HTTP.get(url, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ]).requireOK()

        struct Limit: Decodable {
            let type: String?
            let percentage: Double?
            let usage: Int?
            let remaining: Int?
            let nextResetTime: Double?
            let unit: Int?
            let number: Int?
        }
        struct DataBody: Decodable {
            let limits: [Limit]?
        }
        struct Body: Decodable {
            let data: DataBody?
        }

        let body = try response.json(Body.self)
        guard let limits = body.data?.limits else { throw ProviderError.badResponse }

        // z.ai encodes the window as (unit, number); minutes per unit code.
        let unitMinutes: [Int: Int] = [0: 1, 1: 60, 2: 1440, 3: 10_080, 4: 43_200, 5: 43_800]
        var windows: [UsageWindow] = []
        for limit in limits {
            let minutes = (limit.number ?? 0) * (unitMinutes[limit.unit ?? -1] ?? 0)
            let title = minutes > 0
                ? WindowTitle.forMinutes(minutes)
                : (limit.type ?? L10n.t("Quota", "额度"))
            windows.append(UsageWindow(
                title: title,
                usedPercent: limit.percentage,
                detail: limit.usage.flatMap { usage in
                    limit.remaining.map { L10n.t("\($0) left of \(usage)", "剩余 \($0) / 共 \(usage)") }
                },
                resetsAt: Dates.parseEpoch(limit.nextResetTime),
                windowSeconds: minutes > 0 ? minutes * 60 : nil))
        }
        return UsageSnapshot(windows: windows)
    }
}
