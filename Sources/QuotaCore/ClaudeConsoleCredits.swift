import Foundation
import QuotaModel

/// The API credit a Claude plan comes with — $200 a month on Max 20x — as the
/// Claude Console (platform.claude.com) keeps it. Neither Claude Code's
/// sign-in nor an API key can read billing; the Console's own browser
/// sign-in, a `sessionKey` of its own beside claude.ai's, can. Found in the
/// same jars `ClaudeWebSession` searches, never with a dialog: a sealed jar
/// whose key macOS has not handed over yet is passed over until the card's
/// "Allow keychain access" is pressed.
///
/// The endpoints are the ones the Console's billing page calls, read-only:
/// `/api/organizations` (those with the `api` capability own billing), then
/// `/api/organizations/{uuid}/prepaid/credits`. The same reading as
/// steipete/CodexBar's Claude Platform provider.
///
/// Beside the plan's limits, so the rows are extras; a failure costs them,
/// never the Claude reading, and keeps the last ones read.
public enum ClaudeConsoleCredits {
    static let origin = "https://platform.claude.com"

    /// One credit grant: an amount given or bought, and when it runs out.
    struct Grant: Equatable, Sendable {
        var name: String?
        /// `subscription_api_credit` for the one a plan includes.
        var program: String?
        var purchased: Bool
        var granted: Double
        var remaining: Double
        var expiresAt: Date?

        var isSubscription: Bool { program == "subscription_api_credit" }
    }

    struct Reading: Equatable, Sendable {
        var organization: String?
        var grants: [Grant]
    }

    // MARK: For Settings

    /// "Chrome, Safari": the browsers signed in to platform.claude.com.
    public static var detectedNames: [String] { ClaudeWebSession.detectedNames(.console) }

    /// Every Console sign-in found is sealed with a key macOS has not let
    /// QuotaBar read yet. Quiet: it never asks.
    public static func needsAuthorization() -> Bool { ClaudeWebSession.needsAuthorization(.console) }

    /// The keychain dialog, from a click; the next reading asks the Console
    /// again rather than answering from the memo.
    @discardableResult
    public static func authorize() -> Bool {
        let any = ClaudeWebSession.authorize(.console)
        memo.reset()
        return any
    }

    public static func invalidate() { memo.reset() }

    // MARK: Card rows

    /// The rows for the Claude card: every grant given rather than bought
    /// that has something left, the plan's own first, then soonest deadline.
    public static func windows(now: Date = .now) async -> [UsageWindow] {
        guard let reading = await reading(now: now) else { return [] }
        return windows(reading, now: now)
    }

    static func windows(_ reading: Reading, now: Date = .now) -> [UsageWindow] {
        let given = reading.grants
            .filter { !$0.purchased && $0.remaining > 0 && ($0.expiresAt ?? .distantFuture) > now }
            .sorted { lhs, rhs in
                if lhs.isSubscription != rhs.isSubscription { return lhs.isSubscription }
                return (lhs.expiresAt ?? .distantFuture) < (rhs.expiresAt ?? .distantFuture)
            }
        return given.enumerated().map { index, grant in window(grant, index: index, organization: reading.organization) }
    }

    static func window(_ grant: Grant, index: Int, organization: String?) -> UsageWindow {
        let used = max(grant.granted - grant.remaining, 0)
        let day = grant.expiresAt.map(utcDay)
        let title = grant.isSubscription
            ? L10n.t("API credit", "API 赠送额度")
            : (grant.name ?? L10n.t("API bonus credit", "API 赠送额度"))
        var detail = "\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(grant.granted))"
        if let day { detail += L10n.t(" · expires \(day)", " · \(day)到期") }
        let place = organization.map { L10n.t(" (\($0))", "（\($0)）") } ?? ""
        var window = UsageWindow(
            title: title,
            usedPercent: grant.granted > 0 ? used / grant.granted * 100 : nil,
            detail: detail,
            note: grant.isSubscription
                ? L10n.t(
                    "API credit the Claude plan includes, kept in the Claude Console\(place). It pays for API calls only and is counted apart from the plan's limits\(day.map { "; what is left runs out \($0) (UTC)" } ?? "").",
                    "Claude 订阅附送的 API 额度，在 Claude Console\(place)里，只能用于 API 调用，和套餐限额分开计算\(day.map { "，没用完的在 \($0)（UTC）到期" } ?? "")。")
                : L10n.t(
                    "A credit given to the Claude Console organization\(place), for API calls only\(day.map { "; what is left runs out \($0) (UTC)" } ?? "").",
                    "Claude Console\(place)获赠的额度，只能用于 API 调用\(day.map { "，没用完的在 \($0)（UTC）到期" } ?? "")。"))
        window.id = "console-credit-\(index)"
        window.credit = CreditAmount(
            amount: QuotaFormat.usd(grant.remaining),
            caption: L10n.t(
                "Used \(QuotaFormat.usd(used)) of \(QuotaFormat.usd(grant.granted))",
                "已用 \(QuotaFormat.usd(used)) / \(QuotaFormat.usd(grant.granted))"),
            expiresAt: grant.expiresAt)
        window.extra = true
        return window
    }

