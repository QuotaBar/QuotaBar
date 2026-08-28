import AppKit
import SwiftUI
import QuotaCore

/// A strip docked to the right edge of the screen that hides itself until the
/// pointer reaches the edge.
///
/// The panel is always present and always at the edge; hiding is done by
/// sliding it off-screen and leaving a sliver behind. That keeps the reveal
/// entirely inside the panel's own tracking area — no global mouse monitor,
/// which would be a heavier thing to ask of the system for a hover affordance.
@MainActor
final class EdgeDockCoordinator {
    private var panel: NSPanel?
    /// The callout lives in its own panel. Drawing it inside the strip would
    /// need a panel wide enough to hold it, and that panel's empty region
    /// would swallow clicks meant for whatever is underneath.
    private var calloutPanel: NSPanel?
    private var collapseTask: Task<Void, Never>?
    private var expanded = false

    static let calloutWidth: CGFloat = 260
    /// One ring plus its label plus the stack spacing.
    static let cellHeight: CGFloat = 78

    /// Collapsed, the dock is a handle rather than a sliver of the strip.
    /// Five points of an off-screen panel is neither visible nor clickable —
    /// it reads as the feature not being there at all.
    static let handleWidth: CGFloat = 18
    static let handleHeight: CGFloat = 92
    static let width: CGFloat = 74

    func sync(store: UsageStore) {
        if store.presentation == .edgeDock {
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
        hideCallout()
        expanded = false
    }

    // MARK: Callout

    /// Shows the bubble beside ring `index`, or hides it when nil.
    func showCallout<Content: View>(
        at index: Int?,
        total: Int,
        @ViewBuilder content: () -> Content)
    {
        guard let index, expanded, let strip = panel else {
            hideCallout()
            return
        }
        let host = NSHostingView(rootView: content())
        let size = host.fittingSize
        let panel = calloutPanel ?? makeCalloutPanel()
        panel.contentView = host

        // Line the bubble up with the ring it belongs to. The strip lays its
        // rings out from the top, and AppKit measures from the bottom.
        let stripFrame = strip.frame
        let insetTop = Design.space4
        let centreFromTop = insetTop + CGFloat(index) * Self.cellHeight + Self.cellHeight / 2
        let centreY = stripFrame.maxY - centreFromTop
        let height = max(size.height, 40)
        let x = stripFrame.minX - Self.calloutWidth - Design.space2
        panel.setFrame(
            NSRect(x: x, y: centreY - height / 2, width: Self.calloutWidth, height: height),
            display: true)
        panel.orderFrontRegardless()
        calloutPanel = panel
    }

    func hideCallout() {
        calloutPanel?.orderOut(nil)
        calloutPanel = nil
    }

    private func makeCalloutPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.calloutWidth, height: 40)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Purely informational: never take a click that was meant for the
        // window underneath.
        panel.ignoresMouseEvents = true
        return panel
    }

    private func show(store: UsageStore) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 200)),
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
        panel.contentView = NSHostingView(
            rootView: EdgeDockView(store: store, coordinator: self))
        self.panel = panel
        layout(expanded: false, height: nil)
        panel.orderFrontRegardless()
    }

    /// Whether the strip should sit fully on screen regardless of the pointer.
    var alwaysVisible: Bool { ConfigStore.shared.dockAlwaysVisible }

    /// Collapsing is delayed so a pointer crossing the strip on its way
    /// somewhere else does not make it flap open and shut.
    func setExpanded(_ value: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        if value {
            expanded = true
            apply(true)
            layout(expanded: true, height: nil)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self?.expanded = false
            apply(false)
            self?.hideCallout()
            self?.layout(expanded: false, height: nil)
        }
    }

    /// The strip is as tall as its contents, so the panel resizes as providers
    /// are enabled or disabled.
    func setContentHeight(_ height: CGFloat) {
        layout(expanded: expanded, height: height)
    }

    private var lastHeight: CGFloat = 200

    private func layout(expanded: Bool, height: CGFloat?) {
        guard let panel, let screen = Self.hostScreen else { return }
        if let height { lastHeight = max(80, height) }
        let config = ConfigStore.shared
        let visible = screen.visibleFrame
        // Always-visible means the full strip, whatever the pointer is doing.
        let out = expanded || config.dockAlwaysVisible

        // Both states sit flush against the edge and are fully on screen; what
        // changes is how wide and tall the panel is.
        let panelWidth = out ? Self.width : Self.handleWidth
        let panelHeight = out ? lastHeight : Self.handleHeight
        let x = config.dockEdge == .right
            ? visible.maxX - panelWidth
            : visible.minX

        // dockPosition is a fraction from the top; AppKit measures from the
        // bottom, and the panel is kept fully on screen at either extreme.
        let travel = max(0, visible.height - panelHeight)
        let y = visible.maxY - panelHeight - travel * CGFloat(config.dockPosition)
        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: true,
            animate: true)
    }

    /// Records where the user dragged the strip to, as a fraction of the
    /// available travel.
    func persistPosition() {
        guard let panel, let screen = Self.hostScreen else { return }
        let visible = screen.visibleFrame
        let travel = max(1, visible.height - panel.frame.height)
        let fromTop = visible.maxY - panel.frame.maxY
        ConfigStore.shared.dockPosition = Double(fromTop / travel)
    }

    func move(byVertical delta: CGFloat) {
        guard let panel, let screen = Self.hostScreen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.y = min(
            max(frame.origin.y - delta, visible.minY),
            visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    /// The screen holding the menu bar. `NSScreen.main` follows the key window,
    /// which for a menu-bar-only app can be any display.
    static var hostScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }
}

