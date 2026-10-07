import Foundation

// MARK: - Codex (ChatGPT OAuth via ~/.codex/auth.json → wham/usage)

public struct CodexProvider: QuotaProvider {
    public let id = ProviderID.codex

    public init() {}

    public func isConfigured(config: ConfigStore) -> Bool {
        LocalCredentials.codexAuth() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        // A profile (#8) reading a kept account other than the CLI's.
        if let kept = config.experience.activeProfile?.codexAccountID,
           await CodexAccountVault.shared.live()?.accountID != kept
        {
            let file = try await CodexAccountVault.shared.credentials(for: kept)
            return try await Self.usage(accessToken: file.accessToken, accountID: file.accountID)
        }
        guard let auth = LocalCredentials.codexAuth() else {
            throw ProviderError.notConfigured(hint: ProviderID.codex.setupHint)
        }
        return try await Self.usage(accessToken: auth.accessToken, accountID: auth.accountId)
    }

    /// One account's limits, read with that account's own token: the one the
    /// CLI is signed in as, or one QuotaBar keeps (`CodexAccountVault`).
    public static func usage(accessToken: String, accountID: String?) async throws -> UsageSnapshot {
        let auth = LocalCredentials.CodexAuth(accessToken: accessToken, accountId: accountID)
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
        ]
        if let accountId = auth.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let response = try await HTTP.get(url, headers: headers).requireOK()
        var snapshot = try parse(response.data, fallbackAccount: auth.accountId)
        // The usage reply only counts the resets the account was given; what
        // they are, when each runs out and how many came in all is one list
        // away. A failure there costs those, not the reading (issue #3).
        if let available = snapshot.resetCredits?.available {
            let account = auth.accountId ?? snapshot.account
            var list = creditList.reusable(account: account, available: available)
            if list == nil,
               let response = try? await HTTP.get(
                   URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, headers: headers).requireOK(),
               let read = resetCreditList(response.data)
            {
                creditList.store(read, account: account, available: available)
                list = read
            }
            if let list {
                snapshot.resetCredits?.credits = list.credits
                snapshot.resetCredits?.totalEarned = list.totalEarned
            }
        }
        // The usage reply gives the credit balance but not where it came from
        // or when it runs out; the account's balance does. Same terms: a
        // failure costs the deadline, not the reading.
        if let index = snapshot.windows.firstIndex(where: { $0.credit != nil }),
           let account = auth.accountId, let balance = snapshot.windows[index].credit?.amount
        {
            var grants = creditGrants.reusable(account: account, balance: balance)
            if grants == nil,
               let response = try? await HTTP.get(
                   URL(string: "https://chatgpt.com/backend-api/accounts/\(account)/remaining_balance")!, headers: headers)
                   .requireOK(),
               let read = creditGrants(response.data)
            {
                creditGrants.store(read, account: account, balance: balance)
                grants = read
            }
            if let grants { apply(grants, to: &snapshot.windows[index]) }
        }
        return snapshot
    }

    static let creditGrants = CreditGrantCache()

    /// Where the credits came from and when they run out, as
    /// `/accounts/{id}/remaining_balance` lists them.
    struct CreditGrant: Equatable, Sendable {
        var granted: Double?
        var remaining: Double?
        var expiresAt: Date?
        /// "promotional_credit" for credits given; others for bought ones.
        var kind: String?

        var isGiven: Bool { kind?.lowercased().contains("promo") == true }
    }

    /// The last grants read per account, asked again when the balance
    /// changes or after an hour.
    final class CreditGrantCache: @unchecked Sendable {
        private struct Entry {
            let balance: String
            let grants: [CreditGrant]
            let readAt: Date
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func reusable(account: String, balance: String, now: Date = .now) -> [CreditGrant]? {
            lock.withLock {
                guard let entry = entries[account], entry.balance == balance,
                      now.timeIntervalSince(entry.readAt) < 3600
                else { return nil }
                return entry.grants
            }
        }

        func store(_ grants: [CreditGrant], account: String, balance: String, now: Date = .now) {
            lock.withLock { entries[account] = Entry(balance: balance, grants: grants, readAt: now) }
        }
    }

    /// `{"balance":"62500","expiring_balance_details":[{"amount_granted":"62500",
    /// "amount_remaining":"62500","expiry_date":"2027-01-01T00:00:00Z",
    /// "grant_type":"promotional_credit"}]}` — the grants with something
    /// left, soonest deadline first. Nil for a reply that is not that.
    static func creditGrants(_ data: Data, now: Date = .now) -> [CreditGrant]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = root["expiring_balance_details"] as? [[String: Any]]
        else { return nil }
        func amount(_ value: Any?) -> Double? {
            if let text = value as? String { return Double(text) }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
            return nil
        }
        return details
            .map { detail in
                CreditGrant(
                    granted: amount(detail["amount_granted"]),
                    remaining: amount(detail["amount_remaining"]),
                    expiresAt: Dates.parseISO(detail["expiry_date"] as? String),
                    kind: detail["grant_type"] as? String)
            }
            .filter { ($0.remaining ?? 1) > 0 && ($0.expiresAt ?? .distantFuture) > now }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The soonest deadline on the credit row, and what was given.
    static func apply(_ grants: [CreditGrant], to window: inout UsageWindow) {
        guard var credit = window.credit, !grants.isEmpty else { return }
        credit.expiresAt = grants.first?.expiresAt
        let given = grants.filter(\.isGiven).compactMap(\.granted).reduce(0, +)
        if given > 0, credit.caption?.hasPrefix(L10n.t("Overage", "已达")) != true {
            let count = QuotaFormat.grouped(given)
            credit.caption = grants.allSatisfy(\.isGiven)
                ? L10n.t("Given \(count) credits", "赠送 \(count) 点")
                : L10n.t("\(count) given", "其中赠送 \(count) 点")
        }
        if grants.count > 1, let soonest = grants.first, let left = soonest.remaining {
            let note = L10n.t(
                "\(QuotaFormat.grouped(left)) of them run out first.",
                "其中 \(QuotaFormat.grouped(left)) 点最先到期。")
            window.note = [window.note, note].compactMap { $0 }.joined(separator: " ")
        }
        window.credit = credit
    }

    static let creditList = ResetCreditListCache()

    /// What the credit list says: the available credits and how many the
    /// account was ever given.
    struct ResetCreditList: Equatable, Sendable {
        var credits: [ResetCredit]
        var totalEarned: Int?
    }

    /// The last credit list read, so it is not read with every refresh: the
    /// endpoint answers 429 when polled. Asked again when the count changes —
    /// a reset given or spent — when a deadline it listed has passed, or
    /// after an hour.
    final class ResetCreditListCache: @unchecked Sendable {
        private struct Entry {
            let account: String?
            let available: Int
            let list: ResetCreditList
            let readAt: Date
        }

        private let lock = NSLock()
        /// One per account: with several Codex accounts kept (issue #6) they
        /// are read in turn, and a single entry would be replaced by each,
        /// sending every account's list back to the endpoint each refresh.
        private var entries: [String: Entry] = [:]

        func reusable(account: String?, available: Int, now: Date = .now) -> ResetCreditList? {
            lock.withLock {
                guard let entry = entries[account ?? ""], entry.account == account, entry.available == available,
                      now.timeIntervalSince(entry.readAt) < 3600,
                      !entry.list.credits.contains(where: { ($0.expiresAt ?? .distantFuture) <= now })
                else { return nil }
                return entry.list
            }
        }

        func store(_ list: ResetCreditList, account: String?, available: Int, now: Date = .now) {
            lock.withLock { entries[account ?? ""] = Entry(account: account, available: available, list: list, readAt: now) }
        }
    }

    /// `{"credits":[{"id":…,"reset_type":"codex_rate_limits","status":"available",
    /// "granted_at":"2026-06-17T00:00:00Z","expires_at":"2026-07-17T00:00:00Z",
    /// "title":"Full reset (Weekly + 5 hr)"}],"available_count":1,
    /// "total_earned_count":3}` — the shape the Codex CLI reads. The credits
    /// still available, soonest deadline first and the ones that never expire
    /// last; nil for a reply that is not that list.
    static func resetCreditList(_ data: Data, now: Date = .now) -> ResetCreditList? {
        struct Credit: Decodable {
            let id: String?
            let status: String?
            let title: String?
            let grantedAt: String?
            let expiresAt: String?
            enum CodingKeys: String, CodingKey {
                case id, status, title
                case grantedAt = "granted_at"
                case expiresAt = "expires_at"
            }
        }
        struct Body: Decodable {
            let credits: [Credit]?
            let totalEarnedCount: Int?
            enum CodingKeys: String, CodingKey {
                case credits
                case totalEarnedCount = "total_earned_count"
            }
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              body.credits != nil || body.totalEarnedCount != nil
        else { return nil }
        let credits = (body.credits ?? [])
            .filter { ($0.status ?? "available") == "available" }
            .map { credit in
                ResetCredit(
                    id: credit.id,
                    title: credit.title.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                    grantedAt: Dates.parseISO(credit.grantedAt),
                    expiresAt: Dates.parseISO(credit.expiresAt))
            }
            .filter { ($0.expiresAt ?? .distantFuture) > now }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return ResetCreditList(credits: credits, totalEarned: body.totalEarnedCount)
    }

    // MARK: Response shape

    struct Window: Decodable {
        let usedPercent: Double?
        /// Window length; the label is derived from this rather than assumed —
        /// a Pro plan reports a single 7-day primary window, not a 5-hour one.
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        let allowed: Bool?
        let limitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
            case allowed
            case limitReached = "limit_reached"
        }
    }

    struct AdditionalLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?
        /// The model this limit's requests go to, e.g. "gpt-5.6-luna" for the
        /// reserve.
        let normalModelSlug: String?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
            case normalModelSlug = "normal_model_slug"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
        let overageLimitReached: Bool?
        /// How many local Codex messages the balance is worth, fewest to most
        /// — the range ChatGPT's own usage page gives.
        let approxLocalMessages: [Int]?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
            case overageLimitReached = "overage_limit_reached"
            case approxLocalMessages = "approx_local_messages"
        }
    }

    struct ResetCreditsBody: Decodable {
        let availableCount: Int?
        let applicableAvailableCount: Int?

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case applicableAvailableCount = "applicable_available_count"
        }
    }

    struct Body: Decodable {
        let email: String?
        let accountId: String?
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalLimit]?
        let credits: Credits?
        let rateLimitResetCredits: ResetCreditsBody?

        enum CodingKeys: String, CodingKey {
            case email
            case accountId = "account_id"
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
            case credits
            case rateLimitResetCredits = "rate_limit_reset_credits"
        }
    }

    /// The plan as ChatGPT sells it. The usage endpoint names the three Pro
    /// tiers by their internal ids, so capitalising the id showed them all as
    /// "Pro"; the names are the ones ChatGPT's own app gives them —
    /// `prolite` is Pro 100, `pro` Pro 200, `promax` Pro 500. Anything else
    /// is the id with its underscores turned into spaces.
    public static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 100"
        case "pro": return "Pro 200"
        case "promax": return "Pro 500"
        case "self_serve_business_prolite": return "Business Premium"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    /// Pure parse step, kept separate from the network call so it can be
    /// tested against recorded responses.
    public static func parse(_ data: Data, fallbackAccount: String? = nil) throws -> UsageSnapshot {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw ProviderError.badResponse
        }

        var windows: [UsageWindow] = []
        windows.append(contentsOf: convert(body.rateLimit, prefix: nil, active: true))
        let planLimitReached = body.rateLimit?.limitReached == true || body.rateLimit?.allowed == false
        for extra in body.additionalRateLimits ?? [] {
            let name = extra.limitName ?? extra.meteredFeature
            var converted = convert(extra.rateLimit, prefix: name, active: false)
            for index in converted.indices { converted[index].extra = true }
            if let reserve = Reserve(extra, planLimitReached: planLimitReached) {
                for index in converted.indices {
                    converted[index].label = reserve.label
                    converted[index].note = reserve.note
                    converted[index].inUse = reserve.inUse
                }
            }
            windows.append(contentsOf: converted)
        }
        if let creditWindow = creditWindow(body.credits) {
            windows.append(creditWindow)
        }

        // Kept at zero too: an account that was given resets before still has
        // a count to show, once the list says how many it had.
        var resetCredits: ResetCredits?
        if let raw = body.rateLimitResetCredits, let available = raw.availableCount, available >= 0 {
            resetCredits = ResetCredits(
                available: available,
                applicable: raw.applicableAvailableCount)
        }

        return UsageSnapshot(
            planName: planName(body.planType),
            account: body.email ?? body.accountId ?? fallbackAccount,
            windows: windows,
            resetCredits: resetCredits)
    }

    /// Codex's reserve: once a plan's own limit is reached, requests go to a
    /// lighter model ("Luna") with a weekly allowance of its own, reported as
    /// `gpt-reserve`. OpenAI's own banner for it reads "You're now using Luna,
    /// a faster model for simpler tasks."
    struct Reserve: Equatable {
        let label: String
        let note: String
        let inUse: Bool

        init?(_ limit: AdditionalLimit, planLimitReached: Bool) {
            guard let name = limit.limitName, name.lowercased().contains("reserve") else { return nil }
            let model = Self.modelName(limit.normalModelSlug)
            label = model.map { L10n.t("Reserve · \($0)", "备用 · \($0)") } ?? L10n.t("Reserve", "备用")
            let modelText = model ?? L10n.t("a lighter model", "较轻的模型")
            note = L10n.t(
                "Once the plan's own limit is used up, Codex moves to \(modelText), a faster model for simpler tasks, and draws on this reserve until the plan resets.",
                "套餐本身的额度用完后，Codex 会改用 \(modelText)（更快、适合简单任务的模型），消耗这份备用额度，直到套餐额度重置。")
            inUse = planLimitReached && limit.rateLimit?.allowed != false && limit.rateLimit?.limitReached != true
        }

        /// "gpt-5.6-luna" → "Luna": the last part that is a word, not a version.
        static func modelName(_ slug: String?) -> String? {
            guard let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else { return nil }
            let word = slug.split(separator: "-").last { part in
                part.count > 1 && part.allSatisfy(\.isLetter) && part.lowercased() != "gpt"
            }
            return word.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        }
    }

    private static func convert(_ limit: RateLimit?, prefix: String?, active: Bool) -> [UsageWindow] {
        guard let limit else { return [] }
        return [limit.primaryWindow, limit.secondaryWindow]
            .compactMap { $0 }
            .compactMap { window -> UsageWindow? in
                guard let percent = window.usedPercent else { return nil }
                let base = window.limitWindowSeconds.map(WindowTitle.forSeconds)
                    ?? L10n.t("Usage", "用量")
                let resetsAt = Dates.parseEpoch(window.resetAt)
                    ?? window.resetAfterSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
                return UsageWindow(
                    title: prefix.map { "\($0) · \(base)" } ?? base,
                    usedPercent: percent,
                    resetsAt: resetsAt,
                    isActive: active,
                    windowSeconds: window.limitWindowSeconds,
                    scope: prefix)
            }
    }

    private static func creditWindow(_ credits: Credits?) -> UsageWindow? {
        guard let credits else { return nil }
        if credits.unlimited == true {
            return UsageWindow(
                title: L10n.t("Credits", "额度点数"),
                detail: L10n.t("Unlimited", "无限制"))
        }
        // A zero balance on an account that has never had credits is noise.
        guard credits.hasCredits == true, let raw = credits.balance else { return nil }
        let balance = creditCount(raw)
        var note: String?
        if let range = credits.approxLocalMessages, range.count == 2, range[1] > 0 {
            let low = QuotaFormat.grouped(range[0]), high = QuotaFormat.grouped(range[1])
            note = L10n.t(
                "Credits come from a purchase or a promotion and are spent once the plan's limits are used up — about \(low)–\(high) local Codex messages.",
                "credits 来自购买或赠送，套餐额度用完后才会消耗，大约够在本地发 \(low)–\(high) 条 Codex 消息。")
        }
        var window = UsageWindow(
            title: L10n.t("Credits", "额度点数"),
            detail: credits.overageLimitReached == true
                ? L10n.t("\(balance) · overage limit reached", "\(balance) · 已达超额上限")
                : balance,
            note: note)
        // The endpoint gives no deadline for credits.
        window.credit = CreditAmount(
            amount: balance,
            caption: credits.overageLimitReached == true
                ? L10n.t("Overage limit reached", "已达超额上限")
                : credits.approxLocalMessages.flatMap { range in
                    range.count == 2 && range[1] > 0
                        ? L10n.t("About \(QuotaFormat.grouped(range[0]))–\(QuotaFormat.grouped(range[1])) local messages",
                                 "约可发 \(QuotaFormat.grouped(range[0]))–\(QuotaFormat.grouped(range[1])) 条本地消息")
                        : nil
                })
        return window
    }

    /// "62500" → "62,500 credits"; a balance that is not a plain number is
    /// shown as the endpoint gives it.
    static func creditCount(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return trimmed }
        let number = QuotaFormat.grouped(value)
        return L10n.t("\(number) credits", "\(number) 点")
    }
}

