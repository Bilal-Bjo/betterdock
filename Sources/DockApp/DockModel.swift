import AppKit
import SwiftUI

enum DockEntry: Identifiable {
    case app(FolderApp)
    case folder(id: String, FolderController)
    case widget(WidgetKind)
    case trash
    case overflow
    case separator(String)

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .folder(let id, _): return "folder:" + id
        case .widget(let kind): return "widget:" + kind.rawValue
        case .trash: return "trash"
        case .overflow: return "overflow"
        case .separator(let id): return "separator:" + id
        }
    }
}

/// The display under the cursor, where the Dock starts.
func screenUnderCursor() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

func appEntry(_ path: String) -> FolderApp? {
    guard path.hasPrefix("/"), path.hasSuffix(".app") else { return nil }
    let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    return FolderApp(id: path, url: URL(fileURLWithPath: path), name: name, icon: NSWorkspace.shared.icon(forFile: path))
}

// MARK: - Model

final class DockModel: ObservableObject {
    var config: DockConfig
    @Published var pinned: [DockEntry] = []
    @Published var dragID: String?
    @Published var dragX: CGFloat = 0
    @Published var dragY: CGFloat = 0
    @Published var dragOut = false        // dragged up and away: releasing removes the tile
    @Published var dropFolder: String?    // folder the dragged app will drop into
    @Published var poofs: [Poof] = []
    @Published var agents: [String: AgentState] = [:] // app path -> agent status
    @Published var badges: [String: String] = [:]     // app path -> unread label
    var configPath = ""
    var unresolvedFolders: [DockConfig.Item] = []
    @Published var keyboardIndex: Int?
    var store: ConfigStore { ConfigStore(path: configPath) }
    let folderDir: String
    let widgetData = WidgetData()
    var widgetSizes: [WidgetKind: WidgetSize] = [:]
    @Published var running: Set<String> = []
    @Published var extras: [FolderApp] = []
    @Published var mouseX: CGFloat? // screen x while magnifying
    @Published var revealed = true
    @Published var bouncing: Set<String> = []
    @Published var bounceTick: [String: Int] = [:] // each increment plays one launch hop
    @Published var wiggleTick: [String: Int] = [:] // a folder wiggles each time an app is dragged over it
    @Published var pulses: [String: AgentState] = [:] // tiles playing a one-shot agent pulse
    var screen: NSScreen = screenUnderCursor()

    let padding: CGFloat = 8
    let spacing: CGFloat = 6
    let separatorWidth: CGFloat = 13
    let bottomMargin: CGFloat = 4

    init(config: DockConfig, folderDir: String) {
        self.config = config
        self.folderDir = folderDir
        pinned = entries(for: config.items)
        widgetData.kinds = presentWidgets
        widgetData.weatherCity = config.weatherCity
        if let minutes = config.timerMinutes { widgetData.setTimerLength(minutes) }
        refreshRunning()
    }

    /// Builds tiles for a layout; folders whose file has gone missing are skipped.
    func entries(for items: [DockConfig.Item]) -> [DockEntry] {
        var entries: [DockEntry] = []
        unresolvedFolders = []
        for item in items {
            if let path = item.app, let app = appEntry(path) {
                entries.append(.app(app))
            } else if let slug = item.folder {
                let path = "\(folderDir)/\(slug).json"
                if let folder = loadConfig(path) { entries.append(.folder(id: slug, FolderController(config: folder, path: path))) }
                else { unresolvedFolders.append(item) }
            } else if let name = item.widget, let kind = WidgetKind(rawValue: name) {
                entries.append(.widget(kind))
                widgetSizes[kind] = WidgetSize(rawValue: item.size ?? "medium") ?? .medium
            }
        }
        return entries
    }

    /// The pinned tiles as dock.json items.
    var items: [[String: String]] {
        let visible: [[String: String]] = pinned.compactMap { entry in
            switch entry {
            case .app(let app): return ["app": app.id]
            case .folder(let slug, _): return ["folder": slug]
            case .widget(let kind): return ["widget": kind.rawValue, "size": size(of: kind).rawValue]
            case .trash, .overflow, .separator: return nil
            }
        }
        return visible + unresolvedFolders.compactMap { $0.folder.map { ["folder": $0] } }
    }

    var folders: [FolderController] {
        pinned.compactMap { if case .folder(_, let f) = $0 { return f } else { return nil } }
    }

    /// Apps living in folders (or hidden) never get their own tile, even while running.
    var foldered: Set<String> {
        Set(folders.flatMap(\.config.apps)).union(config.hidden ?? [])
    }

