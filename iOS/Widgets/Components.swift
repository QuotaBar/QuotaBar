import QuotaModel
import SwiftUI
import WidgetKit

// MARK: - Which windows a widget draws

extension UsageSnapshot {
    /// The fullest of the plan's own windows on one horizon, and nothing —
    /// not a stand-in from the other horizon — when the plan has none there.
    /// A Codex Pro account has no 5-hour window; its dual ring draws one
    /// ring rather than the weekly figure twice.
    func window(on horizon: WindowHorizon) -> UsageWindow? {
        ownWindows.filter { $0.horizon == horizon }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    /// The plan's own windows with a figure, short first.
    var shownWindows: [UsageWindow] {
        ownWindows.sorted { ($0.windowSeconds ?? .max) < ($1.windowSeconds ?? .max) }
    }
}

extension MergedReadings {
    /// Today's spend across every provider with logs behind it.
    var todayUSD: Double {
        items.reduce(0) { $0 + ($1.spend?.period("today")?.usd ?? 0) }
    }

    var hasSpend: Bool { items.contains { $0.spend != nil } }
}

// MARK: - Figures

/// "22%" with the sign smaller, in the ramp's colour for what is used.
struct LeftFigure: View {
    let used: Double?
    var size: CGFloat = 28
    var tinted = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(used.map { "\(Int((100 - $0).rounded()))" } ?? "–")
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("%")
                .font(.system(size: size * 0.45, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tinted && used != nil ? Color.usage(used ?? 0) : Color.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The provider's mark and name, with the window's badge at the far end.
struct WidgetHeader: View {
    let item: MergedReadings.Item?
    var badge: String?
    var markSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            if let item {
                ProviderMark(id: item.provider, size: markSize)
                Text(item.provider.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                BrandLockup(iconSize: markSize, textSize: 13)
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Two rings, one inside the other: outside the short limit, inside the
/// long one, each filled with what is left. The Mac's dual glyph as rings.
struct DualRing: View {
    let short: Double?
    let long: Double?
    var lineWidth: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let inset = lineWidth + lineWidth * 0.5
            ZStack {
                UsageRing(used: short, lineWidth: lineWidth)
                    .frame(width: side, height: side)
                UsageRing(used: long, lineWidth: lineWidth)
                    .frame(width: side - inset * 2, height: side - inset * 2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// "22% · 1小时59分后重置" — or, when the Mac has gone quiet, a plain word
/// that the figure may be old. The countdown ticks by itself between
/// timeline entries.
struct ResetLine: View {
    let window: UsageWindow?
    let date: Date
    let quiet: Bool

    var body: some View {
        if quiet {
            Text(L10n.t("Mac not syncing", "Mac 未同步"))
                .foregroundStyle(.orange)
        } else if let window, window.hasReset(now: date) {
            Text(L10n.t("Reset", "已重置")).foregroundStyle(.secondary)
        } else if let resetsAt = window?.resetsAt {
            let countdown = Text(resetsAt, style: .relative)
            Text(L10n.isChinese ? "\(countdown)后重置" : "resets in \(countdown)")
                .foregroundStyle(.secondary)
        }
    }
}

/// One window as a row: badge, stepped bar, what is left.
struct WindowBarRow: View {
    let window: UsageWindow
    let date: Date
    var showsReset = false
    var quiet = false

    var body: some View {
        let used = window.usedNow(at: date) ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.shortLabel ?? window.displayName)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((100 - used).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.usage(used))
            }
            SteppedMeter(fill: 100 - used, tint: Color.usage(used), height: 5)
            if showsReset {
                ResetLine(window: window, date: date, quiet: quiet)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }
}

/// What a widget says when no Mac has sent anything yet.
struct NoReadings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandLockup(iconSize: 16, textSize: 13)
            Spacer(minLength: 0)
            Text(L10n.t("Turn on iCloud sync in QuotaBar on your Mac.", "请在 Mac 版 QuotaBar 中开启 iCloud 同步。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
