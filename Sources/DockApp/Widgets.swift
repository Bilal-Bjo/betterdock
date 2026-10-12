// Dock widgets. Each refreshes only while the Dock is on screen.
import AppKit
import EventKit
import IOKit.ps
import SwiftUI

enum WidgetKind: String, CaseIterable {
    case nowPlaying, calendar, weather, clock, timer, system, network, storage, battery, agents

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
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
        case (.nowPlaying, .small), (.calendar, .small): return 1
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

    struct Event: Equatable {
        var title: String
        var start: Date
        var allDay: Bool
    }

    struct Weather: Equatable {
        var city: String
        var temperature: Double
        var code: Int
        var high: Double
        var low: Double
    }

    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var battery: (level: Int, charging: Bool)?
    @Published var events: [Event] = []
    @Published var calendarAllowed = true
    @Published var weather: Weather?
    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var download: Double = 0   // bytes per second
    @Published var upload: Double = 0
    @Published var diskFree: Double = 0   // bytes
    @Published var diskTotal: Double = 1
    private var lastBytes: (rx: UInt64, tx: UInt64, at: Date)?
    @Published var timerEnd: Date?
    @Published var timerPaused: TimeInterval?
    var timerLength: TimeInterval = 25 * 60

    var kinds: Set<WidgetKind> = []
    private var timer: Timer?
    private var slowTimer: Timer?
    private var artworkFor: String?
    private let queue = DispatchQueue(label: "widgets")
    private let store = EKEventStore()
    private var lastCPU: host_cpu_load_info?
    private var location: (lat: Double, lon: Double, city: String)?

    var active = false {
        didSet { if active != oldValue { active ? start() : stop() } }
    }

    private func start() {
        refresh()
        refreshSlow()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
        slowTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.refreshSlow() }
    }

    private func stop() {
        timer?.invalidate()
        slowTimer?.invalidate()
        timer = nil
        slowTimer = nil
    }

    /// Fast sources: music, battery, CPU and memory.
    func refresh() {
        if kinds.contains(.battery) { battery = Self.readBattery() }
        if kinds.contains(.system) { readSystem() }
        if kinds.contains(.calendar) { readCalendar() }
        if kinds.contains(.network) { readNetwork() }
        if kinds.contains(.storage) { readStorage() }
        guard kinds.contains(.nowPlaying) else { return }
        queue.async { [weak self] in
            let track = Self.readTrack()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.track != track { self.track = track }
                self.loadArtwork(track?.artworkURL)
            }
        }
    }

    /// Slow sources: weather every ten minutes.
    func refreshSlow() {
        if kinds.contains(.weather) { readWeather() }
    }

    // MARK: Music

    private func loadArtwork(_ url: String?) {
        guard url != artworkFor else { return }
        artworkFor = url
        guard let url, let link = URL(string: url) else { artwork = nil; return }
        URLSession.shared.dataTask(with: link) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { if self?.artworkFor == url { self?.artwork = image } }
        }.resume()
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

    func control(_ command: String) {
        let player = track?.player ?? "Spotify"
        queue.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player)\" to \(command)")?.executeAndReturnError(&error)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // MARK: Battery and system

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

    private func readSystem() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if ok == KERN_SUCCESS {
            if let last = lastCPU {
                let user = Double(load.cpu_ticks.0 &- last.cpu_ticks.0)
                let sys = Double(load.cpu_ticks.1 &- last.cpu_ticks.1)
                let idle = Double(load.cpu_ticks.2 &- last.cpu_ticks.2)
                let nice = Double(load.cpu_ticks.3 &- last.cpu_ticks.3)
                let total = user + sys + idle + nice
                if total > 0 { cpu = (user + sys + nice) / total }
            }
            lastCPU = load
        }
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmOK = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        if vmOK == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
            memory = used / Double(ProcessInfo.processInfo.physicalMemory)
        }
    }

    // MARK: Network and storage

    private func readNetwork() {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
            cursor = ifa.pointee.ifa_next
        }
        let now = Date()
        if let last = lastBytes {
            let dt = max(now.timeIntervalSince(last.at), 0.5)
            download = Double(rx &- last.rx) / dt
            upload = Double(tx &- last.tx) / dt
        }
        lastBytes = (rx, tx, now)
    }

    private func readStorage() {
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(v.volumeTotalCapacity ?? 1)
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .memory) + "/s"
    }

    // MARK: Calendar

    private var calendarRequested = false

    private func readCalendar() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined, !calendarRequested {
            calendarRequested = true
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.calendarAllowed = granted
                    if granted { self?.readCalendar() }
                }
            }
            return
        }
        guard status == .fullAccess else { calendarAllowed = false; return }
        calendarAllowed = true
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { Event(title: $0.title ?? "Event", start: $0.startDate, allDay: $0.isAllDay) }
        if events != Array(next) { events = Array(next) }
    }

    // MARK: Weather (Open-Meteo, no key; the city comes from your Mac's time zone)

    private func readWeather() {
        if let location {
            fetchForecast(location)
            return
        }
        let city = TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return }
            let place = (lat, lon, (first["name"] as? String) ?? city)
            DispatchQueue.main.async {
                self?.location = place
                self?.fetchForecast(place)
            }
        }.resume()
    }

    private func fetchForecast(_ place: (lat: Double, lon: Double, city: String)) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.lat)),
            URLQueryItem(name: "longitude", value: String(place.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int else { return }
            let daily = json["daily"] as? [String: Any]
            let high = (daily?["temperature_2m_max"] as? [Double])?.first ?? temp
            let low = (daily?["temperature_2m_min"] as? [Double])?.first ?? temp
            DispatchQueue.main.async {
                self?.weather = Weather(city: place.city, temperature: temp, code: code, high: high, low: low)
            }
        }.resume()
    }

    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    // MARK: Focus timer

    func toggleTimer() {
        if let end = timerEnd {
            timerPaused = max(0, end.timeIntervalSinceNow)
            timerEnd = nil
        } else {
            timerEnd = Date().addingTimeInterval(timerPaused ?? timerLength)
            timerPaused = nil
        }
    }

    func resetTimer() {
        timerEnd = nil
        timerPaused = nil
    }

    func setTimerLength(_ minutes: Int) {
        timerLength = TimeInterval(minutes * 60)
        resetTimer()
    }
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
            shape.fill(Color.black.opacity(Theme.current == .ember ? 0.55 : 0.28))
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            content
                .padding(height * 0.12)
                .foregroundStyle(.white)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
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
                                Capsule().fill(Theme.current == .ember ? Theme.emberRed : Color(red: 1, green: 0.66, blue: 0.16))
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
                timerFace(data.timerPaused ?? data.timerLength, running: false)
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
                    if rich { Text(running ? "Focus" : "Click to start").font(font(0.14)).foregroundStyle(.secondary) }
                }
            }
        }
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
    }
}
