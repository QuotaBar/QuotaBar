import Foundation
import QuotaModel

/// What is left of the plan's API credit. ChatGPT's sign-in cannot read the
/// API organization's billing, an OpenAI API key can: one typed in Settings,
/// else one already on this Mac. Two ways, the first that answers:
///
/// 1. `GET /v1/dashboard/billing/credit_grants`, the grants the Platform's
///    Credit grants page lists, exact. Not in OpenAI's public reference, and
///    not every key may read it.
/// 2. An organization Admin key (`sk-admin-…`): `GET /v1/organization/costs`
///    since this period began, taken from the period's allowance. An
///    estimate: the first period is paid pro rata, and spending paid from
///    bought credit counts as well.
extension CodexAPICredits {
    // MARK: Keys

    public struct APIKey: Sendable, Equatable {
        public let value: String
        /// Where it was found: "Settings", "OPENAI_ADMIN_KEY", "~/.zshrc".
        public let source: String

        var isAdmin: Bool { value.hasPrefix("sk-admin-") }
    }

    static let keyNames = ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"]
    static let shellFiles = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]

    /// The keys to try, the one typed in Settings alone when there is one —
    /// it overrides what the Mac has — else every one found, admin first.
    public static func keys(saved: String?) -> [APIKey] {
        if let saved, !saved.isEmpty { return [APIKey(value: saved, source: L10n.t("Settings", "设置"))] }
        if let cached = keysMemo.cached() { return cached }
        let found = localKeys(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
        keysMemo.store(found)
        return found
    }

    /// The process's environment (an app opened from Finder has little of
    /// the shell's), Codex's `auth.json` when it signs in with a key, and the
    /// shell's start-up files, read for literal `export NAME=value` lines.
    static func localKeys(environment: [String: String], home: URL) -> [APIKey] {
        var out: [APIKey] = []
        func add(_ value: String?, _ source: String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  looksLikeKey(value), !out.contains(where: { $0.value == value })
            else { return }
            out.append(APIKey(value: value, source: source))
        }
        for name in keyNames { add(environment[name], name) }
        if let data = try? Data(contentsOf: home.appendingPathComponent(".codex/auth.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            add(root["OPENAI_API_KEY"] as? String, "~/.codex/auth.json")
        }
        for file in shellFiles {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            let exported = exports(text)
            for name in keyNames { add(exported[name], "~/\(file) · \(name)") }
        }
        return out.sorted { $0.isAdmin && !$1.isAdmin }
    }

    static func looksLikeKey(_ value: String) -> Bool {
        value.hasPrefix("sk-") && value.count >= 20 && !value.contains(where: \.isWhitespace)
    }

    /// `export OPENAI_API_KEY="sk-…"` and `OPENAI_API_KEY=sk-…` lines, the
    /// last one winning as the shell would have it; a value that refers to
    /// something else (`$(…)`, `$VAR`) is not one.
    static func exports(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            guard keyNames.contains(name) else { continue }
            var value = String(line[line.index(after: equals)...])
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.contains("$"), !value.contains("`") else { continue }
            out[name] = value
        }
        return out
    }

    private static let keysMemo = KeysMemo()

    final class KeysMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [APIKey]?
        private var at = Date.distantPast
        func cached() -> [APIKey]? { lock.withLock { Date().timeIntervalSince(at) < 60 ? value : nil } }
        func store(_ keys: [APIKey]?) { lock.withLock { value = keys; at = keys == nil ? .distantPast : Date() } }
    }

    /// Settings' "Save" and "Test" read the Mac again.
    public static func invalidateKeys() {
        keysMemo.store(nil)
        balanceMemo.reset()
    }

    // MARK: Balance

    struct Balance: Equatable, Sendable {
        var granted: Double
        var used: Double
        /// From the costs, not the grant.
        var estimated: Bool
        var remaining: Double { max(granted - used, 0) }
    }

    /// The last reading with a key, for Settings to say what it got.
    public enum KeyResult: Sendable, Equatable {
        case exact(source: String)
        case estimated(source: String)
        /// Every key refused: wrong, revoked, or a project key without access.
        case rejected(source: String)
        /// A key read nothing this way and none is an Admin key.
        case unreadable(source: String)

        public var description: String {
            switch self {
            case let .exact(source):
                L10n.t("Reading the exact balance with the key from \(source).", "正在用来自「\(source)」的 Key 读取准确余额。")
            case let .estimated(source):
                L10n.t("Estimating the balance from this period's API spend, with the Admin key from \(source).",
                       "正在用来自「\(source)」的 Admin Key 按本期 API 花费估算余额。")
            case let .rejected(source):
                L10n.t("The key from \(source) was refused: check that it is valid and belongs to the linked organization.",
                       "来自「\(source)」的 Key 被拒绝：请确认它有效，并且属于绑定的那个组织。")
            case let .unreadable(source):
                L10n.t("The key from \(source) cannot read billing. An organization Admin key (sk-admin-…) can estimate it.",
                       "来自「\(source)」的 Key 读不到账单。可以换成组织的 Admin Key（sk-admin-…）来估算。")
            }
        }
    }

    public static var lastKeyResult: KeyResult? { balanceMemo.result }

    static let balanceMemo = BalanceMemo()

    /// Ten minutes per key and period; a failed read keeps the last balance
    /// for an hour.
    final class BalanceMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (key: String, balance: Balance?, at: Date)?
        private var kept: (key: String, balance: Balance, at: Date)?
        var result: KeyResult? { lock.withLock { _result } }
        private var _result: KeyResult?

        func fresh(_ key: String, now: Date) -> Balance?? {
            lock.withLock {
                guard let entry, entry.key == key, now.timeIntervalSince(entry.at) < 600 else { return nil }
                return .some(entry.balance)
            }
        }

        func store(_ balance: Balance?, key: String, result: KeyResult?, now: Date) -> Balance? {
            lock.withLock {
                _result = result
                if let balance { kept = (key, balance, now) }
                entry = (key, balance, now)
                if balance == nil, let kept, kept.key == key, now.timeIntervalSince(kept.at) < 3600 { return kept.balance }
                return balance
            }
        }

        func reset() { lock.withLock { entry = nil; kept = nil; _result = nil } }
    }

    static func balance(keys: [APIKey], benefit: Benefit, now: Date = .now) async -> Balance? {
        guard !keys.isEmpty else { return nil }
        let memoKey = keys.map(\.value).joined(separator: "|") + "@\(benefit.expiresAt?.timeIntervalSince1970 ?? 0)"
        if let cached = balanceMemo.fresh(memoKey, now: now) { return cached }
        var rejected: APIKey?
        var unreadable: APIKey?
        for key in keys {
            switch await grantBalance(key: key, benefit: benefit) {
            case let .read(balance):
                return balanceMemo.store(balance, key: memoKey, result: .exact(source: key.source), now: now)
            case .rejected: rejected = rejected ?? key
            case .unreadable: unreadable = unreadable ?? key
            case .failed: break
            }
        }
        for key in keys where key.isAdmin {
            if let spent = await spend(key: key, benefit: benefit, now: now) {
                let balance = Balance(granted: benefit.amount, used: spent, estimated: true)
                return balanceMemo.store(balance, key: memoKey, result: .estimated(source: key.source), now: now)
            }
        }
        let result: KeyResult? = rejected.map { .rejected(source: $0.source) } ?? unreadable.map { .unreadable(source: $0.source) }
        return balanceMemo.store(nil, key: memoKey, result: result, now: now)
    }

    enum Answer { case read(Balance), rejected, unreadable, failed }

    private static func headers(_ key: APIKey) -> [String: String] {
        ["Authorization": "Bearer \(key.value)", "Accept": "application/json", "User-Agent": "QuotaBar"]
    }

    static func grantBalance(key: APIKey, benefit: Benefit) async -> Answer {
        guard let response = try? await HTTP.get(
            URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!, headers: headers(key))
        else { return .failed }
        switch response.status {
        case 200:
            return grantBalance(response.data, expiring: benefit.expiresAt).map(Answer.read) ?? .unreadable
        case 401: return key.isAdmin ? .unreadable : .rejected
        case 403, 404: return .unreadable
        default: return .failed
        }
    }

    /// `{"object":"credit_summary","total_granted":266.0,"total_used":0.07,"total_available":265.93,
    /// "grants":{"data":[{"grant_amount":266.0,"used_amount":0.07,"effective_at":1793232000,
    /// "expires_at":1794666601}]}}` — the grant that runs out with this
    /// period, else every grant together. Nil for a reply that is not that.
    static func grantBalance(_ data: Data, expiring: Date?) -> Balance? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let grants = ((root["grants"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        if let expiring {
            let match = grants.first { grant in
                guard let seconds = number(grant["expires_at"]) else { return false }
                return abs(seconds - expiring.timeIntervalSince1970) < 2 * 86_400
            }
            if let match, let granted = number(match["grant_amount"]), granted > 0 {
                return Balance(granted: granted, used: number(match["used_amount"]) ?? 0, estimated: false)
            }
        }
        guard let granted = number(root["total_granted"]), granted > 0 else { return nil }
        let used = number(root["total_used"]) ?? number(root["total_available"]).map { granted - $0 } ?? 0
        return Balance(granted: granted, used: max(used, 0), estimated: false)
    }

    /// Dollars spent since the period began, every page; nil when the key
    /// cannot read organization costs.
    static func spend(key: APIKey, benefit: Benefit, now: Date) async -> Double? {
        guard let start = periodStart(benefit, now: now) else { return nil }
        var total = 0.0
        var page: String?
        for _ in 0..<4 {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31"),
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            guard let url = components.url,
                  let response = try? await HTTP.get(url, headers: headers(key)), response.status == 200,
                  let read = costs(response.data)
            else { return nil }
            total += read.total
            guard let next = read.next else { return total }
            page = next
        }
        return total
    }

    /// The period this one is: a month before it ends.
    static func periodStart(_ benefit: Benefit, now: Date) -> Date? {
        guard let end = benefit.expiresAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(byAdding: .month, value: -1, to: end)
        return start.map { min($0, now) }
    }

    /// `{"data":[{"results":[{"amount":{"value":0.06,"currency":"usd"}}]}],"has_more":false,"next_page":null}`.
    static func costs(_ data: Data) -> (total: Double, next: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]]
        else { return nil }
        var total = 0.0
        for bucket in buckets {
            for result in bucket["results"] as? [[String: Any]] ?? [] {
                guard let amount = result["amount"] as? [String: Any],
                      (amount["currency"] as? String ?? "usd").lowercased() == "usd",
                      let value = number(amount["value"])
                else { continue }
                total += value
            }
        }
        let more = root["has_more"] as? Bool ?? false
        return (total, more ? root["next_page"] as? String : nil)
    }

    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text).flatMap { $0.isFinite ? $0 : nil } }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.doubleValue
        }
        return nil
    }
}
