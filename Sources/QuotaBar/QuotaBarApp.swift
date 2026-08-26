import SwiftUI
import AppKit
import QuotaCore

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()
    private let island = IslandCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.render(
                percent: store.headlinePercent,
                style: store.menuBarStyle,
                level: store.alertLevel,
                mode: store.meterMode))
                .onAppear { island.sync(store: store) }
                .onChange(of: store.presentation) { _, _ in island.sync(store: store) }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist carries LSUIElement for the packaged app; setting it here
        // too keeps the dev loop (bare binary, no bundle) out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "./snapshots"
            Snapshot.run(directory: directory)
            NSApp.terminate(nil)
        }
        if arguments.contains("--cost") {
            Diagnostics.printCost()
            NSApp.terminate(nil)
        }
    }
}
