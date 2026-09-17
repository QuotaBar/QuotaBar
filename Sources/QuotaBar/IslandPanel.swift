import SwiftUI
import QuotaCore

// MARK: - The island, opened

/// Fixed metrics for the expanded island, so the coordinator can size the
/// panel before SwiftUI has laid anything out. After codex-island: 24pt
/// insets, a header the height of the notch, 96pt tiles, a 44pt footer.
enum IslandPanelLayout {
    static let horizontalInset: CGFloat = 24
    static let columnWidth: CGFloat = 300
    /// Between the columns on a screen with no notch to keep them apart.
    static let columnGap: CGFloat = 24
    /// One height for every chart style and every page, so switching
    /// either never resizes the panel. The tallest tile, the usage page's and
    /// the big figure's, sets it (74pt drawn); a shorter one is centred in
    /// it, the blank shared above and below rather than left under it. The
    /// overview is laid out to fit the same row.
    static let tileHeight: CGFloat = 76
    /// A provider's title row and the 10pt gap under it, then a tile.
    static let rowHeight: CGFloat = 28 + tileHeight
    static let rowGap: CGFloat = 12
    /// Above the rows, and below them. The footer's rule reads as more room
    /// than the title's text above a tile, so the rows sit 2pt lower than
    /// centre: measured, the blank over and under each tile then match.
    static let bodyTop: CGFloat = 12
    static let bodyBottom: CGFloat = 10
    static let footerHeight: CGFloat = 44

    static func headerHeight(notch: CGFloat) -> CGFloat { max(32, notch) }

    static func width(notchWidth: CGFloat?) -> CGFloat {
        columnWidth * 2 + (notchWidth ?? columnGap) + horizontalInset * 2
    }

    static func height(rows: Int, notch: CGFloat) -> CGFloat {
        let rows = max(1, rows)
        return headerHeight(notch: notch)
            + bodyTop + bodyBottom + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
            + footerHeight
    }
}

/// Two columns either side of the notch, one provider per row: its name and
/// plan, then a tile per horizon — label, the figure in the alert colour, a
/// stepped bar in the brand colour, the reset under it. The header carries
/// the wordmark; the footer the settings gear, the chart and meter chips, the
/// page dots, and the sync state with a refresh button.
struct IslandPanel: View {
    @ObservedObject var store: UsageStore
    let notch: IslandCoordinator.NotchMetrics?
    @ObservedObject var bridge: IslandCoordinator.Bridge

    /// 额度 shows the quota tiles; 用量 what each provider consumed from the
    /// local logs; 总览 the spend across them. After codex-island: swipe with
    /// two fingers, or click a dot in the footer.
    enum Page: CaseIterable {
        case quota
        case usage
        case overview

        var label: String {
            switch self {
            case .quota: L10n.t("Quota", "额度")
            case .usage: L10n.t("Usage", "用量")
            case .overview: L10n.t("Overview", "总览")
            }
        }
    }

    private var page: Page { bridge.page }
    /// How far the pointer has dragged the open panel sideways; the pages
    /// follow it a little, then turn once it lets go past the line.
    @State private var dragX: CGFloat = 0
    /// The list of providers that are not updating, over the right column.
    /// Hovering the sync note opens it and leaving both closes it; a click
    /// on the note keeps it open until the next click.
    @State private var failuresShown = false
    @State private var failuresPinned = false
    @State private var noteHovered = false
    @State private var listHovered = false
    @State private var failuresHideTask: Task<Void, Never>?

    init(store: UsageStore, notch: IslandCoordinator.NotchMetrics?, bridge: IslandCoordinator.Bridge, showsFailures: Bool = false) {
        self.store = store
        self.notch = notch
        self.bridge = bridge
        // Seeded for the snapshot renderer, which cannot hover.
        _failuresShown = State(initialValue: showsFailures)
        _failuresPinned = State(initialValue: showsFailures)
    }

