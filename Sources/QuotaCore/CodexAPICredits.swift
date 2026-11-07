import Foundation
import QuotaModel

/// The API credit a ChatGPT Pro plan comes with since October 2026 — the
/// plan's price each month, $500 on Pro 500 — once claimed and linked to an
/// API organization. ChatGPT's backend says what the plan gives, to which
/// organization and until when, and answers the same sign-in the usage is
/// read with:
///
/// - `/product-account-links/accounts/{id}/benefits/chatgpt_api_credits_promo?destination_type=api_org`:
///   `{"eligible":false,"ineligibility_reason":"already_linked","offer":null,
///   "benefit":{"currency":"USD","cadence":"monthly","period_credit_amount_usd":"500.00",
///   "expires_at":"2026-11-14T14:30:01Z"}}`, recorded live in November 2026.
/// - `/product-account-links/accounts/{id}?destination_types=api_org`: the
///   organization it is linked to, by name.
///
/// What is left of it is the organization's billing, which only the Platform
/// site's own sign-in reads, so the row gives the allowance and its deadline,
/// not a balance. Beside the plan: a failure costs the row, never the reading.
public enum CodexAPICredits {
    struct Benefit: Equatable, Sendable {
        /// Dollars a period.
        var amount: Double
        /// "monthly".
        var cadence: String?
        /// When this period's credit runs out, unspent; the next one follows.
        var expiresAt: Date?
        /// Already claimed and linked to an organization.
        var linked: Bool
        /// Not claimed yet, and the account may.
        var claimable: Bool
        /// The organization it went to, when the link list names it.
        var organization: String?
    }

