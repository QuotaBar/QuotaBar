import Charts
import QuotaModel
import SwiftUI

/// CLI totals reuse the same readings as the provider details and widgets.
struct UsageView: View {
    let model: ReadingsModel
    @State private var period: UsageSummary.Period = .today
    @State private var selectedDate: Date?
    @State private var metric: Metric = .tokens

    private enum Metric: String, CaseIterable {
        case tokens, cost
        var title: String { self == .tokens ? "Token" : L10n.t("Cost", "花费") }
    }

    private var summary: UsageSummary { UsageSummary(readings: model.readings) }
    private var days: [UsageSummary.Day] { summary.days() }
    private var selectedDay: UsageSummary.Day? {
        guard let selectedDate else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }
    private var providers: [UsageSummary.Provider] {
        if selectedDate != nil { return selectedDay?.providers.sorted { $0.usd > $1.usd } ?? [] }
        return summary.providers(in: period)
    }
    private var usd: Double { providers.reduce(0) { $0 + $1.usd } }
    private var tokens: Int { providers.reduce(0) { $0 + $1.tokens } }
    private var estimated: Bool { providers.contains { $0.estimated } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        BrandLockup()
                        Spacer()
                        Text(L10n.t("Usage", "用量"))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    FreshnessBanner(readings: model.readings, error: model.error, macRefresh: model.macRefresh)
                    if model.isDemo {
                        Label(L10n.t("Sample data", "示例数据"), systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.readings.items.contains(where: { $0.spend != nil }) {
                        Picker(L10n.t("Period", "时间范围"), selection: $period) {
                            ForEach(UsageSummary.Period.allCases) { value in Text(value.title).tag(value) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: period) { _, _ in selectedDate = nil }
                        totals
                        if !days.isEmpty { trend }
                        breakdown
                        Text(L10n.t(
                            "Only services with CLI usage synced by your Mac are included. Estimated costs use API list prices, not your subscription bill. Missing days and model details are not inferred.",
                            "仅统计 Mac 已同步 CLI 用量的服务。估算花费按 API 公开价格计算，不是订阅账单；缺失日期和模型明细不会推算补齐。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
                            Text(L10n.t("No usage synced yet", "暂无同步的用量"))
                                .font(.headline)
                            Text(L10n.t(
                                "Your Mac's CLI usage will appear here after it syncs. Account balances are shown on the Quota page.",
                                "Mac 同步 CLI 用量后，这里会显示 Token、估算花费和模型明细。账户余额可在额度页查看。"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .usageCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh() }
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedDate.map { $0.formatted(.dateTime.month().day().locale(L10n.locale)) } ?? period.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if selectedDate != nil {
                    Button(L10n.t("Clear", "取消选择")) { selectedDate = nil }.font(.caption)
                }
            }
            if providers.isEmpty {
                Text(L10n.t("No reading for this period", "此时间范围暂无读数"))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    total(QuotaFormat.compact(tokens), label: "Token")
                    total(model.readings.money.format(usd), label: estimated
                          ? L10n.t("Estimated cost", "估算花费") : L10n.t("Cost", "花费"))
                }
                Text(L10n.t("\(providers.count) services reporting", "\(providers.count) 个服务提供读数"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .usageCard()
    }

    private func total(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("Last 30 days", "近 30 天趋势")).font(.subheadline.weight(.semibold))
                Spacer()
                Picker(L10n.t("Metric", "指标"), selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 140)
            }
            Chart {
                ForEach(days) { day in
                    ForEach(day.providers) { provider in
                        BarMark(x: .value("Day", day.date, unit: .day),
                                y: .value(metric.title, metric == .tokens ? Double(provider.tokens) : provider.usd))
                            .foregroundStyle(Color(hex: provider.id.accentHex))
                            .opacity(selectedDay == nil || selectedDay?.date == day.date ? 1 : 0.35)
                            .cornerRadius(2)
                    }
                }
                if let selectedDay {
                    RuleMark(x: .value("Day", selectedDay.date, unit: .day))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .frame(height: 150)
            Text(L10n.t("Touch the chart to inspect a day", "轻点或拖动图表查看当天用量"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .usageCard()
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("Services and models", "服务与模型")).font(.subheadline.weight(.semibold))
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProviderMark(id: provider.id, size: 20)
                        Text(model.readings.item(for: provider.id)?.displayName ?? provider.id.displayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(model.readings.money.format(provider.usd)).font(.subheadline.monospacedDigit())
                    }
                    HStack {
                        Text("\(QuotaFormat.compact(provider.tokens)) tokens")
                        Spacer()
                        if usd > 0 { Text("\(Int((provider.usd / usd * 100).rounded()))%") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let item = model.readings.item(for: provider.id) {
                        if let error = item.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if item.deviceUpdatedAt.addingTimeInterval(CloudFreshness.quietAfter) < Date() {
                            Text(L10n.t("This service's Mac has stopped syncing", "此服务所在的 Mac 已停止同步"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    ForEach(provider.models.sorted { $0.usd > $1.usd }) { value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(value.name).lineLimit(2)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(model.readings.money.format(value.usd))
                                Text("\(QuotaFormat.compact(value.tokens)) tokens").foregroundStyle(.tertiary)
                            }
                            .monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if provider.models.isEmpty {
                        Text(L10n.t("Model details unavailable for this period", "此时间范围没有模型明细"))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if provider.id != providers.last?.id { Divider().overlay(Color.white.opacity(0.06)) }
            }
        }
        .usageCard()
    }
}

private extension View {
    func usageCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
