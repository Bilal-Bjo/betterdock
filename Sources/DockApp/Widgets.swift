// Dock widgets. Each refreshes only while the Dock is on screen.
import AppKit
import EventKit
import IOKit.ps
import SwiftUI

enum WidgetKind: String, CaseIterable {
    case nowPlaying, aiUsage, calendar, weather, clock, timer, system, network, storage, battery, agents

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .aiUsage: return "AI Usage"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .clock: return "Clock"
        case .timer: return "Focus Timer"
        case .system: return "System"
        case .network: return "Network"
        case .storage: return "Storage"
        case .battery: return "Battery"
        case .agents: return "Agents"
        }
    }

    /// Width in icon units for each size.
    func span(_ size: WidgetSize) -> CGFloat {
        switch (self, size) {
        case (.battery, .small), (.weather, .small), (.timer, .small), (.system, .small), (.agents, .small), (.clock, .small),
             (.network, .small), (.storage, .small): return 1
        case (.nowPlaying, .small), (.calendar, .small), (.aiUsage, .small): return 1
        case (.aiUsage, .medium): return 2.5
        case (.aiUsage, .large): return 3.5
        case (.nowPlaying, .medium): return 3
        case (.nowPlaying, .large): return 4
        case (.calendar, .large), (.system, .large), (.weather, .large), (.agents, .large): return 3
        case (_, .large): return 2.5
        case (.battery, .medium): return 1.5
        default: return 2
        }
    }
}

enum WidgetSize: String, CaseIterable {
    case small, medium, large
    var title: String { rawValue.capitalized }
}

// MARK: - Views

struct WidgetTile: View {
    let kind: WidgetKind
    let size: WidgetSize
    let height: CGFloat
    let width: CGFloat
    @ObservedObject var data: WidgetData
    let agents: [String: AgentState]

