#if BETTERDOCK_TESTS
import AppKit
import SwiftUI

enum NativeTests {
    static var passed = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) {
        let success: Bool
        do { success = try condition() } catch { fputs("FAIL: \(name): \(error)\n", stderr); exit(1) }
        guard success else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1; print("PASS: \(name)")
    }
    static func pump(_ seconds: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func run() {
        guard AppSetup.isPreview else { fputs("Tests require an isolated preview configuration\n", stderr); exit(1) }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("betterdock-tests-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folders"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ConfigStore(path: root.appendingPathComponent("dock.json").path)
            try store.write(ConfigStore.fallback)
            let initial = try store.recover()
            expect(initial.iconSize == 52, "valid settings load")
            let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
            do { try store.write([:]); expect(false, "invalid settings rejected") } catch { expect(true, "invalid settings rejected") }
            expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == before, "failed save preserves working file")
            try Data("{}".utf8).write(to: URL(fileURLWithPath: store.path))
            expect(try store.recover().iconSize == 52, "schema-invalid startup recovers last working layout")
            expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains(".invalid-") }, "invalid file archived")
            var invalid = ConfigStore.fallback
            invalid["iconSize"] = 0
            do { try store.write(invalid); expect(false, "zero icon size rejected") } catch { expect(true, "zero icon size rejected") }
            invalid = ConfigStore.fallback
            invalid["items"] = [["folder": "../bad"]]
            do { try store.write(invalid); expect(false, "folder traversal rejected") } catch { expect(true, "folder traversal rejected") }
            invalid = ConfigStore.fallback
            invalid["items"] = [["app": "/A.app"], ["app": "/A.app"]]
            do { try store.write(invalid); expect(false, "duplicate tile rejected") } catch { expect(true, "duplicate tile rejected") }
            expect(!ProfileRule(profile: "Work", from: "99:00", to: "18:00").valid, "invalid profile time rejected")
            expect(ProfileRule(profile: "Work", from: "22:00", to: "06:00").valid, "overnight profile time accepted")
            let folder = FolderConfig(name: "Shared", columns: 4, apps: ["/A.app"])
            let bytes = try JSONEncoder().encode(folder)
            try bytes.write(to: root.appendingPathComponent("folders/dev.json"))
            var profiles = ConfigStore.fallback
            profiles["profile"] = "Work"
            profiles["items"] = [["folder": "dev"]]
            profiles["profiles"] = ["Work": [["folder": "dev"]], "Personal": [["folder": "dev"]]]
            try store.write(profiles)
            try store.isolateProfiles()
            let migrated = try store.read()
            let layouts = migrated["profiles"] as! [String: [[String: String]]]
            let personal = layouts["Personal"]![0]["folder"]!
            expect(personal != "dev", "existing profiles get independent folder identities")
            expect(try Data(contentsOf: root.appendingPathComponent("folders/" + personal + ".json")) == bytes, "migration preserves folder contents")
            let copy = try store.cloneLayout([["folder": "dev"]])
            expect(copy[0]["folder"] != "dev", "new profile clones mutable folders")
            let model = DockModel(config: try store.recover(), folderDir: store.folderDir)
            model.configPath = store.path
            model.pinned = [.app(appEntry("/Volumes/Unavailable/Test.app")!)]
            model.saveOrder()
            expect((try store.read()["items"] as? [[String: String]])?.first?["app"] == "/Volumes/Unavailable/Test.app", "unavailable app remains pinned after saving")
            var many = ConfigStore.fallback
            many["items"] = (0..<80).map { ["app": "/Missing/App\($0).app"] }
            try store.write(many)
            let crowded = DockModel(config: try store.recover(), folderDir: store.folderDir)
            expect(!crowded.overflowEntries.isEmpty, "crowded Dock exposes overflow")
            expect(crowded.baseBarRect().width <= crowded.screen.frame.width, "crowded Dock fits the display")
            let widget = WidgetData()
            var finished = 0
            widget.onTimerFinished = { finished += 1 }
            widget.timerLength = 0.05
            widget.toggleTimer()
            pump(0.15)
            expect(widget.timerCompleted && widget.timerEnd == nil && finished == 1, "hidden focus timer completes exactly once")
            widget.toggleTimer(); widget.toggleTimer(); pump(0.1)
            expect(finished == 1 && widget.timerPaused != nil, "paused timer does not complete")
            widget.resetTimer()
            expect(!widget.timerCompleted && widget.timerPaused == nil, "timer reset clears completion and pause")
            var clicked = false
            let menu = MenuBuilder.build([DockMenuItem(title: "Action") { clicked = true }])
            (menu.items[0].target as? MenuAction)?.run()
            expect(clicked, "native menu trailing closure invokes action rather than sound preview")
            let backup = root.appendingPathComponent("dock-backup.plist")
            let plist = try PropertyListSerialization.data(fromPropertyList: ["autohide": false], format: .xml, options: 0)
            try plist.write(to: backup)
            do { try AppleDock.restoreBackup(at: backup.path, using: { _, _ in false }); expect(false, "failed Dock restore rejected") }
            catch { expect(FileManager.default.fileExists(atPath: backup.path), "failed Dock restore retains original backup") }
            var calls: [[String]] = []
            try AppleDock.restoreBackup(at: backup.path, using: { _, args in calls.append(args); return true })
            expect(calls.first?.first == "import" && calls.last?.first == "Dock", "successful Dock restore imports before restarting")
            expect(FileManager.default.fileExists(atPath: backup.path + ".restored"), "successful restore keeps a recovery copy")
            try FileManager.default.createDirectory(at: AgentWatcher.directory, withIntermediateDirectories: true)
            let statusFile = AgentWatcher.directory.appendingPathComponent("fixture.json")
            let epoch = Date().timeIntervalSince1970
            try JSONSerialization.data(withJSONObject: ["state": "working", "bundle": "com.apple.finder", "updated": epoch]).write(to: statusFile)
            let watcher = AgentWatcher()
            var statuses: [String: AgentState] = [:]
            watcher.onChange = { statuses = $0 }
            watcher.now = { Date(timeIntervalSince1970: epoch + 1801) }
            watcher.reload()
            expect(statuses.values.contains(.stale), "abandoned agent becomes stale")
            watcher.now = { Date(timeIntervalSince1970: epoch + 13 * 3600) }
            watcher.reload()
            expect(statuses.isEmpty && !FileManager.default.fileExists(atPath: statusFile.path), "expired agent is removed without a hook event")
            print("\(passed) native regression checks passed")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func runEndToEnd(config: DockConfig) {
        guard AppSetup.isPreview else { fputs("E2E requires --preview and an isolated config directory\n", stderr); exit(1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = DockModel(config: config, folderDir: AppSetup.folderDir)
        model.configPath = AppSetup.configPath
        let controller = DockController(model: model)
        app.delegate = controller
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        pump()
        controller.revealForKeyboard()
        expect(controller.panel.isVisible && model.revealed && controller.panel.canBecomeKey, "E2E keyboard reveal shows native Dock window")
        controller.showPreferences(); pump()
        expect(controller.preferences?.window.isVisible == true, "E2E native settings window opens")
        controller.setLayout(iconSize: 44, magnification: 1.3, autohide: false)
        expect(model.config.iconSize == 44 && model.config.autohide == false, "E2E settings save and apply without restart")
        expect((try? ConfigStore(path: model.configPath).recover().iconSize) == 44, "E2E settings survive disk reload")
        if let folder = model.folders.first {
            folder.show(anchor: NSPoint(x: model.screen.frame.midX, y: model.screen.frame.minY + 80)); pump()
            expect(folder.isOpen && folder.panel.isVisible, "E2E folder native panel opens")
            folder.state.search = "Terminal"; pump()
            expect(folder.state.filteredApps.allSatisfy { $0.name.localizedCaseInsensitiveContains("Terminal") }, "E2E folder search filters apps")
            folder.hide(); pump()
            expect(!folder.panel.isVisible, "E2E folder dismisses")
        }
        let healthy = try! Data(contentsOf: URL(fileURLWithPath: model.configPath))
        try! Data("{}".utf8).write(to: URL(fileURLWithPath: model.configPath), options: .atomic)
        pump(0.6)
        expect((try? ConfigStore.decode(Data(contentsOf: URL(fileURLWithPath: model.configPath))).iconSize) == 44, "E2E invalid external edit recovers without crashing")
        expect(controller.panel.isVisible, "E2E Dock stays available during configuration recovery")
        try! healthy.write(to: URL(fileURLWithPath: model.configPath), options: .atomic)
        pump(0.4)
        let firstOrder = model.items
        if model.pinned.count > 1 {
            model.pinned.swapAt(0, 1); model.saveOrder()
            expect(model.items != firstOrder, "E2E reorder changes layout")
            expect((try? model.store.read()["items"] as? [[String: String]]) == model.items, "E2E reordered layout persists")
        }
        controller.preferences?.window.close()
        controller.panel.orderOut(nil)
        print("\(passed) native integration checks passed")
    }
}
#endif
