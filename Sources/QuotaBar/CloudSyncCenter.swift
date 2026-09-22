import Foundation
import IOKit
import QuotaCloud
import QuotaCore
import SystemConfiguration

// MARK: - The readings, sent on to the iPhone

/// What the iPhone sync is doing, said in Settings.
enum CloudSyncStatus: Equatable {
    /// The owner has not turned it on.
    case off
    /// This build has no iCloud entitlement: a development or ad-hoc build.
    case unavailable
    /// On, and nothing written yet since launch.
    case starting
    case synced(Date)
    case failed(String)
}

/// Writes this Mac's readings to the owner's private iCloud for the iPhone
/// app. Off until the owner turns it on in Settings; once on, the store
/// hands it the readings after every refresh, and it writes when
/// `CloudSyncPolicy` says so — plus a heartbeat between refreshes, so the
/// phone can tell a quiet Mac from one that is asleep.
///
/// Its own object, like `RunCenter`, so the status line in Settings does not
/// redraw the menu-bar item.
@MainActor
final class CloudSyncCenter: ObservableObject {
    @Published private(set) var status: CloudSyncStatus = .off
    /// The last "refresh now" a phone sent and this Mac acted on.
    @Published private(set) var lastRequest: CloudRefreshRequest?

    /// Nil when this build cannot use iCloud or the centre is inert: nothing
    /// here may touch CloudKit then, or the process traps.
    private let cloud: CloudReadingsStore?
    private var readings: (() -> CloudReadings)?
    private var enabled = false
    private var last: (signature: CloudReadings.Signature, at: Date)?
    private var writing = false
    private var heartbeatTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    /// What a phone's request runs: the store's refresh of everything.
    private var refreshAll: (() -> Void)?
    private var lastHandled: Date?
    private var lastRequestedRefresh: Date?
    /// Set when a phone asked: the write after that refresh goes out even if
    /// nothing moved, since the phone is waiting to see this Mac answer.
    private var forceNextWrite = false

    init(inert: Bool = false) {
        cloud = !inert && CloudEntitlement.present ? CloudReadingsStore() : nil
    }

    var isAvailable: Bool { cloud != nil }

    /// Called once by the store with how to make the readings, and whether
    /// the owner has syncing on.
    func start(enabled: Bool, readings: @escaping () -> CloudReadings, refreshAll: @escaping () -> Void) {
        self.readings = readings
        self.refreshAll = refreshAll
        setEnabled(enabled)
    }

    func setEnabled(_ on: Bool) {
        let wasOn = enabled
        enabled = on
        heartbeatTask?.cancel()
        heartbeatTask = nil
        requestTask?.cancel()
        requestTask = nil
        guard let cloud else {
            status = on ? .unavailable : .off
            if on { CloudSyncLog.note("on, but this build has no iCloud entitlement") }
            return
        }
        guard on else {
            status = .off
            last = nil
            // Turned off: the Mac's record goes too, so the phone does not
            // keep showing figures that will never move again.
            if wasOn {
                Task {
                    // A write still out would land after the removal and
                    // put the record back.
                    while writing { try? await Task.sleep(for: .milliseconds(200)) }
                    guard !enabled else { return }
                    try? await cloud.remove(deviceID: CloudDevice.id)
                }
            }
            return
        }
        if !wasOn { status = .starting }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard !Task.isCancelled else { return }
                self?.writeIfDue()
            }
        }
        requestTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForRequest()
                try? await Task.sleep(for: .seconds(RefreshRequestPolicy.pollInterval))
            }
        }
        writeIfDue(force: !wasOn)
    }

    /// A phone's "refresh now": read everything, and write the moment the
    /// refresh lands. One small fetch every half minute while syncing is on.
    private func checkForRequest() async {
        guard enabled, let cloud else { return }
        let request: CloudRefreshRequest?
        do {
            request = try await cloud.latestRefreshRequest()
        } catch {
            CloudSyncLog.note("could not look for a refresh request: \(error)")
            return
        }
        guard let request else { return }
        let now = Date()
        guard RefreshRequestPolicy.shouldHonor(
            request, lastHandled: lastHandled, lastRequestedRefresh: lastRequestedRefresh, now: now)
        else {
            // Seen and passed over — too old, or too soon after the last —
            // is still handled: it is not looked at again.
            if lastHandled.map({ request.requestedAt > $0 }) ?? true {
                lastHandled = request.requestedAt
                CloudSyncLog.note("passed over the request from \(request.from) at \(request.requestedAt)")
            }
            return
        }
        lastHandled = request.requestedAt
        lastRequestedRefresh = now
        lastRequest = request
        forceNextWrite = true
        CloudSyncLog.note("refreshing for \(request.from), asked at \(request.requestedAt)")
        refreshAll?()
    }

    /// After every refresh.
    func afterRefresh() {
        writeIfDue(force: forceNextWrite)
    }

    /// Writes now, whatever the policy says: the button in Settings.
    func syncNow() {
        writeIfDue(force: true)
    }

    private func writeIfDue(force: Bool = false) {
        guard enabled, let cloud, let readings, !writing else { return }
        let current = readings()
        let signature = current.signature
        guard force || CloudSyncPolicy.shouldWrite(current: signature, last: last, now: current.updatedAt) else { return }
        writing = true
        Task {
            do {
                try await cloud.checkAccount()
                try await cloud.write(current)
                last = (signature, current.updatedAt)
                forceNextWrite = false
                if enabled { status = .synced(current.updatedAt) }
                // Read back what the database now holds, so the log says
                // whether this Mac's record is there for the phone to find.
                let seen = (try? await cloud.readAll())?.map(\.deviceName) ?? []
                CloudSyncLog.note("wrote \(current.providers.count) providers; the zone holds \(seen.count) Mac(s)")
            } catch {
                // `last` stays as it was, so the next refresh tries again.
                if enabled { status = .failed(error.localizedDescription) }
                CloudSyncLog.note("write failed: \(error)")
            }
            writing = false
        }
    }
}

