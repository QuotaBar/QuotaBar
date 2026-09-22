import BackgroundTasks
import QuotaModel
import SwiftUI
import UIKit
import WidgetKit

@main
struct QuotaBarPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ReadingsModel()
    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-QuotaBarWidgetGallery") {
            WidgetGallery()
        } else {
            ContentView(model: model)
        }
        #else
        ContentView(model: model)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                // The Mac's figures are drawn on dark surfaces everywhere, and
                // the usage ramp's contrast is measured against black.
                .preferredColorScheme(.dark)
                // The Mac's neutral accent, not system blue: the provider
                // colours are the only hues on screen.
                .tint(Color(hex: QuotaTheme.accentDarkHex))
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.refresh() }
            case .background: BackgroundRefresh.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule()
            if case .success = await ReadingsSync.fetch() {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

/// A Mac's write wakes the app with a silent push (the CloudKit database
/// subscription). The system throttles these, so they are a bonus on top of
/// the widgets' own schedule, never the only way figures arrive.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        application.registerForRemoteNotifications()
        return true
    }

    /// The payload only says "something changed"; it is not read.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        Task {
            switch await ReadingsSync.fetch() {
            case .success:
                WidgetCenter.shared.reloadAllTimelines()
                completionHandler(.newData)
            case .failure:
                completionHandler(.failed)
            }
        }
    }
}

enum BackgroundRefresh {
    static let identifier = "bar.quota.QuotaBar.ios.refresh"

    /// Asks for a refresh in about fifteen minutes; the system decides when.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - What the screen shows

@MainActor
@Observable
final class ReadingsModel {
    private(set) var readings: MergedReadings
    private(set) var isRefreshing = false
    /// Why the last fetch failed; the readings on screen are then the cache's.
    private(set) var error: String?
    /// What each provider's public status page says, read by the phone
    /// itself: the pages need no sign-in, and a sleeping Mac should not
    /// leave an outage unreported.
    private(set) var status: [ProviderID: ServiceStatus] = [:]
    /// Where a "refresh now" sent to the Mac has got to.
    enum MacRefresh: Equatable {
        case idle
        case asking(since: Date)
        case done
        /// No Mac wrote within `RefreshRequestPolicy.phoneWaits`.
        case noAnswer
        case failed(String)
    }

    private(set) var macRefresh: MacRefresh = .idle
    private var clearTask: Task<Void, Never>?
    /// The optional Quota Run route, for a Mac on another iCloud account.
    let quotaRun = QuotaRunSession()

    /// Days per status-page component id, loaded as they are needed.
    private(set) var uptime: [String: [UptimeDay]] = [:]
    private var uptimeLoading: Set<String> = []

    /// Showing the sample readings rather than the Macs'.
    private(set) var isDemo = Demo.isOn

    init() {
        if Demo.isOn {
            // Into the cache too, so the widgets show the same sample.
            ReadingsCache.save(CloudReadings.samples)
            WidgetCenter.shared.reloadAllTimelines()
        }
        readings = ReadingsCache.merged
    }

    func start() async {
        guard !Demo.isOn else {
            await refresh()
            return
        }
        // Once is enough; saving the same subscription again is harmless.
        try? await ReadingsSync.store.subscribe()
        await refresh()
        #if DEBUG
        // `-QuotaBarAskMac`: press "refresh now" at launch, so the round trip
        // can be run on a device nobody is holding.
        if ProcessInfo.processInfo.arguments.contains("-QuotaBarAskMac") { await askMacToRefresh() }
        #endif
    }

    /// The samples, from the empty page's "查看示例".
    func showDemo() {
        Demo.set(true)
        isDemo = true
        ReadingsCache.save(CloudReadings.samples)
        readings = ReadingsCache.merged
        error = nil
        WidgetCenter.shared.reloadAllTimelines()
        Task { await refreshStatus() }
    }

    /// Back to the Macs' own readings: the samples leave the cache, so no
    /// widget goes on showing them.
    func endDemo() {
        Demo.set(false)
        isDemo = false
        ReadingsCache.save([])
        readings = ReadingsCache.merged
        WidgetCenter.shared.reloadAllTimelines()
        Task {
            // Started in demo mode, the subscription was never made.
            try? await ReadingsSync.store.subscribe()
            await refresh()
        }
    }

    /// A card dropped somewhere else in the list; the order is remembered
    /// and the overview widget follows it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = readings.items
        items.move(fromOffsets: source, toOffset: destination)
        readings.items = items
        CardOrder.save(items.map(\.provider))
        WidgetCenter.shared.reloadTimelines(ofKind: "overview")
    }

    /// Back to the Mac's order.
    func resetOrder() {
        CardOrder.reset()
        readings = ReadingsCache.merged
        WidgetCenter.shared.reloadTimelines(ofKind: "overview")
    }

