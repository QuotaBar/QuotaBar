import QuotaModel
import SwiftUI
import WidgetKit

struct BalanceWidgetView: View {
    let entry: ReadingsEntry
    var family: WidgetFamily

    private var item: MergedReadings.Item? {
        if let provider = entry.provider { return entry.readings.items.first { $0.provider == provider } }
        return entry.readings.items.first { $0.snapshot?.balance?.balances.isEmpty == false }
    }
    private var sheet: BalanceSheet? { item?.snapshot?.balance }
    private var compact: Bool { family == .accessoryRectangular }
    private var capacity: Int { family == .systemMedium ? 3 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            WidgetHeader(item: item, badge: compact ? nil : L10n.t("Balance", "余额"))
            if let sheet, !sheet.balances.isEmpty {
                if !compact { Spacer(minLength: 0) }
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(sheet.balances.prefix(capacity)), id: \.currency) { balance in
                            amount(balance).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if let balance = sheet.balances.first {
                    amount(balance)
                }
                if !compact { Spacer(minLength: 0) }
                if !compact, sheet.canCallAPI == false {
                    Label(L10n.t("API unavailable", "余额不可调用"), systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
                if !compact, sheet.balances.count > capacity {
                    Text(L10n.t("+\(sheet.balances.count - capacity) currencies in app", "另有 \(sheet.balances.count - capacity) 种币种，见 App"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                if !compact { Spacer(minLength: 0) }
                Text(L10n.t("No balance synced yet", "暂无同步的余额"))
                    .font(.caption).foregroundStyle(.secondary)
                if !compact {
                    Text(L10n.t("Choose a service with an account balance after your Mac syncs.", "Mac 同步后，请选择提供账户余额的服务。"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            freshness
        }
    }

    private func amount(_ balance: AccountBalance) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 4) {
            Text(QuotaFormat.amount(balance.total, code: balance.currency))
                .font(.system(size: compact ? 18 : 30, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
                .widgetAccentable()
            if !compact {
                if let paid = balance.paid { detail(L10n.t("Paid", "充值"), value: paid, currency: balance.currency) }
                if let granted = balance.granted { detail(L10n.t("Bonus", "赠送"), value: granted, currency: balance.currency) }
            }
        }
    }

    private func detail(_ label: String, value: Double, currency: String) -> some View {
        Text("\(label) \(QuotaFormat.amount(value, code: currency))")
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    @ViewBuilder private var freshness: some View {
        if compact, sheet?.canCallAPI == false {
            Text(L10n.t("API unavailable", "余额不可调用"))
                .foregroundStyle(.orange).font(.system(size: 10)).lineLimit(1)
        } else if let error = item?.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption2).lineLimit(1)
        } else if let item {
            if item.deviceUpdatedAt.addingTimeInterval(CloudFreshness.quietAfter) < entry.date {
                Text(L10n.t("Mac not syncing", "Mac 未同步"))
                    .foregroundStyle(.orange).font(.caption2).lineLimit(1)
            } else {
                Text(L10n.t("Updated \(QuotaFormat.age(of: item.snapshot?.fetchedAt ?? item.deviceUpdatedAt, now: entry.date))",
                            "\(QuotaFormat.age(of: item.snapshot?.fetchedAt ?? item.deviceUpdatedAt, now: entry.date))更新"))
                    .foregroundStyle(.secondary).font(.caption2).lineLimit(1)
            }
        }
    }
}
