// Live status shared by the dock and folders: themes, agent dots, unread badges.
import AppKit
import SwiftUI

// MARK: - Theme

enum Theme: String {
    case glass, ember, wallpaper

    static var current: Theme = .glass
    static var wallpaperTint: Color = .clear

    static let emberRed = Color(red: 0.86, green: 0.12, blue: 0.14)

    var runningDot: Color {
        switch self {
        case .ember: return Theme.emberRed
        default: return .primary.opacity(0.75)
        }
    }

    var folderTitle: Color {
        self == .ember ? Theme.emberRed.opacity(0.9) : .secondary
    }

    /// Bar and panel surface for the active theme.
    @ViewBuilder
    func surface<S: InsettableShape>(_ shape: S) -> some View {
        switch self {
        case .glass:
            GlassSurface(shape: shape, tint: .clear)
        case .wallpaper:
            GlassSurface(shape: shape, tint: Theme.wallpaperTint.opacity(0.38))
        case .ember:
            shape
                .fill(LinearGradient(colors: [Color(white: 0.11).opacity(0.94), Color(white: 0.04).opacity(0.96)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.emberRed.opacity(0.9), Theme.emberRed.opacity(0.15)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }

    /// Average colour of the current wallpaper, used by the wallpaper theme.
    static func loadWallpaperTint(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        if let c = rep.colorAt(x: 0, y: 0) { wallpaperTint = Color(nsColor: c) }
    }
}

struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    let tint: Color

    var body: some View {
        if #available(macOS 26.0, *), !GlassBackground.useMaterial {
            Color.clear.glassEffect(.regular.tint(tint), in: shape)
        } else {
            shape.fill(Color(white: 0.55).opacity(0.28)) // stand-in for glass in snapshots
                .overlay(shape.fill(tint))
                .overlay(shape.strokeBorder(.white.opacity(0.15)))
        }
    }
}

// MARK: - Agent status

enum AgentState: Int, Comparable {
    case done = 1, working = 2, attention = 3

    static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .working: return Color(red: 1.0, green: 0.66, blue: 0.16)
        case .done: return Color(red: 0.2, green: 0.82, blue: 0.4)
        case .attention: return Color(red: 1.0, green: 0.27, blue: 0.23)
        }
    }

    var label: String {
        switch self {
        case .working: return "Agent working"
        case .done: return "Agent finished"
        case .attention: return "Agent needs you"
        }
    }
}

/// Top-right status dot: amber breathes while an agent works, green when it is done, red when it needs you.
struct AgentDot: View {
    let state: AgentState
    let size: CGFloat
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(state.color)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: state.color.opacity(0.7), radius: state == .working ? 3 : 2)
            .opacity(state == .working && breathe ? 0.45 : 1)
            .animation(state == .working && !Motion.reduce ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: breathe)
            .onAppear { breathe = true }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .help(state.label)
    }
}

/// Red unread badge that wiggles when the count goes up.
struct UnreadBadge: View {
    let text: String
    let height: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: height * 0.62, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19)))
            .overlay(Capsule().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
            .keyframeAnimator(initialValue: 0.0, trigger: text) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                CubicKeyframe(Motion.reduce ? 0 : -14, duration: 0.07)
                CubicKeyframe(Motion.reduce ? 0 : 12, duration: 0.1)
                CubicKeyframe(Motion.reduce ? 0 : -7, duration: 0.09)
                SpringKeyframe(0, duration: 0.3, spring: .init(duration: 0.3, bounce: 0.3))
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// Sums numeric badges (for a folder); falls back to a dot-like "•" for non-numeric labels.
func combinedBadge(_ labels: [String]) -> String? {
    guard !labels.isEmpty else { return nil }
    let numbers = labels.compactMap { Int($0) }
    if numbers.count == labels.count { return String(numbers.reduce(0, +)) }
    return "•"
}
