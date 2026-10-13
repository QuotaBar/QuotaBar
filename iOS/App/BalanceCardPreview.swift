#if DEBUG
import QuotaModel
import SwiftUI

/// The production card rendered with public, independent balance fixtures.
struct BalanceCardPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.t("Independent balance layout samples", "独立余额布局验证样本"))
                    .font(.headline)
                sample(L10n.t("One currency", "单币种"), balances: [AccountBalance(currency: "USD", total: 12.33)])
                sample(L10n.t("USD and CNY", "USD 与 CNY"), balances: [
                    AccountBalance(currency: "USD", total: 12.33), AccountBalance(currency: "CNY", total: 19.79),
                ])
                sample(L10n.t("Unknown balance", "未知余额"), balances: [])
            }
            .padding(16)
        }
        .background(Color.black)
    }

    private func sample(_ title: String, balances: [AccountBalance]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ProviderCard(item: BalanceCardPreviewFixtures.item(balances: balances), money: CloudMoney(), still: .now)
        }
    }
}
#endif
