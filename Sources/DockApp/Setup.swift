// Installation-free setup: where settings live, launching at login, and keeping Apple's Dock out of the way.
import AppKit
import ServiceManagement

enum AppSetup {
    /// Shipped builds keep settings in Application Support; developer builds point BDConfigDir at the repo.
    static let configDir: String = {
        if let dir = Bundle.main.object(forInfoDictionaryKey: "BDConfigDir") as? String { return dir }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterDock").path
    }()

    static var configPath: String { configDir + "/dock.json" }
    static var folderDir: String { configDir + "/folders" }

    /// First launch: start from the examples bundled in the app, or a bare Dock if there are none.
    static func seedConfig() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configPath) else { return }
        try? fm.createDirectory(atPath: folderDir, withIntermediateDirectories: true)
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
        guard !managedByLaunchAgent, on != enabled else { return }
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
        if alert.runModal() == .alertFirstButtonReturn { restore() }
    }

    static func hide() {
        if !hidden { defaults("export", "com.apple.dock", backupPath) }
        defaults("write", "com.apple.dock", "autohide", "-bool", "true")
        defaults("write", "com.apple.dock", "autohide-delay", "-float", "1000")
        defaults("write", "com.apple.dock", "tilesize", "-int", "16")
        defaults("write", "com.apple.dock", "magnification", "-bool", "false")
        defaults("write", "com.apple.dock", "launchanim", "-bool", "false")
        defaults("write", "com.apple.dock", "show-recents", "-bool", "false")
        restartDock()
    }

    static func restore() {
        if hidden {
            defaults("import", "com.apple.dock", backupPath)
            try? FileManager.default.removeItem(atPath: backupPath)
        } else {
            defaults("delete", "com.apple.dock", "autohide-delay")
        }
        restartDock()
    }

    private static func defaults(_ arguments: String...) {
        run("/usr/bin/defaults", arguments)
    }

    private static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardError = FileHandle.nullDevice
        if (try? task.run()) != nil { task.waitUntilExit() }
    }
}
