import Foundation
import QuotaCloud
import QuotaModel

// MARK: - The Macs' readings, kept where the app and its widgets both see them

/// The last readings fetched from iCloud, in the app group's container. The
/// app writes it after every fetch and the widgets draw from it, so a widget
/// never waits on the network to show something — and a fetch that fails
/// leaves the last good readings in place rather than an empty widget.
enum ReadingsCache {
    static let appGroup = "group.bar.quota.QuotaBar"

    private struct File: Codable {
        var devices: [CloudReadings]
        var fetchedAt: Date
    }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("readings.json")
    }

    static func load() -> (devices: [CloudReadings], fetchedAt: Date?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(File.self, from: data)
        else { return ([], nil) }
        return (file.devices, file.fetchedAt)
    }

    static func save(_ devices: [CloudReadings], fetchedAt: Date = .now) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let url, let data = try? encoder.encode(File(devices: devices, fetchedAt: fetchedAt)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Both routes' Macs: iCloud's, and what came through quota.run. A Mac
    /// that sends both ways is one Mac — the newer copy stands.
    static var allDevices: [CloudReadings] {
        // The samples alone while they are on: nothing real mixed in.
        Demo.isOn ? load().devices : combine(load().devices, RelayCache.load().devices)
    }

    static func combine(_ cloud: [CloudReadings], _ relay: [CloudReadings]) -> [CloudReadings] {
        var newest: [String: CloudReadings] = [:]
        var order: [String] = []
        for device in cloud + relay {
            if let held = newest[device.deviceID] {
                if device.updatedAt > held.updatedAt { newest[device.deviceID] = device }
            } else {
                newest[device.deviceID] = device
                order.append(device.deviceID)
            }
        }
        return order.compactMap { newest[$0] }
    }

    /// In the order the owner dragged the cards into.
    static var merged: MergedReadings { MergedReadings(allDevices).ordered(by: CardOrder.saved) }
}

/// The card order the owner dragged into on the phone, kept in the app
/// group so the overview widget lists providers the same way. The Mac's own
/// order is untouched; a provider the saved order has not seen goes last.
enum CardOrder {
    private static let key = "cardOrder"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ReadingsCache.appGroup) }

    static var saved: [String] { defaults?.stringArray(forKey: key) ?? [] }

    static func save(_ providers: [ProviderID]) {
        defaults?.set(providers.map(\.rawValue), forKey: key)
    }

    static func reset() {
        defaults?.removeObject(forKey: key)
    }
}

/// Whether figures read as what is left or what is used — the Mac's meter
/// mode, chosen on the phone. Kept in the app group beside the card order.
enum MeterPreference {
    static let key = "meterMode"
    static let store = UserDefaults(suiteName: ReadingsCache.appGroup)
}

/// Fetches every Mac's readings into the cache: from iCloud, and through
/// quota.run when this phone is signed in there.
enum ReadingsSync {
    static let store = CloudReadingsStore()

    /// The fresh readings, or the error and whatever the cache still holds.
    /// One route failing is not a failure while the other answered: a phone
    /// on another iCloud account has nothing in its own.
    @discardableResult
    static func fetch() async -> Result<MergedReadings, Error> {
        // Showing the samples: a fetch would put the real (empty) readings
        // over them, in the app and in every widget.
        if Demo.isOn { return .success(ReadingsCache.merged) }
        async let cloud = fetchCloud()
        async let relay = fetchRelay()
        let (fromCloud, fromRelay) = await (cloud, relay)
        switch (fromCloud, fromRelay) {
        case let (.failure(error), .failure):
            return .failure(error)
        case let (.failure(error), .success(nil)):
            return .failure(error)
        default:
            return .success(ReadingsCache.merged)
        }
    }

    private static func fetchCloud() async -> Result<[CloudReadings], Error> {
        do {
            try await store.checkAccount()
            let devices = try await store.readAll()
            ReadingsCache.save(devices)
            #if DEBUG
            Diagnostics.note(devices: devices, error: nil)
            #endif
            return .success(devices)
        } catch {
            #if DEBUG
            Diagnostics.note(devices: nil, error: error)
            #endif
            return .failure(error)
        }
    }

