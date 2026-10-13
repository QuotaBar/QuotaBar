import Foundation

/// The current dashboard's read-only routes. These are separate from Cursor's
/// legacy monthly usage summary, which remains available after migration and
/// must not be mistaken for the shared weekly allowance.
enum XSubscriptionClient {
    static let unifiedMeURL = URL(string: "https://cursor.com/api/unified-dashboard/get-unified-me")!
    static let planURL = URL(string: "https://cursor.com/api/dashboard/get-plan-info")!
    static let usageURL = URL(string: "https://cursor.com/api/dashboard/v2/usage-status?scope=user")!
    static let prepaidURL = URL(string: "https://cursor.com/api/dashboard/get-user-prepaid-billing")!
    static let identityURL = URL(string: "https://cursor.com/api/dashboard/get-xai-commerce-bearer-token")!

    struct UnifiedMe: Decodable {
        let isMerged: Bool?
        let isUnificationComplete: Bool?
        let dashboard: Dashboard?

        struct Dashboard: Decodable {
            let email: String?
            let userId: Int?
            let publicUserId: String?
        }
    }

    struct Plan: Decodable {
        let isMerged: Bool?
        let planInfo: Info?

        struct Info: Decodable { let planName: String? }
    }

    struct Usage: Decodable {
        let availability: String?
        let weeklyIncludedUsage: Weekly?

        struct Weekly: Decodable {
            let usedCents: Double?
            let budgetCents: Double?
            let periodStart: String?
            let resetsAt: String?
        }
    }

    /// Protobuf int64 values arrive as decimal strings. The schema confirms
    /// the non-optional available_cents scalar defaults to zero when omitted,
    /// but only a valid PREPAID reply establishes that this is a balance.
    struct Prepaid: Decodable {
        let billingMode: String?
        let eligible: Bool?
        let availableCents: Double?
        let availableWasPresent: Bool

        private enum CodingKeys: String, CodingKey { case billingMode, eligible, availableCents }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            billingMode = try c.decodeIfPresent(String.self, forKey: .billingMode)
            eligible = try c.decodeIfPresent(Bool.self, forKey: .eligible)
            availableWasPresent = c.contains(.availableCents)
            if let number = try? c.decode(Double.self, forKey: .availableCents) {
                availableCents = number.isFinite ? number : nil
            } else if let string = try? c.decode(String.self, forKey: .availableCents),
                      let number = Double(string), number.isFinite {
                availableCents = number
            } else { availableCents = nil }
        }