    /// `benefits/chatgpt_api_credits_promo`; nil for an account the offer is
    /// not for (Plus, a plan too new) or a reply that is not that.
    static func benefit(_ data: Data) -> Benefit? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let eligible = root["eligible"] as? Bool ?? false
        let reason = root["ineligibility_reason"] as? String
        let block = (root["benefit"] as? [String: Any]) ?? (root["offer"] as? [String: Any])
        guard let block else { return nil }
        if let currency = block["currency"] as? String, currency.uppercased() != "USD" { return nil }
        guard let amount = dollars(block["period_credit_amount_usd"] ?? block["credit_amount_usd"]), amount > 0
        else { return nil }
        let linked = reason == "already_linked"
        guard linked || eligible else { return nil }
        return Benefit(
            amount: amount,
            cadence: block["cadence"] as? String,
            expiresAt: Dates.parseISO(block["expires_at"] as? String),
            linked: linked,
            claimable: eligible && !linked)
    }

    /// The active API organization's name from the link list.
    static func organization(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = root["links"] as? [[String: Any]]
        else { return nil }
        let link = links.first { $0["destination_type"] as? String == "api_org" && $0["state"] as? String == "active" }
        return (link?["destination_display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func dollars(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text).flatMap { $0.isFinite ? $0 : nil } }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number.doubleValue
        }
        return nil
    }

    // MARK: The row

    static func window(_ benefit: Benefit, balance: Balance? = nil, now: Date = .now) -> UsageWindow? {
        if let expires = benefit.expiresAt, expires <= now, !benefit.claimable { return nil }
        if let balance, !benefit.claimable { return window(benefit, balance: balance) }
        let amount = QuotaFormat.usd(benefit.amount)
        let monthly = benefit.cadence == nil || benefit.cadence == "monthly"
        let allowance = monthly ? L10n.t("\(amount) a month", "每月 \(amount)") : amount
        let day = benefit.expiresAt.map(day)
        var parts = [allowance]
        if benefit.claimable {
            parts.append(L10n.t("not claimed", "未领取"))
        } else {
            if let organization = benefit.organization { parts.append(L10n.t("to \(organization)", "绑定 \(organization)")) }
            if let day { parts.append(L10n.t("this period ends \(day)", "本期 \(day)到期")) }
        }
        var window = UsageWindow(
            title: L10n.t("API credit", "API 赠送额度"),
            detail: parts.joined(separator: " · "),
            note: benefit.claimable
                ? L10n.t(
                    "The ChatGPT plan includes \(allowance) of OpenAI API credit. Claim it and link an API organization at platform.openai.com; what is not used by the end of each billing period does not carry over.",
                    "ChatGPT 订阅附送\(allowance)的 OpenAI API 额度。到 platform.openai.com 领取并绑定一个 API 组织后才会发放，每个计费周期没用完的不结转。")
                : L10n.t(
                    "API credit the ChatGPT plan includes, paid into the API organization\(benefit.organization.map { " \($0)" } ?? ""). It pays for API calls (not Codex through API keys) and does not carry over: this period's runs out\(day.map { " \($0)" } ?? " at the end of the billing period"). What is left shows at platform.openai.com › Billing › Credit grants.",
                    "ChatGPT 订阅附送的 API 额度，发到 API 组织\(benefit.organization.map { "「\($0)」" } ?? "")里，用于 API 调用（不能通过 API key 用 Codex），不结转：本期额度\(day.map { "在 \($0)" } ?? "在计费周期结束时")到期。剩余多少见 platform.openai.com › Billing › Credit grants。"))
        window.id = "codex-api-credit"
        window.credit = CreditAmount(
            amount: allowance,
            caption: benefit.claimable
                ? L10n.t("Not claimed yet", "还没领取")
                : benefit.organization.map { L10n.t("Linked to \($0)", "已绑定 \($0)") } ?? L10n.t("Linked", "已绑定"))
        window.extra = true
        return window
    }

    /// With what is left, read with an API key: a bar like the other credits.
    static func window(_ benefit: Benefit, balance: Balance) -> UsageWindow {
        let used = min(balance.used, balance.granted)
        let approx = balance.estimated ? L10n.t("about ", "约 ") : ""
        let day = benefit.expiresAt.map(day)
        var parts = ["\(approx)\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(balance.granted))"]
        if let organization = benefit.organization { parts.append(L10n.t("to \(organization)", "绑定 \(organization)")) }
        if let day { parts.append(L10n.t("expires \(day)", "\(day)到期")) }
        let how = balance.estimated
            ? L10n.t(
                " Estimated from this period's API spend with an Admin key: the first period is paid pro rata, and spending paid from bought credit counts too.",
                "这是用 Admin Key 按本期 API 花费估算的：第一个周期按天折算发放，用购买额度付的花费也会算进去。")
            : ""
        var window = UsageWindow(
            title: L10n.t("API credit", "API 赠送额度"),
            usedPercent: balance.granted > 0 ? used / balance.granted * 100 : nil,
            detail: parts.joined(separator: " · "),
            note: L10n.t(
                "API credit the ChatGPT plan includes (\(QuotaFormat.usd(benefit.amount)) a period), paid into the API organization\(benefit.organization.map { " \($0)" } ?? ""). It pays for API calls, not Codex through API keys, and does not carry over\(day.map { ": what is left runs out \($0)" } ?? "").\(how)",
                "ChatGPT 订阅附送的 API 额度（每期 \(QuotaFormat.usd(benefit.amount))），发到 API 组织\(benefit.organization.map { "「\($0)」" } ?? "")里，用于 API 调用（不能通过 API key 用 Codex），不结转\(day.map { "：没用完的在 \($0)到期" } ?? "")。\(how)"))
        window.id = "codex-api-credit"
        window.credit = CreditAmount(
            amount: approx + QuotaFormat.usd(balance.remaining),
            caption: L10n.t(
                "Used \(approx)\(QuotaFormat.usd(used)) of \(QuotaFormat.usd(balance.granted))",
                "已用 \(approx)\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(balance.granted))"),
            // An exact balance about to be lost is worth the reminder; an
            // estimate is not sure enough to send one.
            expiresAt: balance.estimated ? nil : benefit.expiresAt)
        window.extra = true
        return window
    }

    /// "Nov 14", "11月14日", in local time.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    // MARK: Reading

    private static let memo = Memo()

    /// Per account, read again after an hour or once the period it named
    /// has ended; a failed read keeps the last answer for a day.
    final class Memo: @unchecked Sendable {
        private struct Entry {
            var benefit: Benefit?
            var readAt: Date
            var triedAt: Date
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func fresh(_ account: String, now: Date) -> Benefit?? {
            lock.withLock {
                guard let entry = entries[account], now.timeIntervalSince(entry.triedAt) < 3600,
                      (entry.benefit?.expiresAt ?? .distantFuture) > now
                else { return nil }
                return .some(entry.benefit)
            }
        }

        func store(_ benefit: Benefit?, read: Bool, account: String, now: Date) -> Benefit? {
            lock.withLock {
                var entry = entries[account] ?? Entry(benefit: nil, readAt: .distantPast, triedAt: now)
                entry.triedAt = now
                if read {
                    entry.benefit = benefit
                    entry.readAt = now
                } else if now.timeIntervalSince(entry.readAt) >= 86_400 {
                    entry.benefit = nil
                }
                entries[account] = entry
                return entry.benefit
            }
        }
    }

    /// The row for one account, read with that account's own headers.
    /// `keys`: OpenAI API keys for what is left, tried only for the account
    /// the CLI is signed in as — a kept account's organization is another.
    static func window(account: String, headers: [String: String], keys: [APIKey] = [], now: Date = .now) async -> UsageWindow? {
        let benefit: Benefit?
        if let cached = memo.fresh(account, now: now) {
            benefit = cached
        } else {
            benefit = await read(account: account, headers: headers, now: now)
        }
        guard let benefit else { return nil }
        let balance = benefit.linked ? await balance(keys: keys, benefit: benefit, now: now) : nil
        return window(benefit, balance: balance, now: now)
    }

    private static func read(account: String, headers: [String: String], now: Date) async -> Benefit? {
        let base = "https://chatgpt.com/backend-api/product-account-links/accounts/\(account)"
        guard let url = URL(string: "\(base)/benefits/chatgpt_api_credits_promo?destination_type=api_org"),
              let response = try? await HTTP.get(url, headers: headers)
        else { return memo.store(nil, read: false, account: account, now: now) }
        guard response.status == 200 else {
            // 404: no such offer for this account — a reading, not a failure.
            return memo.store(nil, read: response.status == 404, account: account, now: now)
        }
        guard var benefit = benefit(response.data) else { return memo.store(nil, read: true, account: account, now: now) }
        if benefit.linked,
           let links = URL(string: "\(base)?destination_types=api_org"),
           let response = try? await HTTP.get(links, headers: headers), response.status == 200
        {
            benefit.organization = organization(response.data)
        }
        return memo.store(benefit, read: true, account: account, now: now)
    }
}
