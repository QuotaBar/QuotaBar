import SwiftUI
import QuotaCore

// MARK: - Small shared pieces
//
// Kept from the 0.4 panel when it was removed: the trend line, the reset
// credits row and the settings tile style are still used elsewhere.

/// Snappy press feedback for grid tiles.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Mini trend line of recorded headline readings (0–100% scale).
struct SparklineView: View {
    let values: [Double]
    let accent: Color
    var height: CGFloat = 26

    var body: some View {
        if values.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    // Fixed 0–100 scale: an auto-scaled axis would make 3% look
                    // as dramatic as 90%, which is the opposite of useful here.
                    // The plot area is drawn so the headroom above a low line
                    // reads as "plenty left", not as a layout gap.
                    // Line only, no area fill. A series pinned at 100% — which
                    // is exactly what an exhausted quota looks like — fills the
                    // whole plot and stops reading as a trend at all.
                    line(in: proxy.size).stroke(
                        accent.opacity(0.9),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .frame(height: height)
                .padding(.horizontal, 1)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                        .fill(Design.track.opacity(0.35)))
                HStack(spacing: Design.space1) {
                    Text(L10n.t(
                        "trend · last \(values.count) refreshes",
                        "趋势 · 最近 \(values.count) 次刷新"))
                    if let last = values.last, let peak = values.max(), peak > last {
                        Text(L10n.t("· peak \(QuotaFormat.percent(peak))",
                                    "· 峰值 \(QuotaFormat.percent(peak))"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let stepX = size.width / CGFloat(values.count - 1)
        let clamped = min(max(values[index], 0), 100)
        return CGPoint(x: CGFloat(index) * stepX, y: size.height * (1 - CGFloat(clamped / 100)))
    }

    private func line(in size: CGSize) -> Path {
        Path { path in
            for index in values.indices {
                let next = point(index, in: size)
                if index == 0 { path.move(to: next) } else { path.addLine(to: next) }
            }
        }
    }

}

/// Each banked early reset under their count: what it resets, as the
/// provider names it ("Full reset"), and when it runs out — in the reset
/// rows' format, and a click switches it the way theirs does (issue #3).
/// Three at most, then how many more.
struct ResetCreditDeadlines: View {
    @ObservedObject var store: UsageStore
    let credits: ResetCredits
    let accent: Color

    var body: some View {
        let now = Date()
        let listed = credits.credits.filter { ($0.expiresAt ?? .distantFuture) > now }
        if !listed.isEmpty {
            let prefs = store.experience
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(listed.prefix(3).enumerated()), id: \.offset) { _, credit in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(accent.opacity(0.8))
                        Text(credit.title ?? L10n.t("Full reset", "完整重置"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: Design.space2)
                        Text(QuotaFormat.creditExpiry(credit, format: prefs.resetTimeFormat, clock: prefs.clockStyle))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    .help(QuotaFormat.creditExpiry(
                        credit, format: prefs.resetTimeFormat == .countdown ? .exact : .countdown, clock: prefs.clockStyle))
                }
                if listed.count > 3 {
                    Text(L10n.t("+\(listed.count - 3) more", "另 \(listed.count - 3) 次"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.leading, 16)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.toggleResetFormat() }
        }
    }
}

/// A balance the account holds — credits bought or given — as its name, the
/// amount at the end, and beneath it what it is and when it runs out.
struct BalanceCreditRow: View {
    @ObservedObject var store: UsageStore
    let window: UsageWindow
    let accent: Color

    var body: some View {
        if let credit = window.credit {
            let prefs = store.experience
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "gift")
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                    Text(window.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: Design.space2)
                    Text(credit.amount)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                if credit.caption != nil || credit.expiresAt != nil {
                    HStack(spacing: 6) {
                        Text(credit.caption ?? "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Design.space2)
                        if let expiresAt = credit.expiresAt {
                            Text(QuotaFormat.creditExpiry(
                                ResetCredit(expiresAt: expiresAt), format: prefs.resetTimeFormat, clock: prefs.clockStyle))
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 17)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.toggleResetFormat() }
            .help(window.note ?? "")
        }
    }
}

/// Early-reset credits, when the account has been given some.
struct ResetCreditsRow: View {
    @ObservedObject var store: UsageStore
    let credits: ResetCredits
    let accent: Color

    var body: some View {
        HStack(spacing: Design.space2) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(accent)
            Text(L10n.t("Early resets", "限额重置额度"))
                .font(.callout.weight(.medium))
            Spacer()
            if let earned = credits.totalEarned, earned > credits.available {
                Text(L10n.t("\(earned) given ·", "累计获得 \(earned) 次 ·"))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(L10n.t(
                "\(credits.available) available",
                "\(credits.available) 次可用"))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(credits.available > 0 ? accent : .secondary)
        }
        .help(store.resetCreditHelp(credits))
    }
}
