import Charts
import QuotaModel
import SwiftUI
import WidgetKit

/// Several providers at once, in the order the cards were dragged into:
/// rings, stepped bars, or plain figures.
struct OverviewWidgetView: View {
    let entry: ReadingsEntry
    /// Passed in rather than read from the environment, so the app can draw
    /// every size side by side (`WidgetGallery`).
    var family: WidgetFamily

    private var capacity: Int {
        switch (family, entry.overviewStyle) {
        case (.systemSmall, .list): 3
        case (.systemSmall, _): 4
        case (.systemMedium, .rings): 4
        case (.systemMedium, _): 4
        case (.systemLarge, .rings): 8
        case (.systemLarge, .list): 7
        case (.systemLarge, _): 10
        case (.accessoryRectangular, _): 3
        default: 4
        }
    }

    private var items: [MergedReadings.Item] { Array(entry.readings.items.prefix(capacity)) }

    private func used(_ item: MergedReadings.Item) -> Double? {
        item.snapshot.flatMap { entry.window.window(in: $0) }?.usedNow(at: entry.date)
    }

    var body: some View {
        if items.isEmpty {
            NoReadings()
        } else if family == .accessoryRectangular {
            rectangular
        } else {
            VStack(alignment: .leading, spacing: 8) {
                switch entry.overviewStyle {
                case .rings: rings
                case .list: list
                case .figures: figures
                }
                if family != .systemSmall {
                    Spacer(minLength: 0)
                    footer
                }
            }
        }
    }

    // MARK: Rings

    @ViewBuilder
    private var rings: some View {
        // Large with four or fewer: a 2×2 of bigger rings rather than one
        // row and an empty panel under it.
        let columns = family == .systemSmall || (family == .systemLarge && items.count <= 4) ? 2 : min(4, max(items.count, 1))
        let grid = Array(repeating: GridItem(.flexible(), spacing: family == .systemLarge ? 20 : 10), count: columns)
        LazyVGrid(columns: grid, spacing: family == .systemSmall ? 10 : 16) {
            ForEach(items) { item in
                VStack(spacing: 4) {
                    ZStack {
                        UsageRing(used: used(item), lineWidth: family == .systemSmall ? 5 : (columns == 2 ? 9 : 6))
                        ProviderMark(id: item.provider, size: family == .systemSmall ? 18 : (columns == 2 ? 30 : 20))
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: columns == 2 && family == .systemLarge ? 104 : .infinity)
                    if family != .systemSmall {
                        Text(used(item).map { "\(Int((100 - $0).rounded()))%" } ?? "–")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(used(item).map { Color.usage($0) } ?? .secondary)
                        Text(item.provider.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxHeight: family == .systemSmall ? .infinity : nil)
    }

    // MARK: Stepped bars

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            ForEach(items) { item in
                let used = used(item) ?? 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        ProviderMark(id: item.provider, size: 14)
                        Text(item.provider.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if item.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        }
                        Text(self.used(item).map { "\(Int((100 - $0).rounded()))%" } ?? "–")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.usage(used))
                    }
                    SteppedMeter(fill: self.used(item).map { 100 - $0 }, tint: Color.usage(used), height: family == .systemLarge ? 6 : 4)
                    if family == .systemLarge {
                        ResetLine(
                            window: item.snapshot.flatMap { entry.window.window(in: $0) },
                            date: entry.date, quiet: entry.quiet)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Figures

    private var figures: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 6) {
            ForEach(items) { item in
                let short = item.snapshot?.window(on: .short)
                let long = item.snapshot?.window(on: .long)
                HStack(spacing: 8) {
                    ProviderMark(id: item.provider, size: 16)
                    if family != .systemSmall {
                        Text(item.provider.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if family == .systemSmall {
                        // One figure: the limit the widget is set to follow.
                        figure(item.snapshot.flatMap { entry.window.window(in: $0) }, badge: false)
                    } else {
                        figure(short, badge: true)
                        if long?.id != short?.id { figure(long, badge: true) }
                    }
                }
            }
            if family == .systemSmall { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func figure(_ window: UsageWindow?, badge: Bool) -> some View {
        if let window, let used = window.usedNow(at: entry.date) {
            HStack(spacing: 3) {
                if badge, let label = window.shortLabel {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(Int((100 - used).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.usage(used))
            }
            .frame(minWidth: badge ? 54 : 36, alignment: .trailing)
        }
    }

    // MARK: Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Text(item.provider.displayName).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(used(item).map { "\(Int((100 - $0).rounded()))%" } ?? "–")
                        .monospacedDigit()
                        .widgetAccentable()
                }
                .font(.caption)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            switch entry.readings.freshness(now: entry.date) {
            case .macQuiet:
                Label(L10n.t("Your Mac has stopped syncing", "Mac 已停止同步"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .current, .nothing:
                if let updatedAt = entry.readings.updatedAt {
                    Text(L10n.t("Updated \(QuotaFormat.age(of: updatedAt, now: entry.date))", "\(QuotaFormat.age(of: updatedAt, now: entry.date))更新"))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if entry.readings.hasSpend {
                Text(L10n.t(
                    "Today \(entry.readings.money.format(entry.readings.todayUSD))",
                    "今日 \(entry.readings.money.format(entry.readings.todayUSD))"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }
}

// MARK: - Spend

/// What today and the month cost across every provider with CLI logs
/// behind it — the Mac's spend card, on the home screen.
struct SpendWidgetView: View {
    let entry: ReadingsEntry
    /// Passed in rather than read from the environment, so the app can draw
    /// every size side by side (`WidgetGallery`).
    var family: WidgetFamily

    private var spending: [MergedReadings.Item] {
        entry.readings.items.filter { $0.spend != nil }
    }

    private var money: CloudMoney { entry.readings.money }

    private var monthUSD: Double {
        spending.reduce(0) { $0 + ($1.spend?.period("window")?.usd ?? 0) }
    }

    var body: some View {
        if spending.isEmpty {
            NoReadings()
        } else if family == .systemMedium {
            HStack(spacing: 16) {
                totals.frame(width: 120, alignment: .leading)
                chart
            }
        } else {
            totals
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Spend today", "今日花费"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(money.format(entry.readings.todayUSD))
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            ForEach(spending.prefix(3)) { item in
                HStack(spacing: 6) {
                    ProviderMark(id: item.provider, size: 12)
                    Text(money.format(item.spend?.period("today")?.usd ?? 0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The month, a bar a day, split by provider in their colours.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t("30 days", "30 天")).foregroundStyle(.secondary)
                Spacer()
                Text(money.format(monthUSD)).monospacedDigit()
            }
            .font(.caption2)
            Chart {
                ForEach(spending) { item in
                    ForEach(item.spend?.trend ?? []) { day in
                        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Spend", day.usd))
                            .foregroundStyle(Color(hex: item.provider.accentHex))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}
