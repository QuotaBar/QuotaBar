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
}

// MARK: - A provider's mark

/// The provider's logo from the same PNGs the Mac ships. A mark with no
/// colour of its own — Codex, Cursor, OpenCode — is recoloured, or it would
/// vanish into the dark surfaces it is drawn on.
struct ProviderMark: View {
    let id: ProviderID
    var size: CGFloat = 20

    var body: some View {
        if let logo = ProviderLogo.load(id) {
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

    nonisolated(unsafe) private static var cache: [ProviderID: Logo] = [:]
    private static let lock = NSLock()

    /// A mark cut for dark surfaces (`<id>-dark.png`) wins where there is one.
    static func load(_ id: ProviderID) -> Logo? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let url = ["\(id.rawValue)-dark", id.rawValue].lazy.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "logos")
        }.first
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        let dark = url.lastPathComponent.hasSuffix("-dark.png")
        let logo = Logo(image: image, isMonochrome: !dark && isMonochrome(image))
        cache[id] = logo
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
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
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
