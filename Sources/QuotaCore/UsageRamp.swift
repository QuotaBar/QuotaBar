import Foundation

/// The colour a usage figure is drawn in on the always-dark surfaces — the edge
/// dock's rings and handle, the desktop widget, the notch strip, the hover
/// callout.
///
/// A **continuous** ramp, not the three steps it replaces. Green holds through
/// the comfortable half, then walks green → olive → amber → red, reaching full
/// red at 90% used, i.e. a tenth left. Below 50 and above 90 it is flat: there
/// is nothing new to say at either end.
///
/// ## Why it is anchored to fixed percentages
///
/// Colour answers "how hot am I", which has to mean the same thing on two
/// machines and in two screenshots. The alert thresholds answer a different
/// question — "interrupt me" — and stay where they are, driving notifications
/// and the menu-bar glyph's monochrome/tinted gate. Binding the colour to a
/// user-set threshold would make one number two colours depending on settings.
///
/// ## Why the luminance falls the whole way
///
/// Relative luminance decreases monotonically across every stop, 0.423 → 0.167.
/// That is the "deeper" the ramp was asked for, and it is also the only channel
/// a red-green colourblind viewer keeps: a green→red hue sweep alone is the
/// classic failure case for deuteranopia and protanopia. Arc length, bar fill
/// and the printed percentage all encode the same reading independently, so
/// colour is a redundant channel here rather than the only one.
///
/// ## Why the middle looks olive
///
/// `#A8A81E` at 65% is dark gold, and any ramp whose luminance falls the whole
/// way has to pass through it: sRGB's chroma ceiling in the yellow band
/// (h≈87°, L≈0.69) is only 0.135, well under the 0.194 the endpoints carry.
/// Avoiding it would need a luminance bump at yellow, which is the opposite of
/// what "deeper" means. Do not "fix" the dip.
public enum UsageRamp {
    /// Nine stops, 5% apart, spanning 50→90.
    ///
    /// The ends are the app's existing green and red, unchanged: the ramp grows
    /// out of the palette rather than replacing it. Generated offline from an
    /// OKLCH path — smoothstep on hue and chroma, `u²` on lightness, so the
    /// seam at 50% has a zero derivative and the green plateau does not kink
    /// into the slope.
    static let stops = [
        "34C759", "4FC447", "82B91F", "A8A81E", "BF961C",
        "D0801B", "DE6418", "E83A1A", "DC2626",
    ]
    //   50        55        60        65        70        75        80        85        90

    /// The colour for a **used** percentage.
    ///
    /// Named `used` and offered no other spelling on purpose. The dock handle
    /// fills by `MeterMode`, so in remaining mode a long bar means plenty left;
    /// hand this the displayed figure instead of the usage and a nearly-empty
    /// quota draws full and green.
    ///
    /// There is no `Optional` overload either. "No reading yet" is not 0% used
    /// — it is unknown — and 0 here is the brightest green in the ramp. Call
    /// sites guard first and keep their own neutral.
    public static func hex(used: Double) -> String {
        let p = min(max(used, 0), 100)
        if p <= 50 { return stops[0] }
        if p >= 90 { return stops[8] }
        let x = (p - 50) / 5
        let i = Int(x)
        return blend(stops[i], stops[i + 1], t: x - Double(i))
    }

    /// Straight sRGB component mix between neighbouring stops.
    ///
    /// Interpolating sRGB across the *whole* green→red span would cut through
    /// the neutral axis and go muddy at the midpoint. Across a single 5% step
    /// it does not: the worst departure from the continuous OKLCH path is
    /// ΔE00 ≈ 1.6, under the ~2.3 just-noticeable difference, and these are 3pt
    /// strokes and 5pt bars. Ten-percent stops would break 3 and band visibly.
    private static func blend(_ from: String, _ to: String, t: Double) -> String {
        let a = channels(from)
        let b = channels(to)
        return String(
            format: "%02X%02X%02X",
            Int((Double(a.0) + (Double(b.0) - Double(a.0)) * t).rounded()),
            Int((Double(a.1) + (Double(b.1) - Double(a.1)) * t).rounded()),
            Int((Double(a.2) + (Double(b.2) - Double(a.2)) * t).rounded()))
    }

    private static func channels(_ hex: String) -> (Int, Int, Int) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }
}
