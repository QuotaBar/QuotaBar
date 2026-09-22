import Charts
import QuotaModel
import SwiftUI
import WidgetKit

/// One provider, in whichever style its settings say, at whichever size it
/// was placed: a square on the home screen, a full-width row, a large
/// panel, or a gauge, a line or a strip on the lock screen.
struct ProviderWidgetView: View {
    let entry: ReadingsEntry
    /// Passed in rather than read from the environment, so the app can draw
    /// every size side by side (`WidgetGallery`).
    var family: WidgetFamily

    private var item: MergedReadings.Item? { entry.item }
    private var snapshot: UsageSnapshot? { item?.snapshot }
    private var window: UsageWindow? { snapshot.flatMap { entry.window.window(in: $0) } }
    private var used: Double? { window?.usedNow(at: entry.date) }
    private var shortUsed: Double? { snapshot?.window(on: .short)?.usedNow(at: entry.date) }
    private var longUsed: Double? { snapshot?.window(on: .long)?.usedNow(at: entry.date) }

    var body: some View {
        if entry.readings.items.isEmpty, family != .accessoryInline, family != .accessoryCircular {
            NoReadings()
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            case .systemLarge: large
            default: small
            }
        }
    }

    // MARK: Home screen, small

    @ViewBuilder
    private var small: some View {
        switch entry.providerStyle {
        case .ring: smallRing
        case .dualRing: smallDualRing
        case .bars: smallBars
        case .number: smallNumber
        }
    }

    private var smallRing: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(item: item, badge: window?.shortLabel)
            ZStack {
                UsageRing(used: used, lineWidth: 8)
                VStack(spacing: 0) {
                    LeftFigure(used: used, size: 24, tinted: false)
                    Text(L10n.t("left", "剩余")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ResetLine(window: window, date: entry.date, quiet: entry.quiet)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    private var smallDualRing: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(item: item)
            HStack(spacing: 10) {
                DualRing(short: shortUsed, long: longUsed, lineWidth: 7)
                    .overlay { item.map { ProviderMark(id: $0.provider, size: 18) } }
                VStack(alignment: .leading, spacing: 6) {
                    legend(snapshot?.window(on: .short), used: shortUsed)
                    legend(snapshot?.window(on: .long), used: longUsed)
                }
                .fixedSize()
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func legend(_ window: UsageWindow?, used: Double?) -> some View {
        if let window {
            VStack(alignment: .leading, spacing: 0) {
                Text(window.shortLabel ?? window.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                LeftFigure(used: used, size: 17)
            }
        }
    }

    private var smallBars: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(item: item)
            Spacer(minLength: 0)
            ForEach((snapshot?.shownWindows ?? []).prefix(2)) { window in
                WindowBarRow(window: window, date: entry.date)
            }
            Spacer(minLength: 0)
            ResetLine(window: window, date: entry.date, quiet: entry.quiet)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    private var smallNumber: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(item: item, badge: window?.shortLabel)
            Spacer(minLength: 0)
            LeftFigure(used: used, size: 52)
            Text(L10n.t("left", "剩余")).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ResetLine(window: window, date: entry.date, quiet: entry.quiet)
                .font(.caption2)
                .lineLimit(1)
        }
    }

    // MARK: Home screen, medium — full width

    /// The style's figure on the left; on the right every limit with its
    /// bar and reset, and today's spend where the Mac has it.
    private var medium: some View {
        HStack(spacing: 16) {
            if entry.providerStyle != .bars {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(item: item)
                    mediumFigure
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 118)
            }
            VStack(alignment: .leading, spacing: 8) {
                if entry.providerStyle == .bars {
                    WidgetHeader(item: item, badge: todaySpend)
                } else if let todaySpend {
                    Text(todaySpend)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Spacer(minLength: 0)
                ForEach((snapshot?.shownWindows ?? []).prefix(entry.providerStyle == .bars ? 3 : 2)) { window in
                    WindowBarRow(window: window, date: entry.date, showsReset: true, quiet: entry.quiet)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var mediumFigure: some View {
        switch entry.providerStyle {
        case .dualRing:
            DualRing(short: shortUsed, long: longUsed, lineWidth: 8)
                .overlay { item.map { ProviderMark(id: $0.provider, size: 22) } }
        case .number:
            VStack(alignment: .leading, spacing: 0) {
                LeftFigure(used: used, size: 44)
                Text(window.map { $0.shortLabel ?? $0.displayName } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                UsageRing(used: used, lineWidth: 9)
                LeftFigure(used: used, size: 22, tinted: false)
            }
        }
    }

    private var todaySpend: String? {
        guard let today = item?.spend?.period("today"), !today.isEmpty else { return nil }
        return L10n.t("Today \(entry.readings.money.format(today.usd))", "今日 \(entry.readings.money.format(today.usd))")
    }

    // MARK: Home screen, large

    /// Everything the detail page leads with: the style's figure, every
    /// limit, spend, and a month of usage.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let item { ProviderMark(id: item.provider, size: 22) }
                Text(item?.provider.displayName ?? "QuotaBar").font(.headline)
                if let chip = snapshot?.chipLabel {
                    Text(chip.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if let todaySpend {
                    Text(todaySpend).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                if entry.providerStyle != .bars {
                    mediumFigure.frame(width: 104, height: 104)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach((snapshot?.shownWindows ?? []).prefix(3)) { window in
                        WindowBarRow(window: window, date: entry.date, showsReset: true, quiet: entry.quiet)
                    }
                }
            }
            if let spend = item?.spend, spend.trend.contains(where: { $0.tokens > 0 }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("Last 30 days", "近 30 天")).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let window = spend.period("window") {
                            Text("\(entry.readings.money.format(window.usd)) · \(QuotaFormat.compact(window.tokens)) tokens")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Chart(spend.trend) { day in
                        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.tokens))
                            .foregroundStyle(Color(hex: item?.provider.accentHex ?? "FFFFFF"))
                            .cornerRadius(1)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Lock screen

    @ViewBuilder
    private var circular: some View {
        switch entry.providerStyle {
        case .dualRing:
            ZStack {
                AccessoryWidgetBackground()
                // Faint full tracks, so each arc reads against where it ends.
                Circle().stroke(lineWidth: 4).opacity(0.22).padding(3)
                Circle().stroke(lineWidth: 4).opacity(0.22).padding(10)
                Circle().trim(from: 0, to: left(shortUsed) / 100)
                    .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                Circle().trim(from: 0, to: left(longUsed) / 100)
                    .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(10)
                    .opacity(0.7)
                item.map { ProviderMark(id: $0.provider, size: 14) }
            }
            .widgetAccentable()
        case .number:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text(used.map { "\(Int((100 - $0).rounded()))" } ?? "–")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(window?.shortLabel ?? "%").font(.system(size: 10, weight: .medium))
                }
            }
            .widgetAccentable()
        default:
            Gauge(value: left(used), in: 0...100) {
                item.map { ProviderMark(id: $0.provider, size: 12) }
            } currentValueLabel: {
                Text(used.map { "\(Int((100 - $0).rounded()))" } ?? "–")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }

    private func left(_ used: Double?) -> Double {
        used.map { 100 - min(max($0, 0), 100) } ?? 0
    }

    @ViewBuilder
    private var rectangular: some View {
        if entry.providerStyle == .number {
            rectangularNumbers
        } else {
            rectangularBars
        }
    }

    /// Both limits as large figures side by side — the lock screen's version
    /// of the big-number style.
    private var rectangularNumbers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item?.provider.displayName ?? "QuotaBar").font(.caption.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach((snapshot?.shownWindows ?? []).prefix(2)) { window in
                    let windowUsed = window.usedNow(at: entry.date) ?? 0
                    VStack(alignment: .leading, spacing: -2) {
                        Text("\(Int((100 - windowUsed).rounded()))%")
                            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                            .widgetAccentable()
                        Text(window.shortLabel ?? window.displayName).font(.caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rectangularBars: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(item?.provider.displayName ?? "QuotaBar").font(.headline).widgetAccentable()
                Spacer(minLength: 0)
                if entry.quiet {
                    Image(systemName: "exclamationmark.triangle").font(.caption2)
                }
            }
            ForEach((snapshot?.shownWindows ?? []).prefix(2)) { window in
                let windowUsed = window.usedNow(at: entry.date) ?? 0
                HStack(spacing: 6) {
                    Text(window.shortLabel ?? "")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 22, alignment: .leading)
                    Gauge(value: 100 - windowUsed, in: 0...100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .widgetAccentable()
                    Text("\(Int((100 - windowUsed).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    private var inline: some View {
        Group {
            if let item, let used {
                let badge = window?.shortLabel.map { " · \($0)" } ?? ""
                Text("\(item.provider.displayName) \(L10n.t("\(Int((100 - used).rounded()))% left", "剩 \(Int((100 - used).rounded()))%"))\(badge)")
            } else {
                Text("QuotaBar")
            }
        }
    }
}
