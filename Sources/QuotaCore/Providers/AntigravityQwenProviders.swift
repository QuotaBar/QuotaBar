import Foundation

// MARK: - Antigravity (the app's own OAuth token → Cloud Code quota buckets)

/// Google's Antigravity IDE keeps a standalone OAuth token on disk and
/// asks the Cloud Code companion API for its model quotas. The same
/// calls, with the same token: `loadCodeAssist` for the project and plan,
/// `retrieveUserQuotaSummary` for each model family's 5-hour and weekly
/// limit, `fetchAvailableModels` for a family the summary leaves out, and
/// `retrieveUserQuota` when the model list carries no fractions. Request
/// shapes follow CodexBar's, which follow the app's.
public struct AntigravityProvider: QuotaProvider {
    public let id = ProviderID.antigravity

    static let base = "https://cloudcode-pa.googleapis.com/v1internal"

    public func isConfigured(config: ConfigStore) -> Bool {
        AntigravityLocal.isInstalled || AntigravityCLI.executable() != nil
            || LocalCredentials.antigravityToken() != nil || LocalCredentials.geminiAccessToken() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        // While the app runs, its own language server has the quota, and
        // needs no token: the one on disk is an hour old at most (issue #4).
        let local = await AntigravityLocal.read()
        if case let .quota(snapshot) = local { return snapshot }
        // Closed, or never installed: the CLI reports the same quota.
        if let snapshot = await AntigravityCLI.read() { return snapshot }

        // Written at sign-in and never refreshed; refreshing it would take the
        // app's own OAuth client.
        guard let token = LocalCredentials.antigravityToken(), !token.isExpired() else {
            // Without Antigravity, a Gemini CLI sign-in still has a quota of
            // its own on an enterprise seat.
            if let gemini = LocalCredentials.geminiAccessToken() {
                return try await GeminiCLIQuota.read(token: gemini)
            }
            if LocalCredentials.antigravityToken() == nil {
                throw ProviderError.notConfigured(hint: ProviderID.antigravity.setupHint)
            }
            throw ProviderError.sessionExpired(Self.expiredTokenHint(local))
        }
        return try await Self.readCloud(accessToken: token.accessToken)
    }

