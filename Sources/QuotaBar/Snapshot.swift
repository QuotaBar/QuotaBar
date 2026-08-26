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
        let now = referenceDate
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
        // A believable 30 days: quiet weekends, a ramp, one spike.
        let shape: [Double] = [
            12, 18, 4, 2, 22, 31, 27, 19, 6, 3,
            24, 38, 44, 29, 15, 5, 2, 33, 41, 52,
            47, 22, 8, 4, 36, 58, 214, 61, 33, 27,
        ]
        let today = Calendar.current.startOfDay(for: referenceDate)
        let daily = shape.enumerated().compactMap { index, usd -> DailyCost? in
            guard let day = Calendar.current.date(
                byAdding: .day, value: index - (shape.count - 1), to: today) else { return nil }
            return DailyCost(day: day, usd: usd, tokens: Int(usd * 260_000))
        }
        let total = shape.reduce(0, +)
        return CostSummary(
            todayUSD: shape.last ?? 0,
            todayTokens: Int((shape.last ?? 0) * 260_000),
            windowBySource: [.claudeCode: total * 0.62, .codexCLI: total * 0.38],
            windowUSD: total,
            windowTokens: Int(total * 260_000),
            daily: daily,
            topModel: "claude-opus-5")
    }

    /// Snapshots must not shift with the wall clock, so every sample date is
    /// derived from one fixed instant.
    private static let referenceDate = Date(timeIntervalSince1970: 1_787_760_000)

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

    /// Renders the overview panel once per candidate accent, for picking a
    /// theme against real content rather than against a colour swatch.
    static func themePreview(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let candidates: [(name: String, accent: String, ink: String)] = [
            ("00-current-neon", "69EA28", "101010"),
            ("01-emerald", "0E9F6E", "FFFFFF"),
            ("02-indigo", "4F46E5", "FFFFFF"),
            ("03-graphite", "3F3F46", "FFFFFF"),
            ("04-slate-blue", "1D4ED8", "FFFFFF"),
        ]
        let savedAccent = QuotaTheme.accentHex
        let savedInk = QuotaTheme.inkHex
        L10n.override = .zhHans
        for candidate in candidates {
            QuotaTheme.accentHex = candidate.accent
            QuotaTheme.inkHex = candidate.ink
            write(
                MenuContentView(store: makeStore(selected: nil), scrollable: false),
                to: base,
                name: "theme-\(candidate.name)")
        }
        QuotaTheme.accentHex = savedAccent
        QuotaTheme.inkHex = savedInk
        L10n.override = ConfigStore.shared.language
        FileHandle.standardOutput.write(Data("Wrote theme previews to \(base.path)\n".utf8))
    }

    /// Renders every menu-bar style across a range of levels, so a style can
    /// be judged on whether its gradations are actually readable rather than
    /// on how it sounds.
    static func iconPreview(directory: String) {
        let base = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let levels: [Double] = [0, 12, 25, 40, 50, 63, 75, 88, 100]
        L10n.override = .zhHans

        let sheet = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("").frame(width: 74, alignment: .leading)
                ForEach(levels, id: \.self) { level in
                    Text("\(Int(level))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40)
                }
            }
            ForEach(MenuBarStyle.allCases) { style in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(style.displayName)
                            .font(.system(size: 11, weight: .semibold))
                        if let steps = style.steps {
                            Text("\(steps) 格")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("连续")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 74, alignment: .leading)
                    ForEach(levels, id: \.self) { level in
                        // `.used` so the fill matches the printed figure.
                        Image(nsImage: MenuBarIcon.render(
                            percent: level, style: style, mode: .used))
                            .frame(width: 40, height: 22)
                    }
                }
            }
        }
        .padding(16)

        render(sheet, to: base, name: "icon-styles", backing: Color(hex: "F5F5F5"))

        // The Settings picker itself. `SettingsView` as a whole cannot be
        // rendered (it assigns @State from onAppear), but this component can.
        let picker = MenuBarStylePicker(selection: .grid, mode: .remaining, onSelect: { _ in })
            .frame(width: 420)
            .padding(16)
        render(picker, to: base, name: "icon-picker", backing: Color(hex: "F5F5F5"))
        render(
            picker.environment(\.colorScheme, .dark),
            to: base,
            name: "icon-picker-dark",
            backing: Color(hex: "1E1E1E"))
        L10n.override = ConfigStore.shared.language
        FileHandle.standardOutput.write(Data("Wrote icon sheet to \(base.path)\n".utf8))
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
            // Dark mode has its own accent pair; render it so a selection block
            // sinking into the window is visible here rather than in the wild.
            for (name, selected) in panels {
                write(
                    MenuContentView(store: makeStore(selected: selected), scrollable: false),
                    to: base,
                    name: "panel-\(name)-\(suffix)-dark",
                    dark: true)
            }
        }
        L10n.override = ConfigStore.shared.language

        writeMenuBarIcons(to: base)
        FileHandle.standardOutput.write(Data("Wrote snapshots to \(base.path)\n".utf8))
    }

    private static func write(
        _ view: some View,
        to directory: URL,
        name: String,
        dark: Bool = false)
    {
        guard !dark else {
            // Adaptive colours resolve against the drawing appearance, which
            // ImageRenderer does not inherit from the SwiftUI environment.
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                render(
                    view.environment(\.colorScheme, .dark),
                    to: directory,
                    name: name,
                    backing: Color(hex: "1E1E1E"))
            }
            return
        }
        render(view, to: directory, name: name, backing: Color(hex: "ECECEC"))
    }

    private static func render(
        _ view: some View,
        to directory: URL,
        name: String,
        backing: Color)
    {
        // The panel normally sits on the menu-bar window's material. The
        // backing is passed in rather than read from `.windowBackgroundColor`,
        // which resolves outside the dark drawing scope and comes out light.
        let framed = view
            .frame(alignment: .top)
            .background(backing)
        let renderer = ImageRenderer(content: framed)
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
