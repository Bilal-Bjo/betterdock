// Icon styles: Default, Dark, Clear and Tinted, rendered from each app's regular icon.
import AppKit
import SwiftUI

enum IconStyle: String, CaseIterable {
    case standard = "default", dark, clear, tinted

    static var current: IconStyle = .standard
    /// Accent for the tinted style; follows the wallpaper unless the config sets one.
    static var tint: Color = Color(red: 0.55, green: 0.7, blue: 1.0)

    var title: String { self == .standard ? "Default" : rawValue.capitalized }
}

/// Average brightness of an icon, cached per app: decides whether "dark" inverts it.
enum IconLuma {
    private static var cache: [String: CGFloat] = [:]

    static func of(_ id: String, _ image: NSImage) -> CGFloat {
        if let cached = cache[id] { return cached }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32) else { return 0.5 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        NSGraphicsContext.restoreGraphicsState()
        var total: CGFloat = 0, weight: CGFloat = 0
        for x in 0..<8 { for y in 0..<8 {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
            total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            weight += 1
        } }
        let luma = weight > 0 ? total / weight : 0.5
        cache[id] = luma
        return luma
    }
}

/// An app icon drawn in the current icon style.
struct StyledIcon: View {
    let id: String
    let image: NSImage
    var style: IconStyle = IconStyle.current

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width
            let base = Image(nsImage: image).resizable().interpolation(.high)
            let tile = RoundedRectangle(cornerRadius: size * 0.225 * 0.84, style: .continuous)
            switch style {
            case .standard:
                base
            case .dark:
                if IconLuma.of(id, image) > 0.55 {
                    // Light icons: invert lightness but keep hue, so white tiles go black and colours survive.
                    base.colorInvert().hueRotation(.degrees(180)).saturation(1.15).brightness(0.02)
                } else {
                    base.brightness(-0.06)
                }
            case .clear:
                ZStack {
                    tile.fill(.white.opacity(0.14))
                        .overlay(tile.strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, size * 0.012)))
                        .padding(size * 0.08)
                    base.grayscale(1).contrast(1.4).brightness(0.25).opacity(0.72).blendMode(.plusLighter)
                }
            case .tinted:
                ZStack {
                    tile.fill(Color(white: 0.09)).padding(size * 0.08)
                    base.grayscale(1).contrast(1.3).colorMultiply(IconStyle.tint).blendMode(.screen)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