        var balance: AccountBalance? {
            guard billingMode == "PREPAID_BILLING_MODE_PREPAID", eligible == true else { return nil }
            let cents: Double
            if let availableCents { cents = availableCents }
            else if !availableWasPresent { cents = 0 }
            else { return nil }
            return AccountBalance(currency: "USD", total: cents / 100, paid: cents / 100)
        }
    }

    struct Probe {
        let migrated: Bool
        let snapshot: UsageSnapshot?
        var migrationUnavailable = false
    }

    struct Bridge: Decodable {
        let credential: Credential?
        struct Credential: Decodable {
            let token: String?
            let edgeBaseUrl: String?
            let tokenSource: String?
        }
    }

    /// This token is issued by Cursor's authenticated dashboard response. It
    /// is decoded only in memory to corroborate its Cursor user and xAI seat;
    /// neither it nor any credential is part of the persisted reading.
    static func identity(
        credential: Bridge.Credential?, dashboardUserID: Int?, now: Date = .now) -> XSubscriptionInfo.Identity?
    {
        guard let credential, credential.tokenSource == "XAI_COMMERCE_BEARER_TOKEN_SOURCE_PARTNER_JWT",
              let endpoint = credential.edgeBaseUrl.flatMap(URL.init(string:)),
              endpoint.scheme == "https", endpoint.host == "grok.com",
              let token = credential.token, let claims = LocalCredentials.jwtPayload(token),
              claims["iss"] as? String == "cursor", claims["aud"] as? String == "https://auth.x.ai",
              claims["principal_type"] as? String == "User",
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let dashboardUserID, claims["cursor_user_id"] as? String == String(dashboardUserID),
              claims["xai_team_id"] is String,
              let userID = nonempty(claims["xai_user_id"] as? String),
              claims["principal_id"] as? String == userID
        else { return nil }
        let workspace = nonempty(claims["xai_team_id"] as? String).map { "team:\($0)" } ?? "personal:\(userID)"
        return XSubscriptionInfo(tier: "", workspaceID: workspace, seatID: "user:\(userID)").verifiedIdentity
    }

    static func grokIdentity(_ auth: LocalCredentials.GrokAuth) -> XSubscriptionInfo.Identity? {
        guard let userID = nonempty(auth.userID), let claims = LocalCredentials.jwtPayload(auth.accessToken),
              claims["iss"] as? String == "https://auth.x.ai",
              claims["sub"] as? String == userID, claims["principal_id"] as? String == userID,
              claims["principal_type"] as? String == "User", claims["team_id"] is String
        else { return nil }
        let tokenTeam = nonempty(claims["team_id"] as? String)
        guard tokenTeam == nonempty(auth.workspaceID) else { return nil }
        return XSubscriptionInfo(tier: "",
            workspaceID: tokenTeam.map { "team:\($0)" } ?? "personal:\(userID)",
            seatID: "user:\(userID)").verifiedIdentity
    }

    private static func nonempty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func read(
        cookie: String, account: String?, tierFallback: String? = nil,
        sand: GrokBot.Status? = nil, send: HTTPSend = HTTP.live) async -> Probe
    {
        let headers = [
            "Accept": "application/json", "Content-Type": "application/json", "Cookie": cookie,
            // The dashboard rejects POST reads without its same-origin CSRF
            // header. Its GET usage route works without one, which otherwise
            // hides this failure behind a valid meter and missing identity.
            "Origin": "https://cursor.com",
        ]
        @Sendable func get(_ url: URL, method: String = "POST", body: String = "{}") async -> Data? {
            try? await send(method, url, headers, method == "POST" ? Data(body.utf8) : nil, 20).requireOK().data
        }
        async let meData = get(unifiedMeURL)
        async let planData = get(planURL)
        let me = await meData.flatMap { try? JSONDecoder().decode(UnifiedMe.self, from: $0) }
        let plan = await planData.flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
        // The old isUnifiedBillingUser flag existed on SuperGrok before The X
        // Subscription. Only the dashboard's explicit completed migration or
        // Grok Bot's new isUnified marker establishes the new subscription.
        let completed = me?.isMerged == true && me?.isUnificationComplete == true
        let incomplete = me?.isMerged == false || me?.isUnificationComplete == false
        let migrated = completed || (!incomplete && sand?.isUnified == true)
        guard migrated else {
            // A transport failure is not an affirmative legacy subscription.
            // Cursor's retained monthly summary can report obsolete zeroes
            // even when both current migration endpoints are unreachable.
            let knownLegacy = incomplete || sand?.isUnified == false
            return Probe(migrated: false, snapshot: nil, migrationUnavailable: !knownLegacy)
        }
        let tier = supportedTier(plan?.planInfo?.planName)
            ?? supportedTier(sand?.cursorPlanName)
            ?? supportedTier(tierFallback)
        guard let tier else { return Probe(migrated: true, snapshot: nil) }
        async let usageData = get(usageURL, method: "GET")
        async let prepaidData = get(prepaidURL)
        // purpose=1 is the vendor's BROWSER_COMMERCE protobuf enum. This is
        // a read-only identity bridge; no checkout, top-up or account switch.
        async let bridgeData = get(identityURL, body: "{\"purpose\":1}")
        let usage = await usageData.flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
        let prepaid = await prepaidData.flatMap { try? JSONDecoder().decode(Prepaid.self, from: $0) }
        let bridge = await bridgeData.flatMap { try? JSONDecoder().decode(Bridge.self, from: $0) }
        let verified = identity(credential: bridge?.credential, dashboardUserID: me?.dashboard?.userId)
        let window = weeklyWindow(usage)
        let balance = prepaid?.balance.map { BalanceSheet(balances: [$0]) }
        let info = XSubscriptionInfo(tier: tier, workspaceID: verified?.workspaceID, seatID: verified?.seatID)
        let snapshot = UsageSnapshot(
            planName: info.tierLabel,
            account: me?.dashboard?.email ?? account,
            windows: [window],
            balance: balance,
            xSubscription: info)
        return Probe(migrated: true, snapshot: snapshot)
    }

    static func supportedTier(_ raw: String?) -> String? {
        guard let tier = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              XSubscriptionInfo.supportedTiers.contains(tier) else { return nil }
        return tier
    }

    static func weeklyWindow(_ response: Usage?) -> UsageWindow {
        let period = response?.weeklyIncludedUsage
        let start = Dates.parseISO(period?.periodStart)
        let end = Dates.parseISO(period?.resetsAt)
        var percent: Double?
        if response?.availability == "available",
           let used = period?.usedCents, used.isFinite, used >= 0,
           let budget = period?.budgetCents, budget.isFinite, budget > 0,
           let start, let end, end > start {
            percent = used / budget * 100
        }
        return UsageWindow(
            title: L10n.t("Shared weekly usage", "共享每周额度"),
            usedPercent: percent,
            detail: percent == nil ? L10n.t("The shared usage could not be read this time.", "这次未能读取共享用量。") : nil,
            resetsAt: end,
            windowSeconds: 7 * 86_400)
    }
}