    /// `statusPages: false` for the quiet re-reads while a Mac is still to
    /// allow this phone: the readings only.
    func refresh(statusPages: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // The status pages alongside, in demo mode as well: they are real.
        async let pages: Void = statusPages ? refreshStatus() : ()
        if !Demo.isOn {
            switch await ReadingsSync.fetch() {
            case let .success(fresh):
                readings = fresh
                error = nil
                WidgetCenter.shared.reloadAllTimelines()
            case let .failure(failure):
                // Signed out of Quota Run meanwhile: its Macs go too.
                readings = ReadingsCache.merged
                error = failure.localizedDescription
            }
            quotaRun.reload()
        }
        await pages
    }

    // MARK: Service status

    /// Every shown provider's page at once; a page that does not answer
    /// keeps what it said last rather than blanking the badge.
    func refreshStatus(only provider: ProviderID? = nil) async {
        let ids = (provider.map { [$0] } ?? readings.items.map(\.provider)).filter { StatusPages.page(for: $0) != nil }
        let fresh = await withTaskGroup(of: (ProviderID, ServiceStatus?).self) { group in
            for id in ids { group.addTask { (id, await StatusPages.fetch(id)) } }
            var out: [ProviderID: ServiceStatus] = [:]
            for await (id, reading) in group { if let reading { out[id] = reading } }
            return out
        }
        for (id, reading) in fresh {
            status[id] = reading
            // The provider's own service, which the card and the detail's
            // headline show; the rest load when the detail opens.
            if let primary = StatusPages.primaryComponent(for: id, in: reading.components) {
                uptime[primary.id] = nil
                await loadUptime(for: id, only: primary.id)
            }
        }
    }

    /// The days of every component the page lists, or of the one named.
    func loadUptime(for id: ProviderID, only component: String? = nil) async {
        guard let reading = status[id] else { return }
        let wanted = reading.components.filter {
            (component == nil || $0.id == component) && uptime[$0.id] == nil && !uptimeLoading.contains($0.id)
        }
        guard !wanted.isEmpty else { return }
        for item in wanted { uptimeLoading.insert(item.id) }
        await withTaskGroup(of: (String, [UptimeDay]?).self) { group in
            for item in wanted {
                group.addTask { (item.id, await StatusPages.uptime(for: id, component: item.id)) }
            }
            for await (componentID, days) in group {
                uptimeLoading.remove(componentID)
                if let days { uptime[componentID] = days }
            }
        }
    }

    // MARK: Asking the Mac

    /// Leaves a request for the Mac — in iCloud, and through quota.run when
    /// signed in there — then watches for its next write. The Mac looks
    /// every half minute, reads everything, and writes at once. A Mac that
    /// is asleep never answers, and the phone says so rather than spinning.
    func askMacToRefresh() async {
        if case .asking = macRefresh { return }
        clearTask?.cancel()
        let asked = Date()
        macRefresh = .asking(since: asked)
        if Demo.isOn {
            try? await Task.sleep(for: .seconds(2.5))
            finish(.done)
            return
        }
        // Both routes at once; either one reaching the Mac is enough, and
        // the Mac reads once for the pair.
        async let viaCloud: Error? = {
            do {
                try await ReadingsSync.store.requestRefresh(from: UIDevice.current.name, at: asked)
                return nil
            } catch {
                return error
            }
        }()
        async let viaRelay: Bool = {
            guard let (client, _, _) = QuotaRunStore.signedIn() else { return false }
            return (try? await client.requestRefresh()) != nil
        }()
        let (cloudError, relaySent) = await (viaCloud, viaRelay)
        if let cloudError, !relaySent {
            #if DEBUG
            Diagnostics.note(devices: [], error: cloudError, extra: "could not ask the Mac")
            #endif
            finish(.failed(cloudError.localizedDescription))
            return
        }
        #if DEBUG
        Diagnostics.note(devices: [], error: nil, extra: "asked the Mac at \(asked)")
        #endif
        let deadline = asked.addingTimeInterval(RefreshRequestPolicy.phoneWaits)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(4))
            guard case let .success(fresh) = await ReadingsSync.fetch() else { continue }
            readings = fresh
            if let updated = fresh.updatedAt, updated > asked {
                #if DEBUG
                Diagnostics.note(devices: [], error: nil, extra: "Mac answered \(updated.timeIntervalSince(asked))s after the request")
                #endif
                error = nil
                WidgetCenter.shared.reloadAllTimelines()
                finish(.done)
                await refreshStatus()
                return
            }
        }
        #if DEBUG
        Diagnostics.note(devices: [], error: nil, extra: "no answer from the Mac")
        #endif
        finish(.noAnswer)
    }

    /// Says how it went, then goes back to saying nothing.
    private func finish(_ outcome: MacRefresh) {
        macRefresh = outcome
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(outcome == .done ? 3 : 8))
            guard !Task.isCancelled else { return }
            self?.macRefresh = .idle
        }
    }
}

