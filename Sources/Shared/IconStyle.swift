// Icon styles: Default, Dark, Clear and Tinted. Each app's symbol is lifted off its background and
// redrawn on a fresh tile, the way macOS builds its own dark and tinted icons.
import AppKit
import SwiftUI

enum IconStyle: String, CaseIterable {
    case standard = "default", dark, clear, tinted

    static var current: IconStyle = .standard
    var title: String { self == .standard ? "Default" : rawValue.capitalized }
}

/// Accent colours for tinted icons.
enum IconTint: String, CaseIterable {
    case wallpaper, yellow, blue, pink, green, purple, graphite

    static var current: IconTint = .wallpaper
    var title: String { rawValue.capitalized }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .wallpaper:
            let c = NSColor(Theme.wallpaperTint).usingColorSpace(.deviceRGB) ?? .systemBlue
            // Lift the wallpaper's average colour so the tint reads as a colour, not mud.
            let (h, s, _, _) = { () -> (CGFloat, CGFloat, CGFloat, CGFloat) in
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                return (h, s, b, a)
            }()
            let lifted = NSColor(hue: h, saturation: max(0.45, min(s * 1.4, 0.8)), brightness: 0.98, alpha: 1)
            return (lifted.redComponent, lifted.greenComponent, lifted.blueComponent)
        case .yellow: return (0.97, 0.85, 0.31)
        case .blue: return (0.45, 0.68, 1.0)
        case .pink: return (1.0, 0.52, 0.72)
        case .green: return (0.4, 0.88, 0.55)
        case .purple: return (0.72, 0.56, 1.0)
        case .graphite: return (0.86, 0.87, 0.9)
        }
    }
}

/// Renders and caches styled icons. Work happens once per app and style, at 192 px.
enum IconRenderer {
    private static var cache: [String: NSImage] = [:]
    private static let px = 192

    static func image(id: String, source: NSImage, style: IconStyle) -> NSImage {
        if style == .standard { return source }
        let tint = IconTint.current
        let key = "\(id)|\(style.rawValue)|\(tint.rawValue)"
        if let hit = cache[key] { return hit }
        let result = fromSystem(id: id, style: style, tint: tint.rgb) ?? render(source, style: style, tint: tint.rgb) ?? source
        cache[key] = result
        return result
    }

    static func flush() { cache.removeAll() }

