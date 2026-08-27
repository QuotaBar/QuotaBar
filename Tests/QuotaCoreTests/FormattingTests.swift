import XCTest
@testable import QuotaCore

final class WindowTitleTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testNamedWindows() {
        XCTAssertEqual(WindowTitle.forSeconds(604_800), "Weekly window")
        XCTAssertEqual(WindowTitle.forSeconds(86_400), "Daily window")
        XCTAssertEqual(WindowTitle.forSeconds(2_592_000), "Monthly window")
    }

    func testDerivedWindows() {
        XCTAssertEqual(WindowTitle.forSeconds(18_000), "5-hour window")
        XCTAssertEqual(WindowTitle.forSeconds(3_600), "1-hour window")
        XCTAssertEqual(WindowTitle.forSeconds(1_800), "30-minute window")
        XCTAssertEqual(WindowTitle.forSeconds(432_000), "5-day window")
    }

    func testMinutesMatchSeconds() {
        XCTAssertEqual(WindowTitle.forMinutes(300), WindowTitle.forSeconds(18_000))
        XCTAssertEqual(WindowTitle.forMinutes(10_080), WindowTitle.forSeconds(604_800))
        XCTAssertEqual(WindowTitle.forMinutes(43_200), WindowTitle.forSeconds(2_592_000))
    }

    func testNonPositiveLengthFallsBack() {
        XCTAssertEqual(WindowTitle.forSeconds(0), "Quota")
        XCTAssertEqual(WindowTitle.forSeconds(-1), "Quota")
    }
}

final class QuotaFormatTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCountdown() {
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(45), from: now), "45s")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(600), from: now), "10m")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(8_100), from: now), "2h 15m")
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(180_000), from: now), "2d 2h")
    }

    func testResetLabelReadsAsOnePhrase() {
        // Regression: composing "resets in" + countdown produced
        // "resets in now" / "已重置后重置" once the moment had passed.
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(600), from: now),
                       "resets in 10m")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(-60), from: now),
                       "reset due")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now, from: now), "reset due")

        L10n.override = .zhHans
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(600), from: now),
                       "10 分钟后重置")
        XCTAssertEqual(QuotaFormat.resetLabel(to: now.addingTimeInterval(-60), from: now),
                       "已到重置时间")
        L10n.override = .en
    }

    func testCountdownInThePast() {
        XCTAssertEqual(QuotaFormat.countdown(to: now.addingTimeInterval(-10), from: now), "now")
        XCTAssertEqual(QuotaFormat.countdown(to: now, from: now), "now")
    }

    func testAge() {
        XCTAssertEqual(QuotaFormat.age(of: now, now: now), "just now")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(-172_800), now: now), "2d ago")
    }

    func testAgeNeverGoesNegative() {
        // Clock skew between the provider and the Mac must not read "-1m ago".
        XCTAssertEqual(QuotaFormat.age(of: now.addingTimeInterval(60), now: now), "just now")
    }

    func testPercentDropsTrailingZero() {
        XCTAssertEqual(QuotaFormat.percent(35), "35%")
        XCTAssertEqual(QuotaFormat.percent(35.04), "35%")
        XCTAssertEqual(QuotaFormat.percent(35.25), "35.3%")
    }

    func testMoneyAndCompactCounts() {
        XCTAssertEqual(QuotaFormat.dollars(cents: 1_234), "$12.34")
        XCTAssertEqual(QuotaFormat.usd(8.4), "$8.40")
        XCTAssertEqual(QuotaFormat.usd(4557.331), "$4,557.33", "four figures need grouping")
        XCTAssertEqual(QuotaFormat.usd(0), "$0.00")
        XCTAssertEqual(QuotaFormat.usd(1_234_567.89), "$1,234,567.89")
        XCTAssertEqual(QuotaFormat.compact(999), "999")
        XCTAssertEqual(QuotaFormat.compact(12_400), "12k")
        XCTAssertEqual(QuotaFormat.compact(3_400_000), "3.4M")
        // A month of token usage reaches the billions; stopping at M printed
        // things like "51578.9M".
        XCTAssertEqual(QuotaFormat.compact(51_578_900_000), "51.6B")
        XCTAssertEqual(QuotaFormat.compact(1_000_000_000), "1.0B")
        XCTAssertEqual(QuotaFormat.compact(2_500_000_000_000), "2.5T")
    }
}