    /// Console grants run out at UTC midnight; the UTC calendar day is the
    /// one the Console shows.
    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    // MARK: Parsing

    /// `/prepaid/credits`: `{"amount":20000,"currency":"USD","balance":{"credits":{"exponent":2}},
    /// "promo_tranches":[{"name":…,"program_id":"subscription_api_credit",
    /// "granted_amount_minor_units":20000,"remaining_amount_minor_units":12475,
    /// "expires_at":"2026-12-01T00:00:00Z"}],"tranches":[…]}`. Amounts are in
    /// minor units of `10^exponent` (2 when not said). Nil for a reply that
    /// is not that, or in a currency other than dollars.
    static func grants(_ data: Data, now: Date = .now) -> [Grant]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let currency = root["currency"] as? String, currency.uppercased() != "USD" { return nil }
        var exponent = 2
        if let reported = ((root["balance"] as? [String: Any])?["credits"] as? [String: Any])?["exponent"] {
            guard let value = integer(reported), (0...4).contains(value) else { return nil }
            exponent = value
        }
        let scale = pow(10, Double(exponent))
        var out: [Grant] = []
        var sawList = false
        for (field, purchased) in [("promo_tranches", false), ("tranches", true)] {
            guard let value = root[field], !(value is NSNull) else { continue }
            guard let list = value as? [[String: Any]] else { return nil }
            sawList = true
            for tranche in list {
                guard let granted = integer(tranche["granted_amount_minor_units"]),
                      let remaining = integer(tranche["remaining_amount_minor_units"]),
                      granted > 0
                else { continue }
                let expires = Dates.parseISO(tranche["expires_at"] as? String)
                if let expires, expires <= now { continue }
                out.append(Grant(
                    name: (tranche["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    program: tranche["program_id"] as? String,
                    purchased: purchased,
                    granted: Double(granted) / scale,
                    remaining: Double(max(remaining, 0)) / scale,
                    expiresAt: expires))
            }
        }
        guard sawList || integer(root["amount"]) != nil else { return nil }
        return out
    }

    /// The API organizations, in the order listed: claude.ai's chat
    /// organizations share the list and own no Console billing.
    static func organizations(_ data: Data) -> [(id: String, name: String?)]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { organization in
            guard let capabilities = organization["capabilities"] as? [String], capabilities.contains("api"),
                  let id = organization["uuid"] as? String,
                  !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { return nil }
            return (id, (organization["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// A JSON whole number, not a boolean.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    // MARK: Reading

    private static let memo = Memo()

    /// The last reading, asked again after ten minutes; a failed read keeps
    /// the last one for up to a day, so a timeout does not blank the rows.
    final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (reading: Reading, at: Date)?
        private var triedAt = Date.distantPast

        func fresh(now: Date) -> Reading?? {
            lock.withLock {
                guard now.timeIntervalSince(triedAt) < 600 else { return nil }
                return .some(kept(now: now))
            }
        }

        func kept(now: Date) -> Reading? {
            guard let last, now.timeIntervalSince(last.at) < 86_400 else { return nil }
            return last.reading
        }

        func reset() { lock.withLock { triedAt = .distantPast } }

        func store(_ reading: Reading?, now: Date) -> Reading? {
            lock.withLock {
                triedAt = now
                if let reading { last = (reading, now) }
                return kept(now: now)
            }
        }
    }

    static func reading(now: Date = .now) async -> Reading? {
        if let cached = memo.fresh(now: now) { return cached }
        let sources = ClaudeWebSession.sources(.console)
        guard !sources.isEmpty else { return memo.store(nil, now: now) }
        for source in sources {
            guard case let .session(session) = ClaudeWebSession.read(source, interactive: false, site: .console)
            else { continue }
            if let reading = await read(session, now: now) { return memo.store(reading, now: now) }
        }
        return memo.store(nil, now: now)
    }

    /// One sign-in's grants: the first API organization whose billing the
    /// member may read.
    static func read(_ session: ClaudeWebSession.Session, now: Date) async -> Reading? {
        let headers = [
            "Cookie": session.header, "User-Agent": ClaudeWebSession.userAgent, "Accept": "application/json",
        ]
        guard let response = try? await HTTP.get(URL(string: "\(origin)/api/organizations")!, headers: headers),
              response.status == 200,
              let organizations = organizations(response.data)
        else { return nil }
        for organization in organizations {
            guard let response = try? await HTTP.get(
                URL(string: "\(origin)/api/organizations/\(organization.id)/prepaid/credits")!, headers: headers)
            else { return nil }
            // 403: no billing access in this one; another may grant it.
            guard response.status == 200 else { if response.status == 403 { continue } else { return nil } }
            guard let grants = grants(response.data, now: now) else { return nil }
            return Reading(organization: organization.name, grants: grants)
        }
        return nil
    }
}
