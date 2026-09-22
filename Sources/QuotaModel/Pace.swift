import Foundation

// MARK: - Pace verdict

/// openusage's reading of a window's pace: where the current burn rate lands
/// at reset, and what that means for the bar.
public enum PaceVerdict: String, Sendable, Equatable {
    /// On course to finish with at least 10% to spare.
    case ahead
    /// Projected to land inside the last 10%, with at least 1% to spare.
    case close
    /// Projected to run out before the reset, or to finish with nothing left.
    case over
    /// Nothing left now, whatever the rate.
    case spent
}

extension WindowPace {
    /// Where usage lands at reset if it keeps going at the current rate.
    public var projectedPercent: Double {
        guard expectedPercent > 0 else { return actualPercent }
        return actualPercent / (expectedPercent / 100)
    }

    /// How long the window has run, from how far through it is and how long
    /// is left.
    public var elapsedSeconds: Double {
        let fraction = expectedPercent / 100
        guard fraction < 1 else { return .infinity }
        return secondsToReset * fraction / (1 - fraction)
    }

    /// Enough of the window has passed for its average rate to mean
    /// something: at least 5% of it and at least a quarter of an hour. Three
    /// minutes into a 5-hour window, 3% used projects to 300% — true of the
    /// arithmetic, useless as a forecast.
    public var isSettled: Bool {
        expectedPercent >= 5 && elapsedSeconds >= 900
    }

    /// The pace verdict. Nothing used yet has no rate to project, and a
    /// window too young to have a rate is left alone.
    public var verdict: PaceVerdict? {
        if actualPercent >= 99.5 { return .spent }
        guard actualPercent > 0, isSettled else { return nil }
        let projected = projectedPercent
        if projected <= 90 { return .ahead }
        // "~0% spare" is not a cushion: a projection that lands on the limit
        // is over, so an amber bar always has at least 1% to offer.
        if projected <= 99 { return .close }
        return .over
    }

    /// The even-pace position as a fraction of the bar, for the tick.
    public var tickFraction: Double { min(max(expectedPercent / 100, 0), 1) }

    /// Seconds until the window runs out, only when that lands before reset.
    public var runOutSeconds: Double? {
        guard isSettled, let secondsToExhaustion, secondsToExhaustion < secondsToReset else { return nil }
        return secondsToExhaustion
    }
}
