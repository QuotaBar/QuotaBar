import Charts
import QuotaModel
import SwiftUI

/// Everything the Mac knows about one provider — what its card shows under
/// the arrow: every window with its pace, early-reset credits, what was
/// spent today, yesterday and over the month with the models it went on, a
/// month of usage, the balance, and the console and status page.
struct ProviderDetail: View {
    let model: ReadingsModel
    let provider: ProviderID
    var notice: Binding<String?> = .constant(nil)
    /// The name moves into the bar once the header has scrolled away, so it
    /// is never said twice on screen.
    @State private var headerHidden = false
    @State private var showsStatus = false

    /// Read afresh from the model, so a refresh while the page is open
    /// updates it.
    private var item: MergedReadings.Item? {
        model.readings.items.first { $0.provider == provider }
    }

    private var money: CloudMoney { model.readings.money }
    private var accent: Color { Color(hex: provider.accentHex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item {
                    header(item)
                    if let error = item.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let snapshot = item.snapshot {
                        windows(snapshot)
                        if let credits = snapshot.resetCredits, credits.isShown {
                            ResetCreditsSection(credits: credits, accent: accent)
                        }
                        if let balance = snapshot.balance, !balance.balances.isEmpty {
                            BalanceSection(balance: balance)
                        }
                    }
                    if let spend = item.spend {
                        SpendSection(spend: spend, money: money)
                        TrendSection(spend: spend, accent: accent)
                    }
                    actions(item)
                    source(item)
                } else {
                    Text(L10n.t("This provider is no longer on your Mac.", "Mac 上已经没有这个服务商了。"))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 56 } action: { _, hidden in
            headerHidden = hidden
        }
        .refreshable { await model.refresh() }
        .background(Color.black)
        .navigationTitle(headerHidden ? provider.displayName : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let item {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        CardShareActions(item: item, model: model, notice: notice)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L10n.t("Share", "分享"))
                }
            }
        }
        #if DEBUG
        // `-QuotaBarStatus`: the status sheet up at once, for screenshots.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-QuotaBarStatus") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            showsStatus = true
        }
        #endif
        .sheet(isPresented: $showsStatus) {
            StatusSheet(model: model, provider: provider)
        }
    }

    /// The console, and the service status in a sheet of its own rather
    /// than on this page.
    @ViewBuilder
    private func actions(_ item: MergedReadings.Item) -> some View {
        let hasStatus = StatusPages.page(for: provider) != nil
        let console = item.links?.console
        if hasStatus || console != nil {
            HStack(spacing: 12) {
                if let console {
                    Link(destination: console) {
                        Label(L10n.t("Console", "控制台"), systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                if hasStatus {
                    Button {
                        showsStatus = true
                    } label: {
                        HStack(spacing: 6) {
                            // The band's colour on the button itself, so an
                            // outage is seen before it is opened.
                            if let level = model.status[provider]?.level {
                                Circle().fill(Color(hex: level.colorHex)).frame(width: 7, height: 7)
                            } else {
                                Image(systemName: "waveform.path.ecg")
                            }
                            Text(L10n.t("Service status", "服务状态"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func header(_ item: MergedReadings.Item) -> some View {
        HStack(spacing: 12) {
            ProviderMark(id: provider, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(provider.displayName).font(.title2.weight(.semibold))
                    if let chip = item.snapshot?.chipLabel { PlanChip(text: chip) }
                }
                if let account = item.snapshot?.account {
                    Text(account)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 8)
    }

    private func windows(_ snapshot: UsageSnapshot) -> some View {
        Section(L10n.t("Limits", "额度")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(snapshot.windows.filter { $0.usedPercent != nil }) { window in
                    WindowRow(window: window, pace: .always)
                }
                ForEach(snapshot.windows.filter { $0.usedPercent == nil && $0.detail != nil }) { window in
                    HStack {
                        Text(window.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text(window.detail ?? "").monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func source(_ item: MergedReadings.Item) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let read = item.snapshot?.fetchedAt ?? item.deviceUpdatedAt
            let mac = item.deviceName.isEmpty ? "Mac" : item.deviceName
            // The model only when the owner's name for it does not already say it.
            let model = item.deviceModel.flatMap { mac.localizedCaseInsensitiveContains($0.components(separatedBy: " (").first ?? $0) ? nil : $0 }
            Label {
                Text(L10n.t(
                    "From \(mac)\(model.map { " (\($0))" } ?? "") · read \(QuotaFormat.age(of: read, now: context.date))",
                    "来自 \(mac)\(model.map { "（\($0)）" } ?? "") · \(QuotaFormat.age(of: read, now: context.date))读取"))
            } icon: {
                Image(systemName: MacKind(model: item.deviceModel, name: item.deviceName).symbolName)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
        }
    }
}

// MARK: - Sections

/// A titled card, the detail page's one surface.
private struct Section<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Spend per period, each opening to the models it went on.
private struct SpendSection: View {
    let spend: CloudSpend
    let money: CloudMoney
    @State private var open: Set<String> = []

    var body: some View {
        Section(
            L10n.t("Spend", "花费"),
            footer: spend.estimated
                ? L10n.t(
                    "Worked out on your Mac from the CLI's session logs at API list prices — what the tokens would cost, not a bill. Usage included in a plan is priced the same way.",
                    "由 Mac 根据 CLI 会话日志、按 API 公开价格估算，是这些 token 按量计费的价格，不是账单；套餐内的用量也按同样方式计价。")
                : nil)
        {
            VStack(spacing: 0) {
                ForEach(Array(spend.periods.enumerated()), id: \.element.id) { index, period in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    row(period)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ period: CloudSpend.Period) -> some View {
        let expandable = !period.models.isEmpty
        Button {
            guard expandable else { return }
            withAnimation(.snappy) {
                if open.contains(period.id) { open.remove(period.id) } else { open.insert(period.id) }
            }
        } label: {
            HStack {
                Text(spend.title(of: period)).font(.subheadline.weight(.medium))
                Spacer()
                if period.isEmpty {
                    Text(L10n.t("No data", "暂无数据")).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(money.format(period.usd)).font(.subheadline.monospacedDigit().weight(.semibold))
                        Text("\(QuotaFormat.compact(period.tokens)) tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if expandable {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open.contains(period.id) ? 180 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open.contains(period.id) {
            VStack(spacing: 6) {
                ForEach(period.models) { model in
                    HStack {
                        Text(model.name)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(money.format(model.usd)) · \(QuotaFormat.compact(model.tokens))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        }
    }
}

/// A month of tokens, a bar a day, in the provider's colour.
private struct TrendSection: View {
    let spend: CloudSpend
    let accent: Color

    var body: some View {
        if spend.trend.contains(where: { $0.tokens > 0 }) {
            let total = spend.trend.reduce(0) { $0 + $1.tokens }
            Section(L10n.t("Usage, last 30 days", "近 30 天用量")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(QuotaFormat.compact(total)).font(.title3.monospacedDigit().weight(.semibold))
                        Text("tokens").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let peak = spend.trend.max(by: { $0.tokens < $1.tokens }) {
                            Text(L10n.t(
                                "Peak \(peak.day.formatted(.dateTime.month().day()))",
                                "最高 \(peak.day.formatted(.dateTime.month().day().locale(L10n.locale)))"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Chart(spend.trend) { day in
                        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.tokens))
                            .foregroundStyle(accent)
                            .cornerRadius(1)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .frame(height: 120)
                }
            }
        }
    }
}

private struct ResetCreditsSection: View {
    let credits: ResetCredits
    let accent: Color

    var body: some View {
        Section(L10n.t("Early resets", "提前重置")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t("Available", "可用次数"))
                    Spacer()
                    Text("\(credits.available)")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .foregroundStyle(credits.available > 0 ? accent : .secondary)
                }
                ForEach(Array(credits.credits.compactMap(\.expiresAt).prefix(5).enumerated()), id: \.offset) { _, date in
                    HStack {
                        Text(L10n.t("Expires", "到期")).foregroundStyle(.secondary)
                        Spacer()
                        Text(date.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .font(.subheadline)
        }
    }
}

private struct BalanceSection: View {
    let balance: BalanceSheet

    var body: some View {
        Section(L10n.t("Balance", "余额")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(balance.balances, id: \.currency) { item in
                    HStack {
                        Text(item.currency).foregroundStyle(.secondary)
                        Spacer()
                        Text(QuotaFormat.amount(item.total, code: item.currency))
                            .font(.title3.monospacedDigit().weight(.semibold))
                    }
                }
                ForEach(KeyUsagePeriod.allCases.filter { balance.usage[$0]?.isEmpty == false }) { period in
                    if let figures = balance.usage[period] {
                        HStack {
                            Text(period.displayName).foregroundStyle(.secondary)
                            Spacer()
                            Text(figures.costLine).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}
