import SwiftUI
import AppKit
import Network
@preconcurrency import UserNotifications
import QuotaCore

enum ProviderPhase: Sendable {
    case loading
    case loaded(UsageSnapshot)
    /// Last refresh failed but we still have earlier numbers. Shown with a
    /// staleness badge — silently serving old data is how a user ends up
    /// trusting a figure from an expired session.
    case stale(UsageSnapshot, error: String)
    case failed(String)

    var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot), let .stale(snapshot, _): snapshot
        case .loading, .failed: nil
        }
    }

    var errorMessage: String? {
        switch self {
        case let .stale(_, error), let .failed(error): error
        case .loading, .loaded: nil
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var enabled: [ProviderID]
    @Published var states: [ProviderID: ProviderPhase] = [:]
    /// What the last quiet read of Claude Code's keychain item found. nil
    /// until the first one is back.
    @Published private(set) var claudeCredential: LocalCredentials.ClaudeCredentialState?
    /// Claude Code's session lives in another app's keychain item, and macOS
    /// wants the user's say-so before this app may read it. True while that
    /// is outstanding; the panel and the settings row show the button then.
    var claudeNeedsAuthorization: Bool { claudeCredential == .needsAuthorization }
    /// The item is there with its tokens blanked: Claude Code signed out on
    /// this Mac, and the settings row says so rather than "no sign-in found".
    var claudeSignedOut: Bool { claudeCredential == .signedOut }
    /// Persisted, because it decides what the menu-bar glyph reports — a
    /// choice that silently reverted on every launch would make the icon
    /// change meaning without the user doing anything.
    @Published var selected: ProviderID? {
        didSet {
            guard selected != oldValue else { return }
            config.selected = selected
        }
    }
    @Published var refreshMinutes: Int
    @Published var menuBarStyle: MenuBarStyle
    @Published var menuBarIconMode: MenuBarIconMode
    @Published var meterMode: MeterMode
    @Published var meterStyle: MeterStyle
    /// The notch island and the edge dock, each on its own switch.
    @Published var showsIsland: Bool
    @Published var showsDock: Bool
    @Published var alertSettings: AlertSettings
    @Published var language: L10n.Language
    @Published var cost: CostSummary = .empty
    /// True while the first scan is running. On a heavy log tree that is tens
    /// of seconds, and a blank space for that long reads as "this feature is
    /// broken" rather than "still working".
    @Published var isComputingCost = false
    /// The year-to-date ledger behind the usage pane. Built only once that
    /// pane has been opened — it walks the same log tree as `cost`, and
    /// someone who never looks at the grid should not pay for it — and then
    /// kept fresh on the refresh cycle alongside the spend summary.
    @Published var ledger: UsageLedger = .empty
    @Published var isComputingLedger = false
    /// How far an update has got. Checked once per launch — often enough for
    /// a tool people leave running, and it avoids hammering an unauthenticated
    /// API that rate-limits by IP.
    @Published var updateStage: Updater.Stage = .idle
    /// When the feed was last asked, so the pane can say "checked 3m ago"
    /// instead of leaving an idle stage to mean anything.
    @Published var lastUpdateCheck: Date?
    private var updatePollTask: Task<Void, Never>?
    /// Staged bundle, verified and waiting for the user to restart.
    private var stagedUpdate: URL?
    /// Each provider's windows as they were read before a language switch,
    /// until the reading in the new language arrives.
    private var renamingWindows: [ProviderID: [UsageWindow]] = [:]
    /// Each provider's last reading as it was handed back. `states` carries
    /// the same reading without the windows the owner hid; this keeps them
    /// for the card's menu, to show them again, and for the local API.
    private(set) var reported: [ProviderID: UsageSnapshot] = [:]
    /// The release the last check found, kept for a retry or a manual
    /// download after a failure, whose stage no longer carries it.
    private(set) var lastRelease: UpdateRelease?
    /// The version whose card has been shown this session.
    private var announcedUpdate: String?
    /// Install and Relaunch was clicked before the download finished.
    private var installWhenStaged = false
    var isInstallRequested: Bool { installWhenStaged }
    /// Recorded headline readings per provider, mirrored here so the detail
    /// sparkline redraws when a refresh lands.
    @Published var history: [ProviderID: [Double]] = [:]
    /// Bumped whenever a refresh completes so relative timestamps re-render.
    @Published var tick: Int = 0
    /// Providers whose credentials currently resolve. Computed off the main
    /// actor because `isConfigured` may reach into the keychain, which blocks
    /// while macOS asks the user to authorize access — never do that in a
    /// SwiftUI `body`.
    @Published var configured: Set<ProviderID> = []
    /// The configured providers that take a pasted credential but have none,
    /// so are answering from this Mac's own sign-in — the Kimi Code app,
    /// Cursor.app, the grok CLI. Settings says "Auto" for these, not "Keychain".
    @Published var signedInLocally: Set<ProviderID> = []
    /// For providers with more than one way in, which one the next refresh
    /// uses — "API key · Global (kimi.ai)" — and the console for it.
    @Published var sourceInfo: [ProviderID: ProviderSourceInfo] = [:]

    /// Latest reading of each provider's public status page, for the ones
    /// that have one. Absent until the page has answered once; a failed poll
    /// keeps the previous reading rather than blanking the chip.
    @Published var serviceStatus: [ProviderID: ServiceStatus] = [:]
    private var statusTask: Task<Void, Never>?
    /// 90-day histories by component id, fetched when a 服务状态 row opens.
    @Published var uptime: [String: [UptimeDay]] = [:]
    private var uptimeLoading: Set<String> = []

    // MARK: 0.5

    /// Everything 0.5 added to the preferences, mirrored for SwiftUI.
    @Published var experience: ExperiencePrefs
    /// Bumped when a preference a coordinator acts on changes — hotkey,
    /// local API, glow — so they re-read without watching every tick.
    @Published var experienceRevision = 0
    /// QuotaBar's own record of local token traffic, from the archive.
    @Published var archive: UsageArchive = UsageArchiveStore.shared.current
    /// The same tokens by project, from the project archive.
    @Published var projectArchive: ProjectArchive = UsageArchiveStore.shared.projects.current
    @Published var isUpdatingArchive = false
    /// When the next automatic refresh is due, for the panel footer.
    @Published var nextRefreshAt = Date().addingTimeInterval(300)
    /// When a refresh last finished — the footer says "just updated" for a
    /// minute after it, so a refresh that restarts the timer does not read
    /// as nothing having happened.
    @Published var lastRefreshAt: Date?
    /// The footer's refresh-everything is running.
    @Published var isForceRefreshing = false
    /// What the last refresh-everything came to, for a moment after it
    /// finished; nil the rest of the time.
    @Published var refreshOutcome: RefreshOutcome?
    private var refreshOutcomeTask: Task<Void, Never>?
    /// True while something is capturing the screen and the owner asked for
    /// usage to be hidden then.
    @Published var isPrivacyMasked = false
    /// A provider whose card was copied, for the "copied" pill.
    @Published var copiedNotice: String?
    var captureTask: Task<Void, Never>?
    /// Pace notifications already sent, keyed by provider, window and kind,
    /// with the reset they belong to — so one crossing notifies once.
    var paceNotified: [String: Date] = [:]
    /// Windows that reset a moment ago, by `ResetEvent.id`, and until when
    /// their rows say so.
    @Published var recentResets: [String: Date] = [:]
    /// The read queued for just after the next window resets.
    var resetCheckTask: Task<Void, Never>?
    /// Extra reads spent on a reset the provider has not rolled over yet.
    var resetRetries: [String: Int] = [:]
    /// The surfaces that play the reset moment, with the glyph's reading from
    /// before the reset; set by the coordinators.
    var onResets: (([ResetEvent], MeterReading) -> Void)?
    var paceBaselineTaken = false

    private var lastAlertLevel: AlertLevel = .none
    var notificationsReady = false

    let config = ConfigStore.shared
    /// Quota Run: the personal records every reading feeds, and the upload
    /// once the owner has joined.
    let run: RunCenter
    private var autoRefreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var netMonitor: NWPathMonitor?
    private var lastNetStatus: NWPath.Status?
    private var systemObservers: [NSObjectProtocol] = []
    /// When Kimi Code last wrote its sign-in files; see `noteKimiCodeSignIn`.
    private var kimiCodeWritten: [String: Date]?
    /// Bumped each time a provider's pasted credential is replaced or
    /// cleared: a read that started before belongs to the credential that
    /// was, and is dropped when it lands.
    private var credentialGeneration: [ProviderID: Int] = [:]

    /// Builds a store wired to the real config but with no timers, network
    /// calls or notification prompts — used by `--snapshot` and previews.
    static func preview(
        enabled: [ProviderID],
        states: [ProviderID: ProviderPhase],
        cost: CostSummary = .empty,
        ledger: UsageLedger = .empty,
        history: [ProviderID: [Double]] = [:],
        claudeCredential: LocalCredentials.ClaudeCredentialState? = nil) -> UsageStore
    {
        let store = UsageStore(inert: true)
        store.claudeCredential = claudeCredential
        store.enabled = enabled
        store.reported = states.compactMapValues(\.snapshot)
        store.states = states
        store.reapplyHiddenWindows()
        store.cost = cost
        store.ledger = ledger
        store.history = history
        store.selected = nil
        return store
    }

    private init(inert: Bool) {
        self.run = RunCenter.inert()
        self.enabled = []
        self.refreshMinutes = ConfigStore.shared.refreshMinutes
        self.menuBarStyle = ConfigStore.shared.menuBarStyle
        self.menuBarIconMode = ConfigStore.shared.menuBarIconMode
        self.meterMode = ConfigStore.shared.meterMode
        self.meterStyle = ConfigStore.shared.meterStyle
        self.showsIsland = false
        self.showsDock = false
        self.alertSettings = ConfigStore.shared.alerts
        self.language = ConfigStore.shared.language
        self.experience = ConfigStore.shared.experience
        self.selected = nil
    }

    init() {
        self.run = RunCenter()
        self.enabled = ConfigStore.shared.enabledProviders
        self.refreshMinutes = ConfigStore.shared.refreshMinutes
        self.menuBarStyle = ConfigStore.shared.menuBarStyle
        self.menuBarIconMode = ConfigStore.shared.menuBarIconMode
        self.meterMode = ConfigStore.shared.meterMode
        self.meterStyle = ConfigStore.shared.meterStyle
        self.showsIsland = ConfigStore.shared.showsIsland
        self.showsDock = ConfigStore.shared.showsDock
        self.alertSettings = ConfigStore.shared.alerts
        self.language = ConfigStore.shared.language
        self.experience = ConfigStore.shared.experience
        // Restore the focused provider, dropping it if it is no longer enabled.
        let saved = ConfigStore.shared.selected
        self.selected = saved.flatMap {
            ConfigStore.shared.enabledProviders.contains($0) ? $0 : nil
        }
        for id in enabled {
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
            // Stale-while-revalidate: last session's numbers until the first
            // refresh lands, instead of a column of spinners.
            if let cached = SnapshotCache.shared.snapshot(for: id) {
                reported[id] = cached
                states[id] = .loaded(shown(cached, for: id))
            }
        }
        HTTP.configureProxy(experience.proxy)
        // Spend and the year from the archive on disk: there before the first
        // scan has read a single log.
        applyArchive(UsageArchiveStore.shared.current)
        prepareNotifications()
        refreshConfigured()
        checkForUpdate()
        startUpdatePolling()
        startAutoRefresh()
        startClock()
        startSystemObservers()
        startStatusPolling()
        startExperience()
        run.start()
        refreshAll()
    }

    deinit {
        autoRefreshTask?.cancel()
        clockTask?.cancel()
        statusTask?.cancel()
        updatePollTask?.cancel()
        netMonitor?.cancel()
    }

    // MARK: Derived state

    /// Per-horizon readings driving the menu-bar glyph.
    ///
    /// Follows whatever the panel is focused on: a selected provider reports
    /// only its own windows, while the overview aggregates across everything
    /// enabled. Switching provider in the panel therefore switches what the
    /// menu bar is telling you about.
    var meterReading: MeterReading {
        let sources: [ProviderID] = selected.map { [$0] } ?? enabled
        var reading = MeterReading.across(sources.compactMap { states[$0]?.snapshot })
        // One provider on show: its single figure is the window the owner
        // picked for it, here as everywhere else.
        if let selected, pickedHeadlineWindow(for: selected) != nil {
            reading.preferred = headlinePercent(for: selected)
        }
        return reading
    }

    // MARK: Headline window

    /// The window a provider's single figure follows in one place — the
    /// owner's pick for that place, else the fullest window. Each place picks
    /// for itself (`FigurePlace`): the menu bar can stand for the 5-hour
    /// limit while the dock's ring follows the week. The menu bar goes with
    /// the card: double-clicking a limit there is how its figure is chosen.
    func headlinePercent(for id: ProviderID, on place: FigurePlace = .card) -> Double? {
        states[id]?.snapshot?.headlinePercent(preferring: pickedHeadlineWindow(for: id, on: place))
    }

    func headlineWindow(for id: ProviderID, on place: FigurePlace = .card) -> UsageWindow? {
        states[id]?.snapshot?.headlineWindow(preferring: pickedHeadlineWindow(for: id, on: place))
    }

    /// The pick itself, whether or not the provider currently reports it.
    func pickedHeadlineWindow(for id: ProviderID, on place: FigurePlace = .card) -> String? {
        place == .card ? config.headlineWindow(for: id) : experience.placeWindow(for: id, on: place)
    }

    func setHeadlineWindow(_ windowID: String?, for id: ProviderID, on place: FigurePlace = .card) {
        guard place != .card else {
            config.setHeadlineWindow(windowID, for: id)
            objectWillChange.send()
            return
        }
        updateExperience { $0.setPlaceWindow(windowID, for: id, on: place) }
        // Only the island is re-placed: its bar is as wide as its figures.
        // The dock's frame does not depend on which window its rings follow,
        // and re-placing it closes the callout — where this pick is made.
        if place == .island { islandRevision &+= 1 }
    }

    /// Highest reading overall, for anything that shows a single figure.
    var headlinePercent: Double? {
        meterReading.headline
    }

    var alertLevel: AlertLevel {
        alertSettings.level(for: headlinePercent ?? 0)
    }

    /// The enabled provider currently closest to its limit (for alert captions).
    var hottestProvider: (id: ProviderID, percent: Double)? {
        var best: (ProviderID, Double)?
        for id in enabled {
            guard let percent = states[id]?.snapshot?.headlinePercent else { continue }
            if best == nil || percent > best!.1 { best = (id, percent) }
        }
        return best
    }

    /// Providers whose most recent refresh failed — surfaced in the footer so a
    /// dead credential is visible without opening every tile.
    var failingProviders: [ProviderID] {
        enabled.filter { states[$0]?.errorMessage != nil }
    }

    /// Providers with no reading whose last refresh failed, being read again.
    /// They keep `.failed` until the read is back, as a stale provider keeps
    /// its numbers: a retry is not a recovery, and as `.loading` they dropped
    /// out of `failingProviders` for as long as every refresh took — the
    /// island's list of them lost its rows, or closed, and the amber dots
    /// went green.
    @Published private(set) var retrying: Set<ProviderID> = []

    func isLoading(_ id: ProviderID) -> Bool {
        if retrying.contains(id) { return true }
        if case .loading = states[id] { return true }
        return false
    }

    func isEnabled(_ id: ProviderID) -> Bool {
        enabled.contains(id)
    }

    // MARK: Refreshing

    func refreshAll() {
        refresh(enabled.filter { !isLoading($0) })
        refreshCost()
    }

    func refresh(_ id: ProviderID) {
        guard !isLoading(id) else { return }
        refresh([id])
    }

    /// Fetches every provider concurrently and applies each result the moment
    /// it lands. Waiting for the whole group would let one provider sitting on
    /// its 20s timeout hold the entire panel hostage.
    private func refresh(_ ids: [ProviderID]) {
        guard !ids.isEmpty else { return }
        Task { await refreshNow(ids) }
    }

    /// The footer's refresh button: every provider whatever it is doing,
    /// credentials read afresh, the status pages, and the logs — the lot,
    /// not the one card a card's own button refreshes. The automatic timer
    /// starts over from here.
    ///
    /// The spinner stays up for `RefreshOutcome.minimumSpin` at least, and
    /// the outcome — all up to date, or how many still are not — then sits
    /// in the island's sync note for a moment: reads that fail at once came
    /// back before the spinner could be seen, and the click read as nothing.
    func forceRefreshAll() {
        guard !isForceRefreshing else { return }
        isForceRefreshing = true
        refreshOutcomeTask?.cancel()
        refreshOutcome = nil
        let started = Date()
        config.invalidateCredentialCache()
        LocalCredentials.invalidateClaudeToken()
        startAutoRefresh()
        Task {
            async let providers: Void = refreshNow(enabled)
            async let status: Void = refreshServiceStatus()
            async let logs: Void = refreshCostNow()
            _ = await (providers, status, logs)
            let remaining = RefreshOutcome.remainingSpin(elapsed: Date().timeIntervalSince(started))
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            isForceRefreshing = false
            tick &+= 1
            showRefreshOutcome(RefreshOutcome(failing: failingProviders.count))
        }
    }

    /// Holds the outcome for `RefreshOutcome.holdSeconds`, then clears it.
    private func showRefreshOutcome(_ outcome: RefreshOutcome) {
        refreshOutcomeTask?.cancel()
        refreshOutcome = outcome
        refreshOutcomeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RefreshOutcome.holdSeconds))
            guard !Task.isCancelled else { return }
            self?.refreshOutcome = nil
        }
    }

    private func refreshNow(_ ids: [ProviderID]) async {
        guard !ids.isEmpty else { return }
        for id in ids { markLoading(id) }
        let generations = Dictionary(uniqueKeysWithValues: ids.map { ($0, credentialGeneration[$0, default: 0]) })
        do {
            let config = self.config
            await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, Error>).self) { group in
                for id in ids {
                    group.addTask {
                        do {
                            return (id, .success(try await ProviderRegistry.make(id).fetch(config: config)))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }
                for await (id, result) in group {
                    // Read with a credential replaced since: the read with the
                    // new one is already on its way (`setCredential`).
                    if self.credentialGeneration[id, default: 0] == generations[id] {
                        self.apply(id, result)
                    }
                    // A read may have renewed the Kimi Code sign-in, which
                    // rewrites its file: that is no news to read again for.
                    if id == .kimi { self.kimiCodeWritten = LocalCredentials.kimiCodeFilesWritten() }
                }
            }
            finishRefresh()
            refreshConfigured()
        }
    }

    // MARK: Status pages

    /// Every five minutes, independent of the quota cadence: an incident
    /// lasts hours, and the pages rate-limit by IP.
    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServiceStatus()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Every provider with a feed, enabled or not: the settings list shows
    /// them all, and eight small requests every five minutes is nothing.
    func refreshServiceStatus(_ only: [ProviderID]? = nil) async {
        let ids = (only ?? StatusPages.supported).filter { StatusPages.page(for: $0) != nil }
        guard !ids.isEmpty else { return }
        let fresh = await withTaskGroup(of: (ProviderID, ServiceStatus?).self) { group in
            for id in ids {
                group.addTask { (id, await StatusPages.fetch(id)) }
            }
            var out: [ProviderID: ServiceStatus] = [:]
            for await (id, status) in group {
                if let status { out[id] = status }
            }
            return out
        }
        for (id, status) in fresh {
            serviceStatus[id] = status
            // The one strip a closed row shows; the rest load when it opens.
            if let primary = StatusPages.primaryComponent(for: id, in: status.components) {
                loadUptime(for: id, only: primary.id)
            }
        }
    }

    /// Fetches the 90-day history of every component the page lists — or of
    /// the one named — once.
    func loadUptime(for id: ProviderID, only component: String? = nil) {
        guard let status = serviceStatus[id] else { return }
        let wanted = status.components.filter { component == nil || $0.id == component }
        for component in wanted where uptime[component.id] == nil && !uptimeLoading.contains(component.id) {
            uptimeLoading.insert(component.id)
            Task {
                let days = await StatusPages.uptime(for: id, component: component.id)
                if let days { self.uptime[component.id] = days }
                self.uptimeLoading.remove(component.id)
            }
        }
    }

    private func markLoading(_ id: ProviderID) {
        // Keep showing the previous numbers while a refresh is in flight, and
        // a failure with none keeps its message; only a provider with nothing
        // yet gets the spinner.
        switch states[id] {
        case .loaded, .stale: break
        case .failed: retrying.insert(id)
        case .loading, nil: states[id] = .loading
        }
    }

    private func apply(_ id: ProviderID, _ result: Result<UsageSnapshot, Error>) {
        retrying.remove(id)
        switch result {
        case let .success(reading):
            let snapshot = withBalanceEstimate(id, reading)
            let before = meterReading
            // Signed in to another account: its trend starts afresh rather than
            // splicing two accounts into one line.
            if let previous = states[id]?.snapshot, ResetDetector.accountChanged(from: previous, to: snapshot) {
                UsageHistoryStore.shared.clear(id)
                history[id] = []
            }
            // Before the reading is shown: a hidden window renamed by a
            // language switch has to be hidden under its new name.
            if let old = renamingWindows.removeValue(forKey: id) {
                carryWindowChoices(for: id, from: old, to: snapshot.windows)
            }
            let previousReading = reported[id]
            reported[id] = snapshot
            noteResetCredits(id, previous: previousReading, current: snapshot.resetCredits)
            if snapshot.balance != nil || previousReading?.balance != nil { evaluateBalanceNotices() }
            let visible = shown(snapshot, for: id)
            let resets = ResetDetector.events(provider: id, previous: states[id]?.snapshot, current: visible)
            states[id] = .loaded(visible)
            if !resets.isEmpty { noteResets(resets, before: before) }
            SnapshotCache.shared.store(snapshot, for: id)
            run.record(id, snapshot)
            if let percent = visible.headlinePercent {
                UsageHistoryStore.shared.record(id, percent: percent)
                history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
            }
        case let .failure(error):
            let message = error.localizedDescription
            if let previous = states[id]?.snapshot {
                states[id] = .stale(previous, error: message)
            } else {
                states[id] = .failed(message)
            }
        }
    }

    /// The window the ring follows and the windows a card shows, moved to the
    /// names the same windows have in the new language.
    private func carryWindowChoices(for id: ProviderID, from old: [UsageWindow], to new: [UsageWindow]) {
        let renamed = WindowRename.pairs(from: old, to: new)
        guard !renamed.isEmpty else { return }
        for place in FigurePlace.allCases {
            if let picked = pickedHeadlineWindow(for: id, on: place), let now = renamed[picked] {
                setHeadlineWindow(now, for: id, on: place)
            }
        }
        if let shown = experience.cardWindows[id.rawValue] {
            updateExperience { $0.cardWindows[id.rawValue] = shown.map { renamed[$0] ?? $0 } }
        }
        if let known = experience.cardWindowsKnown[id.rawValue] {
            updateExperience { $0.cardWindowsKnown[id.rawValue] = known.map { renamed[$0] ?? $0 } }
        }
        if let hidden = experience.hiddenWindows[id.rawValue] {
            updateExperience { $0.hiddenWindows[id.rawValue] = hidden.map { renamed[$0] ?? $0 } }
        }
    }

    /// A reading as the app shows it: without the windows the owner hid.
    private func shown(_ snapshot: UsageSnapshot, for id: ProviderID) -> UsageSnapshot {
        snapshot.hiding(experience.hiddenWindows[id.rawValue])
    }

    /// Hiding or showing a window takes effect on the readings already in,
    /// not at the next refresh.
    func reapplyHiddenWindows() {
        for (id, snapshot) in reported {
            switch states[id] {
            case .loaded: states[id] = .loaded(shown(snapshot, for: id))
            case let .stale(_, error): states[id] = .stale(shown(snapshot, for: id), error: error)
            case .loading, .failed, nil: break
            }
        }
    }

    private func finishRefresh() {
        lastRefreshAt = Date()
        tick &+= 1
        evaluateAlerts()
        evaluatePaceAlerts()
        scheduleResetCheck()
        run.afterRefresh()
    }

    /// Re-evaluates which providers have usable credentials.
    func refreshConfigured() {
        Task { [config] in
            let (ready, local, sources, claude) = await Task.detached(priority: .utility) {
                let ready = Set(ProviderID.allCases.filter {
                    ProviderRegistry.make($0).isConfigured(config: config)
                })
                // `isConfigured` has just read these credentials, so this is
                // answered from the memo, not the keychain.
                let local = ready.filter { $0.credentialHint != nil && config.credential(for: $0) == nil }
                var sources: [ProviderID: ProviderSourceInfo] = [:]
                for id in ready {
                    sources[id] = ProviderRegistry.make(id).sourceInfo(config: config)
                }
                // Non-interactive, like every keychain read off a timer.
                let claude = LocalCredentials.claudeCredentialState()
                return (ready, local, sources, claude)
            }.value
            self.configured = ready
            self.signedInLocally = local
            if self.sourceInfo != sources { self.sourceInfo = sources }
            self.claudeCredential = claude
        }
    }

    func isConfigured(_ id: ProviderID) -> Bool {
        configured.contains(id)
    }

    /// The console for the account in use — the kimi.ai one for a global
    /// Kimi Code sign-in — else the provider's usual one.
    func dashboardURL(for id: ProviderID) -> URL? {
        sourceInfo[id]?.consoleURL ?? id.dashboardURL
    }

    /// Raises the keychain dialog for Claude Code's item — the only place the
    /// app ever does — then reads again. Wire it to a button, nothing else.
    func authorizeClaude() {
        Task {
            _ = await LocalCredentials.authorizeClaudeAccessAsync()
            refresh(.claude)
            refreshConfigured()
        }
    }

    /// Only meaningful for a packaged build: the dev binary has no version.
    private var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `manual`: asked for from a menu or the Updates page, which checks even
    /// with automatic checks turned off. `presenting`: the update card opens
    /// straight away and shows the check, its result, or that it is up to date.
    ///
    /// A new version always comes to the owner as the update card — what it is,
    /// when it was released, what changed — and nothing is replaced until they
    /// click Install and Relaunch. Under the automatic policy the download and
    /// its verification happen in the background first, so that click is instant.
    func checkForUpdate(manual: Bool = false, presenting: Bool = false) {
        guard manual || config.checksForUpdates, let current = currentVersion else { return }
        if presenting { UpdateWindow.show(store: self) }
        // A download or a staged bundle is further along than a check.
        switch updateStage {
        case .downloading, .readyToInstall: return
        default: break
        }
        let feed = config.updateFeed
        updateStage = .checking
        Task {
            let release = await Updater.check(feed: feed, currentVersion: current, includePrereleases: self.experience.betaUpdates)
            self.lastUpdateCheck = Date()
            guard let release else {
                self.updateStage = .idle
                return
            }
            self.lastRelease = release
            self.updateStage = .available(release)
            if self.updatePolicy == .automatic, !self.updateIsManagedByHomebrew {
                self.downloadUpdate()
            }
            // Once a session per version: the six-hourly check finding the
            // same release again is not news.
            if self.announcedUpdate != release.version {
                self.announcedUpdate = release.version
                UpdateWindow.show(store: self)
            }
        }
    }

    /// Every six hours after launch: the app is left running for weeks, and
    /// a check only at launch would find a release a month late.
    private func startUpdatePolling() {
        updatePollTask?.cancel()
        updatePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard !Task.isCancelled else { return }
                self?.checkForUpdate()
            }
        }
    }

    /// Downloads and verifies, leaving the bundle staged. `thenInstall`: the
    /// owner already clicked Install and Relaunch, so go straight on.
    func downloadUpdate(thenInstall: Bool = false) {
        guard case let .available(release) = updateStage else { return }
        installWhenStaged = installWhenStaged || thenInstall
        updateStage = .downloading(release)
        Task {
            do {
                let staged = try await Updater.stage(release)
                self.stagedUpdate = staged
                self.updateStage = .readyToInstall(release)
                if self.installWhenStaged, !self.updateIsManagedByHomebrew {
                    self.installUpdate()
                }
            } catch {
                self.installWhenStaged = false
                self.updateStage = .failed(error.localizedDescription)
            }
        }
    }

    /// Install and Relaunch, from wherever the update has got to: download
    /// first if need be, wait for one under way, or swap the staged bundle.
    func installNow() {
        switch updateStage {
        case .available: downloadUpdate(thenInstall: true)
        case .downloading: installWhenStaged = true
        case .readyToInstall: installUpdate()
        case .failed:
            if let lastRelease {
                updateStage = .available(lastRelease)
                downloadUpdate(thenInstall: true)
            }
        default: break
        }
    }

    /// Swaps the bundle and relaunches. Only reachable once a download has
    /// passed verification.
    func installUpdate() {
        guard let staged = stagedUpdate else { return }
        do {
            try Updater.install(staged: staged)
            NSApplication.shared.terminate(nil)
        } catch {
            updateStage = .failed(error.localizedDescription)
        }
    }

    /// Homebrew owns the install; replacing the bundle behind its back would
    /// desync its metadata.
    var updateIsManagedByHomebrew: Bool { Updater.isManagedByHomebrew() }

    var checksForUpdates: Bool { config.checksForUpdates }
    var updatePolicy: UpdatePolicy { config.updatePolicy }

    func setUpdatePolicy(_ policy: UpdatePolicy) {
        config.updatePolicy = policy
        objectWillChange.send()
        // Switching to automatic with a release already found: finish it.
        if policy == .automatic { installNow() }
    }

    var dockEdge: DockEdge { config.dockEdge }
    var widgetEnabled: Bool { config.widgetEnabled }
    var widgetDensity: WidgetDensity { config.widgetDensity }
    var widgetAlwaysOnTop: Bool { config.widgetAlwaysOnTop }

    /// Bumped so the coordinators re-evaluate; the widget is independent of
    /// the island and dock switches, so it needs its own signal.
    @Published var widgetRevision = 0

    func setWidgetEnabled(_ on: Bool) {
        config.widgetEnabled = on
        widgetRevision &+= 1
    }

    func setWidgetAlwaysOnTop(_ on: Bool) {
        config.widgetAlwaysOnTop = on
        widgetRevision &+= 1
    }
    var dockAlwaysVisible: Bool { config.dockAlwaysVisible }

    var islandSlots: Int { config.islandSlots }

    // MARK: Pins

    /// A surface pinned to one provider shows that provider alone. The
    /// menu-bar glyph's equivalent is `selected`.
    var islandPin: ProviderID? { config.islandPin }
    var dockPin: ProviderID? { config.dockPin }
    var widgetPin: ProviderID? { config.widgetPin }
    var widgetScope: WidgetScope { config.widgetScope }

    /// What each surface shows: its pinned provider alone when it has one,
    /// otherwise every enabled provider not hidden there.
    var islandProviders: [ProviderID] { surfaceProviders(.island, pin: islandPin) }

    /// The island's two columns, left and right of the notch.
    var islandColumns: (left: [ProviderID], right: [ProviderID]) {
        IslandRoom.columns(islandProviders, slots: islandSlots)
    }

    /// The providers the closed island shows — the only ones it may speak
    /// for. `islandProviders` is everything allowed on it, which with one
    /// slot a side is mostly providers it has no room to draw.
    var islandShown: [ProviderID] {
        IslandRoom.shown(islandProviders, slots: islandSlots, pill: IslandCoordinator.notchMetrics() == nil)
    }

    /// The worst line a provider on the island is past. The glow's colour
    /// and the peek both read this one, so they are about the same figures.
    var islandSeverity: AlertLevel {
        islandShown.compactMap { headlinePercent(for: $0, on: .island) }
            .map { alertSettings.level(for: $0) }
            .max() ?? .none
    }

    /// A quota on the island down to its last 15%.
    var islandLowQuota: AlertLevel {
        LowQuota.level(used: islandShown.map { headlinePercent(for: $0, on: .island) })
    }
    var dockProviders: [ProviderID] { surfaceProviders(.dock, pin: dockPin) }
    var panelProviders: [ProviderID] { experience.visible(enabled, on: .panel) }

    private func surfaceProviders(_ surface: DisplaySurface, pin: ProviderID?) -> [ProviderID] {
        if let pin, enabled.contains(pin) { return [pin] }
        return experience.visible(enabled, on: surface)
    }

    /// Hides a provider from one surface or shows it there again. It stays
    /// enabled either way.
    func setHidden(_ hidden: Bool, _ id: ProviderID, on surface: DisplaySurface) {
        updateExperience { $0.setHidden(hidden, id, on: surface) }
        switch surface {
        case .dock: dockRevision &+= 1
        case .island: islandRevision &+= 1
        case .desktop: widgetRevision &+= 1
        case .panel: break
        }
    }

    /// Enabled providers hidden from a surface.
    func hiddenProviders(on surface: DisplaySurface) -> [ProviderID] {
        enabled.filter { experience.isHidden($0, on: surface) }
    }

    func setIslandPin(_ id: ProviderID?) {
        config.islandPin = id
        objectWillChange.send()
        islandRevision &+= 1
    }

    func setDockPin(_ id: ProviderID?) {
        config.dockPin = id
        objectWillChange.send()
        dockRevision &+= 1
    }

    /// Pinning a provider to the desktop points the first single-provider
    /// card at it, or adds one; unpinning lets those cards follow the menu
    /// bar again.
    func setWidgetPin(_ id: ProviderID?, unpinning previous: ProviderID? = nil) {
        config.widgetPin = id
        config.widgetScope = id == nil ? .all : .pinned
        if let id {
            if let card = experience.deskCards.first(where: { $0.style.singleProvider }) {
                updateDeskCard(card.id) { $0.provider = id }
            } else {
                updateExperience { $0.deskCards.append(DeskCard(style: .focus, provider: id, x: 0.95, y: 0.06)) }
            }
            if !widgetEnabled { setWidgetEnabled(true) }
        } else if let previous {
            for card in experience.deskCards where card.provider == previous {
                updateDeskCard(card.id) { $0.provider = nil }
            }
        }
        objectWillChange.send()
        widgetRevision &+= 1
    }

    /// Whether some desktop card shows this provider alone.
    func isPinnedToDesktop(_ id: ProviderID) -> Bool {
        widgetEnabled && experience.deskCards.contains { $0.provider == id && $0.style.singleProvider }
    }

    // MARK: Screen

    var displayScreen: String? { config.displayScreen }

    /// Every surface moves: the dock and island re-place themselves, the
    /// widget goes to the same screen at its stored fractions.
    func setDisplayScreen(_ id: String?) {
        config.displayScreen = id
        objectWillChange.send()
        dockRevision &+= 1
        islandRevision &+= 1
        widgetRevision &+= 1
    }

    /// Bumped when the island's strip changes width, so the coordinator
    /// re-places the panel.
    @Published var islandRevision = 0

    func setIslandSlots(_ slots: Int) {
        config.islandSlots = slots
        objectWillChange.send()
        islandRevision &+= 1
    }

    /// Bumped when a setting moves the dock, so the coordinator re-places
    /// the window. Re-assigning `showsDock` to itself did nothing: SwiftUI's
    /// `onChange` compares values, and an unchanged value is not a change —
    /// the strip mirrored its corners for the new edge and stayed put.
    @Published var dockRevision = 0

    func setDockEdge(_ edge: DockEdge) {
        config.dockEdge = edge
        objectWillChange.send()
        dockRevision &+= 1
    }

    func setDockAlwaysVisible(_ on: Bool) {
        config.dockAlwaysVisible = on
        objectWillChange.send()
        dockRevision &+= 1
    }
    func refreshCost() {
        Task { await refreshCostNow() }
    }

    /// Spend, the year's ledger and the archive, from one pass over the logs.
    ///
    /// The archive is the source: the first time it reads every log, after
    /// that only the files touched in the last two days, and every figure the
    /// app shows is derived from it in memory. So the panel, the card's back,
    /// the island's usage page and the usage pane have their numbers the
    /// moment they open — from the archive loaded at launch — and the scan
    /// only ever brings them up to the minute in the background.
    func refreshCostNow() async {
        guard !isComputingCost else { return }
        isComputingCost = true
        isComputingLedger = true
        isUpdatingArchive = true
        // Refresh published model prices before scanning, so a newly released
        // model is not priced through a stale prefix guess.
        await PricingCatalog.shared.refreshIfNeeded()
        let updated = await Task.detached(priority: .utility) {
            UsageArchiveStore.shared.update()
        }.value
        applyArchive(updated)
        isComputingCost = false
        isComputingLedger = false
        isUpdatingArchive = false
    }

    /// Everything local-log shaped, re-derived from the archive.
    func applyArchive(_ archive: UsageArchive) {
        self.archive = archive
        projectArchive = UsageArchiveStore.shared.projects.current
        guard archive.fullScanDone else { return }
        cost = archive.costSummary()
        ledger = archive.ledger()
        evaluateSpendNotices()
    }

    /// True once the logs have been read in full at least once; until then a
    /// page with no figures is still reading, not empty.
    var logsReady: Bool { archive.fullScanDone }

    /// Kept for the views that ask: the ledger is derived from the archive
    /// and always current, so only a Mac that has never been scanned waits.
    func wantLedger() {
        if !logsReady && !isComputingCost { refreshCost() }
    }

    // MARK: Alerts

    func setAlertSettings(_ settings: AlertSettings) {
        let normalized = settings.normalized()
        alertSettings = normalized
        config.alerts = normalized
        evaluateAlerts()
    }

    /// Notifications need a bundle identifier; the dev loop runs the bare
    /// binary, where `UNUserNotificationCenter.current()` would trap.
    var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func prepareNotifications() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.notificationsReady = granted }
            }
    }

    /// Edge-triggered: notify only when the level rises, so a steady 90%
    /// doesn't spam the Notification Center.
    private func evaluateAlerts() {
        let level = alertLevel
        defer { lastAlertLevel = level }
        guard notificationsReady, level > lastAlertLevel, let hot = hottestProvider else { return }
        let content = UNMutableNotificationContent()
        content.title = "QuotaBar"
        let percent = Int(hot.percent.rounded())
        content.body = L10n.t(
            "\(hot.id.displayName) used \(percent)% — \(level.displayName.lowercased())",
            "\(hot.id.displayName) 已用 \(percent)% —— \(level.displayName)")
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bar.quota.alert.\(level.rawValue)",
            content: content,
            trigger: nil))
    }

    // MARK: Settings

    func setEnabled(_ id: ProviderID, _ on: Bool) {
        config.setEnabled(id, on)
        if on {
            if !enabled.contains(id) { enabled.append(id) }
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
            if selected == nil && enabled.count == 1 { selected = id }
            refresh(id)
            Task { await refreshServiceStatus([id]) }
        } else {
            enabled.removeAll { $0 == id }
            states[id] = nil
            retrying.remove(id)
            reported[id] = nil
            SnapshotCache.shared.remove(id)
            if selected == id { selected = enabled.first }
        }
    }

    func setRefreshMinutes(_ minutes: Int) {
        refreshMinutes = QuotaConfig.clampRefresh(minutes)
        config.refreshMinutes = refreshMinutes
        startAutoRefresh()
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        menuBarStyle = style
        config.menuBarStyle = style
    }

    func setMenuBarIconMode(_ mode: MenuBarIconMode) {
        menuBarIconMode = mode
        config.menuBarIconMode = mode
    }

    func setMeterMode(_ mode: MeterMode) {
        meterMode = mode
        config.meterMode = mode
    }

    func setMeterStyle(_ style: MeterStyle) {
        meterStyle = style
        config.meterStyle = style
    }

    func setShowsIsland(_ on: Bool) {
        showsIsland = on
        config.showsIsland = on
    }

    func setShowsDock(_ on: Bool) {
        showsDock = on
        config.showsDock = on
    }

    func setLanguage(_ language: L10n.Language) {
        let wasChinese = L10n.isChinese
        self.language = language
        config.language = language
        // Interface strings are resolved through L10n at render time, so a
        // redraw covers them.
        objectWillChange.send()
        tick &+= 1
        // What a provider hands back is not: window names, plan details and
        // error messages are worded when the reading is taken, and the last
        // reading is kept on disk. Take them again in the new language.
        if L10n.isChinese != wasChinese {
            // The windows come back renamed; remember them as they were, so
            // the owner's picks can follow them to their new names.
            for id in enabled {
                if let windows = (reported[id] ?? states[id]?.snapshot)?.windows { renamingWindows[id] = windows }
            }
            refreshAll()
            Task { await refreshServiceStatus() }
        }
    }

    func setCredential(_ value: String, for id: ProviderID) {
        config.setCredential(value, for: id)
        credentialGeneration[id, default: 0] &+= 1
        // A replaced credential may be a different account entirely, which
        // would splice two unrelated series into one trend line.
        UsageHistoryStore.shared.clear(id)
        history[id] = []
        refreshConfigured()
        // Read now even while a read is out: that one used the credential
        // this replaces — a Kimi Code sign-in can take a minute and more to
        // renew — and its result is dropped when it lands.
        if isEnabled(id) { refresh([id]) }
    }

    /// Wipes every recorded trend line.
    func resetHistory() {
        UsageHistoryStore.shared.clearAll()
        history = [:]
        tick &+= 1
    }

    var credentialError: String? { config.lastCredentialError }

    // MARK: Timers and system events

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        let minutes = QuotaConfig.clampRefresh(refreshMinutes)
        nextRefreshAt = Date().addingTimeInterval(Double(minutes) * 60)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                self?.nextRefreshAt = Date().addingTimeInterval(Double(minutes) * 60)
                guard let self, !Task.isCancelled else { return }
                self.refreshAll()
            }
        }
    }

    /// Drives the "resets in …" / "updated … ago" labels between refreshes.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.tick &+= 1
                self.noteKimiCodeSignIn()
            }
        }
    }

    /// With the clock, when Kimi Code's sign-in files were written is looked
    /// at — never what they hold — and Kimi is read again as soon as Kimi
    /// Code has signed in, signed out or switched edition, rather than at the
    /// next refresh. A renewal QuotaBar made itself is not news: the read
    /// that renewed takes a fresh look at the files (`refreshNow`).
    private func noteKimiCodeSignIn() {
        let written = LocalCredentials.kimiCodeFilesWritten()
        defer { kimiCodeWritten = written }
        guard let previous = kimiCodeWritten, previous != written else { return }
        refreshConfigured()
        if isEnabled(.kimi) { refresh(.kimi) }
    }

    /// Refresh shortly after wake and when the network recovers, mirroring
    /// codex-island's resilience without probing into the post-wake burst.
    private func startSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        systemObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.refreshAll()
            }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let previous, previous != .satisfied else { return }
                try? await Task.sleep(for: .seconds(3))
                self.refreshAll()
            }
        }
        monitor.start(queue: DispatchQueue(label: "bar.quota.network"))
        netMonitor = monitor
    }
}
