import Foundation

// MARK: - OpenCode Go (token/cookie → opencode.ai/zen/go/v1/usage)

public struct OpenCodeGoProvider: QuotaProvider {
    public let id = ProviderID.opencodeGo

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .opencodeGo) != nil || LocalCredentials.openCodeGoKey() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        var headers = ["Accept": "application/json", "User-Agent": "QuotaBar"]
        if let raw = config.credential(for: .opencodeGo) {
            // A pasted credential may be a full Cookie header or a bare token.
            if raw.lowercased().contains("cookie") || raw.contains("=") {
                headers["Cookie"] = raw
            } else {
                headers["Authorization"] = "Bearer \(raw)"
            }
        } else if let key = LocalCredentials.openCodeGoKey() {
            headers["Authorization"] = "Bearer \(key)"
        } else {
            throw ProviderError.notConfigured(hint: ProviderID.opencodeGo.setupHint)
        }
        let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!
        let response = try await HTTP.get(url, headers: headers).requireOK()
        return try Self.parse(response.data)
    }

    /// Pure parse step. The live response nests the windows under a top-level
    /// `usage` object and reports resets as ISO timestamps — both were missed
    /// by the original guesses, so the provider silently returned nothing.
    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        // Windows live under `usage` in the live API; fall back to the root for
        // any older/flatter shape.
        let container = (root["usage"] as? [String: Any]) ?? root

        func window(_ keys: [String], title: String, seconds: Int? = nil) -> UsageWindow? {
            for key in keys {
                guard let dict = container[key] as? [String: Any] else { continue }
                let percent = (dict["percent"] as? Double)
                    ?? (dict["percentUsed"] as? Double)
                    ?? (dict["usage_percent"] as? Double)
                    ?? (dict["used_percent"] as? Double)
                // Prefer the ISO reset the live API sends; keep the seconds
                // form as a fallback.
                let resetsAt = Dates.parseISO(dict["resetsAt"] as? String)
                    ?? Dates.parseAny(dict["reset_at"] as? String)
                    ?? (dict["resetInSec"] as? Int).map { Date().addingTimeInterval(TimeInterval($0)) }
                    ?? (dict["reset_in_sec"] as? Int).map { Date().addingTimeInterval(TimeInterval($0)) }
                return UsageWindow(
                    title: title, usedPercent: percent, resetsAt: resetsAt, windowSeconds: seconds)
            }
            return nil
        }

        var windows: [UsageWindow] = []
        if let rolling = window(["rolling", "rollingUsage", "rolling_usage"], title: L10n.t("Rolling window", "滚动窗口")) {
            windows.append(rolling)
        }
        if let weekly = window(
            ["weekly", "weeklyUsage", "weekly_usage"],
            title: WindowTitle.forSeconds(604_800), seconds: 604_800)
        {
            windows.append(weekly)
        }
        if let monthly = window(
            ["monthly", "monthlyUsage", "monthly_usage"],
            title: WindowTitle.forSeconds(2_592_000), seconds: 2_592_000)
        {
            windows.append(monthly)
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - MiniMax (MiniMax Code's sign-in, or an API token → coding_plan/remains)

public struct MiniMaxProvider: QuotaProvider {
    public let id = ProviderID.minimax
    var environment: MiniMaxCodeEnvironment

    public init(environment: MiniMaxCodeEnvironment = .live) {
        self.environment = environment
    }

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .minimax) != nil || MiniMaxCode.signIn(authHome: environment.authHome) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        // Something pasted is used before the sign-in on this Mac.
        if let raw = config.credential(for: .minimax) {
            return try await Self.fetchPasted(raw, send: environment.send)
        }
        guard let signIn = MiniMaxCode.signIn(authHome: environment.authHome) else {
            throw ProviderError.notConfigured(hint: ProviderID.minimax.setupHint)
        }
        return try await fetchSignedIn(signIn)
    }

    /// With MiniMax Code's sign-in, and the account it is signed in to under
    /// the card's name.
    func fetchSignedIn(_ signIn: MiniMaxCodeSignIn) async throws -> UsageSnapshot {
        var snapshot = try await readSignedIn(signIn)
        if snapshot.account?.isEmpty ?? true {
            // The token the reading went out with, renewed or not.
            let token = MiniMaxCode.signIn(authHome: environment.authHome)?.accessToken ?? signIn.accessToken
            snapshot.account = await MiniMaxCode.account(region: signIn.region, token: token, env: environment)
        }
        return snapshot
    }

    /// Renewed first when it has run out or is about to, and once more when
    /// the quota endpoint turns it down.
    private func readSignedIn(_ signIn: MiniMaxCodeSignIn) async throws -> UsageSnapshot {
        let env = environment
        var token = signIn.accessToken
        if signIn.isDue(now: env.now()) {
            if env.mayRenew, signIn.hasRefreshToken {
                token = try await renewed(signIn, rejected: nil)
            } else if signIn.isExpired(now: env.now()) {
                throw ProviderError.sessionExpired(Self.expiredHint)
            }
        }
        do {
            return try await MiniMaxCode.fetchRemains(region: signIn.region, token: token, send: env.send)
        } catch ProviderError.unauthorized where env.mayRenew && signIn.hasRefreshToken {
            let fresh = try await renewed(signIn, rejected: token)
            do {
                return try await MiniMaxCode.fetchRemains(region: signIn.region, token: fresh, send: env.send)
            } catch ProviderError.unauthorized {
                throw ProviderError.sessionExpired(Self.signInAgainHint)
            }
        } catch ProviderError.unauthorized {
            throw ProviderError.sessionExpired(Self.expiredHint)
        }
    }

    private func renewed(_ signIn: MiniMaxCodeSignIn, rejected: String?) async throws -> String {
        do {
            return try await environment.renewal.token(region: signIn.region, rejected: rejected, env: environment)
        } catch let failure as MiniMaxCodeRenewal.Failure {
            switch failure {
            case .signInAgain:
                throw ProviderError.sessionExpired(Self.signInAgainHint)
            case .busy:
                // MiniMax Code is renewing it right now; its token will do
                // at the next refresh.
                throw ProviderError.unavailable(L10n.t(
                    "MiniMax Code is renewing its sign-in; the next refresh will read it.",
                    "MiniMax Code 正在续期登录，下次刷新就能读到。"))
            case let .unavailable(detail):
                throw ProviderError.unavailable(detail)
            }
        }
    }

    static var expiredHint: String {
        L10n.t(
            "MiniMax Code's sign-in has run out (it lasts an hour). Open MiniMax Code once, or keep QuotaBar running and it renews the sign-in itself.",
            "MiniMax Code 的登录已过期（每次有效一小时）。打开一次 MiniMax Code 即可恢复；QuotaBar 保持运行时会自己续期。")
    }

    static var signInAgainHint: String {
        L10n.t(
            "MiniMax turned down MiniMax Code's sign-in. Open MiniMax Code and sign in again.",
            "MiniMax 拒绝了 MiniMax Code 的登录，请打开 MiniMax Code 重新登录。")
    }

    /// A pasted API token or Cookie header, on the Global API host.
    static func fetchPasted(_ raw: String, send: HTTPSend) async throws -> UsageSnapshot {
        var headers = [
            "Accept": "application/json",
            "MM-API-Source": "QuotaBar",
        ]
        if raw.contains("=") {
            headers["Cookie"] = raw
        } else {
            headers["Authorization"] = "Bearer \(raw)"
        }
        let url = URL(string: "https://api.minimax.io" + MiniMaxCode.remainsPath)!
        let response = try await send("GET", url, headers, nil, 20)
        return try MiniMaxCode.parseRemains(response.requireOK().data)
    }

    /// For Settings: the pasted credential or the sign-in on this Mac, and
    /// which edition.
    public func sourceInfo(config: ConfigStore) -> ProviderSourceInfo? {
        let signIn = MiniMaxCode.signIn(authHome: environment.authHome)
        if config.credential(for: .minimax) != nil {
            return ProviderSourceInfo(
                summary: L10n.t("Pasted API token or Cookie header", "粘贴的 API token 或 Cookie 头"),
                note: signIn.map {
                    L10n.t(
                        "Clear it to use the MiniMax Code sign-in on this Mac (\($0.region.label)).",
                        "清除后改用本机 MiniMax Code 登录（\($0.region.label)）。")
                })
        }
        guard let signIn else { return nil }
        return ProviderSourceInfo(
            summary: L10n.t(
                "MiniMax Code sign-in on this Mac · \(signIn.region.label)",
                "MiniMax Code 本机登录 · \(signIn.region.label)"),
            note: L10n.t(
                "The sign-in lasts an hour; while QuotaBar runs it renews it the way MiniMax Code does, so readings go on with MiniMax Code closed.",
                "登录每次有效一小时；QuotaBar 运行时会按 MiniMax Code 的方式自动续期，MiniMax Code 关着也能继续读取。"),
            consoleURL: signIn.region.consoleURL)
    }
}

// MARK: - Gemini CLI (OAuth file → cloudcode-pa retrieveUserQuota)

/// The Gemini CLI's own quota, now the Antigravity card's last way in: since
/// 2026-06-18 the CLI serves only Code Assist Standard and Enterprise seats
/// and paid API keys — Pro, Ultra and free users were moved to Antigravity —
/// so for most people there is nothing here to read.
enum GeminiCLIQuota {
    static func read(token: String) async throws -> UsageSnapshot {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        let response = try await HTTP.post(url, headers: [
            "Authorization": "Bearer \(token)",
        ]).requireOK()

        struct Bucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        struct Body: Decodable {
            let buckets: [Bucket]?
        }

        let body = try response.json(Body.self)
        guard let buckets = body.buckets, !buckets.isEmpty else {
            throw ProviderError.badResponse
        }
        let windows = buckets.prefix(4).map { bucket in
            UsageWindow(
                title: bucket.modelId ?? L10n.t("Model quota", "模型额度"),
                usedPercent: bucket.remainingFraction.map { (1 - $0) * 100 },
                resetsAt: Dates.parseISO(bucket.resetTime))
        }
        return UsageSnapshot(windows: Array(windows), source: "gemini-cli")
    }
}
