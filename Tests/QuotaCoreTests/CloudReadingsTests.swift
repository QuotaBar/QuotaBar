import XCTest
@testable import QuotaModel

final class CloudReadingsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(_ title: String, used: Double?, resetIn: TimeInterval? = 3600, seconds: Int? = 18_000) -> UsageWindow {
        UsageWindow(
            title: title, usedPercent: used, resetsAt: resetIn.map { t0.addingTimeInterval($0) }, windowSeconds: seconds)
    }

    private func readings(
        device: String = "mac-a",
        at: Date? = nil,
        _ entries: [CloudReadings.Entry]) -> CloudReadings
    {
        CloudReadings(
            deviceID: device, deviceName: device, appVersion: "0.6.0", language: "zh",
            updatedAt: at ?? t0, providers: entries)
    }

    private func entry(_ id: ProviderID, used: Double?, fetchedAt: Date? = nil, error: String? = nil) -> CloudReadings.Entry {
        CloudReadings.Entry(
            id: id.rawValue,
            snapshot: UsageSnapshot(planName: "Pro", windows: [window("5h", used: used)], fetchedAt: fetchedAt ?? t0),
            error: error)
    }

    // MARK: Coding

    func testRoundTripsThroughJSON() throws {
        let original = readings([entry(.codex, used: 42.4), entry(.claude, used: nil, error: "expired")])
        let decoded = try CloudReadings.decode(original.encoded())
        XCTAssertEqual(decoded.deviceID, "mac-a")
        XCTAssertEqual(decoded.language, "zh")
        XCTAssertEqual(decoded.updatedAt, t0)
        XCTAssertEqual(decoded.providers.map(\.id), ["codex", "claude"])
        XCTAssertEqual(decoded.providers[0].snapshot?.windows.first?.usedPercent, 42.4)
        XCTAssertEqual(decoded.providers[1].error, "expired")
        XCTAssertEqual(decoded.signature, original.signature)
    }

    /// A newer Mac may send a provider, or a field, this phone does not know.
    /// Neither may cost the rest of the readings.
    func testUnknownProviderAndBrokenEntryAreDroppedAlone() throws {
        let json = """
        {"version": 3, "deviceID": "m", "updatedAt": 1790000000, "futureField": true,
         "providers": [
           {"id": "codex", "snapshot": {"fetchedAt": 1790000000, "windows": []}},
           {"id": "someday-ai", "snapshot": {"fetchedAt": 1790000000, "windows": []}},
           {"snapshot": "not an entry"}
         ]}
        """
        let decoded = try CloudReadings.decode(Data(json.utf8))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.providers.map(\.id), ["codex", "someday-ai"])
        XCTAssertEqual(MergedReadings([decoded]).items.map(\.provider), [.codex])
    }

    /// Past the limit, a balance's charts and per-key usage go; the balance
    /// itself stays.
    func testOversizedReadingsDropBalanceDetailFirst() throws {
        let buckets = (0..<2000).map { i in
            UsageBucket(start: t0.addingTimeInterval(Double(i) * 3600), costs: [Money(currency: "CNY", amount: Double(i))])
        }
        var sheet = BalanceSheet(balances: [AccountBalance(currency: "CNY", total: 107.39)])
        sheet.chart = [.last30: buckets]
        let snapshot = UsageSnapshot(windows: [], fetchedAt: t0, balance: sheet)
        let big = readings([CloudReadings.Entry(id: ProviderID.deepseek.rawValue, snapshot: snapshot)])

        let full = try big.encoded(limit: .max)
        let trimmed = try big.encoded(limit: 4096)
        XCTAssertGreaterThan(full.count, 4096)
        XCTAssertLessThan(trimmed.count, 4096)
        let balance = try CloudReadings.decode(trimmed).providers.first?.snapshot?.balance
        XCTAssertEqual(balance?.balances.first?.total, 107.39)
        XCTAssertEqual(balance?.chart.isEmpty, true)
    }

    // MARK: When to write

    func testFirstWriteGoesAtOnce() {
        let sig = readings([entry(.codex, used: 10)]).signature
        XCTAssertTrue(CloudSyncPolicy.shouldWrite(current: sig, last: nil, now: t0))
    }

    func testNothingMovedWaitsForTheHeartbeat() {
        let sig = readings([entry(.codex, used: 10)]).signature
        let last = (signature: sig, at: t0)
        XCTAssertFalse(CloudSyncPolicy.shouldWrite(current: sig, last: last, now: t0.addingTimeInterval(19 * 60)))
        XCTAssertTrue(CloudSyncPolicy.shouldWrite(current: sig, last: last, now: t0.addingTimeInterval(20 * 60)))
    }

    func testChangeWaitsForTheMinimumInterval() {
        let before = readings([entry(.codex, used: 10)]).signature
        let after = readings([entry(.codex, used: 12)]).signature
        let last = (signature: before, at: t0)
        XCTAssertFalse(CloudSyncPolicy.shouldWrite(current: after, last: last, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(CloudSyncPolicy.shouldWrite(current: after, last: last, now: t0.addingTimeInterval(120)))
    }

    /// The refresh itself moves `fetchedAt` every minute; that alone is not
    /// something the phone would draw differently.
    func testSignatureIgnoresWhenTheReadingWasTakenAndSubPointNoise() {
        let a = readings([entry(.codex, used: 10.2, fetchedAt: t0)]).signature
        let b = readings(at: t0.addingTimeInterval(60), [entry(.codex, used: 10.4, fetchedAt: t0.addingTimeInterval(60))]).signature
        XCTAssertEqual(a, b)
    }

    func testSignatureNoticesFailureAndOrder() {
        let ok = readings([entry(.codex, used: 10), entry(.claude, used: 5)]).signature
        let failing = readings([entry(.codex, used: 10, error: "x"), entry(.claude, used: 5)]).signature
        let reordered = readings([entry(.claude, used: 5), entry(.codex, used: 10)]).signature
        XCTAssertNotEqual(ok, failing)
        XCTAssertNotEqual(ok, reordered)
    }

    func testClockGoingBackwardsWrites() {
        let sig = readings([entry(.codex, used: 10)]).signature
        XCTAssertTrue(CloudSyncPolicy.shouldWrite(current: sig, last: (sig, t0), now: t0.addingTimeInterval(-600)))
    }

    // MARK: Merging Macs

    func testNewestReadingWinsPerProviderInTheNewestMacsOrder() {
        let older = readings(device: "a", at: t0, [
            entry(.claude, used: 30, fetchedAt: t0),
            entry(.cursor, used: 7, fetchedAt: t0),
        ])
        let newer = readings(device: "b", at: t0.addingTimeInterval(300), [
            entry(.codex, used: 50, fetchedAt: t0.addingTimeInterval(300)),
            entry(.claude, used: 20, fetchedAt: t0.addingTimeInterval(-600)),
        ])
        let merged = MergedReadings([older, newer])
        XCTAssertEqual(merged.items.map(\.provider), [.codex, .claude, .cursor])
        // Mac a looked at Claude more recently than Mac b did.
        XCTAssertEqual(merged.items[1].snapshot?.windows.first?.usedPercent, 30)
        XCTAssertEqual(merged.items[1].deviceName, "a")
        XCTAssertEqual(merged.updatedAt, t0.addingTimeInterval(300))
    }

    func testAReadingBeatsNone() {
        let empty = readings(device: "a", at: t0.addingTimeInterval(60), [
            CloudReadings.Entry(id: "codex", snapshot: nil, error: "not signed in"),
        ])
        let full = readings(device: "b", at: t0, [entry(.codex, used: 40)])
        XCTAssertEqual(MergedReadings([empty, full]).items.first?.snapshot?.windows.first?.usedPercent, 40)
    }

    // MARK: Freshness

    func testFreshness() {
        XCTAssertEqual(CloudFreshness(updatedAt: nil, now: t0), .nothing)
        XCTAssertEqual(CloudFreshness(updatedAt: t0, now: t0.addingTimeInterval(25 * 60)), .current)
        XCTAssertEqual(CloudFreshness(updatedAt: t0, now: t0.addingTimeInterval(31 * 60)), .macQuiet(since: t0))
    }

    func testWindowPastItsResetSaysSo() {
        let w = window("5h", used: 96, resetIn: 60)
        XCTAssertFalse(w.hasReset(now: t0))
        XCTAssertTrue(w.hasReset(now: t0.addingTimeInterval(60)))
        XCTAssertFalse(window("month", used: 10, resetIn: nil).hasReset(now: t0))
    }

    // MARK: Detail page

    private func spend() -> CloudSpend {
        CloudSpend(
            periods: [
                .init(id: "today", usd: 3.2, tokens: 120_000, models: [.init(name: "claude-opus-5-5", usd: 3.2, tokens: 120_000)]),
                .init(id: "yesterday", usd: 0, tokens: 0),
                .init(id: "window", usd: 88, tokens: 4_000_000),
            ],
            windowDays: 30,
            trend: (0..<30).map { .init(day: t0.addingTimeInterval(Double($0) * 86_400), usd: 1, tokens: 1000) },
            estimated: true)
    }

    func testSpendLinksAndMoneySurviveTheTrip() throws {
        var entry = entry(.claude, used: 40)
        entry.spend = spend()
        entry.links = CloudLinks(console: URL(string: "https://claude.ai/settings/usage"))
        var original = readings([entry])
        original.money = CloudMoney(currency: "CNY", usdRate: 7.1)
        let back = try CloudReadings.decode(original.encoded())
        XCTAssertEqual(back.providers.first?.spend, spend())
        XCTAssertEqual(back.providers.first?.links?.console?.host, "claude.ai")
        XCTAssertEqual(back.money, CloudMoney(currency: "CNY", usdRate: 7.1))
        let merged = MergedReadings([back])
        XCTAssertEqual(merged.items.first?.spend?.period("today")?.usd, 3.2)
        XCTAssertEqual(merged.money.format(10), "¥71.00")
    }

    /// A payload from before spend existed reads as dollars and no spend.
    func testOlderPayloadHasNoSpendAndDollars() throws {
        let json = #"{"deviceID":"m","updatedAt":1790000000,"providers":[{"id":"codex"}]}"#
        let back = try CloudReadings.decode(Data(json.utf8))
        XCTAssertNil(back.providers.first?.spend)
        XCTAssertEqual(back.money.format(12.5), "$12.50")
    }

    func testOversizedReadingsDropSpendDetailButKeepTotals() throws {
        var entry = entry(.claude, used: 40)
        entry.spend = spend()
        let trimmed = try CloudReadings.decode(readings([entry]).encoded(limit: 10))
        let kept = try XCTUnwrap(trimmed.providers.first?.spend)
        XCTAssertTrue(kept.trend.isEmpty)
        XCTAssertTrue(kept.period("today")?.models.isEmpty ?? false)
        XCTAssertEqual(kept.period("window")?.usd, 88)
    }

    // MARK: The phone's own order

    func testSavedOrderComesFirstAndNewProvidersGoLast() {
        let merged = MergedReadings([readings([
            entry(.codex, used: 1), entry(.claude, used: 1), entry(.cursor, used: 1), entry(.gemini, used: 1),
        ])])
        let ordered = merged.ordered(by: ["cursor", "codex", "retired-provider"])
        XCTAssertEqual(ordered.items.map(\.provider), [.cursor, .codex, .claude, .gemini])
        XCTAssertEqual(merged.ordered(by: []).items.map(\.provider), [.codex, .claude, .cursor, .gemini])
    }

    // MARK: Which Mac

    func testMacKindFromModelIdentifierOrName() {
        XCTAssertEqual(MacKind(model: "MacBook Pro (16-inch, M5 Max)"), .laptop)
        XCTAssertEqual(MacKind(model: "Mac mini (2024)"), .mini)
        XCTAssertEqual(MacKind(model: "Mac Studio (2025)"), .studio)
        XCTAssertEqual(MacKind(model: "Mac Pro (2023)"), .pro)
        XCTAssertEqual(MacKind(model: "iMac (24-inch, 2024)"), .imac)
        // No model: the owner's own name usually carries it.
        XCTAssertEqual(MacKind(model: nil, name: "Peter's MacBook Air"), .laptop)
        XCTAssertEqual(MacKind(model: nil, name: "Studio"), .unknown)
        XCTAssertEqual(MacKind.displayName(forIdentifier: "Macmini8,1"), "Mac mini")
        XCTAssertEqual(MacKind.displayName(forIdentifier: "MacBookPro16,1"), "MacBook Pro")
        XCTAssertEqual(MacKind.displayName(forIdentifier: "iMacPro1,1"), "iMac Pro")
        XCTAssertNil(MacKind.displayName(forIdentifier: "Mac17,6"))
    }

    func testDevicesAreListedNewestFirstWithTheirModels() throws {
        var a = readings(device: "a", at: t0, [entry(.codex, used: 1)])
        a.deviceModel = "Mac mini (2024)"
        var b = readings(device: "b", at: t0.addingTimeInterval(60), [entry(.claude, used: 1)])
        b.deviceModel = "MacBook Pro (16-inch, M5 Max)"
        let merged = MergedReadings([try CloudReadings.decode(a.encoded()), b])
        XCTAssertEqual(merged.devices.map(\.name), ["b", "a"])
        XCTAssertEqual(merged.devices.map(\.kind), [.laptop, .mini])
        XCTAssertEqual(merged.items.first { $0.provider == .codex }?.deviceModel, "Mac mini (2024)")
    }

    // MARK: Refresh requests

    func testRefreshRequestIsHonouredOnceWhileFresh() {
        let request = CloudRefreshRequest(requestedAt: t0, from: "iPhone")
        XCTAssertTrue(RefreshRequestPolicy.shouldHonor(request, lastHandled: nil, lastRequestedRefresh: nil, now: t0.addingTimeInterval(20)))
        // The same request, seen again on the next look.
        XCTAssertFalse(RefreshRequestPolicy.shouldHonor(request, lastHandled: t0, lastRequestedRefresh: nil, now: t0.addingTimeInterval(50)))
    }

    func testStaleRequestIsIgnored() {
        let request = CloudRefreshRequest(requestedAt: t0, from: "iPhone")
        XCTAssertFalse(RefreshRequestPolicy.shouldHonor(request, lastHandled: nil, lastRequestedRefresh: nil, now: t0.addingTimeInterval(11 * 60)))
    }

    func testRequestsAreSpacedAMinuteApart() {
        let request = CloudRefreshRequest(requestedAt: t0.addingTimeInterval(30), from: "iPhone")
        XCTAssertFalse(RefreshRequestPolicy.shouldHonor(request, lastHandled: t0, lastRequestedRefresh: t0, now: t0.addingTimeInterval(40)))
        XCTAssertTrue(RefreshRequestPolicy.shouldHonor(request, lastHandled: t0, lastRequestedRefresh: t0, now: t0.addingTimeInterval(61)))
    }
}

