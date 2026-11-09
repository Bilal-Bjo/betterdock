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
    var config: DockConfig { didSet { invalidateLayout() } }
    @Published var pinned: [DockEntry] = [] { didSet { invalidateLayout() } }
    @Published var dragID: String? { didSet { if oldValue != dragID { invalidateLayout() } } }
    @Published var dragX: CGFloat = 0
    @Published var dragY: CGFloat = 0
    @Published var dragOut = false { didSet { if oldValue != dragOut { invalidateLayout() } } }        // dragged up and away: releasing removes the tile
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
    var widgetSizes: [WidgetKind: WidgetSize] = [:] { didSet { invalidateLayout() } }
    @Published var running: Set<String> = []
    @Published var extras: [FolderApp] = [] { didSet { invalidateLayout() } }
    @Published var mouseX: CGFloat? // screen x while magnifying
    @Published var revealed = true
    @Published var bouncing: Set<String> = []
    @Published var bounceTick: [String: Int] = [:] // each increment plays one launch hop
    @Published var wiggleTick: [String: Int] = [:] // a folder wiggles each time an app is dragged over it
    @Published var pulses: [String: AgentState] = [:] // tiles playing a one-shot agent pulse
    var screen: NSScreen = screenUnderCursor() { didSet { invalidateLayout() } }

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
    /// Geometry depends on layout changes, never cursor movement. Build it once per revision.
    private struct Geometry {
        let entries: [DockEntry]
        let overflow: [DockEntry]
        let iconSize: CGFloat
        let widths: [CGFloat]
        let centers: [CGFloat]
        let bar: NSRect
        let scaleLimit: CGFloat
        let windowWidth: CGFloat
    }
    private var cachedGeometry: Geometry?
    private var cachedSlots: (mouseX: CGFloat?, reducedMotion: Bool, values: [Slot])?

    private func invalidateLayout() {
        cachedGeometry = nil
        cachedSlots = nil
    }

    private var geometry: Geometry {
        if let cachedGeometry { return cachedGeometry }
        let list = allEntries
        let all = list + [.trash]
        let natural = all.reduce(CGFloat(0)) { total, entry in
            if case .separator = entry { return total + separatorWidth }
            if case .widget(let kind) = entry { return total + config.iconSize * kind.span(size(of: kind)) }
            return total + config.iconSize
        }
        let available = max(100, screen.frame.width - 40 - spacing * CGFloat(all.count - 1))
        let iconSize = max(28, min(config.iconSize, config.iconSize * available / max(natural, 1)))
        let allWidths = all.map { width(of: $0, iconSize: iconSize) }
        let budget = screen.frame.width - padding * 2 - 24
        var visible = all
        var overflow: [DockEntry] = []
        if span(allWidths) > budget {
            let reserve = width(of: .overflow, iconSize: iconSize) + width(of: .trash, iconSize: iconSize)
            var sum: CGFloat = 0
            var count = 0
            var included = 0
            for index in list.indices {
                let w = allWidths[index]
                let nextCount = count + (w > 0 ? 1 : 0)
                if sum + w + reserve + spacing * CGFloat(nextCount + 1) > budget { break }
                sum += w
                count = nextCount
                included += 1
            }
            visible = Array(list.prefix(included))
            overflow = list.dropFirst(included).filter { if case .separator = $0 { return false }; return true }
            if case .separator? = visible.last { visible.removeLast() }
            visible += [.overflow, .trash]
        }
        let widths = visible.map { width(of: $0, iconSize: iconSize) }
        let tileSpan = span(widths)
        var x = screen.frame.midX - tileSpan / 2
        let centers = widths.map { w -> CGFloat in
            let center = x + w / 2
            x += w > 0 ? w + spacing : 0
            return center
        }
        let total = tileSpan + padding * 2
        let bar = NSRect(x: screen.frame.midX - total / 2, y: screen.frame.minY + bottomMargin,
                         width: total, height: iconSize + padding * 2)
        let limit = min(config.magnifiedSize / config.iconSize, 1 + max(0, screen.frame.width - total - 20) / max(total, 1))
        let result = Geometry(entries: visible, overflow: overflow, iconSize: iconSize, widths: widths,
                              centers: centers, bar: bar, scaleLimit: limit,
                              windowWidth: min(screen.frame.width, total * limit + 240))
        cachedGeometry = result
        return result
    }

    var windowWidth: CGFloat { geometry.windowWidth }
    var allEntries: [DockEntry] {
        pinned + (extras.isEmpty ? [] : [.separator("running")]) + extras.map { .app($0) }
    }
    var layoutIconSize: CGFloat { geometry.iconSize }
    var entries: [DockEntry] { geometry.entries }
    var overflowEntries: [DockEntry] { geometry.overflow }
    var barHeight: CGFloat { geometry.bar.height }
    var windowHeight: CGFloat { config.magnifiedSize + padding * 2 + bottomMargin + 34 }

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

    private func width(of entry: DockEntry, iconSize: CGFloat) -> CGFloat {
        if dragOut && entry.id == dragID { return 0 }
        if case .separator = entry { return separatorWidth }
        if case .widget(let kind) = entry {
            let units = kind.span(size(of: kind))
            return iconSize * units + spacing * max(units - 1, 0)
        }
        return iconSize
    }

    func width(of entry: DockEntry) -> CGFloat { width(of: entry, iconSize: geometry.iconSize) }

    func span(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(widths.filter { $0 > 0 }.count - 1, 0))
    }

    func scale(at baseCenter: CGFloat) -> CGFloat {
        guard let mouseX, !Motion.reduce else { return 1 }
        let d = baseCenter - mouseX
        let sigma = config.iconSize * 1.4
        return 1 + (geometry.scaleLimit - 1) * exp(-(d * d) / (2 * sigma * sigma))
    }

    /// Hit testing and SwiftUI share the same O(n) cursor layout rather than rebuilding it per tile.
    func slots() -> [Slot] {
        let reducedMotion = Motion.reduce
        if let cachedSlots, cachedSlots.mouseX == mouseX, cachedSlots.reducedMotion == reducedMotion { return cachedSlots.values }
        let base = geometry
        let sigma = config.iconSize * 1.4
        let denominator = 2 * sigma * sigma
        var scales: [CGFloat] = []
        var widths: [CGFloat] = []
        scales.reserveCapacity(base.entries.count)
        widths.reserveCapacity(base.entries.count)
        for index in base.entries.indices {
            let entry = base.entries[index]
            var scale: CGFloat = 1
            if base.widths[index] == 0 { scale = 0 }
            else if let mouseX, !reducedMotion {
                let distance = base.centers[index] - mouseX
                let swell = (base.scaleLimit - 1) * exp(-(distance * distance) / denominator)
                switch entry {
                case .separator: break
                case .widget: scale += swell * 0.35
                default: scale += swell
                }
            }
            scales.append(scale)
            widths.append(base.widths[index] * scale)
        }
        var cursor = screen.frame.midX - span(widths) / 2
        var result: [Slot] = []
        result.reserveCapacity(base.entries.count)
        for index in base.entries.indices {
            let entry = base.entries[index]
            let w = widths[index]
            let height: CGFloat
            if case .separator = entry { height = separatorWidth } else { height = base.iconSize * scales[index] }
            result.append(Slot(entry: entry, centerX: cursor + w / 2, size: height, width: w))
            cursor += w > 0 ? w + spacing : 0
        }
        cachedSlots = (mouseX, reducedMotion, result)
        return result
    }

    func baseBarRect() -> NSRect { geometry.bar }
}
