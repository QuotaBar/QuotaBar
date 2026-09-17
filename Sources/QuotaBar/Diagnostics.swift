import AppKit
import ObjectiveC
import SwiftUI
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
    /// Opens the settings pane in a real window: `QuotaBar --settings-window`.
    ///
    /// `--settings-preview` shows layout but never material: glass and vibrancy
    /// are composited by the window server, so they exist only on screen. This
    /// is how you look at them without clicking through the menu bar, and it is
    /// also the only way to see the AppKit controls the renderer replaces with
    /// yellow placeholders.
    /// Held for the process lifetime. A local `NSWindow` has no owner under ARC
    /// — `makeKeyAndOrderFront` does not retain it — so without this the window
    /// is deallocated before it ever draws, and the app looks like it ignored
    /// the flag.
    @MainActor private static var debugWindow: NSWindow?

    @MainActor
    static func settingsWindow(section: SettingsSection = .providers, expanded: ProviderID? = nil) {
        // After SwiftUI has finished building its scenes. Creating the window
        // from inside `applicationDidFinishLaunching` gets it ordered out again
        // as the MenuBarExtra scene comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { build(section: section, expanded: expanded) }
    }

    @MainActor
    private static func build(section: SettingsSection, expanded: ProviderID?) {
        // `QUOTABAR_OFFSCREEN=1`: for a website screenshot (`screencapture -l`)
        // while someone is using the Mac — placed past the left edge of every
        // screen and never activated, so it neither shows up nor takes focus.
        let offscreen = ProcessInfo.processInfo.environment["QUOTABAR_OFFSCREEN"] == "1"
        // An accessory app is never activated as a side effect, and this one
        // wants to be looked at.
        if !offscreen { NSApp.setActivationPolicy(.regular) }
        if offscreen { CaptureWindow.answerActive() }
        let windowClass: NSWindow.Type = offscreen ? CaptureWindow.self : NSWindow.self
        let window = windowClass.init(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        let store = UsageStore()
        // `QUOTABAR_LANG=en|zh` picks the interface language for the shot, after
        // the store has applied the saved one.
        switch ProcessInfo.processInfo.environment["QUOTABAR_LANG"] {
        case "en": L10n.override = .en
        case "zh": L10n.override = .zhHans
        default: break
        }
        if offscreen {
            // Never key, so SwiftUI would draw inactive (grey) switches; the shot
            // is of the window in use.
            window.contentView = NSHostingView(rootView: SettingsView(store: store, section: section, expanded: expanded)
                .environment(\.controlActiveState, .key))
        } else {
            window.contentView = NSHostingView(rootView: SettingsView(store: store, section: section, expanded: expanded))
        }
        window.isReleasedWhenClosed = false
        // Floating, because the point of this flag is to look at the window:
        // activating an accessory process does not reliably outrank whatever
        // app happened to be frontmost.
        window.level = .floating
        // Not `center()` — it picks whichever screen is "main", which on a
        // multi-display Mac is routinely not the one you are looking at.
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2))
        }
        debugWindow = window
        if offscreen {
            paintTrafficLights(in: window)
            let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
            window.level = .normal
            window.setFrameOrigin(NSPoint(x: left - window.frame.width - 4000, y: 0))
            window.orderFrontRegardless()
            FileHandle.standardOutput.write(Data("settings window number: \(window.windowNumber)\n".utf8))
            return
        }
        window.makeKeyAndOrderFront(nil)
        // Same ordering rule as `SettingsWindow.focus()`: activating before the
        // window is on screen does nothing.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        FileHandle.standardOutput.write(Data("settings window: \(window.frame)\n".utf8))
    }

    /// The close, minimise and zoom buttons draw grey in a window that is not
    /// key, and this one never is: the same three dots in their active colours,
    /// where the buttons are.
    @MainActor
    private static func paintTrafficLights(in window: NSWindow) {
        let colours: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)),
        ]
        for (type, colour) in colours {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            let dot = NSView(frame: button.frame.insetBy(dx: (button.frame.width - 12) / 2, dy: (button.frame.height - 12) / 2))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = colour.cgColor
            dot.layer?.cornerRadius = 6
            dot.layer?.borderWidth = 0.5
            dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            button.isHidden = true
            parent.addSubview(dot)
        }
    }

    /// Draws as the frontmost window without ever being made key, for the
    /// off-screen website shot.
    private final class CaptureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }

        /// Controls ask the window whether to draw in their active colours
        /// through AppKit's own `_hasActiveAppearance…`; answered yes here,
        /// looked up by name so nothing else in the app depends on them.
        static func answerActive() {
            let always: @convention(block) (AnyObject) -> Bool = { _ in true }
            for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "_hasKeyAppearance", "_hasMainAppearance"] {
                let selector = NSSelectorFromString(name)
                guard class_getInstanceMethod(NSWindow.self, selector) != nil else { continue }
                class_addMethod(CaptureWindow.self, selector, imp_implementationWithBlock(always), "B@:")
            }
        }
    }

    static func printWindows() {
        Task { @MainActor in
            let config = ConfigStore.shared
            for id in config.enabledProviders {
                var out = "\n\(id.displayName)\n"
                do {
                    let snapshot = try await ProviderRegistry.make(id).fetch(config: config)
                    if let plan = snapshot.planName { out += "  plan: \(plan)\n" }
                    if let source = snapshot.sourceLabel { out += "  source: \(source)\(snapshot.editionLabel.map { " · \($0)" } ?? "")\n" }
                    if let credits = snapshot.resetCredits {
                        out += "  resetCredits: \(credits.available) available, \(credits.totalEarned.map(String.init) ?? "?") given\n"
                        for credit in credits.credits {
                            out += "    \(credit.title ?? "(untitled)") expires \(credit.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")\n"
                        }
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

    /// `--ledger`: the year-to-date ledger behind the usage pane, with the
    /// scan time — the first read of a big log tree is the number to watch.
    static func printLedger() {
        let started = Date()
        let ledger = CostEstimator.ledger()
        let elapsed = Date().timeIntervalSince(started)
        var out = "Scanned \(ledger.year) in \(String(format: "%.2f", elapsed))s\n"
        out += "Year     \(QuotaFormat.compact(ledger.total())) tokens over \(ledger.activeDays()) active days"
        out += "  (\(ledger.deduplicated) duplicates dropped)\n"
        for period in LedgerPeriod.allCases {
            let sum = ledger.sum(period)
            out += String(format: "%-8@ %@ tokens  %@  in %@ out %@ cache-read %@ cache-write %@\n",
                          period.rawValue as NSString,
                          QuotaFormat.compact(sum.tokens) as NSString,
                          QuotaFormat.usd(sum.usd) as NSString,
                          QuotaFormat.compact(sum.input) as NSString,
                          QuotaFormat.compact(sum.output) as NSString,
                          QuotaFormat.compact(sum.cacheRead) as NSString,
                          QuotaFormat.compact(sum.cacheWrite) as NSString)
        }
        for item in ledger.sources {
            out += "  \(item.source.displayName): \(QuotaFormat.compact(item.tokens)) tokens, "
            out += "\(ledger.activeDays(.source(item.source))) active days\n"
        }
        for item in ledger.models().prefix(10) {
            out += "    \(item.model) [\(item.source.displayName)]: \(QuotaFormat.compact(item.tokens))\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// Where each automatic session came from, and for Claude, by which of
    /// the two reads. Never the secret.
    static func printCredentials() {
        var out = ""
        let claude = LocalCredentials.claudeCredentialState()
        let route = LocalCredentials.claudeCredentialRoute().rawValue
        let plan = LocalCredentials.claudePlanName().map { " · \($0)" } ?? ""
        out += "Claude   \(claude)\(plan)  (via \(route))\n"
        out += "Codex    \(LocalCredentials.codexAuth() == nil ? "missing" : "available")\n"
        out += "Gemini   \(LocalCredentials.geminiAccessToken() == nil ? "missing" : "available")\n"
        func kimiLine(_ state: String, _ kimi: LocalCredentials.KimiCodeSession) -> String {
            let expiry = kimi.expiresAt.map { date -> String in
                let seconds = Int(date.timeIntervalSinceNow)
                return seconds > 0 ? "\(seconds / 60)m \(seconds % 60)s left" : "\(-seconds / 60)m ago"
            } ?? "no expiry"
            let mode = kimi.isLegacy ? "older Python CLI sign-in (~/.kimi)" : "Kimi Code sign-in"
            return "Kimi     \(state) (\(expiry)) · \(mode) · \(kimi.edition.rawValue) edition · \(kimi.fileName) → \(kimi.baseURL.host ?? "")\n"
        }
        if let kimi = LocalCredentials.kimiCodeSession() {
            out += kimiLine(kimi.isExpired() ? "expired" : "available", kimi)
            // Read only: says whether a read would renew, and never renews.
            let renewable: String
            switch KimiCodeRenewal.renewability(of: kimi) {
            case .renewable: renewable = "yes"
            case let .readOnly(reason): renewable = "no (\(reason))"
            }
            out += "         renewable by QuotaBar: \(renewable)\n"
        } else if let ended = LocalCredentials.kimiCodeSessions().first {
            out += kimiLine("signed out, cannot be renewed", ended)
        } else {
            out += "Kimi     missing\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// Every status page as the badges read it: the band, what it follows,
    /// and what the rest of the page is reporting.
    static func printStatus() {
        let semaphore = DispatchSemaphore(value: 0)
        let box = StatusBox()
        Task.detached {
            for id in StatusPages.supported {
                box.lines.append((id, await StatusPages.fetch(id)))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 60)
        var out = ""
        for (id, status) in box.lines {
            guard let status else { out += "\(id.displayName.padding(toLength: 10, withPad: " ", startingAt: 0)) unreadable\n"; continue }
            out += "\(id.displayName.padding(toLength: 10, withPad: " ", startingAt: 0)) \(status.level.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(status.description)\n"
            if !status.focus.isEmpty { out += "           follows: \(status.focus.joined(separator: ", "))\n" }
            for incident in status.elsewhere { out += "           elsewhere: \(incident)\n" }
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    private final class StatusBox: @unchecked Sendable {
        var lines: [(ProviderID, ServiceStatus?)] = []
    }

    /// Cached readings under five minutes old are used as they are; older
    /// ones, missing ones, or all of them with `force`, are fetched first.
    static func printLimitsJSON(force: Bool) {
        let config = ConfigStore.shared
        let box = LimitsBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: (ProviderID, UsageSnapshot?, String?).self) { group in
                for id in config.enabledProviders {
                    group.addTask {
                        let cached = SnapshotCache.shared.snapshot(for: id)
                        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < 300 {
                            return (id, cached, nil)
                        }
                        do {
                            let fresh = try await ProviderRegistry.make(id).fetch(config: config)
                            SnapshotCache.shared.store(fresh, for: id)
                            return (id, fresh, nil)
                        } catch {
                            return (id, cached, error.localizedDescription)
                        }
                    }
                }
                for await item in group { box.append(item) }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 45)
        let order = config.enabledProviders
        let items = box.items.sorted { (order.firstIndex(of: $0.0) ?? 0) < (order.firstIndex(of: $1.0) ?? 0) }
        let data = LimitsJSON.make(providers: items.map { (id: $0.0, snapshot: $0.1, error: $0.2) })
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private final class LimitsBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [(ProviderID, UsageSnapshot?, String?)] = []
        func append(_ item: (ProviderID, UsageSnapshot?, String?)) { lock.withLock { items.append(item) } }
    }

    /// How long the archive path takes: loading it, deriving the figures
    /// from it, and the incremental scan that keeps it current.
    static func printArchiveTiming() {
        func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }
        var out = ""
        var t = Date()
        let store = UsageArchiveStore()
        let archive = store.current
        out += "Load archive (\(archive.days.count) days, full scan \(archive.fullScanDone)): \(ms(t))\n"
        t = Date()
        let summary = archive.costSummary()
        let ledger = archive.ledger()
        out += "Derive spend + year ledger: \(ms(t))  (today \(QuotaFormat.usd(summary.todayUSD)), year \(QuotaFormat.compact(ledger.total())) tokens)\n"
        t = Date()
        let updated = store.update()
        out += "Incremental scan since \(archive.incrementalCutoff().map { QuotaFormat.shortDay($0) } ?? "the beginning"): \(ms(t))  (today now \(QuotaFormat.usd(updated.costSummary().todayUSD)))\n"
        t = Date()
        _ = store.update()
        out += "Second incremental scan (parse cache warm): \(ms(t))\n"
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// `QuotaBar --projects [days]`: which project the last `days` of tokens
    /// went to, how each was driven, and how long the read took. Nothing is
    /// written; the paths shown never leave this Mac.
    static func printProjects(days: Int) {
        let start = Date()
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: now)) ?? now
        let scan = CostEstimator.archiveScan(since: cutoff, now: now)
        var archive = ProjectArchive()
        archive.merge(scan.projects, infos: scan.projectRefs, scannedAt: now, full: true)
        let overview = archive.overview(from: cutoff, to: now)
        var out = "Projects over \(days) days (read in \(String(format: "%.1f", Date().timeIntervalSince(start))) s): "
        out += "\(overview.projects.count) projects, \(QuotaFormat.usd(overview.usd)), \(QuotaFormat.compact(overview.tokens)) tokens, "
        out += "\(overview.sessions) sessions, \(overview.waysOfWorking) ways of working\n"
        for summary in overview.projects.prefix(25) {
            let sources = summary.sources.map { "\($0.source.displayName) \(QuotaFormat.usd($0.share.usd))" }.joined(separator: ", ")
            let modes = summary.modes.map { "\($0.mode.rawValue) \(QuotaFormat.compact($0.tokens))" }.joined(separator: ", ")
            out += "- \(summary.info.displayName) [\(summary.info.repo ?? summary.info.key)] \(QuotaFormat.usd(summary.usd)) · "
            out += "\(QuotaFormat.compact(summary.tokens)) tokens · \(summary.sessions) sessions · \(summary.activeMinutes) min · "
            out += "\(summary.activeDays) days\n    \(sources)\n    \(modes)\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// `QuotaBar --provider <id>`: one provider's reading, fetched now,
    /// whether or not it is enabled. Never the credential.
    static func printProvider(_ raw: String) {
        guard let id = ProviderID(rawValue: raw) else {
            FileHandle.standardError.write(Data("Unknown provider. One of: \(ProviderID.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
            return
        }
        let box = LimitsBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let provider = ProviderRegistry.make(id)
            let configured = provider.isConfigured(config: ConfigStore.shared)
            do {
                box.append((id, try await provider.fetch(config: ConfigStore.shared), configured ? nil : "not configured"))
            } catch {
                box.append((id, nil, error.localizedDescription))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 45)
        guard let item = box.items.first else { return }
        var out = "\(id.displayName)\n"
        if let snapshot = item.1 {
            out += "  plan: \(snapshot.planName ?? "—")\n"
            if let source = snapshot.sourceLabel { out += "  source: \(source)\(snapshot.editionLabel.map { " · \($0)" } ?? "")\n" }
            for window in snapshot.windows {
                let used = window.usedPercent.map { QuotaFormat.percent($0) + " used" } ?? "—"
                let reset = window.resetsAt.map { " · " + QuotaFormat.resetLabel(to: $0) } ?? ""
                out += "  \(window.title): \(used)\(window.detail.map { " · " + $0 } ?? "")\(reset)\n"
            }
            if let sheet = snapshot.balance {
                out += "  balance: \(sheet.balanceLine.isEmpty ? "—" : sheet.balanceLine)\(sheet.canCallAPI == false ? " · not enough for API calls" : "")\(sheet.estimated ? " · usage estimated" : "")\n"
                for period in KeyUsagePeriod.allCases {
                    let figures = sheet.usage[period]
                    let models = (figures?.models ?? []).prefix(3).map { "\($0.model) \(KeyUsageFigures(costs: $0.costs).costLine)" }.joined(separator: ", ")
                    let bars = sheet.chart[period].map { " · \($0.count) \(period.bucket.rawValue)s, \($0.filter { $0.costTotal > 0 }.count) with spend" } ?? ""
                    out += "  \(period.rawValue): \(figures.map { $0.costLine } ?? "—")\(figures?.requests.map { " · \($0) requests" } ?? "")\(bars)\(models.isEmpty ? "" : " · " + models)\n"
                }
                if let keys = sheet.keys {
                    out += "  keys: \(keys.count), active in 30 days: \(sheet.activeKeys(in: .last30).count)\n"
                    for key in sheet.activeKeys(in: .last30) {
                        let month = key.usage[.last30]
                        out += "    \(key.name) \(key.maskedKey ?? "")\(key.isDisabled ? " (deleted)" : ""): \(month?.costLine ?? "—") · \(month?.requests ?? 0) requests\n"
                    }
                }
                if let note = sheet.keysNote { out += "  note: \(note)\n" }
            }
        }
        if let error = item.2 { out += "  error: \(error)\n" }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    static func printCost() {
        // The panel refreshes this on its own cycle; the CLI has to ask.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await PricingCatalog.shared.refreshIfNeeded()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)

        let started = Date()
        let cost = CostEstimator.summary()
        let elapsed = Date().timeIntervalSince(started)

        var out = ""
        let catalog = PricingCatalog.shared
        out += "Pricing: \(catalog.isLoaded ? "\(catalog.modelCount) models from catalog" : "built-in table only")\n"
        out += "Scanned in \(String(format: "%.2f", elapsed))s\n"
        out += "Today    \(QuotaFormat.usd(cost.todayUSD))  ·  \(QuotaFormat.compact(cost.todayTokens)) tokens\n"
        out += "30 days  \(QuotaFormat.usd(cost.windowUSD))  ·  \(QuotaFormat.compact(cost.windowTokens)) tokens\n"
        out += "Top model: \(cost.topModel ?? "—")\n"
        for period in SpendPeriod.allCases {
            let spend = cost.spend(period)
            out += "\n[\(period.displayName(windowDays: cost.windowDays))] "
            out += "\(QuotaFormat.usd(spend.usd))  \(QuotaFormat.compact(spend.tokens)) tokens\n"
            for item in spend.contributions {
                let kind = item.source.isEstimated ? "估算" : "自报"
                out += "    \(item.source.displayName) (\(kind)): \(QuotaFormat.usd(item.usd))\n"
            }
        }
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
