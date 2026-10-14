// Live inputs for the dock: agent status files written by Claude Code / Codex hooks, and unread badges.
import AppKit
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Agent status

/// Watches ~/Library/Application Support/BetterDock/agents for status files written by
/// hooks/agent-status.sh and maps them to the app hosting each agent (Claude, cmux, Terminal…).
final class AgentWatcher {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BetterDock/agents")

    var onChange: ([String: AgentState]) -> Void = { _ in }
    private var source: DispatchSourceFileSystemObject?
    private var appPaths: [String: String] = [:] // bundle id -> app path

    struct Status: Decodable {
        let state: String
        let bundle: String
        let updated: Double
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        reload()
    }

    private func files() -> [(URL, Status)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
            return (url, status)
        }
    }

    func appPath(for bundle: String) -> String? {
        if let cached = appPaths[bundle] { return cached }
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.path
        appPaths[bundle] = path
        return path
    }

    func reload() {
        var result: [String: AgentState] = [:]
        let now = Date().timeIntervalSince1970
        for (url, status) in files() {
            if now - status.updated > 12 * 3600 { try? FileManager.default.removeItem(at: url); continue } // stale session
            guard let path = appPath(for: status.bundle) else { continue }
            let state: AgentState
            switch status.state {
            case "working": state = .working
            case "attention": state = .attention
            default: state = .done
            }
            result[path] = max(result[path] ?? state, state)
        }
        onChange(result)
    }

    /// Green "done" dots clear once you switch to the app that hosts the agent.
    func acknowledge(bundle: String) {
        for (url, status) in files() where status.bundle == bundle && status.state == "done" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Unread badges

/// Reads unread badges (WhatsApp, Telegram, Mail…) from Apple's hidden Dock through Accessibility.
/// Needs the Accessibility permission; polls every 2s, which costs a handful of cheap AX calls.
final class BadgeReader {
    var onChange: ([String: String]) -> Void = { _ in }
    private var timer: Timer?
    private var last: [String: String] = [:]
    private var polledAt = Date.distantPast
    /// Poll often while the Dock is on screen, rarely while it is hidden.
    var visible = false

    /// The first launch leaves the prompt to onboarding, which explains it first.
    func start(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options) // shows the permission prompt once
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.visible || Date().timeIntervalSince(self.polledAt) > 15 { self.poll() }
        }
        timer?.tolerance = 0.5
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    func poll() {
        polledAt = Date()
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var badges: [String: String] = [:]
        for list in (attribute(root, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for tile in (attribute(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                guard let label = attribute(tile, "AXStatusLabel") as? String, !label.isEmpty,
                      let url = attribute(tile, kAXURLAttribute) else { continue }
                let path = (url as! URL).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                badges["/" + path] = label
            }
        }
        if badges != last {
            last = badges
            onChange(badges)
        }
    }
}

// MARK: - Poof

struct Poof: Identifiable {
    let id = UUID()
    let point: CGPoint // window coordinates
}

/// The classic Dock "poof": a small cloud of puffs that bursts outward and fades.
struct PoofView: View {
    @State private var burst = false

    var body: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let angle = Double(i) / 7 * 2 * .pi
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 18, height: 18)
                    .blur(radius: burst ? 4 : 0.5)
                    .scaleEffect(burst ? 1.5 : 0.5)
                    .offset(x: burst ? cos(angle) * 26 : 0, y: burst ? sin(angle) * 26 : 0)
                    .opacity(burst ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.45)) { burst = true }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Agent signals

/// Which agent events play a sound while the Dock is hidden.
enum AgentSound: String, CaseIterable {
    case attention, all, off

    var title: String {
        switch self {
        case .attention: return "When an Agent Needs You"
        case .all: return "When an Agent Needs You or Finishes"
        case .off: return "Off"
        }
    }

    func plays(_ state: AgentState) -> Bool {
        switch self {
        case .attention: return state == .attention
        case .all: return state != .working
        case .off: return false
        }
    }
}

/// The two moments an agent can make a sound for, each with its own sound.
enum AgentEvent: String, CaseIterable {
    case done, attention

    var menuTitle: String { self == .done ? "Finished Sound" : "Needs You Sound" }
    var defaultSound: String { self == .done ? "Tink" : "Glass" }
}

/// Agent sounds: the sounds that come with macOS, plus any audio file put in the sounds folder
/// next to dock.json. A setting holds either a macOS sound name ("Hero") or a file name ("done.mp3").
enum SoundLibrary {
    static let none = "none"
    static let fileTypes = ["aiff", "aif", "wav", "mp3", "m4a", "caf", "aac"]

    static var folder: URL { URL(fileURLWithPath: AppSetup.configDir).appendingPathComponent("sounds") }

    @discardableResult
    static func ensureFolder() -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var systemSounds: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.map { ($0 as NSString).deletingPathExtension }.sorted()
    }

    static var customSounds: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { fileTypes.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static var cache: [String: NSSound] = [:]

    static func sound(_ choice: String) -> NSSound? {
        if choice == none { return nil }
        if let cached = cache[choice] { return cached }
        let file = choice.hasPrefix("/") ? URL(fileURLWithPath: choice) : folder.appendingPathComponent(choice)
        let loaded = FileManager.default.fileExists(atPath: file.path)
            ? NSSound(contentsOf: file, byReference: true)
            : NSSound(named: choice)
        if let loaded {
            // macOS's own sounds are loud next to a Dock; files someone picked play as recorded.
            loaded.volume = systemSounds.contains(choice) ? 0.35 : 0.8
            cache[choice] = loaded
        }
        return loaded
    }

    static func play(_ choice: String) {
        guard let sound = sound(choice) else { return }
        sound.stop()
        sound.play()
    }

    /// Asks for an audio file, copies it into the sounds folder and returns its name there.
    static func importFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Sound"
        panel.allowedContentTypes = fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        let target = ensureFolder().appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL != target.standardizedFileURL {
            try? FileManager.default.removeItem(at: target)
            do { try FileManager.default.copyItem(at: source, to: target) } catch { return nil }
        }
        cache[target.lastPathComponent] = nil
        return target.lastPathComponent
    }
}

