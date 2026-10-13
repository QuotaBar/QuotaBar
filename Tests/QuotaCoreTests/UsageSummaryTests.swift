import XCTest
@testable import QuotaModel

final class UsageSummaryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private func device(_ name: String, at: Date, entries: [CloudReadings.Entry]) -> CloudReadings {
        CloudReadings(deviceID: name, deviceName: name, appVersion: "test", language: "en", updatedAt: at, providers: entries)
    }
    private func entry(_ provider: ProviderID, usd: Double, windowDays: Int = 30,
                       days: [CloudSpend.Day] = []) -> CloudReadings.Entry {
        .init(id: provider.rawValue, snapshot: UsageSnapshot(windows: [], fetchedAt: date), spend: CloudSpend(
            periods: [.init(id: "today", usd: usd, tokens: 100),
                      .init(id: "window", usd: usd * 10, tokens: 1000)],
            windowDays: windowDays, trend: days, estimated: true))
    }

    func testMergedProvidersAreCountedOnceAndBalancesAreNotCosts() {
        let balance = CloudReadings.Entry(id: ProviderID.deepseek.rawValue,
            snapshot: UsageSnapshot(windows: [], balance: BalanceSheet(balances: [.init(currency: "USD", total: 42)])))
        let readings = MergedReadings([
            device("new", at: date, entries: [entry(.codex, usd: 3), entry(.claude, usd: 2), balance]),
            device("old", at: date.addingTimeInterval(-60), entries: [entry(.codex, usd: 20)])])
        let rows = UsageSummary(readings: readings).providers(in: .today)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.usd }, 5)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tokens }, 200)
    }

    func testMissingPeriodsAndDifferentWindowsAreNotReportedAsZeroOrThirtyDays() {
        let summary = UsageSummary(readings: MergedReadings([
            device("mac", at: date, entries: [entry(.codex, usd: 3), entry(.claude, usd: 2, windowDays: 7)])]))
        XCTAssertTrue(summary.providers(in: .yesterday).isEmpty)
        XCTAssertEqual(summary.providers(in: .window).map(\.id), [.codex])
    }

    func testDayTotalsKeepGapsAndDoNotInventModelDetails() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.startOfDay(for: date)
        let third = calendar.date(byAdding: .day, value: 2, to: first)!
        let summary = UsageSummary(readings: MergedReadings([device("mac", at: date, entries: [
            entry(.codex, usd: 3, days: [.init(day: first, usd: 1, tokens: 10), .init(day: third, usd: 2, tokens: 20)]),
            entry(.claude, usd: 2, days: [.init(day: first.addingTimeInterval(3600), usd: 4, tokens: 40)])])]))
        let days = summary.days(calendar: calendar)
        XCTAssertEqual(days.map(\.date), [first, third])
        XCTAssertEqual(days.map(\.usd), [5, 2])
        XCTAssertEqual(days.map(\.tokens), [50, 20])
        XCTAssertTrue(days.flatMap(\.providers).allSatisfy { $0.models.isEmpty })
    }

    func testTrendKeepsThirtyCalendarDaysRatherThanThirtySparseReadings() {
        let older = date.addingTimeInterval(-40 * 86400)
        let summary = UsageSummary(readings: MergedReadings([device("mac", at: date, entries: [
            entry(.codex, usd: 3, days: [.init(day: older, usd: 1, tokens: 10), .init(day: date, usd: 2, tokens: 20)])])]))
        XCTAssertEqual(summary.days().count, 1)
        XCTAssertEqual(summary.days().first?.tokens, 20)
    }
}
