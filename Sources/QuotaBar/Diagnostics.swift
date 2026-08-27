import AppKit
import Foundation
import QuotaCore

/// `QuotaBar --cost` — prints the real cost estimate as text.
///
/// The panel shows these numbers inside a chart; when they look wrong, this is
/// how you see the underlying figures (including how many duplicate rows were
/// discarded) without attaching a debugger to a menu-bar agent.
enum Diagnostics {
    /// `QuotaBar --windows` — dumps every window each enabled provider
    /// reports, with its length. Used to decide what a multi-meter menu-bar
    /// glyph should actually show.
    ///
    /// Terminates from inside the task rather than blocking the main thread;
    /// blocking in `applicationDidFinishLaunching` deadlocks the SwiftUI app.
    static func printWindows() {
        Task { @MainActor in
            let config = ConfigStore.shared
            for id in config.enabledProviders {
                var out = "\n\(id.displayName)\n"
                do {
                    let snapshot = try await ProviderRegistry.make(id).fetch(config: config)
                    if let plan = snapshot.planName { out += "  plan: \(plan)\n" }
                    if let credits = snapshot.resetCredits {
                        out += "  resetCredits: \(credits.available)\n"
                    }
                    for window in snapshot.windows {
                        let length = window.windowSeconds.map { "\($0)s = \(WindowTitle.short($0) ?? "?")" }
                            ?? "(no fixed length)"
                        let percent = window.usedPercent.map { String(format: "%.0f%%", $0) } ?? "-"
                        out += "  [\(length)] \(percent)"
                        if let scope = window.scope { out += "  scope=\(scope)" }
                        if window.isActive { out += "  ACTIVE" }
                        out += "  — \(window.title)\n"
                    }
                } catch {
                    out += "  失败: \(error.localizedDescription)\n"
                }
                FileHandle.standardOutput.write(Data(out.utf8))
            }
            NSApp.terminate(nil)
        }
    }

    static func printCost() {
        let started = Date()
        let cost = CostEstimator.summary()
        let elapsed = Date().timeIntervalSince(started)

        var out = ""
        out += "Scanned in \(String(format: "%.2f", elapsed))s\n"
        out += "Today    \(QuotaFormat.usd(cost.todayUSD))  ·  \(QuotaFormat.compact(cost.todayTokens)) tokens\n"
        out += "30 days  \(QuotaFormat.usd(cost.windowUSD))  ·  \(QuotaFormat.compact(cost.windowTokens)) tokens\n"
        out += "Top model: \(cost.topModel ?? "—")\n"
        out += "Duplicate rows discarded: \(cost.deduplicated)\n"
        for (source, amount) in cost.windowBySource.sorted(by: { $0.value > $1.value }) {
            out += "  \(source.displayName): \(QuotaFormat.usd(amount))\n"
        }
        if let peak = cost.peakDay {
            out += "Peak: \(QuotaFormat.shortDay(peak.day)) \(QuotaFormat.usd(peak.usd))\n"
        }
        out += "\nDaily:\n"
        let scale = cost.daily.map(\.usd).max() ?? 1
        for day in cost.daily {
            let width = scale > 0 ? Int((day.usd / scale * 40).rounded()) : 0
            out += String(
                format: "  %@  %9@  %@\n",
                QuotaFormat.shortDay(day.day),
                QuotaFormat.usd(day.usd) as NSString,
                String(repeating: "█", count: width))
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}