    /// Left takes the first `slots` enabled providers, right the next.
    private var left: [ProviderID] { Array(store.islandProviders.prefix(store.islandSlots)) }
    private var right: [ProviderID] {
        Array(store.islandProviders.dropFirst(store.islandSlots).prefix(store.islandSlots))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: IslandPanelLayout.headerHeight(notch: notch?.height ?? 0))
            Group {
                if page == .overview {
                    IslandOverview(store: store)
                        // Centred when a second row of tiles leaves it room.
                        .frame(maxHeight: .infinity)
                        .transition(.chartSwap)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        column(left)
                            .frame(width: IslandPanelLayout.columnWidth, alignment: .topLeading)
                        Color.clear.frame(width: notch?.notchWidth ?? IslandPanelLayout.columnGap)
                        column(right)
                            .frame(width: IslandPanelLayout.columnWidth, alignment: .topLeading)
                    }
                    .transition(.chartSwap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(x: dragX)
            .padding(.top, IslandPanelLayout.bodyTop)
            .padding(.bottom, IslandPanelLayout.bodyBottom)
            .contentShape(Rectangle())
            // ⌘-click cycles the chart style, as in codex-island.
            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                withAnimation(Motion.animation(Motion.chartSwap)) {
                    store.updateExperience { $0.islandChart = $0.islandChart.next }
                }
            })
            footer
                .frame(height: IslandPanelLayout.footerHeight)
        }
        // Over the right column, just above the note that opens it, and no
        // taller than the panel above the footer: the panel cannot scroll.
        .overlay(alignment: .bottomTrailing) {
            if failuresShown, !store.failingProviders.isEmpty {
                IslandFailureList(store: store, ids: store.failingProviders) { id in
                    closeFailures()
                    if let id {
                        SettingsWindow.open(provider: id)
                    } else {
                        SettingsWindow.open(section: .providers)
                    }
                }
                .onHover { inside in
                    listHovered = inside
                    hoverChanged()
                }
                .padding(.top, IslandPanelLayout.bodyTop / 2)
                .padding(.bottom, IslandPanelLayout.footerHeight + 2)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(Motion.animation(Motion.hoverFade), value: failuresShown)
        // The last one recovered: the list goes, and a later failure does
        // not bring it back open on its own.
        .onChange(of: store.failingProviders.isEmpty) { _, none in
            if none { closeFailures() }
        }
        .padding(.horizontal, IslandPanelLayout.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .top)
        // Press and drag sideways to turn the page — the dots are small to
        // aim at. Left for the next page, right for the one before, as a
        // two-finger swipe goes. Simultaneous, so a click on a chip or a dot
        // is still a click.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    // The page follows at a third of the pointer, and no
                    // further than 40pt: a hint of where it is going.
                    dragX = max(-40, min(40, value.translation.width / 3))
                }
                .onEnded { value in
                    let width = value.translation.width
                    if abs(width) > 60, abs(width) > abs(value.translation.height) {
                        bridge.turnPage(width < 0 ? 1 : -1, store: store)
                    }
                    withAnimation(Motion.animation(Motion.pageSwipe)) { dragX = 0 }
                })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            // The app's mark in the wordmark's own white, not its green tile:
            // on the black panel the brand colours belong to the providers.
            if let url = ProviderGlyph.markURL(named: "quotabar-mark"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text("QuotaBar")
                .font(Design.wordmark(size: 12, weight: .bold))
            Spacer(minLength: 0)
            // On the overview, the way to the share card: the icon alone,
            // top right, over the refresh button in the footer.
            if page == .overview {
                CalloutButton(symbol: "square.and.arrow.up", help: L10n.t("Share usage card", "分享用量卡片")) {
                    ShareStudio.open(store: store)
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    // MARK: Columns

    @ViewBuilder
    private func column(_ ids: [ProviderID]) -> some View {
        VStack(alignment: .leading, spacing: IslandPanelLayout.rowGap) {
            if ids.isEmpty {
                Text(L10n.t("Enable more providers in Settings.", "在设置里启用更多服务商。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: IslandPanelLayout.rowHeight, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
            ForEach(ids) { id in
                IslandProviderBlock(store: store, id: id, page: page)
                    .frame(height: IslandPanelLayout.rowHeight, alignment: .top)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .white.opacity(0.06), .white.opacity(0.06), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            // Both sides take equal room, so the dots stay centred whatever
            // the switches and the sync note measure.
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    CalloutButton(symbol: "gearshape", help: L10n.t("Settings", "设置")) {
                        SettingsWindow.open()
                    }
                    // Quick switches, each a chip that names its current state:
                    // chart style (⌘-click the panel cycles it too), used or
                    // remaining; then the page dots.
                    chip(store.experience.islandChart.displayName, help: L10n.t("Chart style (⌘-click the panel)", "图表样式（也可在面板上 ⌘ 点击切换）")) {
                        withAnimation(Motion.animation(Motion.chartSwap)) {
                            store.updateExperience { $0.islandChart = $0.islandChart.next }
                        }
                    }
                    chip(store.meterMode.displayName, help: L10n.t("Show used or remaining", "显示已用还是剩余")) {
                        store.setMeterMode(store.meterMode == .used ? .remaining : .used)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                pageDots
                HStack(spacing: 6) {
                    IslandSyncStatus(store: store, open: failuresShown && !store.failingProviders.isEmpty) { inside in
                        noteHovered = inside
                        hoverChanged()
                    } onTap: {
                        if failuresShown, failuresPinned {
                            closeFailures()
                        } else {
                            failuresHideTask?.cancel()
                            failuresPinned = true
                            failuresShown = true
                        }
                    }
                    refreshButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private extension IslandPanel {
    /// Opens on the pointer arriving at the note or the list; closes a beat
    /// after it has left both, so the gap between them can be crossed.
    func hoverChanged() {
        failuresHideTask?.cancel()
        if noteHovered || listHovered {
            if !store.failingProviders.isEmpty { failuresShown = true }
            return
        }
        guard !failuresPinned else { return }
        failuresHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !noteHovered, !listHovered, !failuresPinned else { return }
            failuresShown = false
        }
    }

    func closeFailures() {
        failuresHideTask?.cancel()
        failuresPinned = false
        failuresShown = false
    }

    /// Every provider, the status pages and the logs, as the menu panel's
    /// button does; a spinner in its place until all of it is back.
    @ViewBuilder
    var refreshButton: some View {
        if store.isForceRefreshing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 22, height: 22)
                .help(L10n.t("Refreshing everything…", "正在全部刷新…"))
        } else {
            CalloutButton(symbol: "arrow.clockwise", help: L10n.t("Refresh now", "立即刷新")) {
                store.forceRefreshAll()
            }
        }
    }

    var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(Page.allCases, id: \.self) { option in
                Circle()
                    .fill(Color.white.opacity(option == page ? 0.78 : 0.22))
                    .frame(width: 5, height: 5)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        if option != .quota { store.wantLedger() }
                        withAnimation(Motion.animation(Motion.pageSwipe)) { bridge.page = option }
                    }
                    .help(option.label)
            }
        }
        .animation(Motion.animation(Motion.strongEaseOut), value: page)
    }

    /// A tap gesture rather than a `Button`, for the reason CalloutButton
    /// gives: this panel is never key, and buttons do not fire in it.
    func chip(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityAddTraits(.isButton)
    }
}

/// "● 已同步 3 分钟前", or an amber note that something is not updating;
/// for a moment after the refresh button, what the refresh came to.
///
/// While providers are failing the note is itself a control: hovering or
/// clicking it lists them. A tap gesture with `.help`, as the chips are —
/// this panel is never key, and a `Button` would not fire. With nothing
/// failing it is plain text, laid out exactly as before.
private struct IslandSyncStatus: View {
    @ObservedObject var store: UsageStore
    /// The list it opens is on show.
    var open = false
    var onHover: (Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    @State private var hovering = false

    private var latest: Date? {
        store.enabled.compactMap { store.states[$0]?.snapshot?.fetchedAt }.max()
    }

    var body: some View {
        let failing = store.failingProviders.count
        let note = SyncNote.make(
            refreshing: store.isForceRefreshing,
            outcome: store.refreshOutcome,
            failing: failing,
            latest: latest)
        let row = HStack(spacing: 5) {
            BreathingDot(active: true, color: failing > 0 ? Palette.amber : Palette.live, pulse: store.tick)
            Text(note.text())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(failing > 0 && (hovering || open) ? 0.85 : 0.55))
                .lineLimit(1)
                .contentTransition(.opacity)
            if failing > 0 {
                Image(systemName: open ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering || open ? 0.7 : 0.35))
            }
        }
        .animation(Motion.animation(Motion.hoverFade), value: note)
        if failing > 0 {
            row
                // The highlight reaches past the row rather than padding
                // it, so the footer measures the same as the plain note.
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(hovering || open ? 0.08 : 0))
                        .padding(.horizontal, -5)
                        .padding(.vertical, -3))
                .contentShape(Rectangle().inset(by: -4))
                .onHover { inside in
                    withAnimation(Motion.animation(Motion.hoverFade)) { hovering = inside }
                    onHover(inside)
                }
                .onTapGesture(perform: onTap)
                .help(L10n.t("Which providers are not updating, and why", "哪些服务商未能更新，以及原因"))
                .accessibilityAddTraits(.isButton)
                // Gone with the last failure: the pointer may still be on it.
                .onDisappear { onHover(false) }
        } else {
            row
        }
    }
}

/// The providers that are not updating, each with its mark, its name and
/// what its last refresh said, and a click away from its settings. Fitted to
/// the room above the footer: two lines of reason each while they fit, one
/// line when not, and past that the first few and a line counting the rest.
private struct IslandFailureList: View {
    @ObservedObject var store: UsageStore
    let ids: [ProviderID]
    /// A provider's row, or nil for the line counting the rest.
    let open: (ProviderID?) -> Void

    static let width: CGFloat = 288

    var body: some View {
        ViewThatFits(in: .vertical) {
            list(lines: 2, limit: ids.count)
            list(lines: 1, limit: ids.count)
            list(lines: 1, limit: 3)
            list(lines: 1, limit: 2)
            list(lines: 1, limit: 1)
        }
        .frame(width: Self.width, alignment: .bottomTrailing)
    }

    private func list(lines: Int, limit: Int) -> some View {
        let shown = Array(ids.prefix(limit))
        let rest = ids.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { id in
                IslandFailureRow(
                    id: id,
                    reason: store.states[id]?.errorMessage ?? "",
                    staleSince: store.states[id]?.staleReading?.snapshot.fetchedAt,
                    lines: lines) { open(id) }
            }
            if rest > 0 {
                IslandFailureMore(count: rest) { open(nil) }
            }
        }
        .padding(3)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous)
                .fill(Color(white: 0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

private struct IslandFailureRow: View {
    let id: ProviderID
    let reason: String
    /// When the numbers still on show were read; nil when there are none.
    let staleSince: Date?
    let lines: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                ProviderGlyph(id: id, size: 12, tint: .white)
                    .frame(width: 14)
                Text(id.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let staleSince {
                    Text(StaleReading.note(fetchedAt: staleSince))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.35))
            }
            Text(reason.isEmpty ? StaleReading.label : reason)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.animation(Motion.hoverFade)) { hovering = inside } }
        .onTapGesture(perform: action)
        .help((reason.isEmpty ? "" : reason + "\n")
            + L10n.t("Click to open \(id.displayName) in Settings.", "点击在设置里打开 \(id.displayName)。"))
        .accessibilityLabel("\(id.displayName): \(reason)")
        .accessibilityAddTraits(.isButton)
    }
}

