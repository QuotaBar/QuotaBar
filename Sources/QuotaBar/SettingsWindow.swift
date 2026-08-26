import AppKit

/// Brings the Settings window to the front after SwiftUI has created it.
///
/// `openSettings()` does create the window, but an accessory app (`LSUIElement`)
/// is never activated as a side effect, so the window is ordered in behind
/// whatever the user was already looking at. From their side the menu simply
/// closes and nothing happens.
///
/// Order matters: activating *before* the window exists does nothing, because
/// there is no window to bring forward. Hence the hop to the next runloop turn.
enum SettingsWindow {
    static func focus() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            // The status item and the notch island are ours too, but neither
            // can become main — so this picks out the real settings window
            // without matching on a private class name or a localized title.
            NSApp.windows
                .first { $0.canBecomeMain && $0.isVisible }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
