import Foundation
import QuotaModel

/// Private, in-memory QA fixtures. These never replace synced cache files or
/// preferences, and are unavailable to a release build.
enum XSubscriptionDemo {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-QuotaBarXSubscriptionDemo")
        #else
        false
        #endif
    }

    static var readings: MergedReadings {
        #if DEBUG
        let now = Date()
        let info = XSubscriptionInfo(tier: "premium", workspaceID: "qa-workspace", seatID: "qa-seat")
        let weekEnd = now.addingTimeInterval(3 * 86_400)
        func migrated(_ used: Double, balance: Double, at: Date) -> UsageSnapshot {
            UsageSnapshot(planName: "Premium", account: "qa@example.test", windows: [
                UsageWindow(title: L10n.t("Shared weekly allowance", "共享周额度"), usedPercent: used,
                            resetsAt: weekEnd, windowSeconds: 604_800),
            ], fetchedAt: at, balance: BalanceSheet(balances: [AccountBalance(currency: "USD", total: balance)]),
               xSubscription: info)
        }
        let legacy = ProcessInfo.processInfo.arguments.contains("-QuotaBarXSubscriptionLegacyDemo")
        let cursor = legacy
            ? UsageSnapshot(planName: "Pro Plus", account: "qa@example.test", windows: [
                UsageWindow(title: L10n.t("Monthly plan", "月度套餐"), usedPercent: 63,
                            resetsAt: now.addingTimeInterval(8 * 86_400), windowSeconds: 30 * 86_400),
            ], fetchedAt: now)
            : migrated(18, balance: 20, at: now.addingTimeInterval(-300))
        let grok = legacy
            ? UsageSnapshot(planName: "SuperGrok", account: "qa@example.test", windows: [
                UsageWindow(title: L10n.t("Weekly allowance", "每周额度"), usedPercent: 31,
                            resetsAt: weekEnd, windowSeconds: 604_800),
            ], fetchedAt: now)
            : migrated(42.5, balance: 12.34, at: now)
        let counterSamples = UsageSnapshot(planName: L10n.t("Counter samples", "读数验证样本"), windows: [
            UsageWindow(title: L10n.t("Unknown usage", "未提供的用量"), usedPercent: nil),
            UsageWindow(title: L10n.t("Confirmed zero", "明确返回的零用量"), usedPercent: 0),
        ], fetchedAt: now)
        return MergedReadings([CloudReadings(
            deviceID: "qa-mac", deviceName: L10n.t("QA sample Mac", "独立验证样本 Mac"),
            appVersion: "QA", language: L10n.isChinese ? "zh" : "en", updatedAt: now,
            providers: [
                CloudReadings.Entry(id: ProviderID.cursor.rawValue, snapshot: cursor),
                CloudReadings.Entry(id: ProviderID.grok.rawValue, snapshot: grok),
                CloudReadings.Entry(id: ProviderID.claude.rawValue, snapshot: counterSamples),
            ])])
        #else
        return MergedReadings([])
        #endif
    }
}
