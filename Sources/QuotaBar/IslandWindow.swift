import AppKit
import SwiftUI
import QuotaCore

/// Notch-island presentation: a borderless floating panel pinned to the top
/// center of the screen (over the notch on notched Macs). Compact pill at
/// rest, hover expands to the full panel. The menu-bar item stays as the
/// settings entry point.
@MainActor
final class IslandCoordinator {
    private var panel: NSPanel?
    private var collapseTask: Task<Void, Never>?

    func sync(store: UsageStore) {
        if store.presentation == .island {
            show(store: store)
        } else {
            hide()
        }
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(store: UsageStore) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size(expanded: false)),
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
        panel.contentView = NSHostingView(rootView: IslandView(store: store, coordinator: self))
        self.panel = panel
        layout(expanded: false)
        panel.orderFrontRegardless()
    }

    /// Collapsing is delayed so a quick pointer sweep across the pill does not
    /// make the panel flicker open and shut.
    func requestExpanded(_ expanded: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        if expanded {
            apply(true)
            layout(expanded: true)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            apply(false)
            self?.layout(expanded: false)
        }
    }

    func layout(expanded: Bool) {
        guard let panel, let screen = Self.hostScreen else { return }
        let size = Self.size(expanded: expanded)
        // Anchor to the visible frame's top so the pill sits under the notch
        // rather than behind the menu bar on non-notched displays.
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    /// Prefer the built-in display that actually has a notch; fall back to the
    /// screen holding the menu bar. `NSScreen.main` follows the key window,
    /// which for a menu-bar-only app can be any display.
    static var hostScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    static func size(expanded: Bool) -> NSSize {
        if expanded { return NSSize(width: 388, height: 760) }
        if let notch = notchMetrics() {
            return NSSize(width: notch.totalWidth, height: notch.height)
        }
        return NSSize(width: 220, height: 40)
    }

    /// Where the notch is, and how much room sits either side of it.
    struct NotchMetrics {
        let notchWidth: CGFloat
        let height: CGFloat

        /// Wide enough for "5d 17h · 70%" and a mark, narrow enough to stay in
        /// the dead zone — past this the strip starts covering the app's own
        /// menus on the left and the status items on the right.
        var sideWidth: CGFloat { 132 }
        var totalWidth: CGFloat { notchWidth + sideWidth * 2 }
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

struct IslandView: View {
    @ObservedObject var store: UsageStore
    var coordinator: IslandCoordinator
    @State private var expanded = false

    var body: some View {
        Group {
            if expanded {
                expandedContent
                    .background(panelShape.fill(Color.black))
                    .clipShape(panelShape)
            } else if let notch = notchMetrics {
                NotchStrip(store: store, metrics: notch)
            } else {
                compactPill
                    .background(pillShape.fill(Color.black))
                    .clipShape(pillShape)
            }
        }
        .onHover { hovering in
            coordinator.requestExpanded(hovering) { expanded = $0 }
        }
    }

    /// Read per render rather than captured at construction: the app survives
    /// the display arrangement changing under it, and the strip only exists on
    /// a notched screen.
    private var notchMetrics: IslandCoordinator.NotchMetrics? {
        IslandCoordinator.notchMetrics()
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.radiusPanel + 10, style: .continuous)
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    // MARK: Compact pill

    private var compactPill: some View {
        HStack(spacing: Design.space2 + 2) {
            ZStack {
                Circle().fill(Design.accent)
                Text("Q")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Design.ink)
            }
            .frame(width: 20, height: 20)

            ForEach(store.enabled.prefix(3)) { id in
                if let used = store.states[id]?.snapshot?.headlinePercent {
                    // Same glanceable role as the menu-bar glyph, so it follows
                    // the same remaining/used preference.
                    let shown = store.meterMode.shownPercent(fromUsed: used)
                    HStack(spacing: Design.space1) {
                        ProviderGlyph(id: id, size: 13, tint: .white)
                        Text("\(Int(shown.rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            LiveDot(level: store.alertLevel, warn: !store.failingProviders.isEmpty)
        }
        .padding(.horizontal, Design.space3)
        .frame(height: 40)
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("QuotaBar")
                    .font(Design.wordmark(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { SettingsWindow.focus() })
            }
            .padding(.horizontal, Design.space4)
            .padding(.top, Design.space3)
            .padding(.bottom, Design.space1)

            // The island lives in a fixed-size floating panel, so this is the
            // one place that still needs to scroll when a lot of providers are
            // enabled.
            ScrollView {
                MenuContentBody(store: store, scrollable: false)
                    .padding(.horizontal, Design.space3)
                    .padding(.bottom, Design.space3)
            }
            .frame(height: IslandCoordinator.size(expanded: true).height - 60)
        }
        .environment(\.colorScheme, .dark)
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
/// rather than left-to-right across a gap you cannot draw in.
///
/// Only two providers fit. That is the notch's constraint, not a choice: the
/// strip has to stay clear of the app's own menus on one side and the status
/// items on the other. It shows the first two enabled, so the order is the
/// user's.
struct NotchStrip: View {
    @ObservedObject var store: UsageStore
    let metrics: IslandCoordinator.NotchMetrics

    var body: some View {
        let slots = Array(store.enabled.prefix(2))
        HStack(spacing: 0) {
            NotchSlot(store: store, id: slots.first, mirrored: true)
                .frame(width: metrics.sideWidth)
            // The notch itself. Painted black like the rest so the strip reads
            // as one shape continuous with the hardware, not two tabs.
            Color.black.frame(width: metrics.notchWidth)
            NotchSlot(store: store, id: slots.count > 1 ? slots[1] : nil, mirrored: false)
                .frame(width: metrics.sideWidth)
        }
        .frame(height: metrics.height)
        .background(Color.black)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0,
                style: .continuous))
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
            // `tint` only reaches the monochrome marks, so Claude stays orange
            // and Gemini stays four-colour while Codex is lifted off the black.
            ProviderGlyph(id: id, size: 14, tint: .white)
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
        snapshot?.headlinePercent.map { store.meterMode.shownPercent(fromUsed: $0) }
    }

    private var resetsAt: Date? {
        snapshot?.headlineWindow?.resetsAt
    }
}
