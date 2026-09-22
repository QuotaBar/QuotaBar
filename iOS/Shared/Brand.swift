import SwiftUI
import UIKit

// MARK: - The mark and the word, as the Mac draws them

extension Font {
    /// The Mac's `Design.wordmark`: Instrument Sans at semibold, only ever
    /// for the word "QuotaBar". Everything else stays on the system face.
    ///
    /// The file is one variable font, and on iOS `.weight()` does not reach
    /// its weight axis — `Font.custom(...).weight(.semibold)` draws the
    /// regular cut. The axis is set on the descriptor instead.
    static func wordmark(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let axis: CGFloat = switch weight {
        case .bold: 700
        case .medium: 500
        case .regular: 400
        default: 600
        }
        // 'wght' as the four-character tag CoreText keys variations by.
        let wght = 0x7767_6874
        let descriptor = UIFontDescriptor(fontAttributes: [.family: "Instrument Sans"])
            .addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: axis]])
        let font = UIFont(descriptor: descriptor, size: size)
        // Not registered (it always is in the bundle): the system face.
        guard font.familyName == "Instrument Sans" else { return .system(size: size, weight: weight) }
        return Font(font)
    }
}

/// The app icon at a small size — the Mac's `quotabar-icon.png`, clipped to
/// the icon grid's corner as the Mac's card footer clips it.
struct BrandIcon: View {
    var size: CGFloat = 28

    var body: some View {
        if let url = Bundle.main.url(forResource: "quotabar-icon", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path)
        {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        }
    }
}

/// The icon and the word side by side, as at the top of the Mac's settings.
struct BrandLockup: View {
    var iconSize: CGFloat = 32
    var textSize: CGFloat = 24

    var body: some View {
        HStack(spacing: iconSize * 0.36) {
            BrandIcon(size: iconSize)
            Text("QuotaBar")
                .font(.wordmark(size: textSize))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QuotaBar")
    }
}