// MARK: - Claude (Claude Code Keychain OAuth → /api/oauth/usage)

public struct ClaudeProvider: QuotaProvider {
    public let id = ProviderID.claude

    public init() {}

    public func isConfigured(config: ConfigStore) -> Bool {
        switch config.experience.claudeSource {
        case .oauth: return LocalCredentials.claudeOAuthToken() != nil
        case .web: return ClaudeWebSession.exists
        case .auto: return LocalCredentials.claudeOAuthToken() != nil || Self.usesWeb(config)
        }
    }

    /// Whether a web sign-in answers instead of Claude Code's: when the owner
    /// pinned it, or — on Automatic — when Claude Code has none on this Mac
    /// (never made, or signed out) and the Claude app or a browser is signed in.
    static func usesWeb(_ config: ConfigStore) -> Bool {
        switch config.experience.claudeSource {
        case .oauth: return false
        case .web: return true
        case .auto:
            switch LocalCredentials.claudeCredentialState() {
            case .missing, .signedOut: return ClaudeWebSession.exists
            case .available, .needsAuthorization: return false
            }
        }
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        // A profile (#8) reading another config dir's sign-in.
        if let service = config.experience.activeProfile?.claudeService, service != LocalCredentials.claudeService {
            return try await Self.fetchSignIn(service: service)
        }
        if Self.usesWeb(config) { return try await ClaudeWebSession.fetch() }
        // Run out after eight hours away from Claude Code: have it renew.
        var renewal: ClaudeCodeRenewal.Outcome?
        if let expiry = LocalCredentials.claudeTokenExpiry(), expiry <= Date().addingTimeInterval(60) {
            renewal = await ClaudeCodeRenewal.renewIfExpired()
        }
        guard let token = LocalCredentials.claudeOAuthToken() else {
            throw Self.credentialError(for: LocalCredentials.claudeCredentialState())
        }
        do {
            return try await Self.usage(token: token, plan: LocalCredentials.claudePlanName())
        } catch ProviderError.unauthorized {
            throw ProviderError.sessionExpired(Self.expiredMessage(renewal))
        }
    }

