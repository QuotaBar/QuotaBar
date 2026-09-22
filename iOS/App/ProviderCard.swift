import QuotaModel
import SwiftUI

/// One provider: its mark and plan, then every window the Mac shows, each
/// with what is left, a stepped bar in the usage ramp and the time to its
/// reset. Today's spend sits at the top right when the Mac has it; the rest
/// is a tap away, in the detail.
struct ProviderCard: View {
    let item: MergedReadings.Item
    let money: CloudMoney
    /// Shown on the card only when something is wrong; the detail always
    /// says it.
    var status: ServiceStatus?
    /// Drawn into an image: no chevron, and the time frozen at the moment
    /// of the copy — an image renderer draws no timeline.
    var still: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProviderMark(id: item.provider, size: 22)
                Text(item.provider.displayName)
                    .font(.headline)
                if let chip = item.snapshot?.chipLabel {
                    PlanChip(text: chip)
                }
                Spacer(minLength: 0)
                if let today = item.spend?.period("today"), !today.isEmpty {
                    Text(L10n.t("Today \(money.format(today.usd))", "今日 \(money.format(today.usd))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if still == nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if let status, !status.level.isHealthy {
                HStack(spacing: 6) {
                    StatusBadge(level: status.level)
                    Text(status.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let error = item.error {
                // The figures below, if any, are from before this failure.
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let snapshot = item.snapshot {
                ForEach(snapshot.windows.filter { $0.usedPercent != nil && !$0.extra }) { window in
                    WindowRow(window: window, pace: .whenItMatters, still: still)
                }
                if let balance = snapshot.balance, !balance.balances.isEmpty {
                    Text(balance.balanceLine)
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            } else if item.error == nil {
                Text(L10n.t("No reading yet", "暂无读数"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PlanChip: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.1), in: Capsule())
    }
}

/// One window: badge and name, what is left, the stepped bar, then when it
/// resets and — as on the Mac — where the current pace lands.
struct WindowRow: View {
    enum Pace {
        /// Only when it is close or over, as the Mac's card does by default.
        case whenItMatters
        /// Always, in the detail.
        case always
    }

    let window: UsageWindow
    var pace: Pace = .whenItMatters
    /// A fixed moment instead of a ticking clock, for a copied image.
    var still: Date?
    @AppStorage(MeterPreference.key, store: MeterPreference.store) private var mode: MeterMode = .remaining

    var body: some View {
        if let still {
            row(at: still)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in row(at: context.date) }
        }
    }

    private func row(at date: Date) -> some View {
        let reset = window.hasReset(now: date)
        let used = window.usedNow(at: date) ?? 0
        return Group {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let badge = window.shortLabel {
                        Text(badge)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(window.scope ?? window.label ?? (window.shortLabel == nil ? window.title : ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(figure(used))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.usage(used))
                        .contentTransition(.numericText())
                }
                // The colour stays keyed off what is used; only the length
                // and the figure follow the mode.
                SteppedMeter(fill: mode.shownPercent(fromUsed: used), tint: Color.usage(used))
                HStack(spacing: 8) {
                    if reset {
                        // The Mac has not read it since: the figure is the
                        // window's fresh start, not a reading.
                        Text(L10n.t("Reset — waiting for your Mac to confirm", "已重置，等待 Mac 确认"))
                            .foregroundStyle(.secondary)
                    } else if let resetsAt = window.resetsAt {
                        Text(QuotaFormat.resetLabel(to: resetsAt, from: date))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !reset { PaceNote(window: window, date: date, mode: pace, meter: mode) }
                }
                .font(.caption)
            }
        }
    }

    private func figure(_ used: Double) -> String {
        let shown = Int(mode.shownPercent(fromUsed: used).rounded())
        return switch mode {
        case .remaining: L10n.t("\(shown)% left", "剩 \(shown)%")
        case .used: L10n.t("\(shown)% used", "已用 \(shown)%")
        }
    }
}

/// Where the current burn rate lands at reset — the Mac's pace note, in the
/// same words.
private struct PaceNote: View {
    let window: UsageWindow
    let date: Date
    let mode: WindowRow.Pace
    let meter: MeterMode

    var body: some View {
        if let pace = window.pace(now: date) {
            switch pace.verdict {
            case .spent:
                flame(L10n.t("Limit reached", "已到上限"))
            case .over:
                if let seconds = pace.runOutSeconds {
                    let when = QuotaFormat.countdown(to: date.addingTimeInterval(seconds), from: date)
                    flame(L10n.t("Runs out in \(when)", "按当前速度 \(when)后用完"))
                } else {
                    flame(L10n.t("Runs out before the reset", "会在重置前用完"))
                }
            case .close:
                Text(atReset(pace.projectedPercent, floor: true))
                    .foregroundStyle(Color(hex: "F5A524"))
            case .ahead:
                if mode == .always {
                    Text(atReset(pace.projectedPercent, floor: false))
                        .foregroundStyle(.tertiary)
                }
            case nil:
                EmptyView()
            }
        }
    }

    /// The projection in the row's own terms. A close call never reads as
    /// nothing left, or as all of it used.
    private func atReset(_ projected: Double, floor: Bool) -> String {
        let used = floor ? min(projected, 99) : projected
        let shown = Int(meter.shownPercent(fromUsed: used).rounded())
        return switch meter {
        case .remaining: L10n.t("~\(shown)% left at reset", "预计重置时剩 \(shown)%")
        case .used: L10n.t("~\(shown)% used at reset", "预计重置时已用 \(shown)%")
        }
    }

    private func flame(_ text: String) -> some View {
        Label(text, systemImage: "flame.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(hex: UsageRamp.hex(used: 100)))
    }
}
