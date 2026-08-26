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
    static let radiusTile: CGFloat = 8
    static let radiusCard: CGFloat = 10
    static let radiusPanel: CGFloat = 14

    /// Low-contrast fill used for cards and tiles.
    static let surface = Color.primary.opacity(0.05)
    static let surfaceStrong = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.15)

    static var accent: Color { Color(hex: QuotaTheme.accentHex) }
    static var ink: Color { Color(hex: QuotaTheme.inkHex) }
}

extension View {
    /// Card surface: a fill, no border, no shadow.
    func quotaCard(radius: CGFloat = Design.radiusCard) -> some View {
        padding(Design.space3)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Design.surface))
    }
}