extension DockController {
    func soundChoice(for event: AgentEvent) -> String {
        agentSounds[event.rawValue] ?? event.defaultSound
    }

    func setSound(_ choice: String, for event: AgentEvent) {
        agentSounds[event.rawValue] = choice
        model.saveSetting("agentSounds", agentSounds)
        SoundLibrary.play(choice)
    }

    /// Picking a sound plays it, so the menu doubles as a preview.
    func soundMenu(for event: AgentEvent) -> DockMenuItem {
        let current = soundChoice(for: event)
        let pick = { (choice: String) -> DockMenuItem in
            DockMenuItem(title: (choice as NSString).deletingPathExtension, checked: choice == current) { [weak self] in
                self?.setSound(choice, for: event)
            }
        }
        var items = SoundLibrary.systemSounds.map(pick)
        let custom = SoundLibrary.customSounds
        if !custom.isEmpty { items += [DockMenuItem(title: "-")] + custom.map(pick) }
        items += [
            DockMenuItem(title: "-"),
            DockMenuItem(title: "No Sound", checked: current == SoundLibrary.none) { [weak self] in
                self?.setSound(SoundLibrary.none, for: event)
            },
            DockMenuItem(title: "Choose File…") { [weak self] in
                if let name = SoundLibrary.importFile() { self?.setSound(name, for: event) }
            },
        ]
        return .submenu(event.menuTitle, items)
    }

    /// An agent finished or needs you while the Dock is hidden: a soft sound now, and a pulse on its
    /// tile the next time the Dock shows. Runs only when agent files change.
    func announce(from old: [String: AgentState], to new: [String: AgentState]) {
        guard agentsLoaded, !model.revealed else { return }
        let arrived = new.filter { path, state in state != .working && old[path] != state }
        guard let loudest = arrived.values.max() else { return }
        if agentSound.plays(loudest) { SoundLibrary.play(soundChoice(for: loudest == .attention ? .attention : .done)) }
        for (path, state) in arrived { pendingPulses[path] = max(pendingPulses[path] ?? state, state) }
    }

    func playPendingPulses() {
        guard !pendingPulses.isEmpty else { return }
        var pulses: [String: AgentState] = [:]
        for (path, state) in pendingPulses where model.agents[path] == state {
            let tile = model.entries.first { entry in
                switch entry {
                case .app(let app): return app.id == path
                case .folder(_, let folder): return folder.config.apps.contains(path)
                default: return false
                }
            }
            if let id = tile?.id { pulses[id] = max(pulses[id] ?? state, state) }
        }
        pendingPulses = [:]
        guard !pulses.isEmpty else { return }
        // Start once the Dock has slid in, and drop the rings when they finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.model.pulses = pulses
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self?.model.pulses = [:] }
        }
    }
}
