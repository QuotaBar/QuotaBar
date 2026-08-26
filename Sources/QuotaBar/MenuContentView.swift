import SwiftUI
import QuotaCore

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    /// `ImageRenderer` does not lay out `ScrollView` contents, so the snapshot
    /// tool renders the detail section unscrolled.
    var scrollable: Bool = true

    var body: some View {
        MenuContentBody(store: store, scrollable: scrollable)
            .padding(Design.space3)
            .frame(width: 380)
            .tint(Design.accent)
    }
}

/// Shared panel content, reused by the menu-bar popover and the notch island.
struct MenuContentBody: View {
    @ObservedObject var store: UsageStore
    var scrollable: Bool = true
    @Environment(\.openSettings) private var openSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Design.space2), count: 4)

    var body: some View {
        VStack(spacing: Design.space3) {
            providerGrid
            Divider()
            if scrollable {
                ScrollView {
                    detailSection
                }
                .frame(minHeight: 180, maxHeight: 320)
            } else {
                detailSection
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
    }

    // MARK: Grid switcher

    private var providerGrid: some View {
        LazyVGrid(columns: columns, spacing: Design.space2 + 2) {
            gridCell(
                title: L10n.t("Overview", "总览"),
                logoID: nil,
                accent: .secondary,
                percent: nil,
                warn: !store.failingProviders.isEmpty,
                isSelected: store.selected == nil)
            {
                store.selected = nil
            }
            ForEach(store.enabled) { id in
                gridCell(
                    title: id.displayName,
                    logoID: id,
                    accent: Color(hex: id.accentHex),
                    percent: store.states[id]?.snapshot?.headlinePercent,
                    warn: store.states[id]?.errorMessage != nil,
                    isSelected: store.selected == id)
                {
                    store.selected = id
                }
            }
        }
    }

    private func gridCell(
        title: String,
        logoID: ProviderID?,
        accent: Color,
        percent: Double?,
        warn: Bool,
        isSelected: Bool,
        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            VStack(spacing: Design.space1) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let logoID {
                            ProviderGlyph(id: logoID, size: 17, ink: isSelected)
                        } else {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(height: 18)
                    if warn {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -2)
                    }
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MiniMeter(percent: percent, accent: isSelected ? Design.ink : accent)
            }
            .padding(.vertical, Design.space1 + 2)
            .padding(.horizontal, Design.space1)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(isSelected ? Design.accent : Design.surfaceStrong))
            .foregroundStyle(isSelected ? Design.ink : Color.primary)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel(percent.map { "\(title) \(QuotaFormat.percent($0))" } ?? title)
    }

    // MARK: Detail

    @ViewBuilder
    private var detailSection: some View {
        if let selected = store.selected {
            ProviderDetailView(store: store, id: selected)
        } else {
            overviewRows
        }
    }

    private var overviewRows: some View {
        VStack(spacing: Design.space2 + 2) {
            if store.cost.hasData {
                CostCard(cost: store.cost)
            }
            if store.enabled.isEmpty {
                VStack(spacing: Design.space2) {
                    Text(L10n.t("No providers enabled.", "尚未启用任何服务商。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.t("Open Settings", "打开设置")) { openSettings() }
                        .controlSize(.small)
                }
                .padding(.top, Design.space6)
            }
            ForEach(store.enabled) { id in
                OverviewRow(store: store, id: id)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Design.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Every \(store.refreshMinutes)m", "每 \(store.refreshMinutes) 分钟刷新"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !store.failingProviders.isEmpty {
                    let names = store.failingProviders.map(\.displayName).joined(separator: ", ")
                    Label(
                        L10n.t("\(names) not updating", "\(names) 未能更新"),
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Refresh now", "立即刷新"))
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Settings", "设置"))
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Quit QuotaBar", "退出 QuotaBar"))
        }
    }
}

// MARK: - Overview row

struct OverviewRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: Design.space2 + 2) {
            ProviderGlyph(id: id, size: 16)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Design.space1 + 2) {
                    Text(id.displayName)
                        .font(.callout.weight(.medium))
                    if store.states[id]?.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(store.states[id]?.errorMessage ?? "")
                    }
                    Spacer()
                    trailing
                }
                if let percent = store.states[id]?.snapshot?.headlinePercent {
                    MiniMeter(percent: percent, accent: Color(hex: id.accentHex))
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch store.states[id] {
        case .loading, nil:
            ProgressView().controlSize(.small)
        case let .loaded(snapshot), let .stale(snapshot, _):
            if let percent = snapshot.headlinePercent {
                Text(QuotaFormat.percent(percent))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        store.alertSettings.level(for: percent).hex.map { Color(hex: $0) }
                            ?? Color(hex: id.accentHex))
            } else if let first = snapshot.windows.first, let detail = first.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(message)
        }
    }
}

// MARK: - Cost card