    /// Apple's own dark icon, or its monochrome icon recoloured for Tinted and Clear.
    private static func fromSystem(id: String, style: IconStyle, tint: (CGFloat, CGFloat, CGFloat)) -> NSImage? {
        guard id.hasSuffix(".app") else { return nil }
        if style == .dark {
            return SystemIcons.image(path: id, appearance: 1, variant: 0).map { NSImage(cgImage: $0, size: NSSize(width: 128, height: 128)) }
        }
        guard let mono = SystemIcons.image(path: id, appearance: 1, variant: 2) else { return nil }
        let n = mono.width
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }
        ctx.draw(mono, in: CGRect(x: 0, y: 0, width: n, height: n))
        // The monochrome render is a flat dark tile with a light symbol: the tile's colour is the
        // darkest opaque grey near the middle of the edge, and brightness above it is ink.
        var tileLuma: CGFloat = 1
        for x in stride(from: n / 4, to: n * 3 / 4, by: max(n / 32, 1)) {
            let i = ((n / 8) * n + x) * 4
            if px[i + 3] > 240 { tileLuma = min(tileLuma, CGFloat(px[i]) / 255) }
        }
        for i in stride(from: 0, to: n * n * 4, by: 4) {
            let a = CGFloat(px[i + 3]) / 255
            guard a > 0 else { continue }
            let luma = (CGFloat(px[i]) / 255) / a
            // Ink is anything that differs from the tile, lighter or darker.
            let ink = luma >= tileLuma
                ? min(max((luma - tileLuma) / max(1 - tileLuma, 0.01), 0), 1)
                : min(max((tileLuma - luma) / max(tileLuma, 0.01), 0), 1)
            let (r, g, b): (CGFloat, CGFloat, CGFloat)
            let base: (CGFloat, CGFloat, CGFloat, CGFloat)
            if style == .tinted {
                base = (0.08, 0.08, 0.09, 1)          // near-black tile
                (r, g, b) = (tint.0, tint.1, tint.2)
            } else {
                base = (1, 1, 1, 0.16)                // frosted tile
                (r, g, b) = (1, 1, 1)
            }
            let inkAlpha = ink * (style == .clear ? 0.95 : 1)
            let outA = (inkAlpha + base.3 * (1 - inkAlpha)) * a
            func channel(_ c: CGFloat, _ bc: CGFloat) -> UInt8 {
                UInt8(min(max((c * inkAlpha + bc * base.3 * (1 - inkAlpha)) * a * 255, 0), 255))
            }
            px[i] = channel(r, base.0)
            px[i + 1] = channel(g, base.1)
            px[i + 2] = channel(b, base.2)
            px[i + 3] = UInt8(min(outA * 255, 255))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: 128, height: 128))
    }

    // The icon body on Apple's grid: 824 of 1024, centred, corner radius about 22.5%.
    private static var body: CGRect {
        let inset = CGFloat(px) * 100 / 1024
        return CGRect(x: inset, y: inset, width: CGFloat(px) - inset * 2, height: CGFloat(px) - inset * 2)
    }

    private static func squircle(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    }

    private static func render(_ source: NSImage, style: IconStyle, tint: (CGFloat, CGFloat, CGFloat)) -> NSImage? {
        let n = px
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let raw = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }

        func pixel(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let i = (y * n + x) * 4
            let a = CGFloat(raw[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (CGFloat(raw[i]) / 255 / a, CGFloat(raw[i + 1]) / 255 / a, CGFloat(raw[i + 2]) / 255 / a, a)
        }

        // Sample the background just inside the tile's edge, all the way round.
        let b = body
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        for t in stride(from: 0.22, through: 0.78, by: 0.08) {
            for (fx, fy) in [(t, 0.06), (t, 0.94), (0.06, t), (0.94, t)] {
                let x = Int(b.minX + b.width * fx), y = Int(b.minY + b.height * fy)
                let p = pixel(x, y)
                if p.3 > 0.9 { samples.append((p.0, p.1, p.2)) }
            }
        }
        guard samples.count > 8 else { return nil }

        // Mask: how far each pixel sits from the nearest background colour. The tile's own rim
        // (borders and rings many icons draw) is left out.
        var rawMask = [CGFloat](repeating: 0, count: n * n)
        var nearest = [Int](repeating: 0, count: n * n)
        var coverage: CGFloat = 0, inside: CGFloat = 0
        let bodyPath = squircle(b.insetBy(dx: b.width * 0.045, dy: b.width * 0.045))
        for y in 0..<n {
            for x in 0..<n {
                guard bodyPath.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) else { continue }
                let p = pixel(x, y)
                inside += 1
                guard p.3 > 0.5 else { continue }
                var d: CGFloat = .greatestFiniteMagnitude
                for (k, s) in samples.enumerated() {
                    let dr = p.0 - s.0, dg = p.1 - s.1, db = p.2 - s.2
                    let dist = (dr * dr + dg * dg + db * db).squareRoot()
                    if dist < d { d = dist; nearest[y * n + x] = k }
                }
                rawMask[y * n + x] = min(max((d - 0.06) / 0.2, 0), 1)
            }
        }
        // A light blur softens the cut so edges stay smooth when the icon is scaled down.
        var mask = rawMask
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                var sum: CGFloat = 0
                for dy in -1...1 { for dx in -1...1 { sum += rawMask[(y + dy) * n + x + dx] } }
                mask[y * n + x] = sum / 9
                coverage += mask[y * n + x]
            }
        }
        let share = inside > 0 ? coverage / inside : 0
        let separable = share > 0.03 && share < 0.7

        // Per-icon decisions for dark mode.
        let bgLuma = samples.map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }.reduce(0, +) / CGFloat(samples.count)
        if style == .dark && bgLuma < 0.2 { return source } // already a dark icon
        var inkLuma: CGFloat = 0, inkWeight: CGFloat = 0
        if separable {
            for y in 0..<n { for x in 0..<n where mask[y * n + x] > 0.9 {
                let p = pixel(x, y)
                inkLuma += 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2
                inkWeight += 1
            } }
        }
        let darkInk = inkWeight > 0 && inkLuma / inkWeight < 0.38

        // Output.
        guard let out = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dst = out.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }

        // Tile.
        let tile = squircle(b)
        out.saveGState()
        out.addPath(tile)
        out.clip()
        switch style {
        case .clear:
            out.setFillColor(CGColor(gray: 1, alpha: 0.16))
            out.fill(b)
        default:
            let top = CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1)
            let bottom = CGColor(red: 0.09, green: 0.09, blue: 0.1, alpha: 1)
            if let g = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1]) {
                out.drawLinearGradient(g, start: CGPoint(x: 0, y: b.minY), end: CGPoint(x: 0, y: b.maxY), options: [])
            }
        }
        out.restoreGState()
        // Hairline highlight on the tile's edge.
        out.addPath(squircle(b.insetBy(dx: 0.75, dy: 0.75)))
        out.setStrokeColor(CGColor(gray: 1, alpha: style == .clear ? 0.45 : 0.1))
        out.setLineWidth(1.5)
        out.strokePath()

        // Symbol, composited by hand over the tile.
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
                let p = pixel(x, y)
                guard p.3 > 0 else { continue }
                var alpha = separable ? mask[i] * p.3 : p.3
                guard alpha > 0.01 else { continue }
                var (r, g, bl) = (p.0, p.1, p.2)
                if separable, mask[i] < 0.98 {
                    // Remove the old background from edge pixels so no light or dark fringe survives.
                    let bg = samples[nearest[i]], m = max(mask[i], 0.25)
                    r = min(max((r - (1 - m) * bg.0) / m, 0), 1)
                    g = min(max((g - (1 - m) * bg.1) / m, 0), 1)
                    bl = min(max((bl - (1 - m) * bg.2) / m, 0), 1)
                }
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * bl
                switch style {
                case .dark:
                    if separable && darkInk {
                        // Dark ink flips to light ink with the same hue, so it reads on the dark tile.
                        let shift = (0.94 - luma) - luma
                        (r, g, bl) = (min(max(r + shift, 0), 1), min(max(g + shift, 0), 1), min(max(bl + shift, 0), 1))
                    } else if !separable {
                        (r, g, bl) = (r * 0.8, g * 0.8, bl * 0.8)
                    }
                case .tinted:
                    let shade = separable ? 0.45 + 0.55 * max(luma, 1 - luma) : 0.25 + 0.75 * luma
                    (r, g, bl) = (tint.0 * shade, tint.1 * shade, tint.2 * shade)
                    if !separable { alpha *= 0.95 }
                case .clear:
                    // White glass ink; its opacity follows the symbol's own light and dark parts.
                    (r, g, bl) = (1, 1, 1)
                    alpha *= separable ? 0.45 + 0.5 * max(luma, 1 - luma) : 0.35 + 0.4 * luma
                case .standard:
                    break
                }
                // Source-over onto what the tile already drew.
                let j = i * 4
                let da = CGFloat(dst[j + 3]) / 255
                let oa = alpha + da * (1 - alpha)
                guard oa > 0 else { continue }
                func mix(_ s: CGFloat, _ d: UInt8) -> UInt8 {
                    let dc = CGFloat(d) / 255 // premultiplied
                    return UInt8(min(max((s * alpha + dc * (1 - alpha)) * 255, 0), 255))
                }
                dst[j] = mix(r, dst[j])
                dst[j + 1] = mix(g, dst[j + 1])
                dst[j + 2] = mix(bl, dst[j + 2])
                dst[j + 3] = UInt8(min(oa * 255, 255))
            }
        }
        guard let image = out.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: n, height: n))
    }
}

/// An app icon drawn in the current icon style.
struct StyledIcon: View {
    let id: String
    let image: NSImage
    var style: IconStyle = IconStyle.current

    var body: some View {
        Image(nsImage: IconRenderer.image(id: id, source: image, style: style))
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
    }
}
