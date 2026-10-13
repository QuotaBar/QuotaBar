import Foundation
import QuotaModel

/// Balance layout samples stay in memory and never replace synced readings.
enum BalanceCardPreviewFixtures {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-QuotaBarBalanceCardPreview")
        #else
        false
        #endif
    }

    static var readings: MergedReadings {
        #if DEBUG
        readings(balances: [AccountBalance(currency: "USD", total: 12.33), AccountBalance(currency: "CNY", total: 19.79)])
        #else
        MergedReadings([])
        #endif
    }

    #if DEBUG
    static func item(balances: [AccountBalance]) -> MergedReadings.Item {
        readings(balances: balances).items[0]
    }

    private static func readings(balances: [AccountBalance]) -> MergedReadings {
        let now = Date()
        let amountWindows = balances.map {
            UsageWindow(title: "Balance · \($0.currency)", detail: QuotaFormat.amount($0.total, code: $0.currency))
        }
        let snapshot = UsageSnapshot(planName: L10n.t("Pay as you go", "按量付费"), windows: amountWindows,
            fetchedAt: now, balance: BalanceSheet(balances: balances, representedWindowIDs: amountWindows.map(\.id)))
        return MergedReadings([CloudReadings(deviceID: "qa-balance-mac", deviceName: "QA sample Mac",
            appVersion: "QA", language: L10n.isChinese ? "zh" : "en", updatedAt: now,
            providers: [CloudReadings.Entry(id: ProviderID.deepseek.rawValue, snapshot: snapshot)])])
    }
    #endif
}

enum IsolatedReadingsPreview {
    static var isOn: Bool { XSubscriptionDemo.isOn || BalanceCardPreviewFixtures.isOn }
}