/// "2 more in Settings", when the rest do not fit.
private struct IslandFailureMore: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.t("\(count) more in Settings", "另有 \(count) 个，在设置里查看"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.5))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}

/// One provider: title row, then a tile per horizon.
private struct IslandProviderBlock: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    var page: IslandPanel.Page = .quota

    /// The CLI whose local logs this provider's traffic lands in, if any.
    private var costSource: CostSource? {
        switch id {
        case .claude: .claudeCode
        case .codex: .codexCLI
        case .opencodeGo: .openCode
        default: nil
        }
    }

    private var snapshot: UsageSnapshot? { store.states[id]?.snapshot }
    /// The last refresh failed and these are older numbers.
    private var stale: (snapshot: UsageSnapshot, reason: String)? { store.states[id]?.staleReading }

    /// One window per horizon, two at most — the 5-hour and the 7-day when
    /// both exist, the one there is otherwise.
    ///
    /// The plan's own windows only: a limit on one model or feature (Codex's
    /// GPT-5.3-Codex-Spark) is not a horizon of the plan, and next to a Pro
    /// plan's lone weekly bar it read as a second one. As codex-island, Plus
    /// shows its 5-hour and weekly bars, Pro its weekly. A provider that only
    /// reports scoped windows still shows those.
    private var horizons: [UsageWindow] {
        let reading = (snapshot?.windows ?? []).filter { $0.usedPercent != nil }
        let plan = reading.filter { $0.scope == nil }
        var seen = Set<String>()
        var out: [UsageWindow] = []
        for window in plan.isEmpty ? reading : plan {
            guard seen.insert(window.shortLabel ?? window.title).inserted else { continue }
            out.append(window)
            if out.count == 2 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderGlyph(id: id, size: 14, tint: .white)
                Text(id.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let plan = snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
                    Text(plan.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
                }
                if let status = store.serviceStatus[id] {
                    // Not updating takes the words; a page that says all is
                    // well keeps its dot, one that does not keeps its badge.
                    if stale != nil, status.level.isHealthy {
                        Circle()
                            .fill(Color(hex: status.level.colorHex))
                            .frame(width: 6, height: 6)
                            .help(status.sourceNote)
                    } else {
                        ServiceStatusBadge(status: status, size: 10, ink: .white.opacity(0.5))
                    }
                }
                if let stale {
                    NotUpdatingBadge(id: id, reason: stale.reason, fetchedAt: stale.snapshot.fetchedAt)
                }
                Spacer(minLength: 0)
            }
            switch page {
            case .overview:
                EmptyView()
            case .quota:
                if horizons.isEmpty {
                    emptyTile
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(horizons) { window in
                            IslandTile(window: window, accent: Color(hex: id.accentHex), store: store, id: id, stale: stale != nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // A lone window — Codex Pro's week — takes the column's
                    // full width, ending where a pair of tiles ends.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .usage:
                usageTiles
            }
        }
    }

    /// Today and this month from the local logs: tokens large, the estimate
    /// under them. Providers without logs say so.
    @ViewBuilder
    private var usageTiles: some View {
        if let source = costSource {
            if !store.logsReady || store.ledger.isEmpty {
                Text(!store.logsReady
                    ? L10n.t("Reading local session logs…", "正在读取本地会话日志…")
                    : L10n.t("Nothing logged locally yet.", "本地还没有记录。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach([LedgerPeriod.today, .month]) { period in
                        let sum = store.ledger.sum(period, source: source)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(period.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            IslandTokenFigure(count: sum.tokens, color: Color(hex: id.accentHex))
                            Text(L10n.t("≈ \(QuotaFormat.usd(sum.usd))", "≈ \(QuotaFormat.usd(sum.usd))"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Its figure's line has more air under it than over
                        // the label; at the bottom the two gaps match.
                        .frame(height: IslandPanelLayout.tileHeight, alignment: .bottom)
                    }
                }
            }
        } else {
            Text(L10n.t(
                "No local logs for this provider — only the quota readings.",
                "这个服务商没有本地日志，只有额度读数。"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
        }
    }

    private var emptyTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.states[id]?.errorMessage ?? L10n.t("No reading yet.", "还没有读数。"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: IslandPanelLayout.tileHeight, alignment: .topLeading)
    }
}

/// "243.2" and "M": the figure in the brand colour, the unit dimmer.
private struct IslandTokenFigure: View {
    let count: Int
    let color: Color

    var body: some View {
        let compact = QuotaFormat.compact(count)
        let unit = compact.last.map { $0.isLetter ? String($0).uppercased() : "" } ?? ""
        let value = unit.isEmpty ? compact : String(compact.dropLast())
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color.opacity(0.6))
        }
        .lineLimit(1)
    }
}

/// Label and figure on top, the bar, the reset under it. Figure and bar
/// follow the used-or-remaining switch, like the menu-bar glyph.
private struct IslandTile: View {
    let window: UsageWindow
    let accent: Color
    @ObservedObject var store: UsageStore
    var id: ProviderID = .claude
    /// The provider's last refresh failed and this is an older reading:
    /// figure and bar dimmed, so it is not taken for the current one.
    var stale = false

    private var used: Double { window.usedPercent ?? 0 }
    private var percent: Double { store.meterMode.shownPercent(fromUsed: used) }

    /// The alert colour for the figure — white until the warning band —
    /// so the number, not the bar, says how close this is. Judged on what
    /// is used, whichever way the figure is shown. A stale figure is grey:
    /// an alert colour on an old number would still read as news.
    private var figureColor: Color {
        if stale { return .white.opacity(0.5) }
        guard let hex = store.alertSettings.level(for: used).hex else { return .white }
        return Color(hex: hex)
    }

    private var barTint: Color { stale ? accent.opacity(0.35) : accent }

    /// Reset time passed on a stale reading: the figure belongs to the
    /// window that ended, and nothing says what the new one holds.
    private var resetLapsed: Bool { stale && StaleReading.resetLapsed(window.resetsAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.experience.islandChart {
            case .numeric:
                numeric
            case .ring:
                ringTile
            default:
                HStack(alignment: .firstTextBaseline) {
                    label
                    Spacer(minLength: 4)
                    figureView(size: 18)
                }
                chart
                resetLine
            }
        }
        .frame(height: IslandPanelLayout.tileHeight, alignment: .center)
        .animation(Motion.animation(Motion.chartSwap), value: store.experience.islandChart)
    }

    private var label: some View {
        Text(window.scope ?? window.shortLabel.map(horizonName) ?? window.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
    }

    private func figureView(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(percent.rounded()))")
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .foregroundStyle(figureColor)
                .contentTransition(.numericText(value: percent))
            Text("%")
                .font(.system(size: max(11, size * 0.45), weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch store.experience.islandChart {
        case .bar:
            Meter(percent: percent, tint: barTint, style: .continuous, height: 10, track: .white.opacity(0.10))
                .transition(.chartSwap)
        default:
            Meter(percent: percent, tint: barTint, style: .stepped, height: 13, track: .white.opacity(0.10))
                .transition(.chartSwap)
        }
    }

    private var resetLine: some View {
        Text(window.resetsAt.map { store.resetText($0) } ?? (window.detail ?? " "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(resetLapsed ? Palette.amber : .white.opacity(0.45))
            .lineLimit(1)
            .help(resetLapsed
                ? L10n.t(
                    "This window has reset since these numbers were read, and the provider is not updating: what the new window holds is not known yet.",
                    "读到这些数字之后这个窗口已经重置，而服务商未能更新：新窗口的用量还不知道。")
                : "")
    }

    private var numeric: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
            figureView(size: 34)
            resetLine
        }
        .transition(.chartSwap)
    }

    private var ringTile: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.01, percent / 100))
                    .stroke(barTint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(figureColor)
                    .contentTransition(.numericText(value: percent))
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                label
                resetLine
            }
        }
        .transition(.chartSwap)
    }

    /// "5h" → "5 小时", "7d" → "周": the reference names the horizon, not
    /// the number.
    private func horizonName(_ short: String) -> String {
        switch short {
        case "5h": L10n.t("5 hours", "5 小时")
        case "7d": L10n.t("week", "周")
        case "1d", "24h": L10n.t("day", "天")
        case "30d": L10n.t("month", "月")
        default: short
        }
    }
}


/// The overview page: spend today and over the window, counting up, with
/// each tool's share. The share card opens from the header's button.
private struct IslandOverview: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            figure(.today)
            figure(.window)
            let contributions = store.cost.spend(.window).contributions
            // Three tools at the tiles' bar height overrun a row; the third
            // makes the bars and the gaps a little shorter.
            let crowded = contributions.count > 2
            VStack(alignment: .leading, spacing: crowded ? 5 : 8) {
                ForEach(contributions, id: \.source) { item in
                    let total = max(0.000_001, store.cost.spend(.window).usd)
                    VStack(alignment: .leading, spacing: crowded ? 2 : 3) {
                        HStack {
                            Text(item.source.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text(QuotaFormat.money(item.usd))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        // The quota tiles' stepped bar, so the pages read as one
                        // panel.
                        Meter(percent: item.usd / total * 100, tint: Color(hex: item.source.accentHex), style: .stepped, height: crowded ? 9 : 13, track: .white.opacity(0.10))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
    }

    private func figure(_ period: SpendPeriod) -> some View {
        let spend = store.cost.spend(period)
        return VStack(alignment: .leading, spacing: 6) {
            Text(period.displayName(windowDays: store.cost.windowDays))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            CountUpMoney(usd: spend.usd, font: .system(size: 34, weight: .semibold, design: .monospaced), color: .white)
            Text("\(QuotaFormat.compact(spend.tokens(store.experience.tokenCounting))) tokens")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 180, alignment: .leading)
    }
}
