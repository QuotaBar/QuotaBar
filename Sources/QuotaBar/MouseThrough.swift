import AppKit

// MARK: - Clicks through a borderless panel

/// The island and the edge dock are panels larger than what they draw, and
/// the empty part must not swallow clicks meant for the window underneath.
/// Both watched the pointer the same way, in the same fifteen lines; this is
/// those lines, once.
@MainActor
enum MouseThrough {
    /// Runs `update` now and on every pointer move, inside this app and out,
    /// and hands back the monitors to remove when the panel goes. `update`
    /// decides what counts as inside and sets `ignoresMouseEvents`.
    static func monitors(update: @escaping () -> Void) -> [Any] {
        update()
        var monitors: [Any] = []
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            MainActor.assumeIsolated { update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            MainActor.assumeIsolated { update() }
            return event
        }) {
            monitors.append(local)
        }
        return monitors
    }
}