    /// Another config dir's sign-in, read the way the card's list reads it:
    /// never renewed by QuotaBar, only by Claude Code running with that dir.
    static func fetchSignIn(service: String) async throws -> UsageSnapshot {
        let lookup = LocalCredentials.claudeLookup(service: service)
        switch lookup.state {
        case .needsAuthorization:
            throw ProviderError.needsAuthorization(hint: LocalCredentials.claudeAuthorizationHint)
        case .signedOut:
            throw ProviderError.sessionExpired(ClaudeSignIns.signedOutMessage)
        case .missing:
            throw ProviderError.notConfigured(hint: L10n.t(
                "The profile's Claude sign-in is no longer on this Mac. Pick another in Settings › Providers › Profiles.",
                "这个账号组选的 Claude 登录已经不在这台 Mac 上了。在设置 › 服务商 › 账号组里换一个。"))
        case .available:
            break
        }
        guard var token = lookup.token else { throw ProviderError.notConfigured(hint: ProviderID.claude.setupHint) }
        var plan = lookup.plan
        if let expiry = lookup.expiresAt, expiry <= Date().addingTimeInterval(60) {
            // Run out: have Claude Code renew it, with this sign-in's own config dir.
            guard await ClaudeCodeRenewal.renewIfExpired(service: service) == .renewed else {
                throw ProviderError.sessionExpired(ClaudeSignIns.expiredMessage)
            }
            let renewed = LocalCredentials.readClaudeNow(service: service)
            guard let fresh = renewed.token else { throw ProviderError.sessionExpired(ClaudeSignIns.expiredMessage) }
            token = fresh
            plan = renewed.plan
        }
        do {
            return try await usage(token: token, plan: plan)
        } catch ProviderError.unauthorized {
            throw ProviderError.sessionExpired(ClaudeSignIns.expiredMessage)
        }
    }

