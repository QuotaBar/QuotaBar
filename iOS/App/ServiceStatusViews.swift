import QuotaModel
import SwiftUI

/// The Mac's `ServiceStatusBadge`: a dot in the band's colour and the band's
/// short name — "服务正常", not the page's sentence.
struct StatusBadge: View {
    let level: ServiceStatusLevel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: level.colorHex))
                .frame(width: 7, height: 7)
            Text(level.displayName)
                .font(.caption)
                .foregroundStyle(level.isHealthy ? Color.secondary : Color(hex: level.colorHex))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A day per tick, oldest on the left, in the day's band colour — the
/// Mac's strip. A clean day is the green the quota bars start from.
struct UptimeStrip: View {
    let days: [UptimeDay]
    var height: CGFloat = 14
    private let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, (proxy.size.width - gap * CGFloat(days.count - 1)) / CGFloat(max(days.count, 1)))
            HStack(spacing: gap) {
                ForEach(days.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(days[index].level == .operational
                            ? Color(hex: UsageRamp.hex(used: 0))
                            : Color(hex: days[index].level.colorHex))
                        .frame(width: width)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(L10n.t(
            "\(String(format: "%.2f", UptimeDay.uptimePercent(days)))% uptime over \(days.count) days",
            "\(days.count) 天可用率 \(String(format: "%.2f", UptimeDay.uptimePercent(days)))%"))
    }
}

/// The detail page's status card: the band and the page's own words, the
/// provider's own service over 30 days, every component the page lists
/// with its strip, and incidents elsewhere on the page. Read by the phone
/// from the public page — nothing to open in a browser.
struct StatusSection: View {
    let status: ServiceStatus
    let uptime: [String: [UptimeDay]]
    let provider: ProviderID

    private var primary: ServiceComponent? {
        StatusPages.primaryComponent(for: provider, in: status.components)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    StatusBadge(level: status.level)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(L10n.t(
                            "checked \(QuotaFormat.age(of: status.checkedAt, now: context.date))",
                            "\(QuotaFormat.age(of: status.checkedAt, now: context.date))检查"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !status.level.isHealthy || status.description != status.level.displayName {
                    Text(status.description)
                        .font(.subheadline)
                        .foregroundStyle(status.level.isHealthy ? Color.secondary : Color.primary)
                }
            }

            if let primary, let days = uptime[primary.id], !days.isEmpty {
                let recent = Array(days.suffix(30))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("Last 30 days", "近 30 天"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f%%", UptimeDay.uptimePercent(recent)))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                    UptimeStrip(days: recent, height: 22)
                }
            }

            if !status.components.isEmpty {
                VStack(spacing: 12) {
                    ForEach(status.components) { component in
                        ComponentRow(component: component, days: uptime[component.id])
                    }
                }
            }

            if !status.elsewhere.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Elsewhere on the page", "页面上的其他事件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(status.elsewhere, id: \.self) { incident in
                        Label(incident, systemImage: "exclamationmark.circle")
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// One component: its name and band, then its last 30 days.
private struct ComponentRow: View {
    let component: ServiceComponent
    let days: [UptimeDay]?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(component.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let days, !days.isEmpty {
                    Text(String(format: "%.2f%%", UptimeDay.uptimePercent(Array(days.suffix(30)))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                StatusBadge(level: component.level)
            }
            if let days, !days.isEmpty {
                UptimeStrip(days: Array(days.suffix(30)), height: 10)
            }
        }
    }
}

/// The service status, over the detail page rather than on it, with a
/// cross to close. Reads the page again as it opens, so what it says is
/// current, and loads every component's days.
struct StatusSheet: View {
    let model: ReadingsModel
    let provider: ProviderID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let status = model.status[provider] {
                        StatusSection(status: status, uptime: model.uptime, provider: provider)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle(L10n.t("\(provider.displayName) status", "\(provider.displayName) 服务状态"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.t("Close", "关闭"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task {
            await model.refreshStatus(only: provider)
            await model.loadUptime(for: provider)
        }
    }
}