struct CostCard: View {
    let cost: CostSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space1 + 2) {
            HStack(spacing: Design.space2 + 2) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(Design.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(
                        "Today \(QuotaFormat.usd(cost.todayUSD)) · \(QuotaFormat.compact(cost.todayTokens)) tokens",
                        "今日 \(QuotaFormat.usd(cost.todayUSD)) · \(QuotaFormat.compact(cost.todayTokens)) tokens"))
                        .font(.callout.weight(.medium))
                    Text(L10n.t(
                        "Month \(QuotaFormat.usd(cost.monthUSD)) · \(QuotaFormat.compact(cost.monthTokens)) tokens",
                        "本月 \(QuotaFormat.usd(cost.monthUSD)) · \(QuotaFormat.compact(cost.monthTokens)) tokens"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.t("local logs", "本地日志"))
                    .font(.caption2)
                    .padding(.horizontal, Design.space1 + 2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Design.surfaceStrong))
                    .foregroundStyle(.secondary)
                    .help(L10n.t(
                        "Estimated from the CLIs' own session logs at list prices. Not a bill.",
                        "根据各 CLI 的本地会话日志按官方标价估算，非实际账单。"))
            }
            if sources.count > 1 {
                HStack(spacing: Design.space2) {
                    ForEach(sources, id: \.0) { source, amount in
                        Text("\(source.displayName) \(QuotaFormat.usd(amount))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, Design.space6)
            }
        }
        .quotaCard()
    }

    /// Month-to-date spend per CLI, largest first.
    private var sources: [(CostSource, Double)] {
        cost.monthBySource
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }
}

// MARK: - Detail

struct ProviderDetailView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            switch store.states[id] {
            case .loading, nil:
                HStack {
                    Spacer()
                    ProgressView(L10n.t("Fetching \(id.displayName)…", "正在获取 \(id.displayName)…"))
                        .padding(.top, Design.space6)
                    Spacer()
                }
            case let .loaded(snapshot):
                content(snapshot, error: nil)
            case let .stale(snapshot, error):
                content(snapshot, error: error)
            case let .failed(message):
                FailureView(store: store, id: id, message: message)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func content(_ snapshot: UsageSnapshot, error: String?) -> some View {
        header(snapshot)
        if let error {
            StaleBanner(message: error, fetchedAt: snapshot.fetchedAt) { store.refresh(id) }
        }
        SparklineView(
            values: store.history[id] ?? [],
            accent: Color(hex: id.accentHex))
        if snapshot.windows.isEmpty {
            Text(L10n.t("No quota windows reported.", "服务商未返回任何额度窗口。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(snapshot.windows) { window in
            WindowRow(
                window: window,
                accent: Color(hex: id.accentHex),
                alerts: store.alertSettings)
        }
        if error == nil {
            Text(L10n.t(
                "Updated \(QuotaFormat.age(of: snapshot.fetchedAt))",
                "更新于 \(QuotaFormat.age(of: snapshot.fetchedAt))"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func header(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: Design.space2) {
            ProviderGlyph(id: id, size: 18)
            Text(id.displayName)
                .font(.title3.weight(.semibold))
            if let plan = snapshot.planName {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: id.accentHex).opacity(0.18)))
                    .foregroundStyle(Color(hex: id.accentHex))
            }
            Spacer()
            if let account = snapshot.account {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account)
            }
        }
    }
}

/// Shown when the newest numbers on screen came from an earlier, successful
/// refresh — the panel must never present stale data as current.
struct StaleBanner: View {
    let message: String
    let fetchedAt: Date
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Design.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                // No space before 的: the Chinese age string already ends in 前.
                Text(L10n.t(
                    "Showing data from \(QuotaFormat.age(of: fetchedAt))",
                    "当前显示 \(QuotaFormat.age(of: fetchedAt))的数据"))
                    .font(.caption.weight(.medium))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.t("Retry", "重试"), action: retry)
                .controlSize(.small)
        }
        .padding(Design.space2 + 2)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
    }
}

struct FailureView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let message: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2 + 2) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            // `notConfigured` already quotes the setup hint; repeating it here
            // printed the same sentence twice.
            if !message.contains(id.setupHint) {
                Text(id.setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.space2) {
                Button(L10n.t("Retry", "重试")) { store.refresh(id) }
                    .controlSize(.small)
                Button(L10n.t("Settings", "设置")) { openSettings() }
                    .controlSize(.small)
                if let url = id.dashboardURL {
                    Button(L10n.t("Console", "控制台")) { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.top, Design.space2)
    }
}

// MARK: - Small components

/// Snappy press feedback for grid tiles.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct MiniMeter: View {
    let percent: Double?
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.track)
                Capsule()
                    .fill(accent)
                    .frame(width: max(4, proxy.size.width * CGFloat((percent ?? 0) / 100)))
                    .opacity(percent == nil ? 0 : 1)
            }
        }
        .frame(height: 3)
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
                    ZStack {
                        area(in: proxy.size).fill(accent.opacity(0.18))
                        line(in: proxy.size).stroke(
                            accent.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
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

    private func area(in size: CGSize) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            for index in values.indices {
                path.addLine(to: point(index, in: size))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let accent: Color
    var alerts: AlertSettings = AlertSettings()

    /// Matches the colour the Overview list gives the same number — two
    /// different colours for one reading reads as a bug.
    private var tint: Color {
        guard let percent = window.usedPercent,
              let hex = alerts.level(for: percent).hex else { return accent }
        return Color(hex: hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Design.space1 + 2) {
                Text(window.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if window.isActive {
                    Text(L10n.t("active", "生效中"))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accent)
                }
                Spacer()
                if let percent = window.usedPercent {
                    Text(QuotaFormat.percent(percent))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
            if let percent = window.usedPercent {
                ProgressView(value: min(max(percent, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
            HStack {
                if let detail = window.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let resetsAt = window.resetsAt {
                    Text(L10n.t(
                        "resets in \(QuotaFormat.countdown(to: resetsAt))",
                        "\(QuotaFormat.countdown(to: resetsAt))后重置"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
