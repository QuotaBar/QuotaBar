import AppKit
import SwiftUI
import QuotaCore

/// Notch-island presentation: a borderless floating panel pinned to the top
/// centre of the screen, over the notch on notched Macs. At rest it is a
/// strip of figures either side of the notch (a pill on other displays);
/// hover and it grows downward into the full panel, after codex-island.
/// The menu-bar item stays as the settings entry point.
@MainActor
final class IslandCoordinator {
    private var panel: NSPanel?
    private var collapseTask: Task<Void, Never>?
    private weak var store: UsageStore?
    private(set) var expanded = false
    /// Closed as far as `expanded` goes, and still shrinking on screen.
    private var closing = false
    /// Open, or not yet done closing: a pointer that comes back keeps it
    /// open either way, without waiting out the hover delay again.
    var isOpen: Bool { expanded || closing }
    /// Where the panel is going, and the glow margin it will have there.
    /// The mouse is judged against these, never against `panel.frame`: mid
    /// animation that is neither the shape being left nor the one arrived
    /// at, and a pointer heading down into a panel still growing was told
    /// it had left.
    private var targetFrame: NSRect = .zero
    private var targetMargin: CGFloat = glowMargin
    private var refreshMouseThrough: (() -> Void)?

    /// Room around the silhouette for the glow, after codex-island. The
    /// window is this much wider and taller than the shape; outside the
    /// shape it lets clicks through.
    static let glowMargin: CGFloat = 22

    /// Open, the panel draws no glow, so the window is the panel and nothing
    /// more: a margin there was an empty band round it, and a window
    /// screenshot came out with it.
    static func margin(expanded: Bool) -> CGFloat {
        expanded ? 0 : glowMargin
    }

    /// The window's frame animation, which the view's margin follows so the
    /// silhouette tracks the frame instead of jumping at the start.
    static func frameCurve(expanded: Bool) -> Animation {
        expanded
            ? .timingCurve(0.2, 0.9, 0.3, 1.04, duration: 0.34)
            : .timingCurve(0.5, 0, 0.2, 1, duration: 0.3)
    }

    /// What the view observes that the coordinator decides: a peek request
    /// when a window crosses its warning, whether the island can be seen.
    final class Bridge: ObservableObject {
        @Published var peek = 0
        /// The reset banner on show, if any.
        @Published var banner: ResetBanner?
        @Published var occluded = false
        /// Whether the pointer has come to the island, by the coordinator's
        /// own test. The view's hover follows this, not its tracking area:
        /// that one only hears of a pointer once the panel takes the mouse,
        /// which is a move after it arrived — and a pointer thrown at the
        /// top of the screen stops there and never makes it. A shape that
        /// grew under a resting pointer has not been come to: a peek or a
        /// banner opening over it must still fold away on its own.
        @Published var pointerInside = false
        @Published var page: IslandPanel.Page = .quota

        /// One page on or back, stopping at either end: a swipe, a
        /// shift-scroll or a drag across the open panel.
        @MainActor
        func turnPage(_ step: Int, store: UsageStore?) {
            let pages = IslandPanel.Page.allCases
            guard let index = pages.firstIndex(of: page) else { return }
            let next = min(max(index + step, 0), pages.count - 1)
            guard next != index else { return }
            if pages[next] != .quota { store?.wantLedger() }
            withAnimation(Motion.animation(Motion.pageSwipe)) { page = pages[next] }
        }
    }

    let bridge = Bridge()
    private var mouseMonitors: [Any] = []
    private var occlusionObserver: NSObjectProtocol?
    private var lastSeverity: AlertLevel = .none
    private var severityBaselined = false
    private var bannerTask: Task<Void, Never>?
    private var bannerShown = false

