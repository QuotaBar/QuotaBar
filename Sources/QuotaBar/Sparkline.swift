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
/// Three at most, then how many more. One running out within the day is
/// marked, and the soonest says where to spend it.
struct ResetCreditDeadlines: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderID
    let credits: ResetCredits
    let accent: Color

    var body: some View {
        let now = Date()
        let listed = credits.credits.filter { ($0.expiresAt ?? .distantFuture) > now }
        if !listed.isEmpty {
            let prefs = store.experience
            let hinted = listed.firstIndex { CreditUrgency(expiresAt: $0.expiresAt, now: now) > .none }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(listed.prefix(3).enumerated()), id: \.offset) { index, credit in
                    let warn = Palette.expiry(CreditUrgency(expiresAt: credit.expiresAt, now: now))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: warn == nil ? "clock" : "hourglass")
                                .font(.system(size: 10))
                                .foregroundStyle(warn ?? accent.opacity(0.8))
                            Text(credit.title ?? L10n.t("Full reset", "完整重置"))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(warn == nil ? 0.7 : 0.9))
                                .lineLimit(1)
                            Spacer(minLength: Design.space2)
                            Text(QuotaFormat.creditExpiry(credit, format: prefs.resetTimeFormat, clock: prefs.clockStyle))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(warn ?? .white.opacity(0.5))
                                .lineLimit(1)
                        }
                        if index == hinted, let warn, let hint = ResetCreditCheck.spendHint(for: provider) {
                            Text(hint)
                                .font(.system(size: 10))
                                .foregroundStyle(warn.opacity(0.85))
                                .lineLimit(1)
                                .padding(.leading, 16)
                        }
                    }
                    .expiryMark(warn)
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
/// amount at the end, and beneath it what it is and when it runs out, marked
/// once that is within the day.
struct BalanceCreditRow: View {
    @ObservedObject var store: UsageStore
    let window: UsageWindow
    let accent: Color

    var body: some View {
        if let credit = window.credit {
            let prefs = store.experience
            let warn = Palette.expiry(CreditUrgency(expiresAt: credit.expiresAt))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "gift")
                        .font(.system(size: 11))
                        .foregroundStyle(warn ?? accent)
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
                                .foregroundStyle(warn ?? .white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 17)
                }
            }
            .expiryMark(warn)
            .contentShape(Rectangle())
            .onTapGesture { store.toggleResetFormat() }
            .help(window.note ?? "")
        }
    }
}

extension View {
    /// A wash and a bar down the left edge behind a row running out soon,
    /// drawn past the row's edges so its text stays in line with the rows
    /// beside it.
    @ViewBuilder
    func expiryMark(_ color: Color?) -> some View {
        if let color {
            background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(color.opacity(0.09))
                    Rectangle().fill(color).frame(width: 2)
                }
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
            }
        } else {
            self
        }
    }
}

/// Beside a card's name: the soonest of what the account was given that runs
/// out within the day, in its colour, so it shows with the card folded. A
/// click opens the card on it; hover lists each one. Compact, it says only
/// the time left ("21h", "47m"), for a header that has no room for more.
struct CreditExpiryBadge: View {
    let snapshot: UsageSnapshot
    var compact = false
    var open: (() -> Void)? = nil

    var body: some View {
        let now = Date()
        let due = snapshot.givenDeadlines(now: now).filter { $0.urgency(now: now) > .none }
        if let soonest = due.first, let color = Palette.expiry(soonest.urgency(now: now)) {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9, weight: .semibold))
                Text(compact ? Self.left(until: soonest.expiresAt, now: now) : QuotaFormat.shortExpiry(soonest.expiresAt, now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { open?() }
            .help(due.map { "\($0.name) · \(QuotaFormat.creditExpiry(ResetCredit(expiresAt: $0.expiresAt), format: .countdown, now: now))" }
                .joined(separator: "\n"))
        }
    }

    /// Whole hours, minutes in the last one — the notch strip's way, which
    /// reads the same in either language.
    private static func left(until date: Date, now: Date) -> String {
        let left = Int(max(date.timeIntervalSince(now), 0))
        return left >= 3600 ? "\(left / 3600)h" : "\(max(left / 60, 1))m"
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
