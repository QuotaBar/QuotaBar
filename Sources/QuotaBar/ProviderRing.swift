import SwiftUI
import QuotaCore

/// One provider as a ring with its mark in the middle and the figure below.
///
/// The ring carries the reading and the alert colour at once; the logo says
/// which provider without a label, which is what makes a narrow vertical strip
/// possible at all.
struct ProviderRing: View {
    let id: ProviderID
    let percent: Double?
    let alerts: AlertSettings
    var diameter: CGFloat = 46
    var showsLabel: Bool = true
    /// Marks the provider the menu-bar glyph is reporting. Picking one is a
    /// single click in the dock; opening the panel is a double click, so
    /// choosing what the icon means does not also throw a window at you.
    var selected: Bool = false

    private var level: AlertLevel {
        alerts.level(for: percent ?? 0)
    }

    /// Green until the warning band, then the alert colour. A provider with no
    /// reading yet gets the neutral track only.
    private var tint: Color {
        guard percent != nil else { return .secondary }
        if let hex = level.hex { return Color(hex: hex) }
        return Color(hex: "34C759")
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 3)
                if let percent {
                    Circle()
                        .trim(from: 0, to: max(0.012, min(percent, 100) / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // Always-dark surface: force the mark light rather than
                // leaving it to resolve against the system appearance.
                ProviderGlyph(id: id, size: diameter * 0.42, tint: .white)
            }
            .frame(width: diameter, height: diameter)

            if showsLabel {
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .background {
            if selected {
                // Negative padding so the marker is larger than the cell
                // without changing its size — the dock computes its own height
                // from `cellHeight` and a taller cell would desync the panel.
                RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous)
                    .fill(Color.white.opacity(0.13))
                    .padding(.horizontal, -7)
                    .padding(.vertical, -5)
            }
        }
        .accessibilityLabel(percent.map {
            "\(id.displayName) \(QuotaFormat.percent($0))"
        } ?? id.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The bubble that appears beside a ring, with one row per quota window.
struct ProviderCallout: View {
    let id: ProviderID
    let phase: ProviderPhase?
    let alerts: AlertSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            HStack(spacing: Design.space2) {
                ProviderGlyph(id: id, size: 15, tint: .white)
                Text(L10n.t("\(id.displayName) usage", "\(id.displayName) 用量"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            content
        }
        .padding(Design.space3)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusCard + 2, style: .continuous)
                .fill(Color.black))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading, nil:
            Text(L10n.t("Loading…", "加载中…"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Color(hex: "FF9F0A"))
                .fixedSize(horizontal: false, vertical: true)
        case let .loaded(snapshot), let .stale(snapshot, _):
            if snapshot.windows.isEmpty {
                Text(L10n.t("No quota windows reported.", "服务商未返回额度窗口。"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                VStack(alignment: .leading, spacing: Design.space3) {
                    ForEach(snapshot.windows) { window in
                        row(window)
                    }
                }
            }
        }
    }

    /// Title and reset on one line, the meter under it, the figure below —
    /// the arrangement from the reference: nothing wraps, nothing competes.
    private func row(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.scope ?? window.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: Design.space2)
                if let resetsAt = window.resetsAt {
                    Text(QuotaFormat.resetLabel(to: resetsAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    if let percent = window.usedPercent {
                        Capsule()
                            .fill(meterTint(percent))
                            .frame(width: max(3, proxy.size.width * CGFloat(percent / 100)))
                    }
                }
            }
            .frame(height: 5)
            Text(window.usedPercent.map {
                L10n.t("\(QuotaFormat.percent($0)) used", "已用 \(QuotaFormat.percent($0))")
            } ?? (window.detail ?? "—"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func meterTint(_ percent: Double) -> Color {
        if let hex = alerts.level(for: percent).hex { return Color(hex: hex) }
        return Color(hex: "34C759")
    }
}
