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
        expanded ? NSSize(width: 388, height: 760) : NSSize(width: 220, height: 40)
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
            } else {
                compactPill
            }
        }
        .background(
            RoundedRectangle(cornerRadius: expanded ? Design.radiusPanel + 10 : 20, style: .continuous)
                .fill(Color.black))
        .clipShape(
            RoundedRectangle(cornerRadius: expanded ? Design.radiusPanel + 10 : 20, style: .continuous))
        .onHover { hovering in
            coordinator.requestExpanded(hovering) { expanded = $0 }
        }
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
                    .font(.system(size: 12, weight: .bold))
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
