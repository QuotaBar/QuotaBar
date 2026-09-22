import SwiftUI

/// The Mac's stepped bar (`Meter` in the Mac app, codex-island's "阶梯"): a
/// row of short segments, as many as the width takes at 5pt plus a 2pt gap,
/// so the segments look the same at every width. Same geometry as the Mac,
/// so the phone reads as the same app.
struct SteppedMeter: View {
    /// How full the bar is, 0–100 — what is left, as the figure beside it
    /// says. Nil draws the empty track.
    let fill: Double?
    let tint: Color
    var height: CGFloat = 8
    var track: Color = Color.white.opacity(0.1)

    private static let segment: CGFloat = 5
    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let count = max(8, Int((proxy.size.width + Self.gap) / (Self.segment + Self.gap)))
            let width = (proxy.size.width - Self.gap * CGFloat(count - 1)) / CGFloat(count)
            // Rounded to the nearest segment, and at least one once there is
            // anything: 1% on 48 segments is still a lit bar.
            let lit = fill.map { value -> Int in
                guard value > 0 else { return 0 }
                return max(1, Int((Double(count) * min(value, 100) / 100).rounded()))
            } ?? 0
            HStack(spacing: Self.gap) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < lit ? tint : track)
                        .frame(width: width)
                }
            }
        }
        .frame(height: height + 3)
        .accessibilityHidden(true)
    }
}
