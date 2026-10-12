// Live inputs for the dock: agent status files written by Claude Code / Codex hooks, and unread badges.
import AppKit
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

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options) // shows the permission prompt once
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.5
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private func poll() {
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
