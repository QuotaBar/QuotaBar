import AppKit
import SwiftUI
import QuotaCore

/// Renders the panel off-screen to a PNG: `QuotaBar --snapshot <dir>`.
///
/// Exists so the layout can be inspected without a Mac in front of you — the
/// app is a menu-bar agent, so there is no window to screenshot in CI, and a
/// broken panel would otherwise only show up when a user clicks the icon.
///
/// Two renderer limitations to keep in mind when reading the output, neither of
/// which reflects how the app behaves on screen:
///
/// - `ScrollView` contents are not laid out, so panels render with
///   `scrollable: false`.
/// - AppKit-backed controls (`.borderless` buttons, `ProgressView`) come out as
///   yellow placeholder glyphs.
///
/// `SettingsView` is excluded outright: it assigns `@State` from `onAppear`,
/// which `ImageRenderer` cannot service — it renders outside a SwiftUI update
/// transaction and traps on the queued change.
@MainActor
enum Snapshot {
    /// Representative data: a healthy provider, one in the alert band, one
    /// serving stale numbers, and one that failed outright.
    private static func sampleStates() -> [ProviderID: ProviderPhase] {
        let now = Date()
        return [
            .codex: .loaded(UsageSnapshot(
                planName: "Pro",
                account: "dev@example.com",
                windows: [
                    UsageWindow(
                        title: WindowTitle.forSeconds(604_800),
                        usedPercent: 36,
                        resetsAt: now.addingTimeInterval(524_721),
                        isActive: true),
                    UsageWindow(
                        title: "GPT-5.3-Codex-Spark · \(WindowTitle.forSeconds(18_000))",
                        usedPercent: 4,
                        resetsAt: now.addingTimeInterval(18_000)),
                ],
                fetchedAt: now)),
            .claude: .loaded(UsageSnapshot(
                windows: [
                    UsageWindow(
                        title: WindowTitle.forSeconds(18_000),
                        usedPercent: 18,
                        resetsAt: now.addingTimeInterval(9_000),
                        isActive: true),
                    UsageWindow(
                        title: WindowTitle.forSeconds(604_800),
                        usedPercent: 88,
                        resetsAt: now.addingTimeInterval(320_000)),
                    UsageWindow(
                        title: "\(WindowTitle.forSeconds(604_800)) · Fable",
                        usedPercent: 10,
                        resetsAt: now.addingTimeInterval(320_000)),
                ],
                fetchedAt: now)),
            .cursor: .stale(UsageSnapshot(
                planName: "Pro",
                windows: [
                    UsageWindow(
                        title: L10n.t("Monthly plan", "月度套餐"),
                        usedPercent: 61,
                        detail: "$12.30 / $20.00",
                        resetsAt: now.addingTimeInterval(900_000)),
                ],
                fetchedAt: now.addingTimeInterval(-4_200)),
                error: ProviderError.unauthorized.errorDescription ?? ""),
            .zai: .failed(ProviderError.notConfigured(hint: ProviderID.zai.setupHint)
                .errorDescription ?? ""),
        ]
    }

    private static func sampleCost() -> CostSummary {
        CostSummary(
            todayUSD: 4.82,
            monthUSD: 96.40,
            todayTokens: 1_240_000,
            monthTokens: 28_400_000,
            monthBySource: [.claudeCode: 71.15, .codexCLI: 25.25])
    }

    /// A fresh store per image: `ImageRenderer` runs outside a SwiftUI update
    /// transaction, so mutating a `@Published` between renders traps with
    /// "no current update to enqueue action to".
    private static func makeStore(selected: ProviderID?) -> UsageStore {
        let store = UsageStore.preview(
            enabled: [.codex, .claude, .cursor, .zai],
            states: sampleStates(),
            cost: sampleCost(),
            history: [
                .codex: [8, 11, 14, 14, 19, 23, 22, 27, 31, 36],
                .claude: [4, 9, 9, 13, 12, 15, 17, 16, 18, 18],
            ])
        store.selected = selected
        return store
    }

    static func run(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let panels: [(String, ProviderID?)] = [
            ("overview", nil),
            ("claude", .claude),
            ("stale", .cursor),
            ("failed", .zai),
        ]

        for language in [L10n.Language.en, .zhHans] {
            L10n.override = language
            let suffix = language == .en ? "en" : "zh"
            for (name, selected) in panels {
                write(
                    MenuContentView(store: makeStore(selected: selected), scrollable: false),
                    to: base,
                    name: "panel-\(name)-\(suffix)")
            }
        }
        L10n.override = ConfigStore.shared.language

        writeMenuBarIcons(to: base)
        FileHandle.standardOutput.write(Data("Wrote snapshots to \(base.path)\n".utf8))
    }

    private static func write(_ view: some View, to directory: URL, name: String) {
        let renderer = ImageRenderer(content: view.frame(alignment: .top))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func writeMenuBarIcons(to directory: URL) {
        // 34% used — so "remaining" reads 66% and the two modes are obviously
        // different at a glance.
        for style in MenuBarStyle.allCases {
            for mode in MeterMode.allCases {
                let image = MenuBarIcon.render(percent: 34, style: style, mode: mode)
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:])
                else { continue }
                try? png.write(to: directory
                    .appendingPathComponent("menubar-\(style.rawValue)-\(mode.rawValue).png"))
            }
        }
    }
}
