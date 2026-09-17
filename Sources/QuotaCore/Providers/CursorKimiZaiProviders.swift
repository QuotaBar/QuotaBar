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
        return UsageWindow(
            title: "Grok Bot",
            usedPercent: percent,
            resetsAt: end,
            windowSeconds: seconds,
            scope: "Grok Bot")
    }
}

// MARK: - Kimi Code (Kimi Code's own sign-in → coding/v1/usages, or a kimi-auth cookie → kimi.com billing RPC)

public struct KimiProvider: QuotaProvider {
    public let id = ProviderID.kimi

    /// Two sources, decided the way Cursor, Grok and OpenCode Go decide: a
    /// pasted kimi-auth cookie wins, because pasting one is a deliberate
    /// override and clearing it goes back to the sign-in on this Mac.
    /// Without one, the session the Kimi Code app and CLI share is read.
    /// An expired session still counts as configured: the card then says how
    /// to bring it back, rather than sending the owner to set up a sign-in
    /// that is already there.
    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .kimi) != nil || LocalCredentials.kimiCodeSession() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        if let token = config.credential(for: .kimi) {
            return try await Self.fetchWeb(token: token)
        }
        guard let session = LocalCredentials.kimiCodeSession() else {
            throw ProviderError.notConfigured(hint: ProviderID.kimi.setupHint)
        }
        return try await Self.fetchCode(session: session)
    }

    // MARK: Kimi Code session

    /// `GET <base>/usages` with the access token — the call Kimi Code's own
    /// usage panel makes, and all it sends.
    static func fetchCode(session: LocalCredentials.KimiCodeSession, now: Date = Date()) async throws -> UsageSnapshot {
        // Never renewed here; see `LocalCredentials.kimiCodeSession()`. The
        // server allows no grace either: a token a minute past its expiry
        // gets a 401, so asking would only turn a known answer into a vaguer one.
        guard !session.isExpired(now: now) else {
            throw ProviderError.sessionExpired(expiredSessionHint)
        }
        let response = try await HTTP.get(session.usageURL, headers: [
            "Authorization": "Bearer \(session.accessToken)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
        ])
        switch response.status {
        case 401:
            throw ProviderError.sessionExpired(rejectedSessionHint)
        case 402, 403:
            // Kimi Code's own panel offers the subscription page for these.
            throw ProviderError.noPlan(L10n.t(
                "Signed in to Kimi Code, but this account has no Kimi Code plan.",
                "已登录 Kimi Code，但这个账号没有订阅 Kimi Code 套餐。"))
        default:
            return try parseCodeUsage(response.requireOK().data)
        }
    }

    static var expiredSessionHint: String {
        L10n.t(
            "The sign-in token Kimi Code saved on this Mac has expired. It lasts 15 minutes, and Kimi Code renews it only while in use: use Kimi Code once, in the app or with `kimi`, and the quota shows again. No need to sign in again.",
            "Kimi Code 在本机保存的登录令牌已过期。令牌只有 15 分钟有效，Kimi Code 只在使用时才续期：在应用里或用 `kimi` 用一次 Kimi Code，额度就会重新显示，不用重新登录。")
    }

    static var rejectedSessionHint: String {
        L10n.t(
            "Kimi turned down the sign-in token Kimi Code saved on this Mac. Use Kimi Code once so it renews the token; if it asks you to sign in, sign in again.",
            "Kimi 拒绝了 Kimi Code 在本机保存的登录令牌。用一次 Kimi Code 让它续期；如果它要求登录，请重新登录。")
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
        var windows: [UsageWindow] = []
        if let pool = ratioWindow(pools["limit_5h"], seconds: 18_000) { windows.append(pool) }
        if let pool = ratioWindow(pools["limit_7d"], seconds: 604_800) {
            windows.append(pool)
        } else if let weekly = countWindow(root["usage"], title: WindowTitle.forSeconds(604_800), seconds: 604_800) {
            windows.append(weekly)
        }
        if let pool = ratioWindow(pools["limit_month_total"], seconds: 2_592_000) { windows.append(pool) }

        let covered = Set(windows.compactMap(\.windowSeconds))
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            let seconds = windowSeconds(entry["window"])
            if let seconds, covered.contains(seconds) { continue }
            let named = ["name", "title", "scope"].lazy.compactMap { entry[$0] as? String }.first { !$0.isEmpty }
            let title = seconds.map(WindowTitle.forSeconds) ?? named ?? L10n.t("Rate limit", "速率限制")
            if let window = countWindow(entry["detail"] ?? entry, title: title, seconds: seconds) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }

        // Shortest first, as the other providers list them.
        let ordered = windows.enumerated()
            .sorted { ($0.element.windowSeconds ?? .max, $0.offset) < ($1.element.windowSeconds ?? .max, $1.offset) }
            .map(\.element)
        return UsageSnapshot(planName: planName(root["user"], version: root["version"]), windows: ordered)
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
    /// `limit` — and otherwise worked out from `remaining`.
    static func countWindow(_ raw: Any?, title: String, seconds: Int?) -> UsageWindow? {
        guard let detail = raw as? [String: Any],
              let limit = QwenProvider.number(detail["limit"]), limit > 0
        else { return nil }
        let used: Double
        if let reported = QwenProvider.number(detail["used"]), reported >= 0 {
            used = reported
        } else if let remaining = QwenProvider.number(detail["remaining"]), remaining >= 0, remaining <= limit {
            used = limit - remaining
        } else {
            return nil
        }
        let reset = ["resetTime", "resetAt", "reset_time", "reset_at"].lazy.compactMap { date(detail[$0]) }.first
        return UsageWindow(
            title: title,
            usedPercent: used / limit * 100,
            detail: "\(Int(used)) / \(Int(limit))",
            resetsAt: reset,
            windowSeconds: seconds)
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
        return Int(duration * unit)
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

    // MARK: kimi-auth cookie

    static func fetchWeb(token: String) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Cookie": "kimi-auth=\(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": "https://www.kimi.com",
            "Referer": "https://www.kimi.com/code/console",
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

        let usagesURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
        let usages = try await HTTP.post(usagesURL, headers: headers).requireOK().json(UsagesBody.self)

        var windows: [UsageWindow] = []
        for usage in usages.usages ?? [] {
            guard let detail = usage.detail else { continue }
            let limit = Double(detail.limit ?? "") ?? 0
            let used = Double(detail.used ?? "") ?? 0
            let reset = Dates.parseAny(detail.resetTime) ?? Dates.parseAny(detail.resetAt)
            let percent: Double? = limit > 0 ? used / limit * 100 : nil
            windows.append(UsageWindow(
                title: usage.scope ?? L10n.t("Usage", "用量"),
                usedPercent: percent,
                detail: limit > 0 ? "\(Int(used)) / \(Int(limit))" : nil,
                resetsAt: reset))
        }

        let statsURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!
        if let stats = try? await HTTP.post(statsURL, headers: headers).requireOK().json(StatsBody.self) {
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
