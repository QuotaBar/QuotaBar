import AppKit

// Dev utility: renders the four menu-bar icon styles to PNGs for visual review.
// Usage: swift Scripts/render_style_previews.swift

func makeImage(_ size: NSSize, _ draw: @escaping (NSRect) -> Bool) -> NSImage {
    NSImage(size: size, flipped: false, drawingHandler: draw)
}

func fraction(_ percent: Double) -> CGFloat { CGFloat(min(max(percent, 0), 100) / 100) }

let percent = 66.0

func renderBar() -> NSImage {
    makeImage(NSSize(width: 22, height: 22)) { _ in
        let track = NSBezierPath(roundedRect: NSRect(x: 3, y: 9, width: 16, height: 5), xRadius: 2.5, yRadius: 2.5)
        NSColor.black.withAlphaComponent(0.35).setFill()
        track.fill()
        let fillWidth = max(2, 16 * fraction(percent))
        let fill = NSBezierPath(roundedRect: NSRect(x: 3, y: 9, width: min(fillWidth, 16), height: 5), xRadius: 2.5, yRadius: 2.5)
        NSColor.black.setFill()
        fill.fill()
        return true
    }
}

func renderRing() -> NSImage {
    makeImage(NSSize(width: 22, height: 22)) { _ in
        let center = NSPoint(x: 11, y: 11)
        let radius: CGFloat = 7.5
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 3
        NSColor.black.withAlphaComponent(0.35).setStroke()
        track.stroke()
        let sweep = 360 * fraction(percent)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = 3
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
        return true
    }
}

func renderColumns() -> NSImage {
    makeImage(NSSize(width: 22, height: 22)) { _ in
        let heights: [CGFloat] = [7, 10, 13, 16]
        let barWidth: CGFloat = 3.2
        let spacing: CGFloat = 1.4
        let totalWidth = barWidth * 4 + spacing * 3
        var x = (22 - totalWidth) / 2
        let lit = max(1, Int((fraction(percent) * 4).rounded(.up)))
        for (index, height) in heights.enumerated() {
            let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 3, width: barWidth, height: height), xRadius: 1.6, yRadius: 1.6)
            if index < lit { NSColor.black.setFill() } else { NSColor.black.withAlphaComponent(0.3).setFill() }
            bar.fill()
            x += barWidth + spacing
        }
        return true
    }
}

func renderPercent() -> NSImage {
    let text = "\(Int(percent.rounded()))%"
    let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.black,
    ])
    let textSize = attributed.size()
    let size = NSSize(width: max(20, ceil(textSize.width) + 2), height: 22)
    return makeImage(size) { _ in
        attributed.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        return true
    }
}

func save(_ image: NSImage, _ path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = image.size
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
save(renderBar(), "\(out)/style_bar.png")
save(renderRing(), "\(out)/style_ring.png")
save(renderColumns(), "\(out)/style_columns.png")
save(renderPercent(), "\(out)/style_percent.png")
print("saved to \(out)")