    private var compact: Bool { size == .small }
    private var rich: Bool { size == .large }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        ZStack {
            shape.fill(Theme.current.widgetFill)
                .overlay(shape.strokeBorder(Theme.current.widgetStroke, lineWidth: 0.5))
            content
                .padding(height * 0.12)
                .foregroundStyle(.white)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private func font(_ scale: CGFloat, _ weight: Font.Weight = .regular, rounded: Bool = false) -> Font {
        .system(size: height * scale, weight: weight, design: rounded ? .rounded : .default)
    }

    @ViewBuilder
    var content: some View {
        switch kind {
        case .clock: clock
        case .battery: battery
        case .nowPlaying: nowPlaying
        case .agents: agentSummary
        case .calendar: calendar
        case .weather: weatherView
        case .system: system
        case .timer: focusTimer
        case .network: network
        case .aiUsage: aiUsage
        case .storage: storage
        }
    }

    var clock: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(font(compact ? 0.26 : 0.36, .semibold, rounded: true))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                if !compact {
                    Text(context.date, format: rich ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(font(0.16, .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    var battery: some View {
        let level = data.battery?.level ?? 0
        return ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: height * 0.07)
            Circle().trim(from: 0, to: CGFloat(level) / 100)
                .stroke(level <= 20 ? Color.red : Color(red: 0.2, green: 0.82, blue: 0.4),
                        style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.open, value: level)
            VStack(spacing: 0) {
                if data.battery?.charging == true {
                    Image(systemName: "bolt.fill").font(font(0.14))
                }
                Text("\(level)").font(font(0.2, .semibold, rounded: true)).monospacedDigit()
            }
        }
        .padding(height * 0.04)
    }

    var nowPlaying: some View {
        HStack(spacing: height * 0.14) {
            ZStack {
                RoundedRectangle(cornerRadius: height * 0.1, style: .continuous).fill(.white.opacity(0.1))
                if let art = data.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6))
                }
                if compact {
                    Image(systemName: data.track?.playing == true ? "pause.fill" : "play.fill")
                        .font(font(0.2))
                        .shadow(radius: 3)
                }
            }
            .frame(width: height * 0.76, height: height * 0.76)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.1, style: .continuous))
            .animation(Motion.open, value: data.artwork != nil)
            if !compact {
                VStack(alignment: .leading, spacing: height * 0.04) {
                    Text(data.track?.title ?? "Nothing playing").font(font(0.19, .semibold)).lineLimit(1)
                    Text(data.track?.artist ?? "Spotify or Music").font(font(0.16)).foregroundStyle(.secondary).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(min(max(data.track?.progress ?? 0, 0), 1)))
                            }
                    }
                    .frame(height: max(2, height * 0.05))
                }
                if rich {
                    Button { data.control("previous track") } label: { Image(systemName: "backward.fill") }
                        .buttonStyle(.plain).font(font(0.2))
                }
                Image(systemName: data.track?.playing == true ? "pause.fill" : "play.fill")
                    .font(font(0.24))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height * 0.3)
                if rich {
                    Button { data.control("next track") } label: { Image(systemName: "forward.fill") }
                        .buttonStyle(.plain).font(font(0.2))
                }
            }
        }
    }

    var agentSummary: some View {
        let counts = Dictionary(grouping: agents.values, by: { $0 }).mapValues(\.count)
        return Group {
            if compact {
                // One dot in the most urgent colour, with the number of active agents.
                let top = agents.values.max()
                VStack(spacing: height * 0.04) {
                    Circle().fill(top?.color ?? .white.opacity(0.25)).frame(width: height * 0.26, height: height * 0.26)
                    Text("\(agents.count)").font(font(0.18, .semibold, rounded: true)).monospacedDigit()
                }
            } else {
                VStack(alignment: .leading, spacing: height * 0.06) {
                    ForEach([AgentState.attention, .working, .done], id: \.rawValue) { state in
                        HStack(spacing: height * 0.08) {
                            Circle().fill(state.color).frame(width: height * 0.13, height: height * 0.13)
                            Text("\(counts[state] ?? 0) \(state == .working ? "working" : state == .done ? "done" : "need you")")
                                .font(font(0.16, .medium)).monospacedDigit()
                                .foregroundStyle(.white.opacity((counts[state] ?? 0) > 0 ? 1 : 0.4))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var calendar: some View {
        Group {
            if !data.calendarAllowed {
                Label("Allow Calendar", systemImage: "calendar.badge.exclamationmark")
                    .font(font(0.15, .medium)).labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            } else if let next = data.events.first {
                if compact {
                    VStack(spacing: 0) {
                        Image(systemName: "calendar").font(font(0.18))
                        Text(next.start, format: .dateTime.hour().minute()).font(font(0.17, .semibold, rounded: true)).monospacedDigit()
                    }
                } else {
                    VStack(alignment: .leading, spacing: height * 0.04) {
                        ForEach(Array(data.events.prefix(rich ? 2 : 1).enumerated()), id: \.offset) { _, event in
                            HStack(spacing: height * 0.08) {
                                Capsule().fill(Theme.current.accent)
                                    .frame(width: 3, height: height * 0.3)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(event.title).font(font(0.17, .semibold)).lineLimit(1)
                                    Text(event.start, format: .relative(presentation: .named)).font(font(0.14)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Label(compact ? "" : "No more events", systemImage: "calendar").font(font(0.16, .medium)).foregroundStyle(.secondary)
            }
        }
    }

    var weatherView: some View {
        Group {
            if let w = data.weather {
                HStack(spacing: height * 0.1) {
                    Image(systemName: WidgetData.symbol(for: w.code))
                        .symbolRenderingMode(.multicolor)
                        .font(font(compact ? 0.24 : 0.32))
                    if compact {
                        Text("\(Int(w.temperature.rounded()))°").font(font(0.2, .semibold, rounded: true))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(w.temperature.rounded()))°").font(font(0.3, .semibold, rounded: true))
                            Text(rich ? "\(w.city) · H \(Int(w.high.rounded()))° L \(Int(w.low.rounded()))°" : w.city)
                                .font(font(0.14)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    var system: some View {
        Group {
            if compact {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: height * 0.07)
                    Circle().trim(from: 0, to: data.cpu)
                        .stroke(Color(red: 0.4, green: 0.7, blue: 1), style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(data.cpu * 100))").font(font(0.18, .semibold, rounded: true)).monospacedDigit()
                }
                .padding(height * 0.04)
            } else {
                VStack(alignment: .leading, spacing: height * 0.08) {
                    meter("CPU", data.cpu, Color(red: 0.4, green: 0.7, blue: 1))
                    meter("Memory", data.memory, Color(red: 0.75, green: 0.55, blue: 1))
                }
            }
        }
        .animation(Motion.open, value: data.cpu)
    }

    func meter(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(font(0.14, .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value * 100))%").font(font(0.14, .semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1)) }
            }
            .frame(height: max(3, height * 0.06))
        }
    }

    var aiUsage: some View {
        let rows: [(String, String, WidgetData.Quota?, Color)] = [
            ("Claude", "/Applications/Claude.app", data.claudeWeek, Color(red: 0.85, green: 0.47, blue: 0.34)),
            ("Codex", "/Applications/ChatGPT.app", data.codexWeek, Color(red: 0.62, green: 0.66, blue: 0.75)),
        ]
        return Group {
            if compact {
                // Two concentric rings: Claude outside, Codex inside.
                ZStack {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        let inset = CGFloat(i) * height * 0.13
                        Circle().stroke(.white.opacity(0.12), lineWidth: height * 0.06).padding(inset)
                        Circle().trim(from: 0, to: (row.2?.percent ?? 0) / 100)
                            .stroke(row.3, style: StrokeStyle(lineWidth: height * 0.06, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(inset)
                    }
                }
                .padding(height * 0.06)
            } else {
                VStack(alignment: .leading, spacing: height * 0.07) {
                    ForEach(rows, id: \.0) { name, path, quota, color in
                        HStack(spacing: height * 0.08) {
                            Image(nsImage: WidgetIcons.icon(path)).resizable().frame(width: height * 0.24, height: height * 0.24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(name).font(font(0.14, .medium)).foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text(quota.map { "\(Int($0.percent.rounded()))%" } ?? "–").font(font(0.14, .semibold)).monospacedDigit()
                                        .opacity(quota?.isStale == true ? 0.45 : 1)
                                    if rich, let resets = quota?.resets {
                                        Text(resets, format: .relative(presentation: .named))
                                            .font(font(0.12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                GeometryReader { geo in
                                    Capsule().fill(.white.opacity(0.12)).overlay(alignment: .leading) {
                                        Capsule().fill(color).frame(width: geo.size.width * min(max((quota?.percent ?? 0) / 100, 0), 1))
                                    }
                                }
                                .frame(height: max(3, height * 0.05))
                                .opacity(quota?.isStale == true ? 0.45 : 1)
                            }
                        }
                        .help(quota?.isStale == true
                              ? "\(name) usage last updated \(quota?.updated?.formatted(.relative(presentation: .named)) ?? "a while ago")"
                              : "\(name) weekly usage")
                    }
                }
            }
        }
        .animation(Motion.open, value: data.claudeWeek)
        .animation(Motion.open, value: data.codexWeek)
    }

    var network: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    Image(systemName: "arrow.down").font(font(0.16, .semibold))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.download), countStyle: .memory))
                        .font(font(0.13, .semibold, rounded: true)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: height * 0.06) {
                    Label(WidgetData.rate(data.download), systemImage: "arrow.down")
                    Label(WidgetData.rate(data.upload), systemImage: "arrow.up").foregroundStyle(.secondary)
                }
                .font(font(0.16, .semibold, rounded: true))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var storage: some View {
        let used = 1 - data.diskFree / max(data.diskTotal, 1)
        let free = ByteCountFormatter.string(fromByteCount: Int64(data.diskFree), countStyle: .file)
        return Group {
            if compact {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: height * 0.07)
                    Circle().trim(from: 0, to: used)
                        .stroke(used > 0.9 ? Color.red : Color(red: 0.95, green: 0.78, blue: 0.3),
                                style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "internaldrive").font(font(0.16))
                }
                .padding(height * 0.04)
            } else {
                VStack(alignment: .leading, spacing: height * 0.06) {
                    Text("\(free) free").font(font(0.18, .semibold)).lineLimit(1)
                    meter("Disk", used, used > 0.9 ? .red : Color(red: 0.95, green: 0.78, blue: 0.3))
                }
            }
        }
    }

    var focusTimer: some View {
        Group {
            if let end = data.timerEnd {
                // Ticks once a second, and only while the timer runs.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timerFace(max(0, end.timeIntervalSince(context.date)), running: true)
                }
            } else {
                timerFace(data.timerCompleted ? 0 : data.timerPaused ?? data.timerLength, running: false)
            }
        }
    }

    func timerFace(_ remaining: TimeInterval, running: Bool) -> some View {
        let progress = 1 - remaining / max(data.timerLength, 1)
        let text = String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60)
        return HStack(spacing: height * 0.12) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: height * 0.06)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color(red: 1, green: 0.4, blue: 0.35), style: StrokeStyle(lineWidth: height * 0.06, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: running ? "pause.fill" : "play.fill").font(font(0.16))
            }
            .frame(width: height * (compact ? 0.66 : 0.6), height: height * (compact ? 0.66 : 0.6))
            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text).font(font(0.28, .semibold, rounded: true)).monospacedDigit()
                    if rich { Text(data.timerCompleted ? "Finished · click to restart" : running ? "Focus" : data.timerPaused != nil ? "Paused" : "Click to start").font(font(0.14)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// App icons used inside widgets, looked up once.
enum WidgetIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

/// Lets a label style be chosen at runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Self-test

/// `BetterDock --widget-test` prints what each data source reads on this Mac.
enum WidgetSelfTest {
    static func run() {
        let data = WidgetData()
        data.kinds = Set(WidgetKind.allCases)
        print("battery:", WidgetData.readBattery().map { "\($0.0)% charging=\($0.1)" } ?? "no battery")
        print("now playing:", WidgetData.readTrack().map { "\($0.title) — \($0.artist) [\($0.player), playing=\($0.playing)]" } ?? "nothing playing / no player running")
        data.refresh()
        Thread.sleep(forTimeInterval: 1)
        data.refresh()
        print(String(format: "system: cpu %.0f%%, memory %.0f%%", data.cpu * 100, data.memory * 100))
        print("calendar access:", EKEventStore.authorizationStatus(for: .event) == .fullAccess ? "granted" : "not granted yet (asked on first use)")
        data.refreshSlow()
        let deadline = Date().addingTimeInterval(8)
        while data.weather == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        print("weather:", data.weather.map { "\($0.city) \(Int($0.temperature))° code \($0.code) H\(Int($0.high)) L\(Int($0.low))" } ?? "unavailable")
        data.toggleTimer()
        print("timer: running =", data.timerEnd != nil, "length", Int(data.timerLength / 60), "min")
        print("claude weekly:", WidgetData.readClaudeWeek().map { "\(Int($0.percent))% resets \($0.resets.map { "\($0)" } ?? "?")" } ?? "no data yet (needs a Claude Code session with the BetterDock status line)")
        print("codex weekly:", WidgetData.readCodexWeek().map { "\(Int($0.percent))% resets \($0.resets.map { "\($0)" } ?? "?")" } ?? "no data")
    }
}