    /// Run out, and not renewed: said as it is. Signing in again is not
    /// needed — running Claude Code once is.
    static func expiredMessage(_ renewal: ClaudeCodeRenewal.Outcome?) -> String {
        switch renewal {
        case .noCLI?:
            return L10n.t(
                "Claude Code's sign-in has run out, and QuotaBar could not find `claude` to have it renewed. Run Claude Code once.",
                "Claude Code 的登录已过期，QuotaBar 找不到 `claude` 来让它续期。运行一次 Claude Code 即可。")
        case .failed?, .coolingDown?:
            return L10n.t(
                "Claude Code's sign-in has run out and did not renew when QuotaBar asked; QuotaBar asks again within half an hour. Running Claude Code once renews it too.",
                "Claude Code 的登录已过期，QuotaBar 让它续期没有成功，半小时内会再试；运行一次 Claude Code 也能续期。")
        default:
            return L10n.t(
                "Claude Code's sign-in has run out. Running Claude Code once renews it; there is no need to sign in again.",
                "Claude Code 的登录已过期。运行一次 Claude Code 就会续期，不需要重新登录。")
        }
    }

    static func headers(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        ]
    }

    /// One sign-in's reading: the card's, or another config dir's (#8).
    static func usage(token: String, plan: String?) async throws -> UsageSnapshot {
        let headers = headers(token: token)
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let response = try await HTTP.get(url, headers: headers).requireOK()
        var snapshot = try parse(response.data)
        // The usage endpoint does not name the plan; Claude Code's item does.
        if snapshot.planName == nil { snapshot.planName = plan }
        // Nor the account; /api/oauth/profile does. Memoized per token, so
        // the extra request happens once per sign-in, not once per minute.
        snapshot.account = await profile(token: token)?.email
        snapshot.resetCredits = await resetCredits(headers: headers, token: token, windows: snapshot.windows)
        return snapshot
    }

    // MARK: Limit resets

    /// The limit resets the account was given, read the way Claude Code's
    /// `/limit-reset` reads them: the usage endpoint lists them only when
    /// asked (`cedar_ember=1`) by a current Claude Code — another client is
    /// told `surface`, an old version `cli_version`, and sees none. A failure
    /// costs the count, never the reading, and keeps the last one read.
    static func resetCredits(headers: [String: String], token: String, windows: [UsageWindow]) async -> ResetCredits? {
        let used = windows.compactMap(\.usedPercent).reduce(0, +)
        if let cached = resetGrants.reusable(token: token, used: used) { return cached }
        var headers = headers
        headers["User-Agent"] = "claude-cli/\(claudeCodeVersion) (external, cli)"
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
        guard let response = try? await HTTP.get(url, headers: headers), response.status == 200,
              let read = resetCredits(response.data)
        else {
            // Asked again in a quarter of an hour, not at every refresh.
            let last = resetGrants.last(token: token)
            resetGrants.store(last, token: token, used: used)
            return last
        }
        resetGrants.store(read.credits, token: token, used: used)
        return read.credits
    }

    static let resetGrants = ResetGrantCache()

    /// The last count read, so the endpoint is not asked twice a minute. Read
    /// again after a quarter of an hour, once a deadline it listed has
    /// passed, or when the figures drop — a reset just used in Claude Code
    /// shows as limits refilled before their time.
    final class ResetGrantCache: @unchecked Sendable {
        private struct Entry {
            let token: String
            let credits: ResetCredits?
            let used: Double
            let readAt: Date
        }

        private let lock = NSLock()
        /// By token: with several sign-ins (#8) read in turn, one slot would
        /// send every refresh back to the endpoint.
        private var entries: [String: Entry] = [:]

        func reusable(token: String, used: Double, now: Date = .now) -> ResetCredits?? {
            lock.withLock {
                guard let entry = entries[token], now.timeIntervalSince(entry.readAt) < 900,
                      used >= entry.used - 0.5,
                      !(entry.credits?.credits ?? []).contains(where: { ($0.expiresAt ?? .distantFuture) <= now })
                else { return nil }
                return .some(entry.credits)
            }
        }

        func last(token: String) -> ResetCredits? {
            lock.withLock { entries[token]?.credits }
        }

        func store(_ credits: ResetCredits?, token: String, used: Double, now: Date = .now) {
            lock.withLock {
                // Tokens are renewed every few hours; the stale ones go.
                entries = entries.filter { now.timeIntervalSince($0.value.readAt) < 86_400 }
                entries[token] = Entry(token: token, credits: credits, used: used, readAt: now)
            }
        }
    }

    /// The installed Claude Code's version, newest first among the native
    /// installer's versions and then npm's; the endpoint lists resets only to
    /// a version that knows how to use them.
    static let claudeCodeVersion: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.local/share/claude/versions")) ?? []
        if let newest = versions.filter(isVersion).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            return newest
        }
        for prefix in ["/opt/homebrew/lib", "/usr/local/lib", "\(home)/.npm-global/lib"] {
            let path = "\(prefix)/node_modules/@anthropic-ai/claude-code/package.json"
            if let data = FileManager.default.contents(atPath: path),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? String, isVersion(version)
            {
                return version
            }
        }
        return "2.1.280"
    }()

    private static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    struct ResetRead: Equatable {
        /// Nil when the account has no resets to show: not offered them, or
        /// none given.
        var credits: ResetCredits?
    }

    /// `{"cedar_ember":{"eligible":true,"at_limit":false,"grants":[{"id":
    /// "opus55-launch-promax-20260921","label":"…","resets_total":1,
    /// "resets_left":1,"starts_at":"2026-09-22T16:00:00+00:00","ends_at":
    /// "2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day"],
    /// "paused":false,"usable_now":true}]}}` — one entry per grant, soonest
    /// deadline first. Nil for a reply without the block at all.
    static func resetCredits(_ data: Data, now: Date = .now) -> ResetRead? {
        struct Grant: Decodable {
            let id: String?
            let resetsTotal: Int?
            let resetsLeft: Int?
            let startsAt: String?
            let endsAt: String?
            let clears: [String]?
            let paused: Bool?
            let usableNow: Bool?
        }
        struct Block: Decodable {
            let eligible: Bool?
            let atLimit: Bool?
            let grants: [Grant]?
        }
        struct Body: Decodable { let cedarEmber: Block? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(Body.self, from: data), let block = body.cedarEmber else { return nil }
        let grants = (block.grants ?? []).filter { grant in
            (Dates.parseISO(grant.startsAt) ?? .distantPast) <= now
        }
        guard block.eligible == true, !grants.isEmpty else { return ResetRead(credits: nil) }
        let live = grants.filter { grant in
            grant.paused != true && (grant.resetsLeft ?? 0) > 0 && (Dates.parseISO(grant.endsAt) ?? .distantFuture) > now
        }
        let credits = live
            .map { grant in
                ResetCredit(
                    id: grant.id,
                    title: resetTitle(grant.clears),
                    grantedAt: Dates.parseISO(grant.startsAt),
                    expiresAt: Dates.parseISO(grant.endsAt))
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        let usable = live.filter { $0.usableNow == true }.map { $0.resetsLeft ?? 0 }.reduce(0, +)
        return ResetRead(credits: ResetCredits(
            available: live.map { $0.resetsLeft ?? 0 }.reduce(0, +),
            applicable: block.atLimit == true ? usable : 0,
            totalEarned: grants.map { max($0.resetsTotal ?? 0, $0.resetsLeft ?? 0) }.reduce(0, +),
            credits: credits))
    }

    /// What a grant refills, from the limits it clears.
    static func resetTitle(_ clears: [String]?) -> String? {
        let clears = clears ?? []
        let session = clears.contains("five_hour")
        let weekly = clears.contains { $0.hasPrefix("seven_day") }
        switch (session, weekly) {
        // Claude's own names for them, kept in every language.
        case (true, true): return "Full reset"
        case (true, false): return "Session reset"
        case (false, true): return "Weekly reset"
        case (false, false): return nil
        }
    }

    /// Three situations behind a missing token, each said as it is: no
    /// session at all, a session Claude Code signed out of, or a session
    /// macOS will not hand over until the user says so. Pure, for the tests.
    static func credentialError(for state: LocalCredentials.ClaudeCredentialState) -> ProviderError {
        switch state {
        case .needsAuthorization:
            return .needsAuthorization(hint: LocalCredentials.claudeAuthorizationHint)
        case .signedOut:
            return .sessionExpired(LocalCredentials.claudeSignedOutHint)
        case .available, .missing:
            return .notConfigured(hint: ProviderID.claude.setupHint)
        }
    }

    // MARK: Profile

    private static let profileMemo = ProfileMemo()

    /// By token, for the same reason as the resets.
    final class ProfileMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (profile: Identity, at: Date)] = [:]

        func profile(for token: String) -> Identity? {
            lock.withLock { entries[token]?.profile }
        }

        func store(_ profile: Identity, for token: String, now: Date = .now) {
            lock.withLock {
                entries = entries.filter { now.timeIntervalSince($0.value.at) < 86_400 }
                entries[token] = (profile, now)
            }
        }
    }

    /// Who a sign-in is: one email can sit in several organizations — a
    /// personal plan and a team — each with its own limits, so the
    /// organization is what tells two sign-ins apart (#8).
    public struct Identity: Sendable, Equatable {
        public var email: String?
        public var organization: String?
        var accountID: String?
        var organizationID: String?

        public init(email: String? = nil, organization: String? = nil, accountID: String? = nil, organizationID: String? = nil) {
            self.email = email
            self.organization = organization
            self.accountID = accountID
            self.organizationID = organizationID
        }
    }

    struct Profile: Decodable {
        struct Account: Decodable {
            let uuid: String?
            let email: String?
        }
        struct Organization: Decodable {
            let uuid: String?
            let name: String?
        }
        let account: Account?
        let organization: Organization?

        var identity: Identity {
            func text(_ value: String?) -> String? {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            return Identity(
                email: text(account?.email),
                organization: text(organization?.name),
                accountID: account?.uuid,
                organizationID: organization?.uuid)
        }
    }

    static func cachedProfile(token: String) -> Identity? {
        profileMemo.profile(for: token)
    }

    /// Best effort: a failure here leaves the card without an account line,
    /// never without its numbers. Only a hit is cached, so a transient
    /// failure is retried on the next refresh.
    static func profile(token: String) async -> Identity? {
        if let cached = profileMemo.profile(for: token) { return cached }
        let url = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        guard let response = try? await HTTP.get(url, headers: headers(token: token)),
              response.status == 200,
              let identity = (try? response.json(Profile.self))?.identity,
              identity.email != nil || identity.organization != nil
        else { return nil }
        profileMemo.store(identity, for: token)
        return identity
    }

    // MARK: Response shape

    struct LegacyWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?
        let limitDollars: Double?
        let usedDollars: Double?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case limitDollars = "limit_dollars"
            case usedDollars = "used_dollars"
        }
    }

    struct Scope: Decodable {
        struct Model: Decodable {
            let id: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
        let model: Model?
        let surface: String?
    }

    /// The authoritative list: one entry per limit the account is subject to,
    /// including per-model weekly caps that the legacy top-level fields omit.
    struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        let currency: String?
        let spendLimitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
            case currency
            case spendLimitReached = "spend_limit_reached"
        }
    }

    struct Body: Decodable {
        let fiveHour: LegacyWindow?
        let sevenDay: LegacyWindow?
        let limits: [Limit]?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
            case extraUsage = "extra_usage"
        }
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw ProviderError.badResponse
        }

        var windows: [UsageWindow] = []
        if let limits = body.limits, !limits.isEmpty {
            windows = limits.compactMap { convert($0, body: body) }
        }
        if windows.isEmpty {
            // Older responses only carried the two top-level windows.
            windows = [
                body.fiveHour.map {
                    legacy($0, title: WindowTitle.forSeconds(18_000), seconds: 18_000, active: true)
                },
                body.sevenDay.map {
                    legacy($0, title: WindowTitle.forSeconds(604_800), seconds: 604_800, active: false)
                },
            ].compactMap { $0 }
        }
        if let extra = extraUsageWindow(body.extraUsage) {
            windows.append(extra)
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        windows.append(contentsOf: creditWindows(data))
        return UsageSnapshot(windows: windows)
    }

    // MARK: Credits given

    /// Credits the account was given beside its plan. Each comes under a code
    /// name that changes from one promotion to the next — `iguana_necktie`
    /// held a $250 credit in October 2026 — so any block with a dollar limit
    /// that is not one of the plan's own windows counts, plus `cinder_cove`,
    /// the one-time Claude Code and Cowork credit, which has only a
    /// percentage. Allowances beside the plan, so no figure follows them on
    /// its own.
    static func creditWindows(_ data: Data, now: Date = .now) -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [UsageWindow] = []
        for key in root.keys.sorted() where !key.hasPrefix("five_hour") && !key.hasPrefix("seven_day") {
            guard let block = root[key] as? [String: Any] else { continue }
            let limit = number(block["limit_dollars"]) ?? 0
            guard limit > 0 || key == "cinder_cove" else { continue }
            let expires = Dates.parseISO(block["resets_at"] as? String)
            if let expires, expires <= now { continue }
            let day = expires.map(creditDay)
            var window: UsageWindow
            if limit > 0 {
                let used = number(block["used_dollars"]) ?? 0
                let left = number(block["remaining_dollars"]) ?? max(limit - used, 0)
                let percent = number(block["utilization"]) ?? used / limit * 100
                var detail = "\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(limit))"
                if let day { detail += L10n.t(" · expires \(day)", " · \(day)到期") }
                window = UsageWindow(
                    title: creditNames[key] ?? L10n.t("Bonus credit", "赠送额度"),
                    usedPercent: percent,
                    detail: detail,
                    note: L10n.t(
                        "A credit Anthropic added to the account, counted apart from the plan's limits\(day.map { ". What is left runs out \($0)" } ?? "").",
                        "Anthropic 赠送的额度，和套餐限额分开计算\(day.map { "，没用完的在 \($0)到期" } ?? "")。"))
                window.credit = CreditAmount(
                    amount: QuotaFormat.usd(left),
                    caption: L10n.t("Used \(QuotaFormat.usd(used)) of \(QuotaFormat.usd(limit))",
                                    "已用 \(QuotaFormat.usd(used)) / \(QuotaFormat.usd(limit))"),
                    expiresAt: expires)
            } else {
                let percent = number(block["utilization"])
                window = UsageWindow(
                    title: creditNames[key] ?? L10n.t("Bonus credit", "赠送额度"),
                    usedPercent: percent,
                    detail: day.map { L10n.t("One-time credit · expires \($0)", "一次性额度 · \($0)到期") }
                        ?? L10n.t("One-time credit", "一次性额度"))
                window.credit = CreditAmount(
                    amount: L10n.t("\(QuotaFormat.percent(100 - (percent ?? 0))) left", "剩余 \(QuotaFormat.percent(100 - (percent ?? 0)))"),
                    caption: L10n.t("One-time credit", "一次性额度"),
                    expiresAt: expires)
            }
            window.extra = true
            out.append(window)
        }
        return out
    }

    /// The credits' names on Claude's own usage page, by code name.
    static let creditNames = [
        "iguana_necktie": "Cloud session credit",
        "cinder_cove": "Claude Code and Cowork credit",
    ]

    /// A JSON number, not a string and not a boolean.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    /// "Nov 5", "11月5日".
    private static func creditDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    private static func convert(_ limit: Limit, body: Body) -> UsageWindow? {
        guard let percent = limit.percent else { return nil }
        let kind = limit.kind ?? limit.group ?? ""
        var title: String
        var seconds: Int?
        var scope: String?
        switch kind {
        case "session":
            seconds = 18_000
            title = WindowTitle.forSeconds(18_000)
        case "weekly_all":
            seconds = 604_800
            title = WindowTitle.forSeconds(604_800)
        case "weekly_scoped":
            seconds = 604_800
            let weekly = WindowTitle.forSeconds(604_800)
            scope = limit.scope?.model?.displayName ?? limit.scope?.model?.id
            title = scope.map { "\(weekly) · \($0)" } ?? weekly
        default:
            title = prettify(kind)
        }
        // Dollar figures only exist on the legacy fields; carry them across when
        // they describe the same window.
        let dollars: LegacyWindow? = kind == "session" ? body.fiveHour
            : (kind == "weekly_all" ? body.sevenDay : nil)
        return UsageWindow(
            title: title,
            usedPercent: percent,
            detail: dollarDetail(dollars),
            resetsAt: Dates.parseISO(limit.resetsAt),
            isActive: limit.isActive ?? false,
            windowSeconds: seconds,
            scope: scope)
    }

    private static func legacy(
        _ window: LegacyWindow,
        title: String,
        seconds: Int,
        active: Bool) -> UsageWindow
    {
        UsageWindow(
            title: title,
            usedPercent: window.utilization,
            detail: dollarDetail(window),
            resetsAt: Dates.parseISO(window.resetsAt),
            isActive: active,
            windowSeconds: seconds)
    }

    private static func dollarDetail(_ window: LegacyWindow?) -> String? {
        guard let window, let limit = window.limitDollars, limit > 0 else { return nil }
        let used = window.usedDollars ?? 0
        return "\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(limit))"
    }

    private static func extraUsageWindow(_ extra: ExtraUsage?) -> UsageWindow? {
        guard let extra, extra.isEnabled == true else { return nil }
        var detail: String?
        if let limit = extra.monthlyLimit, limit > 0 {
            detail = "\(QuotaFormat.usd(extra.usedCredits ?? 0)) / \(QuotaFormat.usd(limit))"
        }
        if extra.spendLimitReached == true {
            let reached = L10n.t("spend limit reached", "已达消费上限")
            detail = detail.map { "\($0) · \(reached)" } ?? reached
        }
        return UsageWindow(
            title: L10n.t("Extra usage", "额外用量"),
            usedPercent: extra.utilization,
            detail: detail)
    }

    /// "weekly_opus" → "Weekly opus"
    private static func prettify(_ kind: String) -> String {
        guard !kind.isEmpty else { return L10n.t("Quota", "额度") }
        return kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