final class UsageSnapshotTests: XCTestCase {
    func testHeadlineIsTheMaximumPercent() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "a", usedPercent: 10),
            UsageWindow(title: "b", usedPercent: 72),
            UsageWindow(title: "c", detail: "no percent"),
        ])
        XCTAssertEqual(snapshot.headlinePercent, 72)
    }

    func testHeadlineIsNilWithoutAnyPercent() {
        let snapshot = UsageSnapshot(windows: [UsageWindow(title: "balance", detail: "$3.00")])
        XCTAssertNil(snapshot.headlinePercent)
    }

    func testPercentsAreClamped() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "over", usedPercent: 140),
            UsageWindow(title: "under", usedPercent: -20),
        ])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 100)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 0)
    }

    func testRepeatedTitlesGetUniqueIDs() {
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(title: "Weekly window", usedPercent: 1),
            UsageWindow(title: "Weekly window", usedPercent: 2),
            UsageWindow(title: "Weekly window", usedPercent: 3),
        ])
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.windows.map(\.title), Array(repeating: "Weekly window", count: 3))
    }
}

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.override = .system }

    func testExplicitOverrideWins() {
        L10n.override = .zhHans
        XCTAssertEqual(L10n.t("Weekly", "每周"), "每周")
        L10n.override = .en
        XCTAssertEqual(L10n.t("Weekly", "每周"), "Weekly")
    }

    func testLanguageIsCodable() throws {
        let encoded = try JSONEncoder().encode(L10n.Language.zhHans)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"zh-Hans\"")
        XCTAssertEqual(try JSONDecoder().decode(L10n.Language.self, from: encoded), .zhHans)
    }

    func testEveryLanguageHasADisplayName() {
        for language in L10n.Language.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
        }
    }
}

final class ProviderRegistryTests: XCTestCase {
    func testEveryProviderIDResolvesToItsOwnProvider() {
        for id in ProviderID.allCases {
            XCTAssertEqual(ProviderRegistry.make(id).id, id)
        }
    }

    func testRegistryCoversEveryID() {
        XCTAssertEqual(ProviderRegistry.all.count, ProviderID.allCases.count)
    }

    func testEveryProviderHasBrandMetadata() {
        for id in ProviderID.allCases {
            XCTAssertFalse(id.displayName.isEmpty)
            XCTAssertEqual(id.accentHex.count, 6, "\(id) accent must be a 6-digit hex")
            XCTAssertNotNil(id.dashboardURL, "\(id) should link to its console")
            XCTAssertFalse(id.setupHint.isEmpty, "\(id) must tell the user how to connect")
        }
    }

    func testAutomaticProvidersHaveNoCredentialField() {
        // These read an existing CLI session; showing a paste box would be wrong.
        for id in [ProviderID.codex, .claude, .gemini] {
            XCTAssertNil(id.credentialHint, "\(id) should not ask for a pasted secret")
        }
    }
}

final class MeterModeTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testRemainingInvertsTheUsedFigure() {
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 0), 100)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 34), 66)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 100), 0)
    }

    func testUsedPassesThrough() {
        XCTAssertEqual(MeterMode.used.shownPercent(fromUsed: 34), 34)
    }

    func testOutOfRangeInputIsClampedBeforeInverting() {
        // A provider reporting 120% must not render as -20% remaining.
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 120), 0)
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: -5), 100)
    }

    func testDefaultsToRemaining() {
        // An almost-empty bar reads as "nothing left"; that should mean the
        // quota is nearly gone, not that it is barely touched.
        XCTAssertEqual(QuotaConfig().meterMode, .remaining)
    }

    func testModeIsPersistedAndBackwardCompatible() throws {
        let encoded = try JSONEncoder().encode(QuotaConfig(meterMode: .used))
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: encoded).meterMode, .used)

        // A config file written before this setting existed.
        let older = Data(#"{"enabled":["codex"],"refreshMinutes":5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: older).meterMode, .remaining)
    }

    func testEveryModeHasADisplayName() {
        for mode in MeterMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }
}

