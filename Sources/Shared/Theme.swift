// Themes: one surface language for the bar, folder panels, labels, separators and widget tiles.
import AppKit
import SwiftUI
import simd

enum Theme: String, CaseIterable {
    case glass, graphite, paper, midnight, wallpaper

    static var current: Theme = .glass
    /// Dominant colour of the wallpaper behind the Dock (not its average, which is usually mud).
    static var wallpaperTint: Color = Color(red: 0.3, green: 0.4, blue: 0.6)
    private static var wallpaperHSB: (h: CGFloat, s: CGFloat, b: CGFloat) = (0.6, 0.5, 0.6)

    /// Reads a theme name from dock.json; the retired "ember" theme becomes Graphite.
    init(named name: String?) {
        self = name == "ember" ? .graphite : Theme(rawValue: name ?? "glass") ?? .glass
    }

    var title: String { rawValue.capitalized }

    var scheme: ColorScheme { self == .paper ? .light : .dark }

    /// Set on the Dock and folder windows; cheaper than a colour-scheme environment on every frame.
    var appearance: NSAppearance? { NSAppearance(named: self == .paper ? .aqua : .darkAqua) }

    /// The wallpaper's hue at a chosen depth; saturation is lifted so dim wallpapers still read as colour.
    private static func wall(_ s: CGFloat, _ b: CGFloat) -> Color {
        Color(hue: wallpaperHSB.h, saturation: min(max(wallpaperHSB.s * 1.3, 0.3), s), brightness: b)
    }

    // MARK: Surface

    /// Tint layered into Liquid Glass (and over the material where glass is unavailable).
    var tint: Color {
        switch self {
        case .glass: return .clear
        case .graphite: return Color(white: 0.06).opacity(0.62)
        case .paper: return Color(red: 0.99, green: 0.97, blue: 0.93).opacity(0.72)
        case .midnight: return Color(red: 0.04, green: 0.07, blue: 0.2).opacity(0.7)
        case .wallpaper: return Theme.wall(0.7, 0.3).opacity(0.62)
        }
    }

    /// Stand-in fill for snapshots, which cannot render glass or blur.
    var flatFill: Color {
        switch self {
        case .glass: return Color(white: 0.62).opacity(0.3)
        case .graphite: return Color(white: 0.09).opacity(0.86)
        case .paper: return Color(red: 0.97, green: 0.95, blue: 0.91).opacity(0.9)
        case .midnight: return Color(red: 0.05, green: 0.08, blue: 0.21).opacity(0.86)
        case .wallpaper: return Theme.wall(0.7, 0.26).opacity(0.84)
        }
    }

    /// Hairline around the edge.
    var hairline: Color {
        switch self {
        case .glass: return .white.opacity(0.16)
        case .graphite: return .white.opacity(0.1)
        case .paper: return .black.opacity(0.1)
        case .midnight: return Color(red: 0.45, green: 0.6, blue: 1).opacity(0.22)
        case .wallpaper: return .white.opacity(0.12)
        }
    }

    /// Light catching the top edge.
    var highlight: Color {
        switch self {
        case .glass: return .white.opacity(0.45)
        case .graphite: return .white.opacity(0.22)
        case .paper: return .white
        case .midnight: return Color(red: 0.6, green: 0.75, blue: 1).opacity(0.75)
        case .wallpaper: return Theme.wall(0.35, 1).opacity(0.5)
        }
    }

    /// Soft inner shading along the lower edge, which makes smoked surfaces read as thick glass.
    var innerShade: Color? {
        switch self {
        case .graphite: return .black.opacity(0.5)
        case .midnight: return Color(red: 0, green: 0.02, blue: 0.1).opacity(0.6)
        case .paper: return Color(red: 0.55, green: 0.45, blue: 0.3).opacity(0.18)
        default: return nil
        }
    }

    /// Bar and panel surface for the active theme.
    func surface<S: InsettableShape>(_ shape: S) -> some View {
        ThemeSurface(shape: shape, theme: self)
    }

    // MARK: Details

    var runningDot: Color {
        switch self {
        case .paper: return Color(white: 0.15).opacity(0.7)
        case .midnight: return Color(red: 0.6, green: 0.75, blue: 1)
        case .wallpaper: return Theme.wall(0.35, 1)
        default: return .white.opacity(0.78)
        }
    }

    var folderTitle: Color {
        switch self {
        case .paper: return Color(white: 0.2)
        case .midnight: return Color(red: 0.78, green: 0.85, blue: 1)
        default: return .white.opacity(0.85)
        }
    }

    /// Accent for small highlights inside widgets (calendar marks, progress).
    var accent: Color {
        switch self {
        case .glass: return Color(red: 1, green: 0.66, blue: 0.16)
        case .graphite: return Color(red: 0.95, green: 0.85, blue: 0.31) // #f3d94e
        case .paper: return Color(red: 0.93, green: 0.45, blue: 0.2)
        case .midnight: return Color(red: 0.45, green: 0.66, blue: 1)
        case .wallpaper: return Theme.wall(0.7, 1)
        }
    }