    /// Windows that just reset: the silhouette grows a row under the notch
    /// that says which, glows green, and folds away after a few seconds.
    /// Nothing happens while the panel is open — its rows say it instead.
    func playReset(_ events: [ResetEvent], store: UsageStore) {
        // Only the providers the island draws. One it has no room for would
        // grow a row and turn the glow its colour for a name the strip never
        // shows, and the open panel has no row for it either.
        let onIsland = store.islandShown
        let shown = events.filter { onIsland.contains($0.provider) }
        guard panel != nil, !expanded, !shown.isEmpty else { return }
        bridge.banner = ResetBanner(events: shown)
        bannerShown = true
        layout(expanded: false, animated: true)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissBanner()
        }
    }

    private func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        guard bannerShown else { return }
        bannerShown = false
        bridge.banner = nil
        if !expanded { layout(expanded: false, animated: true) }
    }

    func sync(store: UsageStore) {
        if store.showsIsland {
            show(store: store)
        } else {
            hide()
        }
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        refreshMouseThrough = nil
        panel?.orderOut(nil)
        panel = nil
        expanded = false
        closing = false
        // The bridge outlives the panel. A banner left up would size the
        // next panel for it, and `occluded` left set would hold the next
        // panel's light still for good: it is shown visible and hears of no
        // change.
        bannerTask?.cancel()
        bannerTask = nil
        bannerShown = false
        bridge.banner = nil
        bridge.occluded = false
        bridge.pointerInside = false
    }

    /// Opens the island for a few seconds when a tracked window newly
    /// crosses its warning line — unless it is already open.
    func noteSeverity(_ severity: AlertLevel, enabled: Bool) {
        defer { lastSeverity = severity }
        // What is already past its line at launch is the baseline, not news.
        guard severityBaselined else { severityBaselined = true; return }
        guard enabled, panel != nil, severity > lastSeverity, severity != .none, !expanded else { return }
        bridge.peek &+= 1
    }

    private func show(store: UsageStore) {
        guard panel == nil else { return }
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size(expanded: false, store: store)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.animationBehavior = .none
        let host = IslandHostingView(rootView: IslandView(store: store, coordinator: self, bridge: bridge))
        host.coordinator = self
        // The frame is ours; the content fills whatever it is given.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        layout(expanded: false, animated: false)
        panel.orderFrontRegardless()
        installMouseTracking()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.bridge.occluded = !panel.occlusionState.contains(.visible)
            }
        }
    }

    /// The silhouette in screen coordinates: the window minus the glow margin.
    func silhouetteContains(screenPoint point: NSPoint) -> Bool {
        guard let panel else { return false }
        // Closing is the one time the frame in flight is the one to ask. The
        // target is already the strip, and the panel is still on screen
        // round it: judged against the strip, a pointer that came back to
        // the panel was told it had not, and a click on the black went to
        // the window beneath. The close has no overshoot, so the frame in
        // flight always holds the strip.
        let frame = closing ? panel.frame : targetFrame
        var shape = NSRect(
            x: frame.minX + targetMargin,
            y: frame.minY + targetMargin,
            width: frame.width - targetMargin * 2,
            height: frame.height - targetMargin)
        // The shape's top edge is the screen's, and a pointer thrown at the
        // top of the screen reports exactly that y — which `contains` counts
        // as outside, so the island went dead for the most natural way to
        // reach it. Nothing is above the edge to take the point instead.
        shape.size.height += 1
        return shape.contains(point)
    }

    /// Asked now, not remembered from the last pointer move.
    var pointerInside: Bool { silhouetteContains(screenPoint: NSEvent.mouseLocation) }

    /// Click-through outside the shape: the margin that holds the glow must
    /// not swallow clicks meant for the menu bar or the window beneath.
    private func installMouseTracking() {
        let update: (Bool) -> Void = { [weak self] moved in
            guard let self, let panel = self.panel else { return }
            let inside = self.pointerInside
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
            // Only a pointer that moved has come to the island. Asked again
            // because the shape changed, it can turn out to have been left
            // behind, never to have arrived.
            let here = inside && (moved || self.bridge.pointerInside)
            if self.bridge.pointerInside != here { self.bridge.pointerInside = here }
        }
        mouseMonitors = MouseThrough.monitors { update(true) }
        // The shape changes under a pointer that is not moving — a peek, a
        // banner, a setting — and nothing else would ask again. The dock
        // keeps the same handle for the same reason.
        refreshMouseThrough = { update(false) }
    }

    /// The view's tracking area saw something. It is no witness to a pointer
    /// arriving — it fires late, and for a shape that grew under one — but
    /// it does hear a pointer leave onto one of the app's own windows, where
    /// no pointer move reaches the monitors.
    func pointerMayHaveLeft() { refreshMouseThrough?() }

    /// Re-places the panel after a setting changed the strip's width.
    func relayout() {
        guard panel != nil else { return }
        layout(expanded: expanded, animated: false)
    }

    /// Collapsing is delayed so a quick pointer sweep across the strip does
    /// not make the panel flicker open and shut. The dock's wait, so the two
    /// feel like one hand.
    func requestExpanded(_ value: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        // A view of a panel already hidden, its timers still running.
        guard panel != nil else { return }
        if value {
            closing = false
            if bannerShown {
                bannerTask?.cancel()
                bannerShown = false
                bridge.banner = nil
            }
            expanded = true
            apply(true)
            layout(expanded: true, animated: true)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self?.expanded = false
            // Under Reduce Animations it is closed at once.
            self?.closing = !Motion.reduced
            apply(false)
            self?.layout(expanded: false, animated: true)
            guard self?.closing == true else { return }
            // The close's own length: until it is over the panel is still on
            // screen, and coming back to it is coming back to an open island.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.closing = false
            // The test goes back to the strip here, under a pointer that may
            // not move again.
            self?.refreshMouseThrough?()
        }
    }

    /// Anchored at the top centre, so the panel grows downward out of the
    /// notch. `animator()`, never `setFrame(animate:)`, which blocks the main
    /// thread for the whole animation.
    func layout(expanded: Bool, animated: Bool) {
        guard let panel, let screen = Self.hostScreen, let store else { return }
        let shape = !expanded && bannerShown ? Self.bannerSize(store: store) : Self.size(expanded: expanded, store: store)
        let margin = Self.margin(expanded: expanded)
        let size = NSSize(width: shape.width + margin * 2, height: shape.height + margin)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
        targetFrame = frame
        targetMargin = margin
        defer { refreshMouseThrough?() }
        // Under Reduce Animations the content is placed at once; a window
        // still easing after it was the two coming apart for the length of
        // the animation.
        guard animated, !Motion.reduced else {
            panel.setFrame(frame, display: true)
            return
        }
        let growing = expanded || bannerShown
        NSAnimationContext.runAnimationGroup { context in
            // The banner opens like the Dynamic Island, with a clear rebound;
            // the panel keeps its touch of overshoot.
            context.duration = bannerShown && !expanded ? 0.52 : (growing ? 0.34 : 0.3)
            context.timingFunction = bannerShown && !expanded
                ? CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
                : growing
                    ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.04)
                    : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// The screen the owner chose; else the built-in display that actually
    /// has a notch; else the screen holding the menu bar. `NSScreen.main`
    /// follows the key window, which for a menu-bar-only app can be any
    /// display.
    static var hostScreen: NSScreen? {
        ScreenChoice.chosen
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    static func size(expanded: Bool, store: UsageStore) -> NSSize {
        let slots = store.islandSlots
        let notch = notchMetrics()
        if expanded {
            // Rows per column: the left column is the fuller one.
            let rows = min(slots, max(1, store.islandProviders.count))
            return NSSize(
                width: IslandPanelLayout.width(notchWidth: notch?.notchWidth),
                height: IslandPanelLayout.height(rows: rows, notch: notch?.height ?? 0))
        }
        if let notch {
            return NSSize(width: notch.totalWidth(slots: slots), height: notch.height)
        }
        return NSSize(width: 220, height: 40)
    }

    /// The strip with the reset banner hanging under it.
    static func bannerSize(store: UsageStore) -> NSSize {
        let collapsed = size(expanded: false, store: store)
        return NSSize(width: max(collapsed.width, 400), height: collapsed.height + ResetBannerRow.height)
    }

    /// Where the notch is, and how much room sits either side of it.
    struct NotchMetrics {
        let notchWidth: CGFloat
        let height: CGFloat

        /// One slot is "5d 17h · 70%" and a mark; two are a mark and a
        /// figure each; three need a little more. Kept narrow enough to stay
        /// in the dead zone — past this the strip starts covering the app's
        /// own menus on the left and the status items on the right.
        func sideWidth(slots: Int) -> CGFloat {
            switch slots {
            case ...1: 132
            case 2: 132
            default: 176
            }
        }

        func totalWidth(slots: Int) -> CGFloat { notchWidth + sideWidth(slots: slots) * 2 }
    }

    /// nil on a screen with no notch, which is most external displays. The
    /// caller falls back to the pill; a strip built around a zero-width notch
    /// would just be a centred bar sitting on top of the menu bar's own items.
    static func notchMetrics() -> NotchMetrics? {
        guard let screen = hostScreen else { return nil }
        let height = screen.safeAreaInsets.top
        guard height > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        let notch = screen.frame.width - left.width - right.width
        guard notch > 40 else { return nil }
        return NotchMetrics(notchWidth: notch, height: height)
    }
}

// MARK: - View

struct IslandView: View {
    @ObservedObject var store: UsageStore
    var coordinator: IslandCoordinator
    @ObservedObject var bridge: IslandCoordinator.Bridge
    @State private var expanded = false
    /// The panel's content fades in a beat after the silhouette starts to
    /// grow, and is gone before it starts to shrink — the shape is the
    /// animation, the content arrives in it.
    @State private var contentVisible = false
    @State private var hovering = false
    @State private var peekTask: Task<Void, Never>?
    /// Opens the island once the pointer has rested on it.
    @State private var dwellTask: Task<Void, Never>?
    /// Gives up on a rest the pointer walked away from.
    @State private var leaveTask: Task<Void, Never>?
    /// The half second ran out during a slip off the edge; coming back
    /// within the grace opens the island without starting it over.
    @State private var rested = false

    /// How long the pointer rests on the closed island before it opens. It
    /// used to open on contact, so a pointer passing on its way to the menu
    /// bar grew and shrank the panel; a click opens it at once. Half a
    /// second, the owner's pick after trying a full one.
    static let hoverDelay: Duration = .milliseconds(500)
    /// How long the pointer may slip off the closed strip and still be
    /// resting on it. The strip is a menu bar tall, and a hand settling on
    /// it grazes its edge; each graze used to start the half second over.
    static let leaveGrace: Duration = .milliseconds(120)

    var body: some View {
        ZStack(alignment: .top) {
            // Round the collapsed island only: open, the panel is the whole
            // story and a ring of light round it was just noise.
            if store.experience.islandGlow {
                IslandGlow(
                    shape: silhouette,
                    color: glowColor,
                    // The halo is a shadow, drawn once and composited; the
                    // sweep is motion, and motion with nothing happening is
                    // what kept a core busy (issue #5).
                    ambient: !expanded,
                    sweeping: !expanded && !bridge.occluded && !Motion.reduced
                        && (store.experience.islandSweepAlways || glowEvent))
            }
            if lowQuota != .none, !expanded {
                LowQuotaFlash(shape: silhouette, color: Palette.alert(lowQuota), animating: !bridge.occluded)
                    .transition(.opacity)
            }
            silhouette.fill(Color.black)
            if expanded {
                // The panel is its full size from the first frame, whatever
                // it is offered, so a clip on the panel itself cuts nothing.
                // The clear colour takes what the black shape takes, and the
                // panel rides on it: clipped to the shape as it grows and
                // shrinks, and no longer stretching the stack past a window
                // still small.
                Color.clear
                    .overlay(alignment: .top) {
                        IslandPanel(store: store, notch: notchMetrics, bridge: bridge)
                            .opacity(contentVisible ? 1 : 0)
                            .offset(y: contentVisible ? 0 : -8)
                            .allowsHitTesting(contentVisible)
                    }
                    .clipShape(silhouette)
                    .transition(.opacity)
            } else if let notch = notchMetrics {
                VStack(spacing: 0) {
                    NotchStrip(store: store, metrics: notch, slots: store.islandSlots)
                    if let banner = bridge.banner {
                        ResetBannerRow(banner: banner).id(banner.id)
                    }
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    compactPill
                    if let banner = bridge.banner {
                        ResetBannerRow(banner: banner).id(banner.id)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The rectangle the coordinator lets the mouse through to. The
        // rounded silhouette left two corners that took the click and did
        // nothing with it.
        .contentShape(Rectangle())
        // Where the pointer is comes from the coordinator: the tracking
        // area misses a pointer that arrives and stops, and reports one gone
        // that is over a panel still growing.
        .onHover { _ in coordinator.pointerMayHaveLeft() }
        .onChange(of: bridge.pointerInside) { _, _ in pointerMoved() }
        // Shown under a pointer already resting on it.
        .onAppear { pointerMoved() }
        // A click opens the closed island without the wait. Simultaneous, so
        // the open panel's own buttons and chips still take their clicks.
        .simultaneousGesture(TapGesture().onEnded {
            guard !expanded else { return }
            cancelDwell()
            setExpanded(true)
        })
        // The margin rides the window's own curve. Padding has nothing to
        // interpolate, so an animation scoped to it moved nothing: the
        // silhouette jumped to its new margin while the window had barely
        // set off.
        .animation(Motion.animation(IslandCoordinator.frameCurve(expanded: expanded))) { content in
            content.modifier(IslandMargin(margin: IslandCoordinator.margin(expanded: expanded)))
        }
        .onChange(of: bridge.peek) { _, _ in
            // A window just crossed its warning: open for four seconds, then
            // close again unless the pointer has arrived meanwhile.
            setExpanded(true)
            peekTask?.cancel()
            peekTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, !hovering else { return }
                setExpanded(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .honoursReducedMotion()
    }

    private func pointerMoved() {
        let inside = bridge.pointerInside
        guard inside != hovering else { return }
        hovering = inside
        peekTask?.cancel()
        leaveTask?.cancel()
        leaveTask = nil
        guard inside else {
            if coordinator.isOpen {
                cancelDwell()
                setExpanded(false)
            } else {
                leaveTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.leaveGrace)
                    guard !Task.isCancelled, !hovering else { return }
                    cancelDwell()
                }
            }
            return
        }
        // Back on an open island — or one still closing — keeps it open.
        if coordinator.isOpen {
            cancelDwell()
            setExpanded(true)
            return
        }
        // Back from a slip: the rest it interrupted is either still
        // counting or ran out while the pointer was off the edge.
        if dwellTask != nil {
            if rested {
                cancelDwell()
                setExpanded(true)
            }
            return
        }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            guard hovering else {
                rested = true
                return
            }
            cancelDwell()
            setExpanded(true)
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        rested = false
    }

    private func setExpanded(_ value: Bool) {
        coordinator.requestExpanded(value) { value in
            // The strip and the panel change places in a fade, under the
            // shape's own move; swapped in one frame, the figures landed at
            // the top of a black block that then shrank round them.
            withAnimation(Motion.animation(.easeOut(duration: 0.16))) { expanded = value }
            if value {
                withAnimation(Motion.animation(.easeOut(duration: 0.22).delay(0.1))) { contentVisible = true }
            } else {
                withAnimation(Motion.animation(.easeOut(duration: 0.12))) { contentVisible = false }
            }
        }
    }

    /// What makes the light run when it is not set to run always: a read in
    /// flight, the pointer on the island, a banner, or a quota near its end.
    private var glowEvent: Bool {
        hovering || bridge.banner != nil || store.islandShown.contains { store.isLoading($0) } || store.isComputingCost || severity != .none || lowQuota != .none
    }

    private var lowQuota: AlertLevel { store.islandLowQuota }
    private var severity: AlertLevel { store.islandSeverity }

    /// Cobalt at rest; amber or red when a tracked window is past its line.
    private var glowColor: Color {
        if let banner = bridge.banner { return banner.provider.accent }
        switch severity {
        case .none: return lowQuota == .none ? Palette.cobalt : Palette.alert(lowQuota)
        case .warning, .critical: return Palette.alert(max(severity, lowQuota))
        }
    }

    /// Read per render rather than captured at construction: the app survives
    /// the display arrangement changing under it, and the strip only exists on
    /// a notched screen.
    private var notchMetrics: IslandCoordinator.NotchMetrics? {
        IslandCoordinator.notchMetrics()
    }

    /// Flat against the screen's top edge, 14pt at the bottom corners — the
    /// notch's own curve, and codex-island's.
    private var silhouette: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            topTrailingRadius: 0,
            style: .continuous)
    }

    // MARK: Compact pill (no notch)

    private var compactPill: some View {
        HStack(spacing: Design.space2 + 2) {
            ZStack {
                Circle().fill(Design.accent)
                Text("Q")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Design.ink)
            }
            .frame(width: 20, height: 20)

            ForEach(store.islandShown) { id in
                if let used = store.headlinePercent(for: id, on: .island) {
                    // Same glanceable role as the menu-bar glyph, so it follows
                    // the same remaining/used preference.
                    let shown = store.meterMode.shownPercent(fromUsed: used)
                    HStack(spacing: Design.space1) {
                        ProviderGlyph(id: id, size: 13, tint: .white)
                        Text("\(Int(shown.rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                } else if let balance = store.balanceFigure(for: id) {
                    HStack(spacing: Design.space1) {
                        ProviderGlyph(id: id, size: 13, tint: .white)
                        Text(balance)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            LiveDot(level: severity, warn: store.islandShown.contains { store.failingProviders.contains($0) })
        }
        .padding(.horizontal, Design.space3)
        .frame(height: 40)
    }
}

/// The glow's room round the silhouette, as a value SwiftUI can animate:
/// each frame of the curve lays the shape out again at the margin between.
private struct IslandMargin: ViewModifier, Animatable {
    var margin: CGFloat

    var animatableData: CGFloat {
        get { margin }
        set { margin = newValue }
    }

    func body(content: Content) -> some View {
        // The opening curve overshoots, and a margin below nothing would
        // push the shape past the window's edge.
        let margin = max(0, margin)
        content
            .padding(.horizontal, margin)
            .padding(.bottom, margin)
    }
}

// MARK: - Reset banner

/// The row under the notch when a window resets: a small ring filling in the
/// provider's colour round its mark, "Limit reset" and which window, and
/// what is left counting up to the new figure.
struct ResetBannerRow: View {
    static let height: CGFloat = 60
    let banner: ResetBanner
    var settled = false
    @State private var arrived: Bool

    init(banner: ResetBanner, settled: Bool = false) {
        self.banner = banner
        self.settled = settled
        _arrived = State(initialValue: settled)
    }

    var body: some View {
        HStack(spacing: Design.space3) {
            ZStack {
                RefillRing(color: banner.provider.accent, from: banner.leftBefore / 100, to: banner.leftNow / 100, lineWidth: 3, delay: 0.5, settled: settled)
                ProviderGlyph(id: banner.provider, size: 17, tint: .white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Limit reset", "额度已重置"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(banner.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: Design.space2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUpNumber(from: banner.leftBefore, to: banner.leftNow, delay: 0.55, settled: settled)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(banner.provider.accent)
                Text(L10n.t("% left", "% 可用"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(.horizontal, Design.space4 + 4)
        .frame(height: Self.height)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -8)
        .onAppear {
            guard !settled else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.3).delay(0.22))) { arrived = true }
        }
    }
}

/// Alert indicator dot for the compact pill.
struct LiveDot: View {
    let level: AlertLevel
    var warn: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(warn ? L10n.t("A provider is not updating", "有服务商未能更新") : level.displayName)
    }

    private var color: Color {
        if let hex = level.hex { return Color(hex: hex) }
        return warn ? .orange : Design.accent
    }
}

// MARK: - Notch strip

/// The collapsed island on a notched Mac: the figures sit in the dead space
/// either side of the notch instead of in a pill beside it.
///
/// The two sides are mirrored — the figure is always on the outer edge and the
/// mark always against the notch — so the pair reads outward from the middle
/// rather than left-to-right across a gap you cannot draw in. With one slot a
/// side, the slot also carries the reset countdown; with two or three, each
/// is a mark and a figure, nearest the notch first, in the order enabled.
struct NotchStrip: View {
    @ObservedObject var store: UsageStore
    let metrics: IslandCoordinator.NotchMetrics
    var slots: Int = 1

    private var left: [ProviderID] { IslandRoom.columns(store.islandProviders, slots: slots).left }
    private var right: [ProviderID] { IslandRoom.columns(store.islandProviders, slots: slots).right }

    var body: some View {
        HStack(spacing: 0) {
            side(left, mirrored: true)
                .frame(width: metrics.sideWidth(slots: slots))
            // The notch itself. Painted black like the rest so the strip reads
            // as one shape continuous with the hardware, not two tabs.
            Color.black.frame(width: metrics.notchWidth)
            side(right, mirrored: false)
                .frame(width: metrics.sideWidth(slots: slots))
        }
        .frame(height: metrics.height)
    }

    @ViewBuilder
    private func side(_ ids: [ProviderID], mirrored: Bool) -> some View {
        if slots <= 1 {
            NotchSlot(store: store, id: ids.first, mirrored: mirrored)
        } else {
            HStack(spacing: Design.space2 + 2) {
                // Nearest the notch first: the left side is laid out in
                // reverse so its first provider sits against the middle.
                ForEach(mirrored ? ids.reversed() : ids) { id in
                    NotchMiniSlot(store: store, id: id)
                }
            }
            .padding(.horizontal, Design.space2 + 2)
            .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
        }
    }
}

/// Mark and figure, and nothing else: what fits when a side holds two or
/// three providers.
struct NotchMiniSlot: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: 4) {
            ProviderGlyph(id: id, size: 13, tint: Color(hex: id.accentHex))
            if let used = store.headlinePercent(for: id, on: .island) {
                let shown = store.meterMode.shownPercent(fromUsed: used)
                Text("\(Int(shown.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: id.accentHex))
            } else if let balance = store.balanceFigure(for: id) {
                // A balance has no percentage; its amount is the reading.
                Text(balance)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: id.accentHex))
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

struct NotchSlot: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID?
    let mirrored: Bool

    var body: some View {
        HStack(spacing: 5) {
            if mirrored {
                figure
                separator
                tick
                glyph
            } else {
                glyph
                tick
                separator
                figure
            }
        }
        .padding(.horizontal, Design.space2 + 2)
        .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
    }

    // MARK: Pieces

    @ViewBuilder
    private var glyph: some View {
        if let id {
            // The mark in the brand colour, the same one the figure wears, so
            // each side of the notch reads as one thing in one colour. `tint`
            // only reaches the monochrome marks: Claude stays terracotta and
            // Gemini four-colour either way; Codex turns from white to blue.
            ProviderGlyph(id: id, size: 14, tint: Color(hex: id.accentHex))
        }
    }

    @ViewBuilder
    private var figure: some View {
        if let id, let percent = shownPercent {
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                // Raw brand colour: every accent is required to clear 4.5:1 on
                // black, asserted in ProviderRegistryTests.
                .foregroundStyle(Color(hex: id.accentHex))
        } else if id != nil {
            Text("—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private var tick: some View {
        if let resetsAt {
            Text(QuotaFormat.tick(to: resetsAt))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var separator: some View {
        if resetsAt != nil, shownPercent != nil {
            Text("·").foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: Data

    private var snapshot: UsageSnapshot? {
        guard let id else { return nil }
        return store.states[id]?.snapshot
    }

    /// Follows the same remaining/used preference as the menu-bar glyph — both
    /// are the same glanceable role and disagreeing would be a bug report.
    private var shownPercent: Double? {
        id.flatMap { store.headlinePercent(for: $0, on: .island) }.map { store.meterMode.shownPercent(fromUsed: $0) }
    }

    private var resetsAt: Date? {
        id.flatMap { store.headlineWindow(for: $0, on: .island) }?.resetsAt
    }
}


// MARK: - Glow

/// codex-island's halo: a soft coloured shadow round the silhouette and a
/// light that orbits its outline. Cobalt at rest, amber or red past the
/// alert lines; the sweep pauses when nobody can see the island.
struct IslandGlow: View {
    let shape: UnevenRoundedRectangle
    let color: Color
    /// Halo on.
    let ambient: Bool
    /// Orbiting light on.
    let sweeping: Bool

    var body: some View {
        ZStack {
            if sweeping {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let rotation = (context.date.timeIntervalSinceReferenceDate * 100).truncatingRemainder(dividingBy: 360)
                    shape
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: color.opacity(0), location: 0.55),
                                    .init(color: color, location: 0.78),
                                    .init(color: .white.opacity(0.95), location: 0.92),
                                    .init(color: color.opacity(0), location: 1),
                                ]),
                                center: .center,
                                angle: .degrees(rotation)),
                            lineWidth: 4)
                        .blur(radius: 3)
                }
                .transition(.opacity)
            }
            shape
                .fill(Color.black)
                .shadow(color: color.opacity(ambient ? 0.35 : 0), radius: 14)
        }
        .animation(.easeInOut(duration: 0.45), value: color)
        .animation(.easeInOut(duration: 0.25), value: ambient)
        .animation(.easeInOut(duration: 0.25), value: sweeping)
        .allowsHitTesting(false)
    }
}

/// A quota nearly out: the outline brightens and dims about once a second,
/// amber for the last 15%, red for the last 5%. Drawn under the black like
/// the glow, so only the outer half of the line and its bloom show. Held
/// steady under Reduce Animations and when nobody can see it.
struct LowQuotaFlash<S: Shape>: View {
    let shape: S
    let color: Color
    var animating = true

    /// Seconds from bright to dim and back.
    static var period: Double { 1.2 }

    @State private var dim = false

    var body: some View {
        let live = animating && !Motion.reduced
        // One animation Core Animation runs on the layer, not a frame drawn
        // 30 times a second: the stroke and its bloom are rendered once and
        // only the opacity moves (issue #5).
        shape
            .stroke(color, lineWidth: 4)
            .shadow(color: color.opacity(0.9), radius: 7)
            .opacity(live && dim ? 0.25 : 1)
            .animation(
                live ? .easeInOut(duration: Self.period / 2).repeatForever(autoreverses: true) : .default,
                value: dim)
            .onAppear { dim = live }
            .onChange(of: live) { _, now in dim = now }
            .allowsHitTesting(false)
    }
}

/// Hosts the island: first click counts, and a two-finger horizontal swipe
/// (or shift-scroll) turns the open panel's pages.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var coordinator: IslandCoordinator?
    private var swipeX: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator, coordinator.expanded else { return super.scrollWheel(with: event) }
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
        switch event.phase {
        case .began: swipeX = 0
        case .changed: swipeX += horizontal
        case .ended:
            if abs(swipeX) > 40 { coordinator.turnPage(swipeX < 0 ? 1 : -1) }
            swipeX = 0
        default:
            if event.phase.isEmpty, abs(horizontal) > 2 { coordinator.turnPage(horizontal < 0 ? 1 : -1) }
        }
    }
}

extension IslandCoordinator {
    func turnPage(_ step: Int) {
        bridge.turnPage(step, store: store)
    }
}
