// Profiles: named Dock layouts, switched by hand or by time of day and Wi-Fi network.
import AppKit
import CoreWLAN

/// One automatic switching rule from dock.json, e.g.
/// `{ "profile": "Work", "days": ["weekdays"], "from": "09:00", "to": "18:00" }` or `{ "profile": "Work", "wifi": "Office" }`.
struct ProfileRule: Codable {
    var profile: String
    var days: [String]? = nil  // mon…sun, weekdays, weekends
    var from: String? = nil    // "09:00"
    var to: String? = nil      // "18:00"; a window may cross midnight
    var wifi: String? = nil    // network name

    func matches(_ date: Date, ssid: String?) -> Bool {
        if let wifi, wifi != ssid { return false }
        let calendar = Calendar.current
        if let days, !days.isEmpty {
            let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            let today = names[weekday - 1]
            let weekend = weekday == 1 || weekday == 7
            let hit = days.contains { day in
                let day = day.lowercased()
                return day.hasPrefix(today) || (day == "weekdays" && !weekend) || (day == "weekends" && weekend)
            }
            if !hit { return false }
        }
        if let start = minutes(from), let end = minutes(to) {
            let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let inside = start <= end ? (now >= start && now < end) : (now >= start || now < end)
            if !inside { return false }
        }
        return true
    }

    private func minutes(_ time: String?) -> Int? {
        guard let parts = time?.split(separator: ":"), let hour = Int(parts.first ?? "") else { return nil }
        return hour * 60 + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }
}

enum WiFi {
    /// The current network name; nil when off, disconnected, or when macOS withholds it
    /// (recent versions only share it with apps that have Location access).
    static var ssid: String? { CWWiFiClient.shared().interface()?.ssid() }
}

/// Checks the rules once a minute and on wake, and reports when a different rule starts to apply.
/// A profile picked by hand stays until the next rule change.
final class ProfileSwitcher {
    var rules: [ProfileRule] = []
    var onMatch: (String) -> Void = { _ in }
    private var timer: Timer?
    private var wakeObserver: Any?
    private var lastMatch: String?

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil, !rules.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = 10
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in self?.evaluate() }
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        lastMatch = nil
    }

    func evaluate() {
        let ssid = rules.contains { $0.wifi != nil } ? WiFi.ssid : nil
        let match = rules.first { $0.matches(Date(), ssid: ssid) }?.profile
        guard match != lastMatch else { return }
        lastMatch = match
        if let match { onMatch(match) }
    }
}

// MARK: - Switching

extension DockController {
    /// Saved profiles, read fresh from dock.json so hand edits count.
    var savedProfiles: [String: Any] {
        guard let data = FileManager.default.contents(atPath: model.configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["profiles"] as? [String: Any] ?? [:]
    }

    func profileMenu() -> [DockMenuItem] {
        let names = savedProfiles.keys.sorted()
        var items = names.map { name in
            DockMenuItem(title: name, checked: name == currentProfile) { [weak self] in self?.switchProfile(name) }
        }
        if !items.isEmpty { items.append(DockMenuItem(title: "-")) }
        items.append(DockMenuItem(title: "New Profile…") { [weak self] in self?.newProfile() })
        if let current = currentProfile, names.count > 1 {
            items.append(DockMenuItem(title: "Delete “\(current)”") { [weak self] in self?.deleteProfile(current) })
        }
        if !profiles.rules.isEmpty {
            items.append(DockMenuItem(title: "-"))
            items.append(DockMenuItem(title: "Switch Automatically", checked: autoProfile) { [weak self] in
                guard let self else { return }
                self.autoProfile.toggle()
                self.model.saveSetting("autoProfile", self.autoProfile)
                if self.autoProfile { self.profiles.start() } else { self.profiles.stop() }
            })
        }
        // Wi-Fi rules need the network name, which macOS only shares with apps allowed to use Location.
        if let current = currentProfile, let ssid = WiFi.ssid,
           !profiles.rules.contains(where: { $0.wifi == ssid && $0.profile == current }) {
            items.append(DockMenuItem(title: "Use “\(current)” on “\(ssid)”") { [weak self] in
                self?.addRule(ProfileRule(profile: current, wifi: ssid))
            })
        }
        return items
    }

    /// Stores the current layout under the current profile, then shows the chosen one.
    func switchProfile(_ name: String) {
        guard name != currentProfile else { return }
        let layout = model.items
        var next: [[String: String]] = layout
        model.updateConfig { json in
            var saved = json["profiles"] as? [String: Any] ?? [:]
            saved[currentProfile ?? "Default"] = layout
            next = saved[name] as? [[String: String]] ?? layout
            saved[name] = next
            json["profiles"] = saved
            json["profile"] = name
            json["items"] = next
        }
        currentProfile = name
        let items = next.map { DockConfig.Item(app: $0["app"], folder: $0["folder"], widget: $0["widget"], size: $0["size"]) }
        for folder in folders() where folder.isOpen { folder.hide() }
        model.pinned = model.entries(for: items)
        for case .folder(let id, let folder) in model.pinned { wire(folder, id: id) }
        model.refreshRunning()
        model.widgetData.kinds = model.presentWidgets
        model.widgetData.active = false
        model.widgetData.active = model.revealed && model.hasWidgets
    }

    func newProfile() {
        let alert = NSAlert()
        alert.messageText = "New profile"
        alert.informativeText = "Starts as a copy of this layout. Switch between profiles from BetterDock ▸ Profile."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Work, Personal, Focus…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let chosen = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty, savedProfiles[chosen] == nil else { return }
        let layout = model.items
        model.updateConfig { json in
            var saved = json["profiles"] as? [String: Any] ?? [:]
            saved[currentProfile ?? "Default"] = layout
            saved[chosen] = layout
            json["profiles"] = saved
            json["profile"] = chosen
        }
        currentProfile = chosen
    }

    func deleteProfile(_ name: String) {
        guard let other = savedProfiles.keys.sorted().first(where: { $0 != name }) else { return }
        switchProfile(other)
        model.updateConfig { json in
            var saved = json["profiles"] as? [String: Any] ?? [:]
            saved[name] = nil
            json["profiles"] = saved
            if var rules = json["profileRules"] as? [[String: Any]] {
                rules.removeAll { $0["profile"] as? String == name }
                json["profileRules"] = rules
            }
        }
        profiles.rules.removeAll { $0.profile == name }
    }

    func addRule(_ rule: ProfileRule) {
        profiles.rules.append(rule)
        let encoded = (try? JSONEncoder().encode(profiles.rules)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        model.updateConfig { $0["profileRules"] = encoded }
        if autoProfile {
            profiles.stop()
            profiles.start()
        }
    }
}
