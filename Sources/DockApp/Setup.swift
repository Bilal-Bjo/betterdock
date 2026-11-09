// Installation-free setup: where settings live, launching at login, and keeping Apple's Dock out of the way.
import AppKit
import ServiceManagement

enum AppSetup {
    /// Shipped builds keep settings in Application Support; developer builds point BDConfigDir at the repo.
    static var isPreview: Bool { (Bundle.main.object(forInfoDictionaryKey: "BDPreview") as? Bool ?? false) || CommandLine.arguments.contains("--preview") || ProcessInfo.processInfo.environment["BETTERDOCK_CONFIG_DIR"] != nil }
    static let configDir: String = {
        if let dir = ProcessInfo.processInfo.environment["BETTERDOCK_CONFIG_DIR"] { return dir }
        if let i = CommandLine.arguments.firstIndex(of: "--config-dir"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] }
        if let dir = Bundle.main.object(forInfoDictionaryKey: "BDConfigDir") as? String { return dir }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterDock").path
    }()

    static var configPath: String { configDir + "/dock.json" }
    static var folderDir: String { configDir + "/folders" }

    /// First launch: start from the examples bundled in the app, or a bare Dock if there are none.
    static func seedConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folderDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: configPath) else { return }
        let examples = Bundle.main.resourceURL?.appendingPathComponent("examples")
        if let examples, fm.fileExists(atPath: examples.appendingPathComponent("dock.json").path) {
            try? fm.copyItem(at: examples.appendingPathComponent("dock.json"), to: URL(fileURLWithPath: configPath))
            let folders = (try? fm.contentsOfDirectory(at: examples.appendingPathComponent("folders"), includingPropertiesForKeys: nil)) ?? []
            for file in folders where file.pathExtension == "json" {
                try? fm.copyItem(at: file, to: URL(fileURLWithPath: folderDir).appendingPathComponent(file.lastPathComponent))
            }
        } else {
            let bare: [String: Any] = ["iconSize": 52, "magnifiedSize": 84, "autohide": true, "theme": "glass",
                                       "items": [["app": "/System/Library/CoreServices/Finder.app"]]]
            try? JSONSerialization.data(withJSONObject: bare, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: URL(fileURLWithPath: configPath))
        }
    }
}

// MARK: - Login item

enum LoginItem {
    /// install.sh's developer flow starts the Dock from its own LaunchAgent.
    static var managedByLaunchAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.betterdock.app"
    }

    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        guard !AppSetup.isPreview, !managedByLaunchAgent, on != enabled else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("BetterDock: login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Apple's Dock

/// Hides Apple's Dock the same way install.sh does: it keeps running (Cmd-Tab, Mission Control, badges)
/// but never appears. The user's own settings are saved first and restored exactly.
enum AppleDock {
    static var backupPath: String { AppSetup.configDir + "/apple-dock-backup.plist" }
    static var hidden: Bool { FileManager.default.fileExists(atPath: backupPath) }

    /// macOS updates, System Settings and other apps sometimes put Apple's Dock settings back.
    /// While it is meant to be hidden, check now and then and hide it again if it drifted.
    static func keepHidden() {
        guard !AppSetup.isPreview else { return }
        check()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in check() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check() }
        }
    }

    private static func check() {
        guard hidden else { return }
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool ?? false
        let delay = (CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) as? NSNumber)?.doubleValue ?? 0
        if !autohide || delay < 999 { hide() }
    }

    /// Turning hiding off asks first: it is one click away from the sounds and widgets menus.
    static func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "Show Apple's Dock again?"
        alert.informativeText = "Apple's Dock comes back with your original settings, next to BetterDock."
        alert.addButton(withTitle: "Show Apple's Dock")
        alert.addButton(withTitle: "Keep Hidden")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, !restore() {
            AppNotice.report(ConfigStore.Failure(AppNotice.message ?? "Could not restore Apple’s Dock."))
        }
    }

    /// The runner is injectable so recovery failures can be tested without touching macOS settings.
    static var runner: (String, [String]) -> Bool = run

    @discardableResult static func hide() -> Bool {
        guard !AppSetup.isPreview else { return false }
        do {
            if !hidden {
                let temporary = backupPath + "." + UUID().uuidString
                guard runner("/usr/bin/defaults", ["export", "com.apple.dock", temporary]),
                      let data = FileManager.default.contents(atPath: temporary),
                      (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else {
                    try? FileManager.default.removeItem(atPath: temporary)
                    throw ConfigStore.Failure("Could not back up Apple's Dock. It has not been hidden.")
                }
                try data.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
                try? FileManager.default.removeItem(atPath: temporary)
            }
            let changes = [["autohide", "-bool", "true"], ["autohide-delay", "-float", "1000"],
                           ["tilesize", "-int", "16"], ["magnification", "-bool", "false"],
                           ["launchanim", "-bool", "false"], ["show-recents", "-bool", "false"]]
            for change in changes {
                guard runner("/usr/bin/defaults", ["write", "com.apple.dock"] + change) else {
                    _ = restore()
                    throw ConfigStore.Failure("Could not hide Apple's Dock. Its backup was preserved if restoration failed.")
                }
            }
            _ = runner("/usr/bin/killall", ["Dock"])
            return true
        } catch { AppNotice.report(error); return false }
    }

    @discardableResult static func restore() -> Bool {
        guard !AppSetup.isPreview else { return false }
        guard hidden else { return true }
        do {
            try restoreBackup(at: backupPath, using: runner)
            return true
        } catch { AppNotice.message = error.localizedDescription; return false }
    }

    static func restoreBackup(at path: String, using runner: (String, [String]) -> Bool) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard runner("/usr/bin/defaults", ["import", "com.apple.dock", path]) else {
            throw ConfigStore.Failure("Apple's Dock could not be restored. The original backup is still at \(path).")
        }
        try data.write(to: URL(fileURLWithPath: path + ".restored"), options: .atomic)
        try FileManager.default.removeItem(atPath: path)
        _ = runner("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }
}
