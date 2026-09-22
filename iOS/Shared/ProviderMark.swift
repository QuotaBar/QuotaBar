import QuotaModel
import SwiftUI
import UIKit

// MARK: - Colours

extension Color {
    /// "34C759" → a colour. The provider accents and the usage ramp are both
    /// kept as hex in `QuotaModel`, shared with the Mac.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// The usage ramp, as on the Mac's dark surfaces. Keyed off the **used**
    /// figure, never a displayed "left" one.
    static func usage(_ used: Double) -> Color {
        Color(hex: UsageRamp.hex(used: used))
    }

    /// Behind a widget: white in light mode; in dark, a near-black deeper
    /// than the system's grey, so the figures stand out as on the Mac.
    static let widgetSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1)
            : .white
    })
}

// MARK: - A provider's mark

/// The provider's logo from the same PNGs the Mac ships. A mark with no
/// colour of its own — Codex, Cursor, OpenCode — is recoloured, or it would
/// vanish into the dark surfaces it is drawn on.
struct ProviderMark: View {
    let id: ProviderID
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let logo = ProviderLogo.load(id, dark: colorScheme == .dark) {
            if logo.isMonochrome {
                Image(uiImage: logo.image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(.primary)
            } else {
                Image(uiImage: logo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: id.symbolName)
                .font(.system(size: size * 0.8, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

enum ProviderLogo {
    struct Logo {
        let image: UIImage
        let isMonochrome: Bool
    }

    nonisolated(unsafe) private static var cache: [String: Logo] = [:]
    private static let lock = NSLock()

    /// On a dark surface, a mark cut for one (`<id>-dark.png`) wins where
    /// there is one; a light widget takes the plain mark.
    static func load(_ id: ProviderID, dark: Bool = true) -> Logo? {
        lock.lock(); defer { lock.unlock() }
        let key = "\(id.rawValue)\(dark ? "-dark" : "")"
        if let cached = cache[key] { return cached }
        let names = dark ? ["\(id.rawValue)-dark", id.rawValue] : [id.rawValue]
        let url = names.lazy.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "logos")
        }.first
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cutForDark = url.lastPathComponent.hasSuffix("-dark.png")
        let logo = Logo(image: image, isMonochrome: !cutForDark && isMonochrome(image))
        cache[key] = logo
        return logo
    }

    /// True when every visible pixel is (near-)unsaturated: the mark carries
    /// no brand colour and is safe to recolour. The Mac's test, on a 24×24
    /// sample.
    private static func isMonochrome(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sampled = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
            sampled += 1
            // Premultiplied: undo the alpha before judging the colour.
            let alpha = Double(pixels[i + 3]) / 255
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha, b = Double(pixels[i + 2]) / 255 / alpha
            if !LogoTone.isNeutral(red: r, green: g, blue: b) { return false }
        }
        return sampled > 0
    }
}

// MARK: - A ring

/// One figure as an arc: the ramp's colour for how much is used, the arc's
/// length for how much is left or used — whichever `showsLeft` says.
struct UsageRing: View {
    let used: Double?
    var lineWidth: CGFloat = 6
    var showsLeft = true

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: lineWidth)
            if let used {
                let shown = showsLeft ? 100 - min(max(used, 0), 100) : min(max(used, 0), 100)
                Circle()
                    .trim(from: 0, to: shown / 100)
                    .stroke(Color.usage(used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}
