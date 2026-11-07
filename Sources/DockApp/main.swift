// BetterDock: a replacement Dock with app folders. Apple's Dock stays running but hidden.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window + behaviour

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class DockController: NSObject, NSApplicationDelegate {
    let model: DockModel
    var panel: DockPanel!
    var monitors: [Any] = []
    var hideWork: DispatchWorkItem?
    var menuOpen = false
    let agentWatcher = AgentWatcher()
    let badgeReader = BadgeReader()
    var peekWork: DispatchWorkItem?
    var peekCloseWork: DispatchWorkItem?
    var peekOpened: String?   // folder opened by hovering (closes when the cursor leaves)
    var revealWatch: Any?
    var tileWatch: Any?
    var configWatch: DispatchSourceFileSystemObject?
    var screens: [NSScreen] = NSScreen.screens
    var agentsLoaded = false
    var pendingPulses: [String: AgentState] = [:] // app path -> state that arrived while hidden
    var agentSound: AgentSound
    var agentSounds: [String: String] // AgentEvent raw value -> sound choice
    let profiles = ProfileSwitcher()
    var currentProfile: String?
    var autoProfile: Bool
    var onboarding: OnboardingWindow?
    var preferences: PreferencesWindow?
    var statusItem: NSStatusItem?
    var hotKey: DockHotKey?
    var keyboardMode = false

    init(model: DockModel) {
        self.model = model
        agentSound = AgentSound(rawValue: model.config.agentSound ?? "") ?? .attention
        agentSounds = model.config.agentSounds ?? [:]
        currentProfile = model.config.profile
        autoProfile = model.config.autoProfile ?? true
        profiles.rules = model.config.profileRules ?? []
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = Theme.current.appearance
        panel.contentView = NSHostingView(rootView: DockView(model: model, activate: activate, reorder: reorder,
                                                             dropHandler: { [weak self] in self?.dropHandler($0) }))
        layoutWindow()
        panel.orderFrontRegardless()
        Updater.start()
        installControls()
        if let message = AppNotice.message {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let alert = NSAlert()
                alert.messageText = "BetterDock settings notice"
                alert.informativeText = message
                alert.runModal()
            }
        }
        AppleDock.keepHidden()

        for case .folder(let id, let folder) in model.pinned { wire(folder, id: id) }

        // Widgets only poll while the Dock is on screen.
        revealWatch = model.$revealed.sink { [weak self] revealed in
            guard let self else { return }
            self.model.widgetData.active = revealed && self.model.hasWidgets
            self.badgeReader.visible = revealed
            if revealed {
                self.refreshTrash()
                self.badgeReader.poll()
                self.playPendingPulses()
            }
        }

        agentWatcher.onChange = { [weak self] agents in
            guard let self else { return }
            guard self.model.agents != agents else { return }
            self.announce(from: self.model.agents, to: agents)
            self.model.agents = agents
            for folder in self.model.folders where folder.state.agents != agents { folder.state.agents = agents }
        }
        agentWatcher.start()
        agentsLoaded = true
        watchConfig()
        if !AppSetup.isPreview && (model.config.badges ?? true) {
            badgeReader.onChange = { [weak self] badges in
                guard let self else { return }
                guard self.model.badges != badges else { return }
                self.model.badges = badges
                for folder in self.model.folders where folder.state.badges != badges { folder.state.badges = badges }
            }
            badgeReader.start(prompt: model.config.onboarded == true)
        }
        model.revealed = !model.config.autohide
        panel.ignoresMouseEvents = model.config.autohide

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let path = app.bundleURL?.path {
                    self.model.bouncing.remove(path)
                }
                self.model.refreshRunning()
            }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier {
                self?.agentWatcher.acknowledge(bundle: bundle) // seen it: clear green "done" dots
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = true
            self?.hideWork?.cancel()
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuOpen = false
            self?.mouseMoved()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screens = NSScreen.screens
            self?.layoutWindow()
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            let x = event.locationInWindow.x + self.model.originX
            guard let slot = self.model.slots().first(where: { slot in
                if case .separator = slot.entry { return false }
                return slot.width > 0 && abs(slot.centerX - x) <= (slot.width + self.model.spacing) / 2
            }), let view = self.panel.contentView else { return event }
            NSMenu.popUpContextMenu(MenuBuilder.build(self.menu(slot.entry)), with: event, for: view)
            return nil
        } as Any)
        tileWatch = model.$pinned.combineLatest(model.$extras).dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutWindow() }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.mouseMoved() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in self?.mouseMoved(); return event } as Any)

        profiles.onMatch = { [weak self] name in self?.switchProfile(name) }
        if autoProfile { profiles.start() }
        if !AppSetup.isPreview && model.config.onboarded != true { showOnboarding() }
        if Bundle.main.object(forInfoDictionaryKey: "BDShowPreferences") as? Bool == true { showPreferences() }
    }

    func folders() -> [FolderController] { model.folders }

    /// Saving dock.json in an editor restarts the Dock with the new settings.
    func watchConfig() {
        configWatch?.cancel()
        let fd = open(model.configPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Editors often save by replacing the file; re-arm on the new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let data = FileManager.default.contents(atPath: self.model.configPath)
                if let data, data != self.model.lastWritten {
                    do {
                        _ = try ConfigStore.decode(data)
                        self.applyConfiguration(try self.model.store.recover())
                    } catch {
                        NSLog("BetterDock settings rejected: %@", error.localizedDescription)
                        if let recovered = try? self.model.store.recover() {
                            self.model.lastWritten = FileManager.default.contents(atPath: self.model.configPath)
                            self.applyConfiguration(recovered)
                        } else { AppNotice.message = "Settings were not applied: " + error.localizedDescription }
                        self.updateStatusMenu()
                    }
                }
                self.watchConfig()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatch = source
    }

    func relaunch() {
        // Under the login item, launchd restarts us; otherwise start a fresh copy first.
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != "com.betterdock.app" {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", Bundle.main.bundlePath]
            task.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
            if (try? task.run()) != nil { return }
        }
        NSApp.terminate(nil)
    }

    func wire(_ folder: FolderController, id: String) {
        folder.onClose = { [weak self] in
            if self?.peekOpened == "folder:" + id { self?.peekOpened = nil }
            self?.scheduleHide()
        }
        folder.onChange = { [weak self] in
            self?.model.objectWillChange.send()
            self?.model.refreshRunning()
        }
        folder.onRemoveApp = { [weak self] path in
            guard let self, let app = appEntry(path),
                  let index = self.model.pinned.firstIndex(where: { $0.id == "folder:" + id }) else { return false }
            if !self.model.pinned.contains(where: { $0.id == app.id }) { self.model.pinned.insert(.app(app), at: index + 1) }
            let saved = self.model.saveOrder()
            self.model.refreshRunning()
            return saved
        }
        folder.onDragOutApp = { [weak self] path, point in
            guard let self, let app = appEntry(path) else { return false }
            let others = self.model.slots().filter { self.model.isPinned($0.entry) }
            let index = min(others.filter { $0.centerX < point.x }.count, self.model.pinned.count)
            if !self.model.pinned.contains(where: { $0.id == app.id }) { self.model.pinned.insert(.app(app), at: index) }
            let saved = self.model.saveOrder()
            self.model.refreshRunning()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            return saved
        }
        folder.state.agents = model.agents
        folder.state.badges = model.badges
    }

    func layoutWindow() {
        // Keep the Dock on its display while that display is connected; screen objects are rebuilt on changes.
        model.screen = screens.first { $0.displayID == model.screen.displayID } ?? screenUnderCursor()
        let f = model.screen.frame
        let width = model.windowWidth
        let x = max(f.minX, f.midX - width / 2)
        model.originX = x
        panel.setFrame(NSRect(x: x, y: f.minY, width: width, height: model.windowHeight), display: true)
        model.objectWillChange.send()
    }

    // MARK: Cursor tracking: reveal, magnify, auto-hide

    func mouseMoved() {
        if menuOpen { return }
        let p = NSEvent.mouseLocation
        var screen = model.screen.frame
        if !NSMouseInRect(p, screen, false) {
            // Like Apple's Dock, it moves to another display when the cursor reaches that display's bottom edge.
            guard let other = screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
            if p.y <= other.frame.minY + 1, model.dragID == nil, !folders().contains(where: { $0.isOpen }) {
                move(to: other)
                screen = other.frame
            } else {
                if model.mouseX != nil { model.mouseX = nil }
                if model.revealed && (hideWork?.isCancelled ?? true) { scheduleHide() }
                return
            }
        }
        // Cheapest path: hidden dock, cursor away from the bottom edge, nothing to update.
        if !model.revealed && model.mouseX == nil && p.y > screen.minY + 1 { return }
        let bar = model.baseBarRect()
        let zone = bar.insetBy(dx: -12, dy: 0).union(NSRect(x: bar.minX, y: screen.minY, width: bar.width, height: 1))
        let magnifyZone = NSRect(x: zone.minX, y: screen.minY, width: zone.width, height: bar.maxY - screen.minY + 4)
        let atEdge = p.y <= screen.minY + 1
        let folderOpen = folders().contains { $0.isOpen }

        if !model.revealed && (atEdge || folderOpen) {
            model.revealed = true
        }
        let overDock = model.revealed && NSMouseInRect(p, zone.union(magnifyZone), false)
        let magnifyHeight = bar.maxY + (model.config.magnifiedSize - model.config.iconSize)
        let inMagnify = model.revealed && p.x >= zone.minX && p.x <= zone.maxX && p.y <= magnifyHeight

        let newMouseX = inMagnify ? p.x : nil
        if model.mouseX != newMouseX { model.mouseX = newMouseX }
        updatePeek(p, overDock: inMagnify || overDock)
        let ignore = !(inMagnify || overDock || model.dragID != nil)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }

        if inMagnify || folderOpen || model.dragID != nil || !model.config.autohide || keyboardMode {
            hideWork?.cancel()
        } else if model.revealed {
            scheduleHide()
        }
    }

    /// Hover a folder for a beat and it opens; leave both the tile and the panel and it closes.
    func updatePeek(_ p: NSPoint, overDock: Bool) {
        let hovered = model.slots().first { slot in
            if case .folder = slot.entry { return overDock && abs(slot.centerX - p.x) <= slot.size / 2 } else { return false }
        }
        if let id = peekOpened, case .folder(_, let folder)? = model.pinned.first(where: { $0.id == id }) {
            let overPanel = NSMouseInRect(p, folder.panel.frame.insetBy(dx: 8, dy: 8), false)
            if overPanel || hovered?.entry.id == id {
                peekCloseWork?.cancel()
            } else if peekCloseWork == nil || peekCloseWork!.isCancelled {
                let work = DispatchWorkItem { [weak self] in
                    folder.hide()
                    self?.peekOpened = nil
                }
                peekCloseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
        guard let hovered, model.dragID == nil, case .folder(_, let folder) = hovered.entry, !folder.isOpen else {
            peekWork?.cancel()
            return
        }
        if peekWork == nil || peekWork!.isCancelled {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !folder.isOpen else { return }
                let top = self.model.screen.frame.minY + self.model.bottomMargin + self.model.barHeight + 6
                self.peekOpened = hovered.entry.id
                self.peekCloseWork = nil
                folder.show(anchor: NSPoint(x: hovered.centerX, y: top))
            }
            peekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Moves the Dock to another display, closing anything left open on the old one.
    func move(to screen: NSScreen) {
        for folder in folders() where folder.isOpen { folder.hide() }
        peekWork?.cancel()
        model.mouseX = nil
        model.screen = screen
        if Theme.loadWallpaperTint(for: screen), IconTint.current == .wallpaper { IconRenderer.flush() }
        layoutWindow()
    }

    func scheduleHide() {
        guard model.config.autohide else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.menuOpen, !self.folders().contains(where: { $0.isOpen }) else { return }
            self.model.mouseX = nil
            self.model.revealed = false
            self.panel.ignoresMouseEvents = true
            self.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: Actions

    func activate(_ entry: DockEntry, centerX: CGFloat) {
        switch entry {
        case .app(let app):
            guard FileManager.default.fileExists(atPath: app.id) else {
                AppNotice.report(ConfigStore.Failure("\(app.name) is currently unavailable. Reconnect its drive or restore the app; its Dock pin has been kept."))
                return
            }
            if !model.running.contains(app.id) {
                model.bouncing.insert(app.id)
                hop(app.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.model.bouncing.remove(app.id) }
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true // also restores minimised windows via the reopen event
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        case .folder(_, let folder):
            let top = model.screen.frame.minY + model.bottomMargin + model.barHeight + 6
            peekWork?.cancel()
            if folder.isOpen && peekOpened == entry.id {
                peekOpened = nil // clicked while peeking: keep it open
                peekCloseWork?.cancel()
                return
            }
            if !folder.isOpen { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            folder.toggle(anchor: NSPoint(x: centerX, y: top))
        case .widget(let kind):
            switch kind {
            case .nowPlaying: model.widgetData.control("playpause")
            case .aiUsage: NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            case .timer: model.widgetData.toggleTimer()
            case .clock, .calendar: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            case .weather: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
            case .system, .network: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            case .storage: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
            case .battery: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            case .agents:
                // Jump to the app with the most urgent agent.
                if let path = model.agents.max(by: { $0.value < $1.value })?.key {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
                }
            }
        case .overflow:
            showOverflow()
        case .trash:
            openTrash()
        case .separator:
            break
        }
    }

    func reorder(_ entry: DockEntry, _ phase: DragPhase, _ point: CGPoint) {
        let x = point.x + model.originX
        switch phase {
        case .began:
            peekWork?.cancel()
            if case .app = entry, !model.isPinned(entry) {
                // A running app picked up from the right side joins the pinned apps.
                model.pinned.append(entry)
                model.refreshRunning()
            }
            model.dragID = entry.id
            model.dragX = x
            model.dragY = point.y
        case .changed:
            model.drag(to: x, y: point.y)
        case .ended:
            model.drag(to: x, y: point.y)
            if model.dragOut, case .app = entry {
                removeFromDock(entry, at: point)
            } else if let target = model.dropFolder, case .app(let app) = entry,
                      case .folder(_, let folder)? = model.pinned.first(where: { $0.id == target }) {
                if folder.add(app.id) { model.pinned.removeAll { $0.id == entry.id } }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            model.dragID = nil
            model.dragOut = false
            model.dropFolder = nil
            model.saveOrder()
        }
    }

    func removeFromDock(_ entry: DockEntry, at point: CGPoint) {
        model.pinned.removeAll { $0.id == entry.id }
        let poof = Poof(point: point)
        model.poofs.append(poof)
        NSSound(named: "Pop")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.poofs.removeAll { $0.id == poof.id } }
        model.refreshRunning()
    }

    /// Removes a folder from the Dock. Its apps go back into the Dock where the folder was, so nothing
    /// is lost; a folder with apps in it asks first, an empty one just goes.
    func deleteFolder(_ entry: DockEntry, _ folder: FolderController) {
        let apps = folder.apps
        if !apps.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete “\(folder.config.name)”?"
            alert.informativeText = apps.count == 1
                ? "\(apps[0].name) goes back into the Dock."
                : "Its \(apps.count) apps go back into the Dock."
            alert.addButton(withTitle: "Delete Folder")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        folder.hide()
        guard let index = model.pinned.firstIndex(where: { $0.id == entry.id }) else { return }
        let slot = model.slots().first { $0.entry.id == entry.id }
        let returning = apps.filter { app in !model.pinned.contains { $0.id == app.id } }.map { DockEntry.app($0) }
        model.pinned.replaceSubrange(index...index, with: returning)
        if let slot {
            let poof = Poof(point: CGPoint(x: slot.centerX - model.originX,
                                           y: model.windowHeight - model.bottomMargin - model.barHeight / 2))
            model.poofs.append(poof)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.poofs.removeAll { $0.id == poof.id } }
        }
        NSSound(named: "Pop")?.play()
        guard model.saveOrder() else { return }
        if let path = folder.path, case .folder(let slug, _) = entry, !model.store.referencedElsewhere(slug, current: currentProfile) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               (try? data.write(to: URL(fileURLWithPath: path + ".last-good"), options: .atomic)) != nil {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        model.refreshRunning()
    }

    /// Turns an app tile into a new folder containing it, then asks for a name.
    func newFolder(with app: FolderApp) {
        guard let index = model.pinned.firstIndex(where: { $0.id == app.id }) else { return }
        let slug = "folder-\(UUID().uuidString.lowercased())"
        let path = "\(model.folderDir)/\(slug).json"
        let config = FolderConfig(name: "New Folder", columns: 4, apps: [app.id])
        guard saveConfig(config, to: path) else { return }
        let folder = FolderController(config: config, path: path)
        wire(folder, id: slug)
        model.pinned[index] = .folder(id: slug, folder)
        model.saveOrder()
        model.refreshRunning()
        rename(folder)
    }

    func rename(_ folder: FolderController) {
        let alert = NSAlert()
        alert.messageText = "Folder name"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = folder.config.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            folder.rename(field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Plays launch hops until the app finishes launching (or 6s pass).
    func hop(_ id: String) {
        guard model.bouncing.contains(id) else { return }
        model.bounceTick[id, default: 0] += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in self?.hop(id) }
    }

    func menu(_ entry: DockEntry) -> [DockMenuItem] {
        let own = entryMenu(entry)
        return own + (own.isEmpty ? [] : [DockMenuItem(title: "-")]) + [settingsMenu()]
    }

    /// Everything about the Dock itself lives under one submenu.
    func settingsMenu() -> DockMenuItem {
        let present = Set(model.pinned.compactMap { if case .widget(let k) = $0 { return k } else { return nil } })
        let themes = Theme.allCases.map { theme in
            DockMenuItem(title: theme.title, checked: theme == Theme.current) { [weak self] in self?.setTheme(theme) }
        }
        let icons = IconStyle.allCases.map { style in
            DockMenuItem(title: style.title, checked: style == IconStyle.current) { [weak self] in self?.setIconStyle(style) }
        }
        let tints = IconTint.allCases.map { tint in
            DockMenuItem(title: tint.title, checked: tint == IconTint.current) { [weak self] in self?.setTint(tint) }
        }
        let sizes: [(String, CGFloat)] = [("Small", 44), ("Medium", 52), ("Large", 60)]
        let iconSizes = sizes.map { name, value in
            DockMenuItem(title: name, checked: model.config.iconSize == value) { [weak self] in self?.setLayout(iconSize: value) }
        }
        let factor = model.config.magnifiedSize / model.config.iconSize
        let magnify: [(String, CGFloat)] = [("Off", 1), ("Subtle", 1.3), ("Normal", 1.6), ("Big", 1.9)]
        let magnifications = magnify.map { name, value in
            DockMenuItem(title: name, checked: abs(factor - value) < 0.08) { [weak self] in self?.setLayout(magnification: value) }
        }
        let widgets = WidgetKind.allCases.map { kind in
            DockMenuItem(title: kind.title, checked: present.contains(kind)) { [weak self] in self?.toggleWidget(kind) }
        }
        let sounds = AgentSound.allCases.map { sound in
            DockMenuItem(title: sound.title, checked: sound == agentSound) { [weak self] in
                self?.agentSound = sound
                self?.model.saveSetting("agentSound", sound.rawValue)
            }
        } + [DockMenuItem(title: "-")] + AgentEvent.allCases.map { soundMenu(for: $0) } + [
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Open Sounds Folder") { NSWorkspace.shared.open(SoundLibrary.ensureFolder()) },
        ]
        let configURL = URL(fileURLWithPath: model.configPath)
        return .submenu("BetterDock", [
            DockMenuItem(title: "Settings…") { [weak self] in self?.showPreferences() },
            DockMenuItem(title: "Reveal Dock    ⌃⌥Space") { [weak self] in self?.revealForKeyboard() },
            DockMenuItem(title: "-"),
            .submenu("Profile", profileMenu()),
            DockMenuItem(title: "-"),
            .submenu("Theme", themes),
            .submenu("Icon Style", icons),
            .submenu("Icon Tint", tints),
            .submenu("Icon Size", iconSizes),
            .submenu("Magnification", magnifications),
            DockMenuItem(title: "Hide Automatically", checked: model.config.autohide) { [weak self] in self?.setLayout(autohide: !(self?.model.config.autohide ?? true)) },
            DockMenuItem(title: "-"),
            .submenu("Widgets", widgets),
            .submenu("Agent Sounds", sounds),
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Hide Apple's Dock", checked: AppleDock.hidden) {
                if AppleDock.hidden { AppleDock.confirmRestore() } else { AppleDock.hide() }
            },
            LoginItem.managedByLaunchAgent
                ? DockMenuItem(title: "Open at Login (install.sh)", checked: true, enabled: false)
                : DockMenuItem(title: "Open at Login", checked: LoginItem.enabled) { LoginItem.set(!LoginItem.enabled) },
            DockMenuItem(title: "Setup…") { [weak self] in self?.showOnboarding() },
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Edit Settings…") { NSWorkspace.shared.open(configURL) },
            DockMenuItem(title: "Show Settings in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) },
            DockMenuItem(title: "Check for Updates…") { Updater.checkForUpdates() },
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Quit BetterDock") { [weak self] in self?.quit() },
        ])
    }

    func showOnboarding() {
        if let onboarding {
            onboarding.show()
            return
        }
        let firstRun = model.config.onboarded != true
        let suggestions = FolderSuggestion.scan(excluding: Set(model.folders.flatMap(\.config.apps)))
        let icons = model.pinned.compactMap { entry -> NSImage? in
            if case .app(let app) = entry { return IconRenderer.image(id: app.id, source: app.icon, style: IconStyle.current) }
            return nil
        }
        let state = OnboardingModel(hideDock: firstRun || AppleDock.hidden,
                                    openAtLogin: LoginItem.managedByLaunchAgent || LoginItem.enabled || firstRun,
                                    suggestions: suggestions.map { var s = $0; s.on = firstRun; return s },
                                    wallpaper: wallpaperSlice(for: model.screen), icons: Array(icons.prefix(7)))
        state.onTheme = { [weak self] theme in self?.setTheme(theme) }
        let window = OnboardingWindow(model: state)
        window.onFinish = { [weak self] result in self?.finishOnboarding(result) }
        window.onClose = { [weak self] in
            self?.model.saveSetting("onboarded", true)
            self?.onboarding = nil
        }
        onboarding = window
        window.show()
    }

    func finishOnboarding(_ result: OnboardingModel) {
        if result.hideDock != AppleDock.hidden {
            if result.hideDock { AppleDock.hide() } else { AppleDock.restore() }
        }
        LoginItem.set(result.openAtLogin)
        addFolders(result.suggestions.filter(\.on))
    }

    /// Creates the chosen suggested folders after the pinned apps, taking their apps out of the Dock.
    func addFolders(_ suggestions: [FolderSuggestion]) {
        guard !suggestions.isEmpty else { return }
        let moved = Set(suggestions.flatMap { $0.apps.map(\.id) })
        model.pinned.removeAll { if case .app(let app) = $0 { return moved.contains(app.id) } else { return false } }
        var index = (model.pinned.lastIndex { entry in
            switch entry {
            case .app, .folder: return true
            default: return false
            }
        } ?? -1) + 1
        try? FileManager.default.createDirectory(atPath: model.folderDir, withIntermediateDirectories: true)
        for suggestion in suggestions {
            let base = suggestion.name.lowercased()
            var slug = base
            var n = 2
            while FileManager.default.fileExists(atPath: "\(model.folderDir)/\(slug).json") {
                slug = "\(base)-\(n)"
                n += 1
            }
            let path = "\(model.folderDir)/\(slug).json"
            let config = FolderConfig(name: suggestion.name, columns: 4, apps: suggestion.apps.map(\.id),
                                      color: suggestion.color == .graphite ? nil : suggestion.color.rawValue)
            saveConfig(config, to: path)
            let folder = FolderController(config: config, path: path)
            wire(folder, id: slug)
            model.pinned.insert(.folder(id: slug, folder), at: index)
            index += 1
        }
        model.saveOrder()
        model.refreshRunning()
    }

    /// Quitting while Apple's Dock is hidden would leave the Mac without a Dock, so offer to bring it back.
    func quit() {
        guard AppleDock.hidden else { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = "Bring back Apple's Dock?"
        alert.informativeText = "Apple's Dock is hidden while BetterDock runs. Restore it with your original settings, or keep it hidden for when BetterDock starts again."
        alert.addButton(withTitle: "Restore Apple's Dock")
        alert.addButton(withTitle: "Keep Hidden")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if AppleDock.restore() { NSApp.terminate(nil) }
            else { AppNotice.report(ConfigStore.Failure(AppNotice.message ?? "Could not restore Apple’s Dock.")) }
        case .alertSecondButtonReturn: NSApp.terminate(nil)
        default: break
        }
    }

    // MARK: Trash

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    private let finderQueue = DispatchQueue(label: "finder")

    /// Asks Finder whether the Trash has anything in it (macOS asks once for permission).
    private var trashCheckedAt = Date.distantPast

    func refreshTrash(force: Bool = false) {
        guard force || Date().timeIntervalSince(trashCheckedAt) > 10 else { return }
        trashCheckedAt = Date()
        finderQueue.async { [weak self] in
            let count = Scripts.run("tell application \"Finder\" to count items of trash")?.int32Value ?? 0
            DispatchQueue.main.async {
                if self?.model.trashFull != (count > 0) { self?.model.trashFull = count > 0 }
            }
        }
    }

    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to permanently erase the items in the Trash?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        finderQueue.async { [weak self] in
            _ = Scripts.run("tell application \"Finder\" to empty trash")
            DispatchQueue.main.async {
                NSSound(named: "Purr")?.play()
                self?.refreshTrash(force: true)
            }
        }
    }

    /// Files dropped on the Trash go to the Trash; dropped on an app, they open with it.
    func dropHandler(_ entry: DockEntry) -> (([URL]) -> Void)? {
        switch entry {
        case .trash:
            return { [weak self] urls in
                NSWorkspace.shared.recycle(urls) { _, _ in
                    NSSound(named: "Pop")?.play()
                    self?.refreshTrash(force: true)
                }
            }
        case .app(let app):
            return { urls in
                NSWorkspace.shared.open(urls, withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
            }
        default:
            return nil
        }
    }

    func toggleWidget(_ kind: WidgetKind) {
        if model.pinned.contains(where: { $0.id == "widget:" + kind.rawValue }) {
            model.pinned.removeAll { $0.id == "widget:" + kind.rawValue }
        } else {
            model.pinned.append(.widget(kind))
        }
        widgetsChanged()
    }

    func resizeWidget(_ kind: WidgetKind, _ size: WidgetSize) {
        model.widgetSizes[kind] = size
        model.objectWillChange.send()
        widgetsChanged()
    }

    func widgetsChanged() {
        model.widgetData.kinds = model.presentWidgets
        model.saveOrder()
        model.widgetData.active = false
        model.widgetData.active = model.revealed && model.hasWidgets
    }

    func setTint(_ tint: IconTint) {
        IconTint.current = tint
        model.objectWillChange.send()
        for folder in model.folders { folder.state.objectWillChange.send() }
        model.saveSetting("iconTint", tint.rawValue)
    }

    /// Layout preferences apply in place; changing size never tears down the running Dock.
    func setLayout(iconSize: CGFloat? = nil, magnification: CGFloat? = nil, autohide: Bool? = nil) {
        let icon = iconSize ?? model.config.iconSize
        let factor = magnification ?? model.config.magnifiedSize / model.config.iconSize
        guard model.updateConfig({ json in
            json["iconSize"] = icon
            json["magnifiedSize"] = (icon * factor).rounded()
            if let autohide { json["autohide"] = autohide }
        }) else { return }
        do { applyConfiguration(try model.store.recover()) }
        catch { AppNotice.report(error) }
    }

    func setIconStyle(_ style: IconStyle) {
        IconStyle.current = style
        model.objectWillChange.send()
        for folder in model.folders { folder.state.objectWillChange.send() }
        model.saveSetting("iconStyle", style.rawValue)
    }

    /// Switches theme live and remembers it in dock.json.
    func setTheme(_ theme: Theme) {
        Theme.loadWallpaperTint(for: model.screen)
        IconRenderer.flush()
        Theme.current = theme
        panel.appearance = theme.appearance
        model.objectWillChange.send()
        for folder in model.folders { folder.state.objectWillChange.send() }
        model.saveSetting("theme", theme.rawValue)
    }

    func entryMenu(_ entry: DockEntry) -> [DockMenuItem] {
        switch entry {
        case .app(let app):
            let runningApp = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }
            var items = [
                DockMenuItem(title: runningApp == nil ? "Open" : "Show") { [weak self] in self?.activate(entry, centerX: 0) },
                DockMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) },
            ]
            if let runningApp {
                items += [DockMenuItem(title: "-"),
                          DockMenuItem(title: "Hide") { runningApp.hide() },
                          DockMenuItem(title: "Quit") { runningApp.terminate() }]
            }
            guard model.isPinned(entry) else {
                return items + [DockMenuItem(title: "-"), DockMenuItem(title: "Keep in Dock") { [weak self] in
                    guard let self else { return }
                    self.model.pinned.append(entry)
                    self.model.refreshRunning()
                    self.model.saveOrder()
                }]
            }
            return items + [DockMenuItem(title: "-")] + [
                DockMenuItem(title: "New Folder with \(app.name)") { [weak self] in self?.newFolder(with: app) },
                DockMenuItem(title: "Remove from Dock") { [weak self] in
                    guard let self, let slot = self.model.slots().first(where: { $0.entry.id == entry.id }) else { return }
                    self.removeFromDock(entry, at: CGPoint(x: slot.centerX - self.model.originX,
                                                           y: self.model.windowHeight - self.model.bottomMargin - self.model.barHeight / 2))
                    self.model.saveOrder()
                },
            ]
        case .widget(let kind):
            var items: [DockMenuItem] = [.submenu("Size", WidgetSize.allCases.map { size in
                DockMenuItem(title: size.title, checked: model.size(of: kind) == size) { [weak self] in self?.resizeWidget(kind, size) }
            })]
            if kind == .timer {
                items.append(.submenu("Length", [15, 25, 50].map { minutes in
                    DockMenuItem(title: "\(minutes) minutes", checked: Int(model.widgetData.timerLength / 60) == minutes) { [weak self] in
                        self?.model.widgetData.setTimerLength(minutes)
                        self?.model.saveSetting("timerMinutes", minutes)
                    }
                }))
                items.append(DockMenuItem(title: "Reset Timer") { [weak self] in self?.model.widgetData.resetTimer() })
            }
            if kind == .nowPlaying {
                items.append(DockMenuItem(title: "Next Track") { [weak self] in self?.model.widgetData.control("next track") })
                items.append(DockMenuItem(title: "Previous Track") { [weak self] in self?.model.widgetData.control("previous track") })
            }
            items.append(DockMenuItem(title: "Remove Widget") { [weak self] in
                guard let self else { return }
                self.model.pinned.removeAll { $0.id == entry.id }
                self.widgetsChanged()
            })
            return items
        case .overflow:
            return overflowMenu()
        case .trash:
            return [
                DockMenuItem(title: "Open") { [weak self] in self?.openTrash() },
                DockMenuItem(title: "-"),
                DockMenuItem(title: "Empty Trash…") { [weak self] in self?.emptyTrash() },
            ]
        case .folder(_, let folder):
            let current = FolderColor(named: folder.config.color)
            var items = [
                DockMenuItem(title: "Rename Folder…") { [weak self] in self?.rename(folder) },
                .submenu("Color", FolderColor.allCases.map { color in
                    DockMenuItem(title: color.title, checked: color == current) { folder.setColor(color) }
                }),
            ]
            items += folder.apps.filter { model.running.contains($0.id) }.map { app in
                DockMenuItem(title: "Quit \(app.name)") {
                    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }?.terminate()
                }
            }
            items += [DockMenuItem(title: "-"),
                      DockMenuItem(title: folder.apps.isEmpty ? "Delete Folder" : "Delete Folder…") { [weak self] in
                          self?.deleteFolder(entry, folder)
                      }]
            return items
        case .separator:
            return []
        }
    }
}

// MARK: - Entry


#if BETTERDOCK_TESTS
if CommandLine.arguments.contains("--self-test") {
    NativeTests.run()
    exit(0)
}
#endif
if CommandLine.arguments.contains("--restore-apple-dock") {
    let restored = AppleDock.restore()
    print(restored ? "Apple's Dock restored." : AppNotice.message ?? "Restoration failed; backup kept.")
    exit(restored ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--validate-config"), index + 1 < CommandLine.arguments.count {
    do {
        _ = try ConfigStore.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        print("Configuration is valid.")
        exit(0)
    } catch { fputs("Invalid configuration: \(error.localizedDescription)\n", stderr); exit(1) }
}
AppSetup.seedConfig()
let configStore = ConfigStore(path: AppSetup.configPath)
let dockConfig: DockConfig
do {
    _ = try configStore.recover()
    do { try configStore.isolateProfiles() }
    catch { AppNotice.message = "Profiles could not be separated yet: " + error.localizedDescription + ". Your existing layout has been kept." }
    dockConfig = try configStore.recover()
} catch {
    fputs("BetterDock: could not load settings: \(error.localizedDescription)\n", stderr)
    exit(1)
}
Theme.current = Theme(named: dockConfig.theme)
IconStyle.current = IconStyle(rawValue: dockConfig.iconStyle ?? "default") ?? .standard
IconTint.current = IconTint(rawValue: dockConfig.iconTint ?? "wallpaper") ?? .wallpaper

if let i = CommandLine.arguments.firstIndex(of: "--icon-test"), i + 1 < CommandLine.arguments.count {
    // Renders every app in the Dock and its folders in each icon style, one row per style.
    _ = NSApplication.shared
    if let screen = NSScreen.main { Theme.loadWallpaperTint(for: screen) }
    var paths = dockConfig.items.compactMap(\.app)
    for slug in dockConfig.items.compactMap(\.folder) { paths += loadConfig("\(AppSetup.folderDir)/\(slug).json")?.apps ?? [] }
    paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
    let cell: CGFloat = 76, rows = IconStyle.allCases.count
    let canvas = NSImage(size: NSSize(width: cell * CGFloat(paths.count) + 20, height: cell * CGFloat(rows) + 20))
    canvas.lockFocus()
    NSColor(calibratedRed: 0.17, green: 0.2, blue: 0.3, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    for (r, style) in IconStyle.allCases.enumerated() {
        for (c, path) in paths.enumerated() {
            let icon = IconRenderer.image(id: path, source: NSWorkspace.shared.icon(forFile: path), style: style)
            icon.draw(in: NSRect(x: 10 + CGFloat(c) * cell + 4, y: canvas.size.height - 10 - CGFloat(r + 1) * cell + 4, width: cell - 8, height: cell - 8))
        }
    }
    canvas.unlockFocus()
    let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

if CommandLine.arguments.contains("--bench") {
    // Sweeps a simulated cursor across the Dock and times layout + render per frame.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = DockModel(config: dockConfig, folderDir: AppSetup.folderDir)
    model.agents = ["/Applications/Claude.app": .working]
    let host = NSHostingView(rootView: DockView(model: model, activate: { _, _ in }, reorder: { _, _, _ in }))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: model.windowWidth, height: model.windowHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    model.originX = model.screen.frame.midX - model.windowWidth / 2
    let bar = model.baseBarRect()
    var times: [Double] = []
    for i in 0..<300 {
        model.mouseX = bar.minX + bar.width * CGFloat(i % 150) / 150
        let start = CFAbsoluteTimeGetCurrent()
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
        host.display()
        times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
    let sorted = times.dropFirst(10).sorted()
    print(String(format: "frame ms: median %.2f, p95 %.2f, max %.2f (budget 8.3 at 120 Hz)",
                 sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--setup-preview"), i + 1 < CommandLine.arguments.count {
    // Renders each setup step to <prefix>-1.png … without changing anything.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Snapshot.active = true
    let screen = screenUnderCursor()
    Theme.loadWallpaperTint(for: screen)
    let model = DockModel(config: dockConfig, folderDir: AppSetup.folderDir)
    let icons = model.pinned.compactMap { entry -> NSImage? in
        if case .app(let app) = entry { return IconRenderer.image(id: app.id, source: app.icon, style: IconStyle.current) }
        return nil
    }
    let state = OnboardingModel(hideDock: true, openAtLogin: true,
                                suggestions: FolderSuggestion.scan(excluding: Set(model.folders.flatMap(\.config.apps))),
                                wallpaper: wallpaperSlice(for: screen), icons: Array(icons.prefix(7)))
    let window = OnboardingWindow(model: state)
    window.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.window.orderFrontRegardless()
    for step in 0..<OnboardingModel.steps {
        state.step = step
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let view = window.window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(CommandLine.arguments[i + 1])-\(step + 1).png"))
    }
    exit(0)
}

if CommandLine.arguments.contains("--widget-test") {
    WidgetSelfTest.run()
    exit(0)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot" {
    // Renders the dock over the bottom of your wallpaper with demo agent dots and badges.
    // Usage: --snapshot out.png [glass|graphite|paper|midnight|wallpaper]
    _ = NSApplication.shared
    if CommandLine.arguments.count >= 4 { Theme.current = Theme(named: CommandLine.arguments[3]) }
    let screen = NSScreen.main!
    Theme.loadWallpaperTint(for: screen)
    Snapshot.active = true
    let model = DockModel(config: dockConfig, folderDir: AppSetup.folderDir)
    model.agents = ["/Applications/Claude.app": .working, "/Applications/Google Chrome.app": .done]
    model.badges = ["/Applications/WhatsApp.app": "3", "/Applications/Telegram.app": "12"]
    model.extras = []
    let folderSlot = model.slots().first { if case .folder = $0.entry { return true } else { return false } }
    model.mouseX = folderSlot?.centerX
    let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
    MainActor.assumeIsolated {
        // The first folder is drawn open above its tile, so the panel surface is part of the picture.
        let folder: FolderController? = { if case .folder(_, let f)? = folderSlot?.entry { return f } else { return nil } }()
        folder?.state.open = true
        let panelHeight: CGFloat = folder == nil ? 0 : 300
        let height = model.windowHeight + 60 + panelHeight
        let view = ZStack(alignment: .bottom) {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .frame(width: screen.frame.width, height: height, alignment: .bottom).clipped()
            }
            DockView(model: model, activate: { _, _ in }, reorder: { _, _, _ in })
            if let folder, let folderSlot {
                FolderView(state: folder.state, launch: { _ in }, remove: nil)
                    .fixedSize()
                    .frame(width: screen.frame.width, height: height, alignment: .bottom)
                    .offset(x: folderSlot.centerX - screen.frame.midX, y: -(model.windowHeight - model.bottomMargin - 30))
            }
        }
        .frame(width: model.screen.frame.width, height: height)
        .environment(\.colorScheme, Theme.current.scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        // The renderer can hand back an HDR (PQ) image; flatten it to sRGB so any viewer shows true colours.
        let image = renderer.cgImage!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}
#if BETTERDOCK_TESTS
if CommandLine.arguments.contains("--e2e-test") { NativeTests.runEndToEnd(config: dockConfig); exit(0) }
#endif
Theme.loadWallpaperTint(for: screenUnderCursor())
let dockModel = DockModel(config: dockConfig, folderDir: AppSetup.folderDir)
dockModel.configPath = AppSetup.configPath
let controller = DockController(model: dockModel)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
