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

// MARK: - MiniMax (API token → coding_plan/remains)

public struct MiniMaxProvider: QuotaProvider {
    public let id = ProviderID.minimax

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .minimax) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let raw = config.credential(for: .minimax) else {
            throw ProviderError.notConfigured(hint: ProviderID.minimax.setupHint)
        }
        var headers = [
            "Accept": "application/json",
            "MM-API-Source": "QuotaBar",
        ]
        if raw.contains("=") {
            headers["Cookie"] = raw
        } else {
            headers["Authorization"] = "Bearer \(raw)"
        }

        struct Remains: Decodable {
            let modelName: String?
            let currentIntervalRemainingPercent: Double?
            let currentIntervalTotalCount: Int?
            let currentIntervalUsageCount: Int?
            let endTime: Int?
            let currentWeeklyRemainingPercent: Double?
            let weeklyEndTime: Int?
        }
        struct DataBody: Decodable {
            let modelRemains: [Remains]?
        }
        struct Body: Decodable {
            let data: DataBody?
        }

        let url = URL(string: "https://api.minimax.io/v1/api/openplatform/coding_plan/remains")!
        let body = try await HTTP.get(url, headers: headers).requireOK().json(Body.self)
        guard let remains = body.data?.modelRemains, !remains.isEmpty else {
            throw ProviderError.badResponse
        }

        var windows: [UsageWindow] = []
        for entry in remains.prefix(3) {
            let name = entry.modelName ?? "Model"
            if let remaining = entry.currentIntervalRemainingPercent {
                windows.append(UsageWindow(
                    title: L10n.t("\(name) · interval", "\(name) · 周期"),
                    usedPercent: 100 - remaining,
                    detail: entry.currentIntervalTotalCount.map { total in
                        L10n.t(
                            "\(entry.currentIntervalUsageCount ?? 0) / \(total) req",
                            "\(entry.currentIntervalUsageCount ?? 0) / \(total) 次请求")
                    },
                    resetsAt: Dates.parseEpoch(entry.endTime.map(Double.init))))
            }
            if let weeklyRemaining = entry.currentWeeklyRemainingPercent {
                windows.append(UsageWindow(
                    title: L10n.t("\(name) · weekly", "\(name) · 每周"),
                    usedPercent: 100 - weeklyRemaining,
                    resetsAt: Dates.parseEpoch(entry.weeklyEndTime.map(Double.init)),
                    windowSeconds: 604_800,
                    scope: name))
            }
        }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - Gemini (Gemini CLI OAuth file → cloudcode-pa retrieveUserQuota)

public struct GeminiProvider: QuotaProvider {
    public let id = ProviderID.gemini

    public func isConfigured(config: ConfigStore) -> Bool {
        LocalCredentials.geminiAccessToken() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = LocalCredentials.geminiAccessToken() else {
            throw ProviderError.notConfigured(hint: ProviderID.gemini.setupHint)
        }
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
        return UsageSnapshot(windows: Array(windows))
    }
}
