// Live status shared by the dock and folders: agent dots and unread badges.
import AppKit
import SwiftUI

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

/// Whether the surface this view lives on is on screen. Looping animations only run while it is,
/// so a hidden Dock costs no CPU.
private struct OnScreenKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var onScreen: Bool {
        get { self[OnScreenKey.self] }
        set { self[OnScreenKey.self] = newValue }
    }
}

/// Top-right status dot: amber breathes while an agent works, green when it is done, red when it needs you.
struct AgentDot: View {
    let state: AgentState
    let size: CGFloat
    @Environment(\.onScreen) private var onScreen

    var body: some View {
        Group {
            if state == .working && onScreen && !Motion.reduce && !Snapshot.active {
                BreathingDot(color: state.color, size: size)
            } else {
                dot(state.color)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .tooltip(state.label)
    }

    func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: 2)
    }
}

/// The breathing glow runs as a Core Animation loop in the render server, so the app does no
/// per-frame work while an agent is working.
private struct BreathingDot: NSViewRepresentable {
    let color: Color
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        let dot = CALayer()
        dot.frame = view.bounds
        dot.cornerRadius = size / 2
        dot.backgroundColor = NSColor(color).cgColor
        dot.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dot.borderWidth = 1
        dot.shadowColor = NSColor(color).cgColor
        dot.shadowOpacity = 0.7
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "breathe")
        view.layer?.addSublayer(dot)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// Two rings that swell out of a tile and fade, once: an agent finished or needs you while the Dock
/// was hidden. Lives only for the length of the pulse; Core Animation runs it in the render server.
struct PulseRing: NSViewRepresentable {
    let color: Color
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        for i in 0..<2 {
            let ring = CALayer()
            ring.frame = view.bounds
            ring.cornerRadius = size * 0.225
            ring.borderColor = NSColor(color).cgColor
            ring.borderWidth = 2
            ring.opacity = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.92
            grow.toValue = 1.35
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]
            fade.keyTimes = [0, 0.2, 1]
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.7
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.22
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            ring.add(group, forKey: "pulse")
            view.layer?.addSublayer(ring)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
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