struct EdgeDockView: View {
    @ObservedObject var store: UsageStore
    var coordinator: EdgeDockCoordinator
    @State private var expanded = false
    @State private var hovered: ProviderID?

    @Environment(\.openSettings) private var openSettings

    private var onLeft: Bool { store.dockEdge == .left }

    private var showsStrip: Bool { expanded || coordinator.alwaysVisible }

    var body: some View {
        Group {
            if showsStrip {
                HStack(spacing: 0) {
                    if !onLeft { Spacer(minLength: 0) }
                    strip
                    if onLeft { Spacer(minLength: 0) }
                }
            } else {
                handle
            }
        }
        .onHover { inside in
            coordinator.setExpanded(inside) { expanded = $0 }
            if !inside { hovered = nil }
        }
        .onChange(of: hovered) { _, id in
            presentCallout(for: id)
        }
        .onChange(of: expanded) { _, isOpen in
            if !isOpen { coordinator.hideCallout() }
        }
    }

    /// What the dock looks like at rest: a slim tab carrying the worst reading,
    /// so it is both a target to aim at and worth a glance on its own.
    private var handle: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: onLeft ? 0 : 9,
                bottomLeadingRadius: onLeft ? 0 : 9,
                bottomTrailingRadius: onLeft ? 9 : 0,
                topTrailingRadius: onLeft ? 9 : 0,
                style: .continuous)
                .fill(Color.black.opacity(0.85))
            GeometryReader { proxy in
                VStack {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(handleTint)
                        .frame(width: 4, height: max(6, proxy.size.height * 0.7 * headlineFraction))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
        }
        .frame(
            width: EdgeDockCoordinator.handleWidth,
            height: EdgeDockCoordinator.handleHeight)
    }

    private var headlineFraction: CGFloat {
        CGFloat(min(max(store.headlinePercent ?? 0, 0), 100) / 100)
    }

    private var handleTint: Color {
        guard store.headlinePercent != nil else { return .white.opacity(0.35) }
        if let hex = store.alertLevel.hex { return Color(hex: hex) }
        return Color(hex: "34C759")
    }

    private func presentCallout(for id: ProviderID?) {
        let index = id.flatMap { store.enabled.firstIndex(of: $0) }
        coordinator.showCallout(at: index, total: store.enabled.count) {
            if let id {
                ProviderCallout(
                    id: id,
                    phase: store.states[id],
                    alerts: store.alertSettings)
            }
        }
    }

    private var strip: some View {
        VStack(spacing: Design.space3) {
            ForEach(store.enabled) { id in
                ProviderRing(
                    id: id,
                    percent: store.states[id]?.snapshot?.headlinePercent,
                    alerts: store.alertSettings)
                    .onHover { inside in
                        hovered = inside ? id : (hovered == id ? nil : hovered)
                    }
                    .onTapGesture {
                        // Focus that provider and open the full panel — the
                        // strip is a summary, not a replacement for it.
                        store.selected = id
                        openSettings()
                        SettingsWindow.focus()
                    }
            }
        }
        .padding(.vertical, Design.space4)
        .frame(width: EdgeDockCoordinator.width)
        .background(
            // Rounded only on the side facing the screen; the other runs off
            // the edge.
            UnevenRoundedRectangle(
                topLeadingRadius: onLeft ? 0 : Design.radiusPanel + 6,
                bottomLeadingRadius: onLeft ? 0 : Design.radiusPanel + 6,
                bottomTrailingRadius: onLeft ? Design.radiusPanel + 6 : 0,
                topTrailingRadius: onLeft ? Design.radiusPanel + 6 : 0,
                style: .continuous)
                .fill(Color.black))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { coordinator.move(byVertical: $0.translation.height) }
                .onEnded { _ in coordinator.persistPosition() })
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    coordinator.setContentHeight(height)
                }
            })

    }

}
