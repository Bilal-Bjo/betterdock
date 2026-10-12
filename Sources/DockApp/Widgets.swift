// Dock widgets: Now Playing, Clock, Battery and an agent summary. Each refreshes only while the Dock is visible.
import AppKit
import IOKit.ps
import SwiftUI

enum WidgetKind: String {
    case nowPlaying, clock, battery, agents

    /// Width in icon units.
    var span: CGFloat {
        switch self {
        case .nowPlaying: return 3
        case .clock, .agents: return 2
        case .battery: return 1
        }
    }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .clock: return "Clock"
        case .battery: return "Battery"
        case .agents: return "Agents"
        }
    }
}

// MARK: - Data

final class WidgetData: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var playing: Bool
        var progress: Double
        var artworkURL: String?
        var player: String
    }

    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var battery: (level: Int, charging: Bool)?
    private var timer: Timer?
    private var artworkFor: String?
    private let queue = DispatchQueue(label: "widgets")

    var active = false {
        didSet { if active != oldValue { active ? start() : stop() } }
    }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        battery = Self.readBattery()
        queue.async { [weak self] in
            let track = Self.readTrack()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.track != track { self.track = track }
                self.loadArtwork(track?.artworkURL)
            }
        }
    }

    private func loadArtwork(_ url: String?) {
        guard url != artworkFor else { return }
        artworkFor = url
        guard let url, let link = URL(string: url) else { artwork = nil; return }
        URLSession.shared.dataTask(with: link) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { if self?.artworkFor == url { self?.artwork = image } }
        }.resume()
    }

    static func readBattery() -> (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let level = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (level, charging)
        }
        return nil
    }

    /// Asks Spotify, then Music, what is playing. Only queries a player that is already running,
    /// so it never launches one; macOS asks once for permission to talk to each player.
    static func readTrack() -> Track? {
        for player in ["Spotify", "Music"] {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == player }) else { continue }
            let art = player == "Spotify" ? "artwork url of current track" : "\"\""
            let script = """
            tell application "\(player)"
                if player state is stopped then return ""
                set p to player position
                set d to duration of current track
                if d > 10000 then set d to d / 1000
                return (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as string) & "\\n" & (p / d) & "\\n" & \(art)
            end tell
            """
            var error: NSDictionary?
            guard let out = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 4 else { continue }
            return Track(title: parts[0], artist: parts[1], playing: parts[2] == "playing",
                         progress: Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0,
                         artworkURL: parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil, player: player)
        }
        return nil
    }

    func playPause() {
        let player = track?.player ?? "Spotify"
        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player)\" to playpause")?.executeAndReturnError(&error)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

// MARK: - Views

struct WidgetTile: View {
    let kind: WidgetKind
    let height: CGFloat
    @ObservedObject var data: WidgetData
    let agents: [String: AgentState]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.22, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(Theme.current == .ember ? 0.55 : 0.28))
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            content.padding(height * 0.12)
        }
        .frame(width: height * kind.span + (kind.span - 1) * 6, height: height)
    }

    @ViewBuilder
    var content: some View {
        switch kind {
        case .clock:
            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: height * 0.36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.system(size: height * 0.17, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        case .battery:
            let level = data.battery?.level ?? 0
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: height * 0.07)
                Circle().trim(from: 0, to: CGFloat(level) / 100)
                    .stroke(level <= 20 ? Color.red : Color(red: 0.2, green: 0.82, blue: 0.4),
                            style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.open, value: level)
                VStack(spacing: 0) {
                    if data.battery?.charging == true {
                        Image(systemName: "bolt.fill").font(.system(size: height * 0.14))
                    }
                    Text("\(level)").font(.system(size: height * 0.2, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(.white)
            }
            .padding(height * 0.04)
        case .nowPlaying:
            HStack(spacing: height * 0.14) {
                ZStack {
                    RoundedRectangle(cornerRadius: height * 0.1, style: .continuous).fill(.white.opacity(0.1))
                    if let art = data.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: height * 0.76, height: height * 0.76)
                .clipShape(RoundedRectangle(cornerRadius: height * 0.1, style: .continuous))
                .animation(Motion.open, value: data.artwork != nil)
                VStack(alignment: .leading, spacing: height * 0.04) {
                    Text(data.track?.title ?? "Nothing playing")
                        .font(.system(size: height * 0.19, weight: .semibold)).lineLimit(1)
                    Text(data.track?.artist ?? "Spotify or Music")
                        .font(.system(size: height * 0.16)).foregroundStyle(.secondary).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(min(max(data.track?.progress ?? 0, 0), 1)))
                            }
                    }
                    .frame(height: max(2, height * 0.05))
                }
                .foregroundStyle(.white)
                Image(systemName: data.track?.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: height * 0.24))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height * 0.3)
            }
        case .agents:
            let counts = Dictionary(grouping: agents.values, by: { $0 }).mapValues(\.count)
            VStack(alignment: .leading, spacing: height * 0.06) {
                ForEach([AgentState.attention, .working, .done], id: \.rawValue) { state in
                    HStack(spacing: height * 0.08) {
                        Circle().fill(state.color).frame(width: height * 0.13, height: height * 0.13)
                        Text("\(counts[state] ?? 0) \(state == .working ? "working" : state == .done ? "done" : "need you")")
                            .font(.system(size: height * 0.16, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity((counts[state] ?? 0) > 0 ? 1 : 0.4))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