    var labelFill: Color {
        switch self {
        case .paper: return Color(red: 0.99, green: 0.98, blue: 0.95).opacity(0.96)
        case .midnight: return Color(red: 0.06, green: 0.09, blue: 0.22).opacity(0.92)
        case .wallpaper: return Theme.wall(0.5, 0.2).opacity(0.92)
        default: return Color(white: 0.1).opacity(0.86)
        }
    }

    var labelText: Color { self == .paper ? Color(white: 0.12) : .white }

    /// Widget tiles are always dark cards so their contents read on any theme.
    var widgetFill: Color {
        switch self {
        case .glass: return .black.opacity(0.26)
        case .graphite: return .white.opacity(0.07)
        case .paper: return Color(red: 0.16, green: 0.15, blue: 0.14).opacity(0.88)
        case .midnight: return Color(red: 0.12, green: 0.17, blue: 0.36).opacity(0.55)
        case .wallpaper: return .black.opacity(0.24)
        }
    }

    var widgetStroke: Color {
        switch self {
        case .midnight: return Color(red: 0.5, green: 0.65, blue: 1).opacity(0.2)
        case .paper: return .black.opacity(0.1)
        default: return .white.opacity(0.1)
        }
    }

    @ViewBuilder
    func separator(height: CGFloat) -> some View {
        switch self {
        case .graphite:
            // Engraved: a dark groove with a light edge.
            HStack(spacing: 0) {
                Rectangle().fill(.black.opacity(0.5)).frame(width: 1)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            }
            .frame(height: height)
        case .paper:
            Capsule().fill(.black.opacity(0.14)).frame(width: 1, height: height)
        case .midnight:
            Capsule().fill(LinearGradient(colors: [Color(red: 0.5, green: 0.66, blue: 1).opacity(0.05),
                                                   Color(red: 0.5, green: 0.66, blue: 1).opacity(0.45),
                                                   Color(red: 0.5, green: 0.66, blue: 1).opacity(0.05)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: height)
        default:
            Capsule().fill(.white.opacity(0.28)).frame(width: 1, height: height)
        }
    }

    // MARK: Wallpaper colour

    /// Finds the wallpaper's dominant colour: a small k-means over a thumbnail, with each cluster
    /// weighted by how many pixels it holds and how colourful they are.
    static func loadWallpaperTint(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        if url == wallpaperURL { return }
        guard let image = NSImage(contentsOf: url), let (h, s, b) = dominantColor(of: image) else { return }
        wallpaperURL = url
        wallpaperHSB = (h, s, b)
        wallpaperTint = Color(hue: h, saturation: s, brightness: b)
    }

    private static var wallpaperURL: URL?

    static func dominantColor(of image: NSImage) -> (CGFloat, CGFloat, CGFloat)? {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var pixels: [SIMD3<Float>] = []
        for i in 0..<(side * side) {
            pixels.append(SIMD3(Float(data[i * 4]), Float(data[i * 4 + 1]), Float(data[i * 4 + 2])) / 255)
        }
        let k = 5
        var centers = (0..<k).map { pixels[$0 * pixels.count / k] }
        var assignment = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<8 {
            for (i, p) in pixels.enumerated() {
                assignment[i] = centers.indices.min { simd_length_squared(centers[$0] - p) < simd_length_squared(centers[$1] - p) }!
            }
            for c in 0..<k {
                let members = pixels.indices.filter { assignment[$0] == c }.map { pixels[$0] }
                if !members.isEmpty { centers[c] = members.reduce(SIMD3<Float>(), +) / Float(members.count) }
            }
        }
        let scored = (0..<k).map { c -> (SIMD3<Float>, Float) in
            let count = Float(assignment.filter { $0 == c }.count)
            let rgb = centers[c]
            let maxC = rgb.max(), minC = rgb.min()
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            // Near-black and near-white clusters carry no hue worth tinting with.
            let usable: Float = maxC < 0.12 || (minC > 0.9) ? 0.15 : 1
            return (rgb, count * (0.25 + saturation) * usable)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        let color = NSColor(deviceRed: CGFloat(best.x), green: CGFloat(best.y), blue: CGFloat(best.z), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }
}

/// Liquid Glass on macOS 26, a behind-window material before it, and a flat stand-in in snapshots,
/// finished with the theme's rim light and inner shading.
struct ThemeSurface<S: InsettableShape>: View {
    let shape: S
    let theme: Theme

    var body: some View {
        // Solid strokes and small gradient lines only: a gradient-stroked outline costs a lot while
        // the bar resizes under magnification.
        backdrop
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5))
            .overlay(alignment: .top) { edge(theme.highlight, height: 1) }
            .overlay(alignment: .bottom) {
                if let shade = theme.innerShade { edge(shade, height: 1.5) }
            }
    }

    /// A line along the top or bottom edge that fades out before the rounded corners.
    private func edge(_ color: Color, height: CGFloat) -> some View {
        Rectangle()
            .fill(LinearGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: 0.12),
                                         .init(color: color, location: 0.88), .init(color: color.opacity(0), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: height)
            .padding(.horizontal, 10)
            .padding(.vertical, 0.5)
    }

    @ViewBuilder
    private var backdrop: some View {
        if Snapshot.active {
            shape.fill(theme.flatFill)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(theme.tint), in: shape)
        } else {
            shape.fill(theme == .paper ? .thinMaterial : .ultraThinMaterial).overlay(shape.fill(theme.tint))
        }
    }
}