    /// Nil inside when the phone is not signed in to Quota Run.
    private static func fetchRelay() async -> Result<[CloudReadings]?, Error> {
        do {
            return .success(try await RelaySync.fetch())
        } catch {
            return .failure(error)
        }
    }

    /// Like `fetch`, but gives up after `seconds` — a widget's timeline has
    /// only a few seconds before the system stops waiting for it.
    static func fetch(within seconds: Double) async -> MergedReadings {
        await withTaskGroup(of: MergedReadings?.self) { group in
            group.addTask { try? await fetch().get() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ReadingsCache.merged
        }
    }
}

#if DEBUG
/// The last fetch, in the app's own Documents: a device install can be
/// checked with `devicectl device copy from --domain-type appDataContainer`,
/// which cannot reach the app group. Debug builds only.
enum Diagnostics {
    static func note(devices: [CloudReadings]?, error: Error?, extra: String? = nil) {
        var lines = ["at \(Date())"]
        if let extra { lines.append(extra) }
        if let error { lines.append("error \(error.localizedDescription)") }
        for device in devices ?? [] {
            lines.append("\(device.deviceName) \(device.deviceModel ?? "-") updated \(device.updatedAt) providers \(device.providers.map(\.id))")
        }
        if devices?.isEmpty == true, extra == nil { lines.append("no records") }
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("last-fetch.txt"), atomically: true, encoding: .utf8)
    }
}
#endif

// MARK: - Sample readings

/// Launched with `-QuotaBarDemo`, the app shows these instead of iCloud's:
/// for the simulator, and for App Store screenshots.
/// Sample readings in place of the Macs': turned on from the empty page
/// ("查看示例") so anyone without QuotaBar for Mac — App Review included —
/// can see what the app does, or with `-QuotaBarDemo` for screenshots. Kept in
/// the app group so the widgets show the same samples and do not fetch over
/// them.
enum Demo {
    private static let key = "demoMode"

    static var isOn: Bool {
        isForScreenshots || (UserDefaults(suiteName: ReadingsCache.appGroup)?.bool(forKey: key) ?? false)
    }

    /// Launched with `-QuotaBarDemo`: the samples without the banner that
    /// says they are samples, for App Store screenshots.
    static var isForScreenshots: Bool { ProcessInfo.processInfo.arguments.contains("-QuotaBarDemo") }

    static func set(_ on: Bool) {
        UserDefaults(suiteName: ReadingsCache.appGroup)?.set(on, forKey: key)
    }
}

