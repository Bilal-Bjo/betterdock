import AppKit

// Software updates through Sparkle 2.
//
// Release builds (release/build-release.sh) compile with `-F packaging/vendor/... -framework Sparkle`
// and embed Sparkle.framework, so `canImport(Sparkle)` is true and updates are live. The developer
// build from install.sh has no Sparkle, so the same calls fall back to opening the releases page.
//
// Wiring, in main.swift:
//   applicationDidFinishLaunching:  Updater.start()
//   BetterDock menu:                DockMenuItem(title: "Check for Updates…") { Updater.checkForUpdates() }

#if canImport(Sparkle)
import Sparkle

enum Updater {
    @MainActor private static var controller: SPUStandardUpdaterController?
    @MainActor private static let driverDelegate = UpdaterDriverDelegate()

    /// Starts Sparkle's scheduled checks. Does nothing if the bundle has no feed or public key.
    @MainActor static func start() {
        guard controller == nil, isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: driverDelegate)
    }

    /// Menu action. Safe to call from any closure on the main thread.
    static func checkForUpdates() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let controller else { return openReleasesPage() }
                // BetterDock is an accessory app; bring Sparkle's window to the front.
                NSApp.activate(ignoringOtherApps: true)
                controller.checkForUpdates(nil)
            }
        }
    }

    private static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }
}

/// BetterDock has no Dock icon or menu bar, so scheduled update alerts are shown immediately and the
/// app is activated first; otherwise Sparkle's window could open behind other apps.
final class UpdaterDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

#else

enum Updater {
    static func start() {}

    static func checkForUpdates() { openReleasesPage() }
}

#endif

private func openReleasesPage() {
    NSWorkspace.shared.open(URL(string: "https://github.com/Bilal-Bjo/betterdock/releases/latest")!)
}