final class MenuBarStyleTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testEveryStyleIsNamedInBothLanguages() {
        for style in MenuBarStyle.allCases {
            L10n.override = .en
            XCTAssertFalse(style.displayName.isEmpty, "\(style) has no English name")
            L10n.override = .zhHans
            XCTAssertFalse(style.displayName.isEmpty, "\(style) has no Chinese name")
        }
        L10n.override = .en
    }

    func testSteppedStylesDeclareTheirResolution() {
        XCTAssertEqual(MenuBarStyle.grid.steps, 9)
        XCTAssertEqual(MenuBarStyle.segments.steps, 5)
        XCTAssertEqual(MenuBarStyle.columns.steps, 4)
    }

    func testContinuousStylesDeclareNoSteps() {
        for style in [MenuBarStyle.bar, .ring, .percent, .battery, .gauge, .ticks] {
            XCTAssertNil(style.steps, "\(style) should be continuous")
        }
    }

    func testDefaultIsTheSteppedGrid() {
        // A countable glyph gives an exact reading; a continuous fill has to
        // be estimated.
        XCTAssertEqual(QuotaConfig().menuBarStyle, .grid)
    }

    func testAllStylesRoundTripThroughConfig() throws {
        for style in MenuBarStyle.allCases {
            let encoded = try JSONEncoder().encode(QuotaConfig(menuBarStyle: style))
            XCTAssertEqual(
                try JSONDecoder().decode(QuotaConfig.self, from: encoded).menuBarStyle,
                style)
        }
    }

    func testAnExistingPreferenceIsNotOverriddenByTheNewDefault() throws {
        // Someone who already picked "bar" keeps it; only fresh installs get
        // the new default.
        let existing = Data(#"{"enabled":["codex"],"menuBarStyle":"bar"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: existing).menuBarStyle, .bar)
    }

    func testUnknownStyleFromAFutureVersionFallsBack() throws {
        let future = Data(#"{"enabled":["codex"],"menuBarStyle":"hologram"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(QuotaConfig.self, from: future).menuBarStyle, .grid)
    }
}

final class WindowBadgeTests: XCTestCase {
    override func setUp() { L10n.override = .en }
    override func tearDown() { L10n.override = .system }

    func testShortLabels() {
        XCTAssertEqual(WindowTitle.short(18_000), "5h")
        XCTAssertEqual(WindowTitle.short(604_800), "7d")
        XCTAssertEqual(WindowTitle.short(2_592_000), "30d")
        XCTAssertEqual(WindowTitle.short(3_600), "1h")
        XCTAssertEqual(WindowTitle.short(1_800), "30m")
    }

    func testShortLabelPrefersTheLargerUnit() {
        // 86400s is a day, not "24h".
        XCTAssertEqual(WindowTitle.short(86_400), "1d")
    }

    func testNoBadgeForAnUnknownLength() {
        XCTAssertNil(WindowTitle.short(0))
        XCTAssertNil(WindowTitle.short(-1))
    }

    func testWindowExposesItsBadge() {
        let window = UsageWindow(title: "x", usedPercent: 10, windowSeconds: 604_800)
        XCTAssertEqual(window.shortLabel, "7d")
    }

    func testWindowWithoutALengthHasNoBadge() {
        // Balance and billing-cycle rows have no fixed window.
        XCTAssertNil(UsageWindow(title: "Balance", detail: "$3.00").shortLabel)
    }
}

final class ResetCreditsTests: XCTestCase {
    func testCarriesBothCounts() {
        let credits = ResetCredits(available: 3, applicable: 1)
        XCTAssertEqual(credits.available, 3)
        XCTAssertEqual(credits.applicable, 1)
    }

    func testApplicableIsOptional() {
        XCTAssertNil(ResetCredits(available: 2).applicable)
    }
}