    func agentState(_ entry: DockEntry) -> AgentState? {
        switch entry {
        case .app(let app): return agents[app.id]
        case .folder(_, let folder): return folder.config.apps.compactMap { agents[$0] }.max()
        case .widget, .trash, .overflow, .separator: return nil
        }
    }

    func badge(_ entry: DockEntry) -> String? {
        switch entry {
        case .app(let app): return badges[app.id]
        case .folder(_, let folder): return combinedBadge(folder.config.apps.compactMap { badges[$0] })
        case .widget, .trash, .overflow, .separator: return nil
        }
    }

    // MARK: Reordering

    func isPinned(_ entry: DockEntry) -> Bool { pinned.contains { $0.id == entry.id } }

    /// Moves the dragged tile to wherever the cursor sits among the other pinned tiles.
    func drag(to x: CGFloat, y: CGFloat) {
        dragX = x
        dragY = y
        guard let dragID, let from = pinned.firstIndex(where: { $0.id == dragID }) else { return }
        // Pulled well above the bar: releasing removes it (apps only).
        let out = y < windowHeight - bottomMargin - barHeight - 46
        let isApp: Bool = { if case .app = pinned[from] { return true } else { return false } }()
        if dragOut != (out && isApp) { dragOut = out && isApp }
        if dragOut { dropFolder = nil; return }
        let others = slots().filter { slot in slot.entry.id != dragID && isPinned(slot.entry) }
        // Hovering an app over the middle of a folder drops it in instead of reordering.
        let target = isApp ? others.first { slot in
            if case .folder = slot.entry { return abs(slot.centerX - x) < slot.size * 0.3 } else { return false }
        } : nil
        if dropFolder != target?.entry.id {
            dropFolder = target?.entry.id
            if let id = dropFolder { wiggleTick[id, default: 0] += 1 }
        }
        if target != nil { return }
        let to = others.filter { $0.centerX < x }.count
        if to != from {
            var order = pinned
            order.insert(order.remove(at: from), at: to)
            pinned = order
        }
    }

    /// Bytes this process last wrote, so the config watcher can ignore our own saves.
    var lastWritten: Data?

    @discardableResult func writeConfig(_ json: [String: Any]) -> Bool {
        do {
            lastWritten = try store.write(json)
            return true
        } catch {
            AppNotice.report(error)
            return false
        }
    }

    func saveSetting(_ key: String, _ value: Any) {
        updateConfig { $0[key] = value }
    }

    @discardableResult func updateConfig(_ change: (inout [String: Any]) -> Void) -> Bool {
        do {
            var json = try store.read()
            change(&json)
            return writeConfig(json)
        } catch { AppNotice.report(error); return false }
    }

    /// Unavailable tiles stay in the persisted layout. Failed writes roll the UI back.
    @discardableResult func saveOrder() -> Bool {
        if updateConfig({ $0["items"] = items }) { return true }
        if let saved = try? store.recover() { pinned = entries(for: saved.items); refreshRunning() }
        return false
    }

    @Published var trashFull = false
    @Published var fileDropTarget: String?
    /// The Dock window only spans the Dock at full magnification, not the whole screen.
    var originX: CGFloat = 0
    var windowWidth: CGFloat {
        let maxScale = min(config.magnifiedSize / config.iconSize, 1 + max(0, screen.frame.width - baseBarRect().width - 20) / max(baseBarRect().width, 1))
        return min(screen.frame.width, baseBarRect().width * maxScale + 240)
    }

    var allEntries: [DockEntry] {
        pinned + (extras.isEmpty ? [] : [.separator("running")]) + extras.map { .app($0) }
    }

    var layoutIconSize: CGFloat {
        let list = allEntries + [.trash]
        let natural = list.reduce(CGFloat(0)) { $0 + naturalWidth($1) }
        let available = max(100, screen.frame.width - 40 - spacing * CGFloat(list.count - 1))
        return max(28, min(config.iconSize, config.iconSize * available / max(natural, 1)))
    }

    func naturalWidth(_ entry: DockEntry) -> CGFloat {
        if case .separator = entry { return separatorWidth }
        if case .widget(let kind) = entry { return config.iconSize * kind.span(size(of: kind)) }
        return config.iconSize
    }