    /// The quota from Google's Cloud Code API, with the token the app saved.
    static func readCloud(accessToken: String) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": Self.userAgent(version: AntigravityLocal.installedVersion),
        ]
        let metadata = #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
        let assist = try? await HTTP.post(URL(string: "\(Self.base):loadCodeAssist")!, headers: headers, jsonBody: metadata)
            .requireOK().json(CodeAssist.self)
        let projectBody = assist?.projectID.map { #"{"project":"\#($0)"}"# } ?? "{}"
        let plan = assist?.planName

        // The summary the app itself shows: each family with its 5-hour and
        // weekly limit. The model list below has the 5-hour share alone, so
        // a week half spent read as 0%.
        let summary = (try? await HTTP.post(URL(string: "\(Self.base):retrieveUserQuotaSummary")!, headers: headers, jsonBody: projectBody)
            .requireOK())
            .flatMap { try? AntigravityLocal.parseSummary($0.data) }?.windows ?? []
        let covered = Set(summary.compactMap(\.scope))
        if Family.allCases.allSatisfy({ covered.contains($0.name) }) {
            return UsageSnapshot(planName: plan, windows: summary)
        }

        var quotas: [ModelQuota] = []
        if let models = try? await HTTP.post(URL(string: "\(Self.base):fetchAvailableModels")!, headers: headers, jsonBody: projectBody)
            .requireOK().json(AvailableModels.self)
        {
            quotas = Self.quotas(from: models)
        }
        if !quotas.contains(where: { $0.remainingFraction != nil }), summary.isEmpty {
            let response = try await HTTP.post(URL(string: "\(Self.base):retrieveUserQuota")!, headers: headers, jsonBody: projectBody)
                .requireOK()
            quotas = Self.quotas(from: try response.json(UserQuota.self))
        }
        return try Self.snapshot(summary: summary, quotas: quotas, plan: plan)
    }

    /// The app's own, with the installed app's version: Google's quota
    /// summary leaves the Gemini group out for a client that names no
    /// version — `antigravity` alone got Claude and GPT and nothing else,
    /// `antigravity/2.28.0 darwin/arm64` got both. Measured 2026-10-29.
    static func userAgent(version: String?) -> String {
        guard let version = version?.nilIfEmpty else { return "antigravity" }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/\(version) darwin/\(arch)"
    }

    /// Said when the language server gave nothing and the saved token has
    /// run out. Open, the app would have answered, so the fault is its
    /// service, not the sign-in; closed, opening it is the whole fix. The
    /// hint this replaced sent people to open an app already open.
    static func expiredTokenHint(_ local: AntigravityLocal.Reading) -> String {
        if case .noAnswer = local {
            return L10n.t(
                "Antigravity is open but its quota service did not answer, and the sign-in token it saved has expired. Try again in a moment, or restart Antigravity.",
                "Antigravity 正在运行，但它的额度服务没有应答，保存的登录令牌也已过期。稍后再刷新，或重启 Antigravity。")
        }
        return L10n.t(
            "Antigravity isn't running, and the sign-in token it saved has expired. Open Antigravity and the quota shows again; no need to sign in.",
            "Antigravity 没有运行，保存的登录令牌也已过期。打开 Antigravity 就能重新读到额度，不用重新登录。")
    }

    // MARK: Response shapes

    struct CodeAssist: Decodable {
        struct Tier: Decodable { let id: String?; let name: String? }
        let currentTier: Tier?
        /// The subscription — "Google AI Pro" — where `currentTier` is the
        /// Code Assist tier under it, named just "Antigravity".
        let paidTier: Tier?
        /// A string, or an object with an id — the API has sent both.
        let cloudaicompanionProject: Project?

        var projectID: String? {
            cloudaicompanionProject?.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        var planName: String? {
            paidTier?.name?.nilIfEmpty ?? currentTier?.name?.nilIfEmpty
        }

        struct Project: Decodable {
            let id: String?
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
                    id = value
                    return
                }
                let keyed = try decoder.container(keyedBy: Keys.self)
                id = try keyed.decodeIfPresent(String.self, forKey: .id)
                    ?? keyed.decodeIfPresent(String.self, forKey: .projectId)
            }
            enum Keys: String, CodingKey { case id, projectId }
        }
    }

    struct AvailableModels: Decodable {
        struct Model: Decodable {
            let displayName: String?
            let label: String?
            let quotaInfo: QuotaInfo?
            let isInternal: Bool?
            /// `MODEL_PROVIDER_GOOGLE`, `MODEL_PROVIDER_ANTHROPIC`, …
            let modelProvider: String?
        }
        let models: [String: Model]?
        /// The models behind tab completion, not ones anyone picks.
        let tabModelIds: [String]?
    }

    struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    struct UserQuota: Decodable {
        struct Bucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        let buckets: [Bucket]?
    }

    struct ModelQuota: Equatable {
        let modelID: String
        let label: String
        let family: Family?
        let remainingFraction: Double?
        let resetsAt: Date?

        init(modelID: String, label: String, provider: String? = nil, remainingFraction: Double?, resetsAt: Date?) {
            self.modelID = modelID
            self.label = label
            family = Family(modelID: modelID, label: label, provider: provider)
            self.remainingFraction = remainingFraction
            self.resetsAt = resetsAt
        }

        /// Reads the same as `other`: the same share left and the same reset,
        /// or no reset yet on one side. Models on one allowance always do.
        func readsLike(_ other: ModelQuota) -> Bool {
            guard remainingFraction == other.remainingFraction else { return false }
            guard let mine = resetsAt, let theirs = other.resetsAt else { return true }
            return abs(mine.timeIntervalSince(theirs)) < 60
        }

        /// Of two readings for one model, the one that binds: less left, then
        /// the sooner reset, then the id, so the pick does not hang on the
        /// order the answer listed them in.
        func binds(before other: ModelQuota) -> Bool {
            let left = (remainingFraction ?? .greatestFiniteMagnitude, other.remainingFraction ?? .greatestFiniteMagnitude)
            if left.0 != left.1 { return left.0 < left.1 }
            let reset = (resetsAt ?? .distantFuture, other.resetsAt ?? .distantFuture)
            if reset.0 != reset.1 { return reset.0 < reset.1 }
            return modelID < other.modelID
        }
    }

    /// The groups Antigravity's own quota summary uses, named the way
    /// `AntigravityLocal.groupName` reads them. Each shares one allowance:
    /// every Gemini model resets at the same moment, and every Claude and GPT
    /// one at another. Gemini first, since Antigravity is Google's.
    enum Family: Int, CaseIterable, Hashable {
        case gemini, claudeAndGPT

        var name: String {
            switch self {
            case .gemini: "Gemini"
            case .claudeAndGPT: "Claude and GPT"
            }
        }

        init?(modelID: String, label: String, provider: String?) {
            switch provider {
            case "MODEL_PROVIDER_GOOGLE": self = .gemini
            case "MODEL_PROVIDER_ANTHROPIC", "MODEL_PROVIDER_OPENAI": self = .claudeAndGPT
            default:
                let names = [modelID.lowercased(), label.lowercased()]
                if names.contains(where: { $0.hasPrefix("gemini") }) {
                    self = .gemini
                } else if names.contains(where: { $0.hasPrefix("claude") || $0.hasPrefix("gpt") }) {
                    self = .claudeAndGPT
                } else {
                    return nil
                }
            }
        }
    }

    /// The models a person picks from. The answer also lists the plumbing —
    /// `chat_20706` and `tab_flash_lite_preview` behind tab completion,
    /// `gemini-3.8-flash-tiered` behind the tiers — with no name of their
    /// own, and it gives several ids one name: `gemini-2.5-flash`,
    /// `gemini-2.5-flash-lite` and two more all answer as "Gemini 3.5 Flash
    /// Lite". A model with no name, marked internal or used for tab
    /// completion is left out, and one name is one model. Measured against
    /// Antigravity 2.28.0, 2026-10-29: 17 entries, 8 models.
    static func quotas(from response: AvailableModels) -> [ModelQuota] {
        let tab = Set(response.tabModelIds ?? [])
        var byLabel: [String: ModelQuota] = [:]
        for (modelID, model) in response.models ?? [:] {
            guard let info = model.quotaInfo, model.isInternal != true, !tab.contains(modelID),
                  let label = model.displayName?.nilIfEmpty ?? model.label?.nilIfEmpty
            else { continue }
            let next = ModelQuota(
                modelID: modelID,
                label: label,
                provider: model.modelProvider,
                remainingFraction: info.remainingFraction,
                resetsAt: LocalCredentials.parseFlexibleISO(info.resetTime))
            if let existing = byLabel[label], existing.binds(before: next) { continue }
            byLabel[label] = next
        }
        return byLabel.values.sorted(by: ordered)
    }

    /// Several buckets can name one model; the emptiest one is the binding.
    static func quotas(from response: UserQuota) -> [ModelQuota] {
        var byModel: [String: ModelQuota] = [:]
        for bucket in response.buckets ?? [] {
            guard let modelID = bucket.modelId?.nilIfEmpty else { continue }
            let next = ModelQuota(
                modelID: modelID,
                label: modelID,
                remainingFraction: bucket.remainingFraction,
                resetsAt: LocalCredentials.parseFlexibleISO(bucket.resetTime))
            if let existing = byModel[modelID], existing.binds(before: next) { continue }
            byModel[modelID] = next
        }
        return byModel.values.sorted(by: ordered)
    }

    /// Gemini, then Claude and GPT, then anything else; by name within each.
    static func ordered(_ a: ModelQuota, _ b: ModelQuota) -> Bool {
        let last = Family.allCases.count
        let rank = (a.family?.rawValue ?? last, b.family?.rawValue ?? last)
        return rank.0 != rank.1 ? rank.0 < rank.1 : a.label < b.label
    }

    /// Each family from the summary when the summary has it, else from the
    /// model list; Gemini first, since with nothing used the first window is
    /// the one the menu bar shows. Groups the summary has beyond the two
    /// families come last.
    static func snapshot(summary: [UsageWindow] = [], quotas: [ModelQuota], plan: String?) throws -> UsageSnapshot {
        let names = Set(Family.allCases.map(\.name))
        let covered = Set(summary.compactMap(\.scope))
        let byFamily = Dictionary(grouping: quotas) { $0.family }
        var windows: [UsageWindow] = []
        for family in Family.allCases.map(Optional.some) + [nil] {
            if let family, covered.contains(family.name) {
                windows += summary.filter { $0.scope == family.name }
            } else {
                windows += modelWindows((byFamily[family] ?? []).sorted(by: ordered), family: family)
            }
        }
        windows += summary.filter { !names.contains($0.scope ?? "") }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: plan?.nilIfEmpty, windows: windows)
    }

    /// A family whose models all read alike is on one allowance, and is one
    /// window named for the family, with its models in the hover. A family
    /// whose models part ways keeps a window per model, so one that runs out
    /// on its own still shows.
    static func modelWindows(_ members: [ModelQuota], family: Family?) -> [UsageWindow] {
        var rows: [(title: String, note: String?, quota: ModelQuota)] = []
        if let family, members.count > 1, members.allSatisfy({ a in members.allSatisfy { a.readsLike($0) } }),
           let binding = members.min(by: { $0.binds(before: $1) })
        {
            rows.append((family.name, members.map(\.label).joined(separator: ", "), binding))
        } else {
            rows = members.map { ($0.label, nil, $0) }
        }
        return rows.map { row in
            UsageWindow(
                title: row.title,
                usedPercent: row.quota.remainingFraction.map { (1 - min(max($0, 0), 1)) * 100 },
                resetsAt: row.quota.resetsAt,
                scope: row.title,
                note: row.note)
        }
    }

    /// Pinned by the tests against recorded shapes.
    public static func parse(models data: Data, plan: String? = nil) throws -> UsageSnapshot {
        let response: AvailableModels
        do { response = try JSONDecoder().decode(AvailableModels.self, from: data) } catch { throw ProviderError.badResponse }
        return try snapshot(quotas: quotas(from: response), plan: plan)
    }

    public static func parse(buckets data: Data, plan: String? = nil) throws -> UsageSnapshot {
        let response: UserQuota
        do { response = try JSONDecoder().decode(UserQuota.self, from: data) } catch { throw ProviderError.badResponse }
        return try snapshot(quotas: quotas(from: response), plan: plan)
    }

    /// The summary and the model list together, as `fetch` puts them.
    static func parse(summary: Data?, models: Data, plan: String? = nil) throws -> UsageSnapshot {
        let windows = summary.flatMap { try? AntigravityLocal.parseSummary($0) }?.windows ?? []
        let response: AvailableModels
        do { response = try JSONDecoder().decode(AvailableModels.self, from: models) } catch { throw ProviderError.badResponse }
        return try snapshot(summary: windows, quotas: quotas(from: response), plan: plan)
    }
}

