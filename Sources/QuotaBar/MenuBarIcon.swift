import AppKit
import SwiftUI
import QuotaCore

/// Renders the dynamic menu-bar icon in the user-selected style.
/// Template (monochrome) normally; tinted orange/red while an alert is active.
enum MenuBarIcon {
    /// `percent` is always the *used* figure — the alert level is derived from
    /// it upstream. `mode` decides whether the glyph fills with that or with
    /// what is left; the tint is unaffected either way.
    static func render(
        percent: Double?,
        style: MenuBarStyle,
        level: AlertLevel = .none,
        mode: MeterMode = .remaining) -> NSImage
    {
        let ink: NSColor = level.hex.map(nsColor) ?? .black
        let trackInk = ink.withAlphaComponent(0.35)
        // No reading at all stays empty in both modes: a full bar would claim
        // the quota is untouched when we simply do not know.
        let shown = percent.map { mode.shownPercent(fromUsed: $0) }
        let image: NSImage
        switch style {
        case .bar: image = renderBar(shown, ink: ink, track: trackInk)
        case .ring: image = renderRing(shown, ink: ink, track: trackInk)
        case .columns: image = renderColumns(shown, ink: ink, track: trackInk)
        case .percent: image = renderPercent(shown, ink: ink)
        }
        image.isTemplate = level == .none
        return image
    }

    private static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    private static func fraction(_ percent: Double?) -> CGFloat {
        guard let percent else { return 0 }
        return CGFloat(min(max(percent, 0), 100) / 100)
    }

    // MARK: 横向 — capsule track filled left to right

    private static func renderBar(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let trackPath = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 9, width: 16, height: 5),
                xRadius: 2.5, yRadius: 2.5)
            track.setFill()
            trackPath.fill()

            guard let percent else { return true }
            let fillWidth = max(2, 16 * fraction(percent))
            let fill = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 9, width: min(fillWidth, 16), height: 5),
                xRadius: 2.5, yRadius: 2.5)
            ink.setFill()
            fill.fill()
            return true
        }
    }

    // MARK: 圆形 — activity ring starting at 12 o'clock

    private static func renderRing(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let center = NSPoint(x: 11, y: 11)
            let radius: CGFloat = 7.5

            let trackPath = NSBezierPath()
            trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            trackPath.lineWidth = 3
            track.setStroke()
            trackPath.stroke()

            guard let percent else { return true }
            let sweep = 360 * fraction(percent)
            guard sweep > 1 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            ink.setStroke()
            arc.stroke()
            return true
        }
    }

    // MARK: 柱形 — four ascending columns, lit left to right (25% each)

    private static func renderColumns(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let heights: [CGFloat] = [7, 10, 13, 16]
            let barWidth: CGFloat = 3.2
            let spacing: CGFloat = 1.4
            let totalWidth = barWidth * 4 + spacing * 3
            var x = (22 - totalWidth) / 2

            let lit: Int
            if let percent {
                lit = percent > 0 ? max(1, Int((fraction(percent) * 4).rounded(.up))) : 0
            } else {
                lit = 0
            }

            for (index, height) in heights.enumerated() {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: 3, width: barWidth, height: height),
                    xRadius: 1.6, yRadius: 1.6)
                (index < lit ? ink : track).setFill()
                bar.fill()
                x += barWidth + spacing
            }
            return true
        }
    }

    // MARK: 数字 — monospaced percent text

    private static func renderPercent(_ percent: Double?, ink: NSColor) -> NSImage {
        let text = percent.map { "\(Int($0.rounded()))%" } ?? "--"
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ink,
            ])
        let textSize = attributed.size()
        let size = NSSize(width: max(20, ceil(textSize.width) + 2), height: 22)
        return NSImage(size: size, flipped: false) { _ in
            attributed.draw(at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2))
            return true
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Brand logo (thesvg) with SF Symbol fallback.
///
/// Several brand marks ship as a single flat colour — Codex, Kimi, z.ai and
/// OpenCode are black; Cursor, Grok and Manus are white. Drawn as-is, each of
/// them disappears against one of the two appearances. Monochrome marks are
/// therefore detected and drawn as templates so they take the foreground
/// colour; multi-colour marks (Claude, Gemini, DeepSeek, MiniMax) keep theirs.
struct ProviderGlyph: View {
    let id: ProviderID
    var size: CGFloat = 18
    /// Renders the logo as a solid ink silhouette (for selected tiles on accent background).
    var ink: Bool = false

    var body: some View {
        if let logo = Self.logo(for: id) {
            if logo.isMonochrome {
                Image(nsImage: logo.image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(ink ? Design.ink : Color.primary)
            } else {
                Image(nsImage: logo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .saturation(ink ? 0 : 1)
                    .brightness(ink ? -1 : 0)
            }
        } else {
            Image(systemName: id.symbolName)
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(ink ? Design.ink : Color.primary)
        }
    }

    struct Logo {
        let image: NSImage
        let isMonochrome: Bool
    }

    static func logoImage(for id: ProviderID) -> NSImage? {
        logo(for: id)?.image
    }

    static func logo(for id: ProviderID) -> Logo? {
        if let cached = Self.cache[id] { return cached }
        guard let url = Self.logoURL(for: id), let image = NSImage(contentsOf: url) else {
            return nil
        }
        let logo = Logo(image: image, isMonochrome: Self.isMonochrome(image))
        Self.cache[id] = logo
        return logo
    }

    /// True when every visible pixel is (near-)unsaturated — i.e. the mark
    /// carries no brand colour of its own and is safe to recolour.
    private static func isMonochrome(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return false }
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 24)
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.5
                else { continue }
                sampled += 1
                let maxC = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                let minC = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                if maxC > 0, (maxC - minC) / maxC > 0.15 { return false }
            }
        }
        return sampled > 0
    }

    private static var cache: [ProviderID: Logo] = [:]

    /// Looks in the packaged app bundle first, then the SwiftPM resource bundle (dev runs).
    /// Never touches `Bundle.module`, whose generated accessor traps when the bundle is absent.
    static func logoURL(for id: ProviderID) -> URL? {
        let fileName = "\(id.rawValue).png"
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("logos/\(fileName)"))
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("QuotaBar_QuotaBar.bundle")
                .appendingPathComponent("logos/\(fileName)"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
