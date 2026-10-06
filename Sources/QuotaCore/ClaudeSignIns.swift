import Foundation

/// The Claude Code sign-ins on this Mac besides the card's (issue #8): one per
/// `CLAUDE_CONFIG_DIR`, found in the keychain by name and read the way the
/// card's is. One email can sit in several organizations — a personal plan
/// and a team — each with its own limits, and Claude Code ties a sign-in to
/// one of them, so a second organization means a second config dir.
///
/// Read only. Claude Code renews each sign-in while it runs with that config
/// dir; QuotaBar never spends a refresh token, so it cannot sign one out.
public enum ClaudeSignIns {
    public struct Reading: Sendable, Identifiable {
        /// The keychain item's name.
        public let id: String
        public var identity: ClaudeProvider.Identity?
        public var plan: String?
        public var snapshot: UsageSnapshot?
        public var error: String?

        public init(
            id: String,
            identity: ClaudeProvider.Identity? = nil,
            plan: String? = nil,
            snapshot: UsageSnapshot? = nil,
            error: String? = nil)
        {
            self.id = id
            self.identity = identity
            self.plan = plan
            self.snapshot = snapshot
            self.error = error
        }
    }

    /// Who the card's sign-in is: the default one, or the profile's in use.
    /// Answered from the memo the card's own read filled, so no request of
    /// its own.
    public static func cardIdentity(service: String = LocalCredentials.claudeService) async -> ClaudeProvider.Identity? {
        let token = service == LocalCredentials.claudeService
            ? LocalCredentials.claudeOAuthToken()
            : LocalCredentials.claudeLookup(service: service).token
        guard let token else { return nil }
        return await ClaudeProvider.profile(token: token)
    }

    /// Every other sign-in, read side by side — the default one among them
    /// while a profile (#8) has the card read another.
    public static func readOthers(card cardService: String = LocalCredentials.claudeService, now: Date = .now) async -> [Reading] {
        let extras = LocalCredentials.claudeExtraServices()
        guard !extras.isEmpty else { return [] }
        let services = ([LocalCredentials.claudeService] + extras).filter { $0 != cardService }
        let card = await cardIdentity(service: cardService)
        var readings: [Reading] = []
        await withTaskGroup(of: Reading.self) { group in
            for service in services {
                group.addTask { await read(service: service, now: now) }
            }
            for await reading in group { readings.append(reading) }
        }
        return arranged(readings, card: card)
    }

    /// The same account in the same organization twice — a config dir that
    /// is the default one by another name, or one signed in like another —
    /// is shown once, and not at all when it is the card's. Then by name,
    /// and the ones not read yet last.
    public static func arranged(_ readings: [Reading], card: ClaudeProvider.Identity?) -> [Reading] {
        func key(_ identity: ClaudeProvider.Identity?) -> String? {
            guard let account = identity?.accountID, let organization = identity?.organizationID else { return nil }
            return "\(account)/\(organization)"
        }
        var seen = Set([key(card)].compactMap { $0 })
        var kept: [Reading] = []
        for reading in readings.sorted(by: { $0.id < $1.id }) {
            if let key = key(reading.identity) {
                guard seen.insert(key).inserted else { continue }
            }
            kept.append(reading)
        }
        return kept.sorted { sortKey($0) < sortKey($1) }
    }

    /// A profile switch (#8): the list under the arrow once `service` is on
    /// the card and `previous` — with what it last read — is not. Nothing is
    /// asked of the server for it.
    public static func afterSwitch(
        _ others: [Reading], to service: String, from previous: Reading, card: ClaudeProvider.Identity?) -> [Reading]
    {
        var rest = others.filter { $0.id != service }
        if !rest.contains(where: { $0.id == previous.id }) { rest.append(previous) }
        return arranged(rest, card: card)
    }

    private static func sortKey(_ reading: Reading) -> String {
        let named = reading.identity?.organization ?? reading.identity?.email
        return ([named == nil ? "1" : "0"] + [named, reading.identity?.email, reading.id].compactMap { $0?.lowercased() })
            .joined(separator: "\u{0}")
    }

    static func read(service: String, now: Date) async -> Reading {
        var lookup = LocalCredentials.claudeLookup(service: service)
        // Off the card, the default sign-in is still Claude Code's to renew.
        if service == LocalCredentials.claudeService, let expiry = lookup.expiresAt, expiry <= now.addingTimeInterval(60),
           await ClaudeCodeRenewal.renewIfExpired() == .renewed
        {
            lookup = LocalCredentials.readClaudeNow()
        }
        var reading = Reading(id: service, plan: lookup.plan)
        switch lookup.state {
        case .needsAuthorization:
            reading.error = needsAuthorizationMessage
            return reading
        case .signedOut:
            reading.error = signedOutMessage
            return reading
        case .missing:
            reading.error = missingMessage
            return reading
        case .available:
            break
        }
        guard let token = lookup.token else { return reading }
        // Whoever it was the last time the token was good.
        reading.identity = ClaudeProvider.cachedProfile(token: token)
        if let expiry = lookup.expiresAt, expiry <= now {
            reading.error = expiredMessage
            return reading
        }
        do {
            reading.snapshot = try await ClaudeProvider.usage(token: token, plan: lookup.plan)
            reading.identity = await ClaudeProvider.profile(token: token)
        } catch ProviderError.unauthorized {
            reading.error = expiredMessage
        } catch {
            reading.error = error.localizedDescription
        }
        return reading
    }

    static var needsAuthorizationMessage: String {
        L10n.t(
            "QuotaBar may not read this sign-in yet. Press “Allow keychain access” in Settings › Claude.",
            "QuotaBar 还不能读取这个登录。在设置 › Claude 里点「授权钥匙串访问」。")
    }

    static var signedOutMessage: String {
        L10n.t(
            "Signed out in Claude Code. Sign in again with the same CLAUDE_CONFIG_DIR.",
            "已在 Claude Code 里退出登录。用同一个 CLAUDE_CONFIG_DIR 重新登录即可。")
    }

    static var missingMessage: String {
        L10n.t("No sign-in in this keychain item.", "这个钥匙串项里没有登录信息。")
    }

    public static var expiredMessage: String {
        L10n.t(
            "This sign-in has run out. Claude Code renews it the next time it runs with this CLAUDE_CONFIG_DIR.",
            "这个登录已过期。下次用这个 CLAUDE_CONFIG_DIR 运行 Claude Code 时，它会自己续期。")
    }
}