// MARK: - Qwen Cloud (console Cookie header → token plan usage)

/// Alibaba's Qwen Cloud token plan, read the way the console page reads it:
/// a `sec_token` from the signed-in dashboard, then the console's data
/// gateway, which wraps the plan API. Cookie-based, so the credential is
/// the full Cookie header from a signed-in browser. Shapes follow
/// CodexBar's reading of the same console.
public struct QwenProvider: QuotaProvider {
    public let id = ProviderID.qwen

    static let dashboard = URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
    static let origin = "https://home.qwencloud.com"
    static let gateway = "https://cs-data.qwencloud.com/data/api.json"
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let productCode = "sfm_tokenplansolo_public_intl"
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .qwen) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let cookie = try Self.cookieHeader(config.credential(for: .qwen), for: .qwen)
        // The console injects sec_token into the signed-in page; a page
        // without one is the login page.
        let page = try await HTTP.get(Self.dashboard, headers: [
            "Cookie": cookie,
            "Accept": "text/html,application/xhtml+xml",
            "User-Agent": Self.browserAgent,
        ]).requireOK()
        guard let secToken = Self.secToken(inHTML: String(decoding: page.data, as: UTF8.self))
            ?? Self.cookieValue("sec_token", in: cookie)
        else { throw ProviderError.unauthorized }

        let usage = try await Self.call(Self.usageAPI, data: [:], secToken: secToken, cookie: cookie).requireOK()
        let subscription = try? await Self.call(
            Self.subscriptionAPI, data: ["commodityCode": Self.productCode], secToken: secToken, cookie: cookie)
            .requireOK()
        return try Self.parse(usage.data, subscription: subscription?.data)
    }

    // MARK: Console gateway

    static func call(_ api: String, data: [String: String], secToken: String, cookie: String) async throws -> HTTPResponse {
        var components = URLComponents(string: gateway)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": dashboard.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": dashboard.host ?? "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US",
        ]
        if let anonymous = cookieValue("cna", in: cookie) { cornerstone["X-Anonymous-Id"] = anonymous }
        var payload: [String: Any] = data
        payload["cornerstoneParam"] = cornerstone
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": payload]
        let paramsJSON = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "sec_token", value: secToken),
            URLQueryItem(name: "region", value: "ap-southeast-1"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "params", value: paramsJSON),
        ]
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json, text/plain, */*",
            "Cookie": cookie,
            "Origin": origin,
            "Referer": dashboard.absoluteString,
            "X-Requested-With": "XMLHttpRequest",
            "User-Agent": browserAgent,
        ]
        if let csrf = cookieValue("login_aliyunid_csrf", in: cookie) ?? cookieValue("csrf", in: cookie) {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }
        return try await HTTP.post(components.url!, headers: headers, jsonBody: form.percentEncodedQuery ?? "")
    }

    // MARK: Parsing

    /// The gateway wraps the plan API's JSON as a string inside its own
    /// JSON, sometimes twice; the usage object is wherever it ends up.
    public static func parse(_ data: Data, subscription: Data? = nil, now: Date = Date()) throws -> UsageSnapshot {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { throw ProviderError.badResponse }
        let expanded = expandEmbeddedJSON(raw)
        // Personal and Solo Token Plans report one monthly window and nothing
        // else (`per1MonthPercentage`, as the console's Monthly usage shows).
        guard let usage = findObject(
            containingAnyOf: ["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"], in: expanded)
        else {
            if String(decoding: data, as: UTF8.self).lowercased().contains("login") { throw ProviderError.unauthorized }
            throw ProviderError.badResponse
        }
        var windows: [UsageWindow] = []
        if let ratio = number(usage["per5HourPercentage"]) {
            windows.append(UsageWindow(
                title: L10n.t("5-hour window", "5 小时窗口"),
                usedPercent: percent(ratio),
                resetsAt: date(usage["per5HourResetTime"]),
                windowSeconds: 5 * 3600))
        }
        if let ratio = number(usage["per1WeekPercentage"]) {
            windows.append(UsageWindow(
                title: L10n.t("Weekly window", "周窗口"),
                usedPercent: percent(ratio),
                resetsAt: date(usage["per1WeekResetTime"]),
                windowSeconds: 7 * 86_400))
        }
        if let ratio = number(usage["per1MonthPercentage"]) {
            windows.append(UsageWindow(
                title: L10n.t("Monthly window", "月窗口"),
                usedPercent: percent(ratio),
                resetsAt: date(usage["per1MonthResetTime"]),
                windowSeconds: 2_592_000))
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: subscription.flatMap(planName), windows: windows)
    }

    static func planName(from data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let keys = ["specCode", "spec_code", "planName", "plan_name"]
        guard let plan = findObject(containingAnyOf: Set(keys), in: expandEmbeddedJSON(raw)) else { return nil }
        for key in keys {
            guard let value = (plan[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else { continue }
            switch value {
            case "lite": return "Lite"
            case "standard": return "Standard"
            case "pro": return "Pro"
            case "max": return "Max"
            default: return value
            }
        }
        return nil
    }

    /// Ratios come as 0–1, occasionally already as 0–100.
    static func percent(_ ratio: Double) -> Double {
        ratio <= 1 ? ratio * 100 : ratio
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Epoch milliseconds, epoch seconds, or an ISO string.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let iso = Dates.parseISO(string) { return iso }
        guard let raw = number(value) else { return nil }
        return Dates.parseEpoch(raw)
    }

    static func expandEmbeddedJSON(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data)
            else { return value }
            return expandEmbeddedJSON(decoded)
        }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(expandEmbeddedJSON) }
        if let array = value as? [Any] { return array.map(expandEmbeddedJSON) }
        return value
    }

    static func findObject(containingAnyOf keys: Set<String>, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if !keys.isDisjoint(with: dictionary.keys) { return dictionary }
            for child in dictionary.values {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        }
        return nil
    }

    // MARK: Cookies

    /// "Cookie: a=b; c=d" as pasted from DevTools, or the bare pairs.
    static func normalizeCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return value.isEmpty ? nil : value
    }

    /// The Cookie header a console provider needs, or why what was saved is
    /// not one. A header is always `name=value` pairs; an API key pasted in
    /// its place has no `=`, and sent as a cookie it loads the console signed
    /// out — which read as an expired session.
    static func cookieHeader(_ raw: String?, for id: ProviderID) throws -> String {
        guard let raw, let cookie = normalizeCookie(raw) else { throw ProviderError.notConfigured(hint: id.setupHint) }
        guard cookie.contains("=") else {
            let browser = id == .alibaba || id == .qwen || id == .mimo
            throw ProviderError.notConfigured(hint: browser
                ? L10n.t(
                    "What's saved is an API key, but \(id.displayName) is read through its signed-in console. Choose Sign in in a browser… in Settings, or paste the console's Cookie header.",
                    "填的是 API Key，但\(id.displayName)要通过登录后的控制台读取。请在设置里点「浏览器登录…」，或粘贴控制台的 Cookie 头。")
                : L10n.t(
                    "What's saved is an API key, but \(id.displayName) is read through its signed-in console. Paste the console's Cookie header in Settings.",
                    "填的是 API Key，但\(id.displayName)要通过登录后的控制台读取。请在设置里粘贴控制台的 Cookie 头。"))
        }
        return cookie
    }

    static func cookieValue(_ name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == name, !parts[1].isEmpty else { continue }
            return parts[1]
        }
        return nil
    }

    static func secToken(inHTML html: String) -> String? {
        let patterns = [
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #""secToken"\s*:\s*"([^"]+)""#,
            // The console's config object, as the Bailian page now writes it:
            // `SEC_TOKEN: "…"` inside `window.ALIYUN_CONSOLE_CONFIG`. None of
            // the spellings above matched, and every reading failed as an
            // expired session while the sign-in was fine.
            #"SEC_TOKEN['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let token = String(html[range])
            if !token.isEmpty { return token }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