// MARK: - What happened, for when it did not work

/// The last few hundred sync attempts, one line each, in Application
/// Support: what Settings shows is only the latest, and a failure that
/// came and went is otherwise gone. Nothing in it but outcomes and errors.
enum CloudSyncLog {
    private static let url = AppSupport.directory.appendingPathComponent("icloud-sync.log")
    private static let limit = 400

    static func note(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let old = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").suffix(limit - 1) ?? []
        let text = (old + ["\(stamp) \(line)"]).joined(separator: "\n") + "\n"
        AppSupport.write(Data(text.utf8), to: url)
    }
}

// MARK: - Which Mac this is

/// This Mac's id in iCloud: a random one, made once and kept in Application
/// Support. Not the hardware UUID — the record only needs to be told apart
/// from the owner's other Macs, not to name the machine.
enum CloudDevice {
    static let id: String = {
        let url = AppSupport.directory.appendingPathComponent("icloud-device-id")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty
        {
            return saved
        }
        let made = UUID().uuidString
        AppSupport.write(Data(made.utf8), to: url)
        return made
    }()

    /// "Studio", "MacBook Pro" — the name in System Settings › General › About.
    static var name: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// "MacBook Pro (16-inch, M5 Max)", "Mac mini (2024)". Apple silicon
    /// names itself in the device tree; an Intel Mac has no such node, and
    /// its model identifier ("Macmini8,1") gives the family instead.
    static let model: String? = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? Data,
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces)),
           !name.isEmpty
        {
            return name
        }
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return MacKind.displayName(forIdentifier: String(cString: buffer))
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension UsageStore {
    /// The readings as the Mac shows them — hidden windows left out — in the
    /// order of the enabled providers.
    func cloudReadings(now: Date = Date()) -> CloudReadings {
        CloudReadings(
            deviceID: CloudDevice.id,
            deviceName: CloudDevice.name,
            deviceModel: CloudDevice.model,
            appVersion: CloudDevice.appVersion,
            language: L10n.isChinese ? "zh" : "en",
            updatedAt: now,
            refreshSeconds: refreshMinutes * 60,
            money: CloudMoney(
                currency: experience.currency,
                usdRate: experience.currency == "USD" ? nil : CurrencyRates.shared.rate(for: experience.currency)),
            providers: enabled.map { id in
                CloudReadings.Entry(
                    id: id.rawValue, snapshot: states[id]?.snapshot, error: states[id]?.errorMessage,
                    spend: cloudSpend(for: id),
                    links: CloudLinks(console: dashboardURL(for: id)))
            })
    }

    /// What the card's arrow opens to on the Mac: spend per period with its
    /// models, and a month of days. Counted the way the owner counts tokens
    /// here, so the phone and the Mac agree.
    private func cloudSpend(for id: ProviderID) -> CloudSpend? {
        guard let source = id.costSource else { return nil }
        let counting = experience.tokenCounting
        let periods = SpendPeriod.allCases.map { period -> CloudSpend.Period in
            let spend = cost.spend(period)
            return CloudSpend.Period(
                id: period.rawValue,
                usd: spend.bySource[source] ?? 0,
                tokens: spend.tokens(from: source, counting),
                models: spend.models.filter { $0.source == source }.prefix(8).map {
                    CloudSpend.Model(name: $0.model, usd: $0.usd, tokens: counting == .all ? $0.tokens : $0.billableTokens)
                })
        }
        let trend = archive.trend(for: source, days: 30, counting: counting).map {
            CloudSpend.Day(day: $0.day, usd: $0.usd, tokens: $0.tokens)
        }
        let spend = CloudSpend(periods: periods, windowDays: cost.windowDays, trend: trend, estimated: source.isEstimated)
        return spend.isEmpty ? nil : spend
    }
}