extension CloudReadings {
    /// For the widget gallery and placeholders.
    static var sample: CloudReadings {
        let now = Date()
        func snapshot(
            _ plan: String, _ short: Double, _ long: Double, credits: ResetCredits? = nil, more: [UsageWindow] = []) -> UsageSnapshot
        {
            UsageSnapshot(planName: plan, account: "you@example.com", windows: [
                UsageWindow(title: "5h", usedPercent: short, resetsAt: now.addingTimeInterval(2 * 3600), windowSeconds: 18_000),
                UsageWindow(title: "7d", usedPercent: long, resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 604_800),
            ] + more, fetchedAt: now, resetCredits: credits)
        }
        /// A month that climbs, with quieter weekends.
        func spend(_ scale: Double, models: [(String, Double)]) -> CloudSpend {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let trend = (0..<30).map { offset -> CloudSpend.Day in
                let day = calendar.date(byAdding: .day, value: offset - 29, to: today)!
                let weekend = calendar.isDateInWeekend(day) ? 0.35 : 1
                let tokens = Int(scale * weekend * (0.6 + 0.4 * Double(offset) / 29) * (0.8 + 0.4 * sin(Double(offset))))
                return CloudSpend.Day(day: day, usd: Double(tokens) / 250_000, tokens: tokens)
            }
            func period(_ id: String, _ days: ArraySlice<CloudSpend.Day>) -> CloudSpend.Period {
                let usd = days.reduce(0) { $0 + $1.usd }, tokens = days.reduce(0) { $0 + $1.tokens }
                return CloudSpend.Period(id: id, usd: usd, tokens: tokens, models: models.map {
                    CloudSpend.Model(name: $0.0, usd: usd * $0.1, tokens: Int(Double(tokens) * $0.1))
                })
            }
            return CloudSpend(
                periods: [period("today", trend.suffix(1)), period("yesterday", trend.dropLast().suffix(1)), period("window", trend[...])],
                windowDays: 30, trend: trend, estimated: true)
        }
        return CloudReadings(
            deviceID: "sample", deviceName: "MacBook Pro", deviceModel: "MacBook Pro (16-inch, M5 Max)",
            appVersion: "0.6.0", language: L10n.isChinese ? "zh" : "en",
            updatedAt: now, money: CloudMoney(currency: L10n.isChinese ? "CNY" : "USD", usdRate: 7.1), providers: [
                .init(
                    id: ProviderID.claude.rawValue,
                    // Claude's third limit, as the Mac reads it: the week for one model.
                    snapshot: snapshot("Max", 78, 64, more: [UsageWindow(
                        title: "7d Sonnet", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86_400),
                        windowSeconds: 604_800, scope: "Sonnet")]),
                    spend: spend(9_000_000, models: [("claude-opus-5-5", 0.72), ("claude-sonnet-5", 0.24), ("claude-haiku-4-5", 0.04)]),
                    links: CloudLinks(console: URL(string: "https://claude.ai/settings/usage"))),
                .init(
                    id: ProviderID.codex.rawValue,
                    snapshot: snapshot("Pro", 12, 48, credits: ResetCredits(
                        available: 2, applicable: 0,
                        credits: [ResetCredit(expiresAt: now.addingTimeInterval(5 * 86_400)), ResetCredit(expiresAt: now.addingTimeInterval(18 * 86_400))])),
                    spend: spend(6_000_000, models: [("gpt-5.6-sol", 0.9), ("gpt-5.6-mini", 0.1)]),
                    links: CloudLinks(console: URL(string: "https://chatgpt.com/codex/settings/usage"))),
            ])
    }

    /// Two Macs, as an owner with a laptop and a desk machine has them: the
    /// app lists both and says which reading came from which.
    static var samples: [CloudReadings] {
        let now = Date()
        func snapshot(_ plan: String, _ short: Double, _ long: Double) -> UsageSnapshot {
            UsageSnapshot(planName: plan, windows: [
                UsageWindow(title: "5h", usedPercent: short, resetsAt: now.addingTimeInterval(2 * 3600), windowSeconds: 18_000),
                UsageWindow(title: "7d", usedPercent: long, resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 604_800),
            ], fetchedAt: now.addingTimeInterval(-240))
        }
        let desk = CloudReadings(
            deviceID: "sample-mini", deviceName: "Mac mini", deviceModel: "Mac mini (2024)",
            appVersion: "0.6.0", language: L10n.isChinese ? "zh" : "en",
            updatedAt: now.addingTimeInterval(-240), providers: [
                .init(id: ProviderID.cursor.rawValue, snapshot: snapshot("Pro", 0, 22)),
                .init(id: ProviderID.gemini.rawValue, snapshot: snapshot("", 5, 93)),
            ])
        return [sample, desk]
    }
}

// MARK: - Which window a figure stands for

/// What a widget — or the app's headline — follows for a provider: the
/// fullest of the plan's own limits, or the fullest short or long one. The
/// Mac lets each place pick its own limit, and the phone's widgets do too.
enum WindowChoice: String, CaseIterable, Codable, Sendable {
    case automatic
    case short
    case long

    func window(in snapshot: UsageSnapshot) -> UsageWindow? {
        let own = snapshot.ownWindows
        func fullest(_ windows: [UsageWindow]) -> UsageWindow? {
            windows.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
        }
        switch self {
        case .automatic: return snapshot.headlineWindow
        case .short: return fullest(own.filter { $0.horizon == .short }) ?? snapshot.headlineWindow
        case .long: return fullest(own.filter { $0.horizon == .long }) ?? snapshot.headlineWindow
        }
    }
}

extension UsageWindow {
    /// The figure to draw now: a window past its reset is back at zero,
    /// whatever the Mac last read before it.
    func usedNow(at date: Date = .now) -> Double? {
        hasReset(now: date) ? 0 : usedPercent
    }
}
