import AppKit
import Carbon
import SwiftUI

/// A registered system shortcut; it does not monitor or record other keystrokes.
final class DockHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<DockHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.action() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: 0x42444F43, id: 1)
        RegisterEventHotKey(49, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

extension DockController {
    func installControls() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "BetterDock")
        item.button?.toolTip = "BetterDock — Control–Option–Space to reveal"
        statusItem = item
        updateStatusMenu()
        if !AppSetup.isPreview { hotKey = DockHotKey { [weak self] in self?.revealForKeyboard() } }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                self.showPreferences(); return nil
            }
            guard event.window === self.panel, self.keyboardMode else { return event }
            let list = self.model.entries
            if event.keyCode == 53 {
                self.keyboardMode = false
                self.model.keyboardIndex = nil
                self.scheduleHide()
                return nil
            }
            if [123, 124].contains(event.keyCode) {
                let direction = event.keyCode == 123 ? -1 : 1
                var next = self.model.keyboardIndex ?? 0
                repeat { next = (next + direction + list.count) % list.count }
                while ({ if case .separator = list[next] { return true }; return false })()
                self.model.keyboardIndex = next
                return nil
            }
            if [36, 49, 125].contains(event.keyCode), let index = self.model.keyboardIndex,
               list.indices.contains(index), let slot = self.model.slots().first(where: { $0.entry.id == list[index].id }) {
                self.activate(list[index], centerX: slot.centerX)
                return nil
            }
            return event
        } as Any)
    }

    func updateStatusMenu() {
        var items = [
            DockMenuItem(title: "Show Dock    ⌃⌥Space") { [weak self] in self?.revealForKeyboard() },
            DockMenuItem(title: "Settings…") { [weak self] in self?.showPreferences() },
        ]
        if let message = AppNotice.message {
            items.append(DockMenuItem(title: "Settings / recovery details…") {
                let alert = NSAlert(); alert.messageText = "BetterDock status"; alert.informativeText = message; alert.runModal()
            })
        }
        items += [DockMenuItem(title: "Show Settings in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: self.model.configPath)]) },
                  DockMenuItem(title: "Restore Apple's Dock") { AppleDock.confirmRestore() },
                  DockMenuItem(title: "Check for Updates…") { Updater.checkForUpdates() },
                  DockMenuItem(title: "-"), DockMenuItem(title: "Quit BetterDock") { [weak self] in self?.quit() }]
        statusItem?.menu = MenuBuilder.build(items)
    }

    func revealForKeyboard() {
        keyboardMode = true
        hideWork?.cancel()
        model.revealed = true
        panel.ignoresMouseEvents = false
        model.keyboardIndex = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func overflowMenu() -> [DockMenuItem] {
        model.overflowEntries.map { entry in
            let title: String
            switch entry {
            case .app(let app): title = app.name
            case .folder(_, let folder): title = folder.config.name + " folder"
            case .widget(let kind): title = kind.title
            default: title = "More"
            }
            return DockMenuItem(title: title) { [weak self] in
                guard let self else { return }
                self.activate(entry, centerX: self.model.screen.frame.midX)
            }
        }
    }

    func showOverflow() {
        let menu = MenuBuilder.build(overflowMenu())
        menu.popUp(positioning: nil, at: NSPoint(x: model.screen.frame.midX, y: model.screen.frame.minY + model.barHeight), in: nil)
    }

    func applyConfiguration(_ config: DockConfig) {
        for folder in folders() where folder.isOpen { folder.hide() }
        model.config = config
        model.pinned = model.entries(for: config.items)
        for case .folder(let id, let folder) in model.pinned { wire(folder, id: id) }
        Theme.current = Theme(named: config.theme)
        IconStyle.current = IconStyle(rawValue: config.iconStyle ?? "default") ?? .standard
        IconTint.current = IconTint(rawValue: config.iconTint ?? "wallpaper") ?? .wallpaper
        IconRenderer.flush()
        model.refreshRunning()
        model.widgetData.kinds = model.presentWidgets
        model.widgetData.weatherCity = config.weatherCity
        if let minutes = config.timerMinutes, model.widgetData.timerLength != Double(minutes * 60) { model.widgetData.setTimerLength(minutes) }
        model.widgetData.active = false
        model.revealed = !config.autohide || keyboardMode
        model.widgetData.active = model.revealed && model.hasWidgets
        panel.appearance = Theme.current.appearance
        profiles.stop()
        profiles.rules = config.profileRules ?? []
        autoProfile = config.autoProfile ?? true
        currentProfile = config.profile
        if autoProfile { profiles.start() }
        layoutWindow()
        updateStatusMenu()
    }

    func showPreferences() {
        if preferences?.window.isVisible != true { preferences = PreferencesWindow(controller: self) }
        preferences?.show()
    }
}

final class PreferencesWindow: NSObject {
    let window: NSWindow
    init(controller: DockController) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "BetterDock Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 500)
        window.contentView = NSHostingView(rootView: PreferencesView(controller: controller))
    }
    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    let controller: DockController
    @ObservedObject var model: DockModel
    @State private var city: String
    @State private var theme: String
    @State private var style: String
    @State private var tint: String
    @State private var iconSize: Double
    @State private var magnification: Double
    @State private var autohide: Bool
    @State private var message = ""
    init(controller: DockController) {
        self.controller = controller
        model = controller.model
        let config = controller.model.config
        _city = State(initialValue: config.weatherCity ?? "")
        _theme = State(initialValue: config.theme ?? "glass")
        _style = State(initialValue: config.iconStyle ?? "default")
        _tint = State(initialValue: config.iconTint ?? "wallpaper")
        _iconSize = State(initialValue: config.iconSize)
        _magnification = State(initialValue: config.magnifiedSize / config.iconSize)
        _autohide = State(initialValue: config.autohide)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) { ForEach(Theme.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                    Picker("Icon style", selection: $style) { ForEach(IconStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                    Picker("Icon tint", selection: $tint) { ForEach(IconTint.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                    Slider(value: $iconSize, in: 32...80, step: 4) { Text("Icon size: \(Int(iconSize))") }
                    Slider(value: $magnification, in: 1...2, step: 0.1) { Text("Magnification: \(magnification, specifier: "%.1f")×") }
                    Toggle("Hide automatically", isOn: $autohide)
                }
                Section("Widgets") {
                    TextField("Weather city", text: $city, prompt: Text("Leave empty to estimate from time zone"))
                    ForEach(WidgetKind.allCases, id: \.rawValue) { kind in
                        Toggle(kind.title, isOn: Binding(get: { model.presentWidgets.contains(kind) }, set: { _ in controller.toggleWidget(kind) }))
                    }
                }
                Section("Profiles & recovery") {
                    Button("Profiles…") { MenuBuilder.build(controller.profileMenu()).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
                    Button("Export settings…", action: exportSettings)
                    Button("Import settings…", action: importSettings)
                    Button("Show settings and backups") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.configPath)]) }
                    Text("Control–Option–Space opens the Dock. Use arrows and Return; Escape dismisses it.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Changes to widgets apply immediately.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply appearance & city", action: apply).keyboardShortcut(.defaultAction)
            }.padding(.horizontal)
        }.padding(.bottom, 16)
    }
    func apply() {
        guard model.updateConfig({ json in
            json["theme"] = theme; json["iconStyle"] = style; json["iconTint"] = tint
            json["iconSize"] = iconSize; json["magnifiedSize"] = (iconSize * magnification).rounded()
            json["autohide"] = autohide; json["weatherCity"] = city.trimmingCharacters(in: .whitespacesAndNewlines)
        }) else { return }
        do { controller.applyConfiguration(try model.store.recover()); message = "Settings saved." }
        catch { AppNotice.report(error) }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "BetterDock-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var package = try model.store.read()
            var folders: [String: Any] = [:]
            for file in (try FileManager.default.contentsOfDirectory(atPath: model.folderDir)) where file.hasSuffix(".json") {
                let data = try Data(contentsOf: URL(fileURLWithPath: model.folderDir + "/" + file))
                folders[file] = try JSONSerialization.jsonObject(with: data)
            }
            package["exportedFolders"] = folders
            try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            message = "Backup exported."
        } catch { AppNotice.report(error) }
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try ConfigStore.decode(data)
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let folders = json.removeValue(forKey: "exportedFolders") as? [String: Any] ?? [:]
            // New IDs keep a failed/partial import from modifying any existing profile's folder files.
            var mapping: [String: String] = [:]
            for (file, object) in folders {
                guard !file.contains("/"), file.hasSuffix(".json") else { throw ConfigStore.Failure("Invalid folder filename in backup.") }
                let bytes = try JSONSerialization.data(withJSONObject: object)
                let folder = try JSONDecoder().decode(FolderConfig.self, from: bytes)
                guard folder.isValid else { throw ConfigStore.Failure("Invalid folder in backup.") }
                let slug = "folder-" + UUID().uuidString.lowercased()
                mapping[String(file.dropLast(5))] = slug
                try bytes.write(to: URL(fileURLWithPath: model.folderDir + "/" + slug + ".json"), options: .atomic)
            }
            func remap(_ layout: [[String: String]]) -> [[String: String]] {
                layout.map { item in var item = item; if let slug = item["folder"], let replacement = mapping[slug] { item["folder"] = replacement }; return item }
            }
            json["items"] = remap(json["items"] as? [[String: String]] ?? [])
            if let profiles = json["profiles"] as? [String: [[String: String]]] { json["profiles"] = profiles.mapValues(remap) }
            _ = try model.store.write(json)
            try model.store.isolateProfiles()
            controller.applyConfiguration(try model.store.recover())
            message = "Settings imported. Previous settings are in dock.json.previous."
        } catch { AppNotice.report(error) }
    }
}
