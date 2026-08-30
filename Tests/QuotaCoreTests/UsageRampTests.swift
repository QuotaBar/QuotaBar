import XCTest
@testable import QuotaCore

/// The ramp replaced a three-step mapping that had been copied into six views
/// plus a divergent seventh. These pin the properties that make it readable —
/// each one is something a plausible "tidy-up" would break.
final class UsageRampTests: XCTestCase {
    private func sweep(step: Double = 0.05) -> [Double] {
        stride(from: 0.0, through: 100.0, by: step).map { $0 }
    }

    /// The ends are the palette's existing green and red. Changing either is a
    /// brand decision, not a refactor.
    func testEndsAreTheExistingBrandColours() {
        XCTAssertEqual(UsageRamp.hex(used: 50), "34C759")
        XCTAssertEqual(UsageRamp.hex(used: 90), "DC2626")
    }

    /// Flat below 50 and above 90 — there is nothing new to say at either end,
    /// and this doubles as the clamp for out-of-range input.
    func testPlateausAtBothEnds() {
        for used in [-50.0, 0, 12.5, 33, 49.9, 50] {
            XCTAssertEqual(UsageRamp.hex(used: used), "34C759", "\(used)%")
        }
        for used in [90.0, 95, 99.9, 100, 200] {
            XCTAssertEqual(UsageRamp.hex(used: used), "DC2626", "\(used)%")
        }
    }

    func testInterpolatesBetweenStops() {
        // Exactly halfway between the 50 and 55 stops.
        XCTAssertEqual(UsageRamp.hex(used: 52.5), "42C650")
        // On a stop, not between two.
        XCTAssertEqual(UsageRamp.hex(used: 65), "A8A81E")
    }

    /// The user asked for it to get *deeper*, and for a red-green colourblind
    /// viewer falling luminance is the only channel that survives the hue
    /// sweep. Checked on the stops, where it is strict.
    func testLuminanceFallsAcrossEveryStop() {
        let ys = UsageRamp.stops.map { QuotaTheme.luminance(hex: $0) }
        for i in 0..<(ys.count - 1) {
            XCTAssertGreaterThan(
                ys[i], ys[i + 1],
                "stop \(i) (\(UsageRamp.stops[i])) is not brighter than stop \(i + 1)")
        }
        XCTAssertEqual(ys.first ?? 0, 0.423, accuracy: 0.002)
        XCTAssertEqual(ys.last ?? 0, 0.167, accuracy: 0.002)
    }

    /// Between stops the fall is not quite strict. The cause is rounding to
    /// 8 bits per channel and nothing subtler: one least-significant step in
    /// green is worth about 4.2e-3 of relative luminance, so ±0.5 LSB puts the
    /// ceiling on a reversal near there. A strict assertion here goes red.
    func testLuminanceDoesNotRiseMeasurablyBetweenStops() {
        var previous = QuotaTheme.luminance(hex: UsageRamp.hex(used: 0))
        for used in sweep(step: 0.1).dropFirst() {
            let y = QuotaTheme.luminance(hex: UsageRamp.hex(used: used))
            XCTAssertLessThanOrEqual(
                y, previous + 0.005,
                "luminance climbed at \(used)% by more than 8-bit rounding explains")
            previous = y
        }
    }

    /// Every colour has to be legible on the surfaces that use it — the dock,
    /// the widget and the notch strip all draw on black, and the island's
    /// callout on the panel's own near-black.
    func testLegibleOnTheDarkSurfaces() {
        for used in sweep() {
            let hex = UsageRamp.hex(used: used)
            XCTAssertGreaterThanOrEqual(
                QuotaTheme.contrast(hex, against: "000000"), 4.3,
                "\(used)% -> \(hex) on black")
            XCTAssertGreaterThanOrEqual(
                QuotaTheme.contrast(hex, against: "1E1E1E"), 3.4,
                "\(used)% -> \(hex) on the panel")
        }
    }

    /// Neighbouring stops must be close enough that straight sRGB mixing
    /// between them cannot band, and far enough apart that the ramp reads as
    /// changing. Both ends of that are properties of the stop spacing.
    func testStopsAreEvenlySpacedEnoughNotToBand() {
        let steps = (0..<(UsageRamp.stops.count - 1)).map { i -> Double in
            let a = QuotaTheme.luminance(hex: UsageRamp.stops[i])
            let b = QuotaTheme.luminance(hex: UsageRamp.stops[i + 1])
            return a - b
        }
        XCTAssertGreaterThan(steps.min() ?? 0, 0.005, "a step this small looks static")
        XCTAssertLessThan(steps.max() ?? 1, 0.05, "a step this large looks like a jump")
    }

    /// The colour keys off usage, never the displayed figure. In remaining mode
    /// 95% used is shown as 5%; if the ramp ever saw that number a nearly-empty
    /// quota would draw in the calmest green on the scale.
    func testColourFollowsUsageNotTheDisplayedFigure() {
        XCTAssertEqual(MeterMode.remaining.shownPercent(fromUsed: 95), 5)
        XCTAssertEqual(UsageRamp.hex(used: 95), "DC2626")
        XCTAssertEqual(UsageRamp.hex(used: 5), "34C759")
    }

    /// The ramp is deliberately independent of AlertSettings: colour answers
    /// "how hot am I" and has to mean the same thing on two machines, while the
    /// thresholds answer "interrupt me". Two users at 72% see one colour.
    func testIndependentOfAlertThresholds() {
        let strict = AlertSettings(enabled: true, warning: 60, critical: 80)
        let loose = AlertSettings(enabled: true, warning: 90, critical: 99)
        XCTAssertEqual(strict.level(for: 72), .warning)
        XCTAssertEqual(loose.level(for: 72), AlertLevel.none)
        XCTAssertEqual(UsageRamp.hex(used: 72), UsageRamp.hex(used: 72))
    }
}
