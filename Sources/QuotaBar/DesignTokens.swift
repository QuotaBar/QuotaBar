import AppKit
import SwiftUI
import QuotaCore

/// Single source of truth for spacing, corner radii and surface treatment.
/// Radii are tiered on purpose — tiles, cards and the panel itself should not
/// all round to the same value — and every card uses a fill *or* a border,
/// never both.
enum Design {
    // 4pt grid.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24

    // Radius tiers.
    static let radiusField: CGFloat = 7
    static let radiusTile: CGFloat = 8
    static let radiusCard: CGFloat = 10
    static let radiusPanel: CGFloat = 14

    // Settings window metrics. A form only reads as a form when every control
    // in it is the same height and starts at the same x.
    static let fieldHeight: CGFloat = 30
    static let labelColumn: CGFloat = 132
    static let sidebarWidth: CGFloat = 180
    /// Clears the traffic lights once the titlebar is transparent.
    static let titlebarInset: CGFloat = 30

    /// Opaque panel backing. Explicit rather than a material: the panel must
    /// carry its own contrast, since it cannot rely on what sits behind it.
    static var panelBackground: Color {
        adaptive(light: "F2F2F2", dark: "1E1E1E")
    }

    /// Low-contrast fill used for cards and tiles.
    static let surface = Color.primary.opacity(0.05)
    static let surfaceStrong = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.15)

    /// The settings sidebar is an always-dark surface, like the dock and the
    /// widget. Its colours are therefore pinned, not adaptive: `Color.primary`
    /// and `Design.accent` resolve against the *system* appearance and both go
    /// black-on-black in light mode. Same trap as `ProviderGlyph`'s `tint`.
    static let sidebarSurface = Color.black
    static let sidebarInk = Color.white
    static let sidebarInkDim = Color.white.opacity(0.62)

    /// Specular edge on a glass surface, and the well behind a text field.
    /// Both are `Color.primary` derivatives so they invert with the appearance
    /// on their own — a fixed white hairline is invisible in light mode.
    static let glassEdge = Color.primary.opacity(0.12)
    static let fieldFill = Color.primary.opacity(0.04)

    /// Resolves per appearance: graphite-on-white in light mode, and the
    /// inverse in dark mode so the selection block never sinks into the window.
    static var accent: Color {
        adaptive(light: QuotaTheme.accentHex, dark: QuotaTheme.accentDarkHex)
    }

    static var ink: Color {
        adaptive(light: QuotaTheme.inkHex, dark: QuotaTheme.inkDarkHex)
    }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension View {
    /// Card surface: a fill, no border, no shadow.
    func quotaCard(radius: CGFloat = Design.radiusCard) -> some View {
        padding(Design.space3)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Design.surface))
    }
}


extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