    private func fittedEntries() -> (visible: [DockEntry], hidden: [DockEntry]) {
        let list = allEntries
        let available = screen.frame.width - padding * 2 - 24
        if span((list + [.trash]).map(width)) <= available { return (list + [.trash], []) }
        var visible: [DockEntry] = []
        for entry in list {
            if span((visible + [entry, .overflow, .trash]).map(width)) > available { break }
            visible.append(entry)
        }
        let hidden = Array(list.dropFirst(visible.count)).filter { if case .separator = $0 { return false }; return true }
        if case .separator? = visible.last { visible.removeLast() }
        return (visible + [.overflow, .trash], hidden)
    }

    var entries: [DockEntry] { fittedEntries().visible }
    var overflowEntries: [DockEntry] { fittedEntries().hidden }


    var barHeight: CGFloat { layoutIconSize + padding * 2 }
    var windowHeight: CGFloat { config.magnifiedSize + padding * 2 + bottomMargin + 34 } // room for the name label

    func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let paths = apps.compactMap { $0.bundleURL?.path }
        running = Set(paths)
        let pinnedPaths = Set(pinned.compactMap { if case .app(let a) = $0 { return a.id } else { return nil } })
        extras = paths
            .filter { !pinnedPaths.contains($0) && !foldered.contains($0) }
            .compactMap(appEntry)
    }

    func isRunning(_ entry: DockEntry) -> Bool {
        switch entry {
        case .app(let app): return running.contains(app.id)
        case .folder(_, let folder): return folder.apps.contains { running.contains($0.id) }
        case .widget, .trash, .overflow, .separator: return false
        }
    }

    // MARK: Layout (screen-x coordinates; magnification follows the cursor like Apple's Dock)

    struct Slot {
        let entry: DockEntry
        let centerX: CGFloat
        let size: CGFloat   // height (and width, for square tiles)
        let width: CGFloat
    }

    var hasWidgets: Bool { !presentWidgets.isEmpty }
    var presentWidgets: Set<WidgetKind> { Set(pinned.compactMap { if case .widget(let k) = $0 { return k } else { return nil } }) }
    func size(of kind: WidgetKind) -> WidgetSize { widgetSizes[kind] ?? .medium }

    func width(of entry: DockEntry) -> CGFloat {
        if dragOut && entry.id == dragID { return 0 } // lifted out: the dock closes the gap
        if case .separator = entry { return separatorWidth }
        if case .widget(let kind) = entry {
            let span = kind.span(size(of: kind))
            return layoutIconSize * span + spacing * max(span - 1, 0)
        }
        return layoutIconSize
    }

    /// Total width of tiles plus the gaps between visible ones.
    func span(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(widths.filter { $0 > 0 }.count - 1, 0))
    }

    func scale(at baseCenter: CGFloat) -> CGFloat {
        guard let mouseX, !Motion.reduce else { return 1 }
        let sigma = config.iconSize * 1.4
        let d = baseCenter - mouseX
        let max = min(config.magnifiedSize / config.iconSize, 1 + Swift.max(0, screen.frame.width - baseBarRect().width - 20) / Swift.max(baseBarRect().width, 1))
        return 1 + (max - 1) * exp(-(d * d) / (2 * sigma * sigma))
    }

    func slots() -> [Slot] {
        let list = entries
        let baseWidths = list.map(width)
        var x = screen.frame.midX - span(baseWidths) / 2
        var baseCenters: [CGFloat] = []
        for w in baseWidths { baseCenters.append(x + w / 2); x += w > 0 ? w + spacing : 0 }

        let scales = zip(list, zip(baseCenters, baseWidths)).map { entry, cw -> CGFloat in
            if cw.1 == 0 { return 0 }
            if case .separator = entry { return 1 }
            if case .widget = entry { return 1 + (scale(at: cw.0) - 1) * 0.35 } // widgets swell gently
            return scale(at: cw.0)
        }
        let widths = zip(baseWidths, scales).map { $0 * $1 }
        var cursor = screen.frame.midX - span(widths) / 2
        var result: [Slot] = []
        for (i, entry) in list.enumerated() {
            let w = widths[i]
            let height: CGFloat = { if case .separator = entry { return separatorWidth } else { return layoutIconSize * scales[i] } }()
            result.append(Slot(entry: entry, centerX: cursor + w / 2, size: height, width: w))
            cursor += w > 0 ? w + spacing : 0
        }
        return result
    }

    /// Screen rect of the glass bar at rest (used for hit-testing the cursor).
    func baseBarRect() -> NSRect {
        let list = entries
        let total = span(list.map(width)) + padding * 2
        return NSRect(x: screen.frame.midX - total / 2, y: screen.frame.minY + bottomMargin, width: total, height: barHeight)
    }
}

