import AppKit
import EventKit
import IOKit.ps
import SwiftUI

// MARK: - Data

/// AppleScripts compiled once and reused; compiling is the expensive part.
enum Scripts {
    private static var cache: [String: NSAppleScript] = [:]
    private static let lock = NSLock()

    static func run(_ source: String) -> NSAppleEventDescriptor? {
        lock.lock()
        let script: NSAppleScript? = cache[source] ?? {
            let compiled = NSAppleScript(source: source)
            var error: NSDictionary?
            compiled?.compileAndReturnError(&error)
            cache[source] = compiled
            return compiled
        }()
        lock.unlock()
        var error: NSDictionary?
        return script?.executeAndReturnError(&error)
    }
}

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
    struct Quota: Equatable {
        var percent: Double
        var resets: Date?
        /// When the number was read. Older than two hours, the widget dims it rather than pass it off as current.
        var updated: Date?
        var isStale: Bool { updated.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? false }
    }

    @Published var claudeWeek: Quota?
    @Published var codexWeek: Quota?
    private var usageReadAt = Date.distantPast
    @Published var download: Double = 0   // bytes per second
    @Published var upload: Double = 0
    @Published var diskFree: Double = 0   // bytes
    @Published var diskTotal: Double = 1
    private var lastBytes: (rx: UInt64, tx: UInt64, at: Date)?
    private var storageReadAt = Date.distantPast
    @Published var timerCompleted = false
    var onTimerFinished: () -> Void = { CompletionBanner.show() }
    private var completionTimer: Timer?
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
    var weatherCity: String? {
        didSet { if oldValue != weatherCity { location = nil; weather = nil; if active { readWeather() } } }
    }
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
        if kinds.contains(.battery), let now = Self.readBattery(), now.0 != battery?.level || now.1 != battery?.charging {
            battery = now
        }
        if kinds.contains(.system) { readSystem() }
        if kinds.contains(.calendar), Date().timeIntervalSince(calendarReadAt) > 60 {
            calendarReadAt = Date()
            readCalendar()
        }
        if kinds.contains(.network) { readNetwork() }
        if kinds.contains(.storage), Date().timeIntervalSince(storageReadAt) > 60 {
            storageReadAt = Date()
            readStorage()
        }
        if kinds.contains(.aiUsage), Date().timeIntervalSince(usageReadAt) > 20 {
            usageReadAt = Date()
            queue.async { [weak self] in
                let claude = Self.readClaudeWeek(), codex = Self.readCodexWeek()
                DispatchQueue.main.async {
                    if self?.claudeWeek != claude { self?.claudeWeek = claude }
                    if self?.codexWeek != codex { self?.codexWeek = codex }
                }
            }
        }
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
            guard let out = Scripts.run(script)?.stringValue, !out.isEmpty else { continue }
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
            _ = Scripts.run("tell application \"\(player)\" to \(command)")
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
                if total > 0 {
                    let value = (user + sys + nice) / total
                    if Int(value * 100) != Int(cpu * 100) { cpu = value }
                }
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
            let value = used / Double(ProcessInfo.processInfo.physicalMemory)
            if Int(value * 100) != Int(memory * 100) { memory = value }
        }
    }

    // MARK: AI usage (weekly)

    /// Saved by hooks/claude-statusline.sh from the rate_limits Claude Code gives its status line.
    static func readClaudeWeek() -> Quota? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterDock/usage/claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let percent = (json["weekly"] as? NSNumber)?.doubleValue else { return nil }
        var resets: Date?
        if let raw = json["resets"] as? String {
            if let seconds = Double(raw) { resets = Date(timeIntervalSince1970: seconds) }
            else { resets = ISO8601DateFormatter().date(from: raw) }
        }
        if let resets, resets < Date() { return Quota(percent: 0, resets: nil) } // the week rolled over since
        let updated = (json["updated"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Quota(percent: percent, resets: resets, updated: updated)
    }

    /// Codex writes its rate limits into each session log; the weekly window is 10,080 minutes.
    static func readCodexWeek() -> Quota? {
        // Sessions live in sessions/YYYY/MM/DD; only the last few days can hold the latest one.
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let calendar = Calendar(identifier: .gregorian)
        var newest: (URL, Date)?
        for back in 0..<4 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.1 { newest = (url, date) }
            }
            if newest != nil { break }
        }
        guard let file = newest?.0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let tail = try? handle.readToEnd(), let text = Optional(String(decoding: tail, as: UTF8.self)) else { return nil }

        func weekly(in object: Any) -> Quota? {
            if let dict = object as? [String: Any] {
                if let limits = dict["rate_limits"] as? [String: Any] {
                    for key in ["primary", "secondary"] {
                        if let window = limits[key] as? [String: Any],
                           (window["window_minutes"] as? NSNumber)?.intValue == 10080,
                           let used = (window["used_percent"] as? NSNumber)?.doubleValue {
                            let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                            if let resets, resets < Date() { return Quota(percent: 0, resets: nil) }
                            return Quota(percent: used, resets: resets, updated: newest?.1)
                        }
                    }
                }
                for value in dict.values { if let found = weekly(in: value) { return found } }
            }
            return nil
        }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            if let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
               let found = weekly(in: object) { return found }
        }
        return nil
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
            let down = Double(rx >= last.rx ? rx - last.rx : 0) / dt, up = Double(tx >= last.tx ? tx - last.tx : 0) / dt
            if Self.rate(down) != Self.rate(download) { download = down }
            if Self.rate(up) != Self.rate(upload) { upload = up }
        }
        lastBytes = (rx, tx, now)
    }

    private func readStorage() {
        let url = URL(fileURLWithPath: "/")
        queue.async { [weak self] in
            guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
            let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0), total = Double(v.volumeTotalCapacity ?? 1)
            DispatchQueue.main.async {
                self?.diskFree = free
                self?.diskTotal = total
            }
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .memory) + "/s"
    }

    // MARK: Calendar

    private var calendarRequested = false
    private var calendarReadAt = Date.distantPast

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
        let inferred = TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "London"
        let chosen = weatherCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let city = chosen.isEmpty ? inferred : chosen
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
        completionTimer?.invalidate()
        if let end = timerEnd {
            if end <= Date() { finishTimer(); return }
            timerPaused = max(0, end.timeIntervalSinceNow)
            timerEnd = nil
        } else {
            timerCompleted = false
            timerEnd = Date().addingTimeInterval(timerPaused ?? timerLength)
            timerPaused = nil
            scheduleTimerCompletion()
        }
    }

    func scheduleTimerCompletion() {
        completionTimer?.invalidate()
        guard let end = timerEnd else { return }
        completionTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.finishTimer()
        }
    }

    func finishTimer() {
        guard timerEnd != nil else { return }
        completionTimer?.invalidate()
        completionTimer = nil
        timerEnd = nil
        timerPaused = nil
        timerCompleted = true
        onTimerFinished()
    }

    func resetTimer() {
        completionTimer?.invalidate()
        completionTimer = nil
        timerEnd = nil
        timerPaused = nil
        timerCompleted = false
    }

    func setTimerLength(_ minutes: Int) {
        timerLength = TimeInterval(minutes * 60)
        resetTimer()
    }

}

