// BetterDock: a replacement Dock with app folders. Apple's Dock stays running but hidden.
import AppKit
import SwiftUI

// MARK: - Config

struct DockConfig: Decodable {
    struct Item: Decodable {
        let app: String?
        let folder: String?
    }
    let iconSize: CGFloat
    let magnifiedSize: CGFloat
    let autohide: Bool
    let items: [Item]
    let hidden: [String]? // apps that never get a tile, even while running
    let theme: String?    // glass | ember | wallpaper
    let badges: Bool?     // read unread badges from Apple's Dock (needs Accessibility)
}

enum DockEntry: Identifiable {
    case app(FolderApp)
    case folder(id: String, FolderController)
    case separator(String)

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .folder(let id, _): return "folder:" + id
        case .separator(let id): return "separator:" + id
        }
    }
}

func appEntry(_ path: String) -> FolderApp? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    return FolderApp(id: path, url: URL(fileURLWithPath: path), name: name, icon: NSWorkspace.shared.icon(forFile: path))
}

// MARK: - Model

final class DockModel: ObservableObject {
    let config: DockConfig
    @Published var pinned: [DockEntry]
    @Published var dragID: String?
    @Published var dragX: CGFloat = 0
    @Published var dragY: CGFloat = 0
    @Published var dragOut = false        // dragged up and away: releasing removes the tile
    @Published var dropFolder: String?    // folder the dragged app will drop into
    @Published var poofs: [Poof] = []
    @Published var agents: [String: AgentState] = [:] // app path -> agent status
    @Published var badges: [String: String] = [:]     // app path -> unread label
    var configPath = ""
    let folderDir: String
    @Published var running: Set<String> = []
    @Published var extras: [FolderApp] = []
    @Published var mouseX: CGFloat? // screen x while magnifying
    @Published var revealed = true
    @Published var bouncing: Set<String> = []
    @Published var bounceTick: [String: Int] = [:] // each increment plays one launch hop
    var screen: NSScreen = NSScreen.main!

    let padding: CGFloat = 8
    let spacing: CGFloat = 6
    let separatorWidth: CGFloat = 13
    let bottomMargin: CGFloat = 4

    init(config: DockConfig, folderDir: String) {
        self.config = config
        self.folderDir = folderDir
        var entries: [DockEntry] = []
        for item in config.items {
            if let path = item.app, let app = appEntry(path) {
                entries.append(.app(app))
            } else if let slug = item.folder {
                let path = "\(folderDir)/\(slug).json"
                entries.append(.folder(id: slug, FolderController(config: loadConfig(path), path: path)))
            }
        }
        pinned = entries
        refreshRunning()
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
        case .separator: return nil
        }
    }

    func badge(_ entry: DockEntry) -> String? {
        switch entry {
        case .app(let app): return badges[app.id]
        case .folder(_, let folder): return combinedBadge(folder.config.apps.compactMap { badges[$0] })
        case .separator: return nil
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
        if dropFolder != target?.entry.id { dropFolder = target?.entry.id }
        if target != nil { return }
        let to = others.filter { $0.centerX < x }.count
        if to != from {
            var order = pinned
            order.insert(order.remove(at: from), at: to)
            pinned = order
        }
    }

    func saveSetting(_ key: String, _ value: Any) {
        guard let data = FileManager.default.contents(atPath: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json[key] = value
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Writes the pinned order back to dock.json, keeping every other setting.
    func saveOrder() {
        guard let data = FileManager.default.contents(atPath: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["items"] = pinned.compactMap { entry -> [String: String]? in
            switch entry {
            case .app(let app): return ["app": app.id]
            case .folder(let slug, _): return ["folder": slug]
            case .separator: return nil
            }
        }
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: URL(fileURLWithPath: configPath))
        }
    }

    var entries: [DockEntry] {
        extras.isEmpty ? pinned : pinned + [.separator("running")] + extras.map { .app($0) }
    }

    var barHeight: CGFloat { config.iconSize + padding * 2 }
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
        case .separator: return false
        }
    }

    // MARK: Layout (screen-x coordinates; magnification follows the cursor like Apple's Dock)

    struct Slot { let entry: DockEntry; let centerX: CGFloat; let size: CGFloat }

    func width(of entry: DockEntry) -> CGFloat {
        if dragOut && entry.id == dragID { return 0 } // lifted out: the dock closes the gap
        if case .separator = entry { return separatorWidth }
        return config.iconSize
    }

    /// Total width of tiles plus the gaps between visible ones.
    func span(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(widths.filter { $0 > 0 }.count - 1, 0))
    }

    func scale(at baseCenter: CGFloat) -> CGFloat {
        guard let mouseX, !Motion.reduce else { return 1 }
        let sigma = config.iconSize * 1.4
        let d = baseCenter - mouseX
        let max = config.magnifiedSize / config.iconSize
        return 1 + (max - 1) * exp(-(d * d) / (2 * sigma * sigma))
    }

    func slots() -> [Slot] {
        let list = entries
        let baseWidths = list.map(width)
        var x = screen.frame.midX - span(baseWidths) / 2
        var baseCenters: [CGFloat] = []
        for w in baseWidths { baseCenters.append(x + w / 2); x += w > 0 ? w + spacing : 0 }

        let sizes = zip(list, zip(baseCenters, baseWidths)).map { entry, cw -> CGFloat in
            if cw.1 == 0 { return 0 }
            if case .separator = entry { return separatorWidth }
            return config.iconSize * scale(at: cw.0)
        }
        var cursor = screen.frame.midX - span(sizes) / 2
        var result: [Slot] = []
        for (entry, size) in zip(list, sizes) {
            result.append(Slot(entry: entry, centerX: cursor + size / 2, size: size))
            cursor += size > 0 ? size + spacing : 0
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

// MARK: - Views

struct FolderTileIcon: View {
    let apps: [FolderApp]
    let size: CGFloat

    var body: some View {
        let body = size * 0.84            // macOS icon body sits inside an 84% grid
        let gap = body * 0.07
        let cell = (body - body * 0.17 * 2 - gap * 2) / 3 // 17% inner padding keeps icons off the edges
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .overlay(
                Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        GridRow {
                            ForEach(0..<3, id: \.self) { col in
                                let i = row * 3 + col
                                if i < apps.count {
                                    Image(nsImage: apps[i].icon).resizable().interpolation(.high).frame(width: cell, height: cell)
                                } else {
                                    Color.clear.frame(width: cell, height: cell)
                                }
                            }
                        }
                    }
                }
            )
            .frame(width: body, height: body)
            .frame(width: size, height: size)
    }
}

struct DockView: View {
    @ObservedObject var model: DockModel
    let activate: (DockEntry, CGFloat) -> Void
    let menu: (DockEntry) -> [DockMenuItem]
    let reorder: (DockEntry, DragPhase, CGPoint) -> Void

    var body: some View {
        let slots = model.slots()
        let h = model.windowHeight
        let iconBottom = h - model.bottomMargin - model.padding
        let visible = slots.filter { $0.size > 0 }
        let barLeft = (visible.first?.centerX ?? 0) - (visible.first?.size ?? 0) / 2 - model.padding - model.screen.frame.minX
        let barRight = (visible.last?.centerX ?? 0) + (visible.last?.size ?? 0) / 2 + model.padding - model.screen.frame.minX
        let hovered = slots.first { slot in
            guard let x = model.mouseX else { return false }
            if case .separator = slot.entry { return false }
            return slot.size > 0 && abs(slot.centerX - x) <= (slot.size + model.spacing) / 2
        }

        ZStack(alignment: .topLeading) {
            DockBar()
                .frame(width: max(barRight - barLeft, 0), height: model.barHeight)
                .position(x: (barLeft + barRight) / 2, y: h - model.bottomMargin - model.barHeight / 2)

            ForEach(slots, id: \.entry.id) { slot in
                let dragged = slot.entry.id == model.dragID
                let x = (dragged ? model.dragX : slot.centerX) - model.screen.frame.minX
                switch slot.entry {
                case .separator:
                    Group {
                        if Theme.current == .ember {
                            Circle().fill(Theme.emberRed.opacity(0.8)).frame(width: 5, height: 5)
                        } else {
                            Capsule().fill(.primary.opacity(0.25)).frame(width: 1, height: model.config.iconSize * 0.7)
                        }
                    }
                    .position(x: x, y: iconBottom - model.config.iconSize / 2)
                default:
                    let size = dragged && model.dragOut ? model.config.iconSize : slot.size
                    let dropTarget = slot.entry.id == model.dropFolder
                    DockTile(entry: slot.entry, size: size, running: model.isRunning(slot.entry),
                             bounceTick: model.bounceTick[slot.entry.id, default: 0],
                             agent: model.agentState(slot.entry), badge: model.badge(slot.entry),
                             menu: menu(slot.entry),
                             drag: model.isPinned(slot.entry) ? { phase, point in reorder(slot.entry, phase, point) } : nil) {
                        activate(slot.entry, slot.centerX)
                    }
                        .scaleEffect(dragged ? 1.08 : (dropTarget ? 1.18 : 1))
                        .opacity(dragged && model.dragOut ? 0.6 : 1)
                        .shadow(color: .black.opacity(dragged ? 0.3 : 0), radius: 8, y: 4)
                        .overlay(alignment: .top) {
                            if dragged && model.dragOut {
                                Text("Remove").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(LabelBackground())
                                    .fixedSize()
                                    .offset(y: -26)
                            }
                        }
                        .animation(.spring(duration: 0.25, bounce: 0.2), value: dropTarget)
                        .position(x: x, y: dragged ? model.dragY : iconBottom - size / 2)
                        .zIndex(dragged ? 1 : 0)
                        .transaction { if dragged { $0.animation = nil } } // glued to the cursor
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }

            ForEach(model.poofs) { poof in
                PoofView().position(poof.point)
            }

            if let hovered, model.dragID == nil {
                Text(title(of: hovered.entry))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(LabelBackground())
                    .fixedSize()
                    .position(x: hovered.centerX - model.screen.frame.minX, y: iconBottom - hovered.size - 18)
            }
        }
        .frame(width: model.screen.frame.width, height: h, alignment: .topLeading)
        .offset(y: model.revealed || Motion.reduce ? 0 : model.barHeight + model.bottomMargin + 12)
        .opacity(model.revealed || !Motion.reduce ? 1 : 0)
        .animation(model.revealed ? .spring(duration: 0.3, bounce: 0) : .spring(duration: 0.2, bounce: 0), value: model.revealed)
        .animation(.spring(duration: 0.22, bounce: 0), value: model.mouseX) // fluid tracking; retargets every mouse event
        .animation(Motion.open, value: model.extras.map(\.id))
        .animation(.spring(duration: 0.3, bounce: 0), value: model.pinned.map(\.id))
        .animation(.spring(duration: 0.3, bounce: 0), value: model.dragOut)
        .animation(Motion.open, value: model.agents)
        .animation(Motion.open, value: model.badges)
    }

    func title(of entry: DockEntry) -> String {
        switch entry {
        case .app(let app): return app.name
        case .folder(_, let folder): return folder.config.name
        case .separator: return ""
        }
    }
}

/// Pill behind tooltips; snapshots get a solid fill because the renderer can't draw materials.
struct LabelBackground: View {
    var body: some View {
        if GlassBackground.useMaterial {
            Capsule().fill(Color(white: 0.16).opacity(0.85))
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

struct DockBar: View {
    var body: some View {
        Theme.current.surface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct DockMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

enum DragPhase { case began, changed, ended }

struct DockTile: View {
    let entry: DockEntry
    let size: CGFloat
    let running: Bool
    let bounceTick: Int
    let agent: AgentState?
    let badge: String?
    let menu: [DockMenuItem]
    let drag: ((DragPhase, CGPoint) -> Void)?
    let tap: () -> Void
    @State private var pressed = false
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch entry {
                case .app(let app):
                    Image(nsImage: app.icon).resizable().interpolation(.high)
                case .folder(_, let folder):
                    FolderTileIcon(apps: folder.apps, size: size)
                case .separator:
                    EmptyView()
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                // Unread badge wins over the agent dot; both sit on the top-right corner.
                ZStack(alignment: .topTrailing) {
                    if let badge {
                        UnreadBadge(text: badge, height: max(16, size * 0.3)).offset(x: size * 0.1, y: -size * 0.06)
                    } else if let agent {
                        AgentDot(state: agent, size: max(9, size * 0.2)).offset(x: size * 0.02, y: size * 0.02)
                    }
                }
            }
            .brightness(pressed ? -0.15 : 0)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: bounceTick) { content, lift in
                content.offset(y: -lift)
            } keyframes: { _ in
                // Quick rise, then a spring landing: one hop per tick while the app launches.
                CubicKeyframe(Motion.reduce ? 0 : size * 0.38, duration: 0.24)
                SpringKeyframe(0, duration: 0.42, spring: .init(duration: 0.42, bounce: 0.3))
            }

            Circle()
                .fill(Theme.current.runningDot)
                .frame(width: 4, height: 4)
                .offset(y: 6)
                .opacity(running ? 1 : 0)
                .animation(Motion.hover, value: running)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let moved = hypot(value.translation.width, value.translation.height) > 4
                    if !dragging, moved, let drag {
                        dragging = true
                        pressed = false
                        drag(.began, value.location)
                    }
                    if dragging { drag?(.changed, value.location) } else { pressed = true }
                }
                .onEnded { value in
                    pressed = false
                    if dragging {
                        dragging = false
                        drag?(.ended, value.location)
                    } else if hypot(value.translation.width, value.translation.height) <= 4 {
                        tap()
                    }
                }
        )
        .contextMenu {
            if case .app(let app) = entry {
                AppMenu(app: app, running: running, open: tap)
                if !menu.isEmpty { Divider() }
            }
            ForEach(menu) { item in Button(item.title, action: item.action) }
        }
    }
}

// MARK: - Window + behaviour

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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

    init(model: DockModel) { self.model = model }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DockView(model: model, activate: activate, menu: menu, reorder: reorder))
        layoutWindow()
        panel.orderFrontRegardless()

        for case .folder(let id, let folder) in model.pinned { wire(folder, id: id) }

        agentWatcher.onChange = { [weak self] agents in
            guard let self else { return }
            if self.model.agents != agents { self.model.agents = agents }
            for folder in self.model.folders { folder.state.agents = agents }
        }
        agentWatcher.start()
        if model.config.badges ?? true {
            badgeReader.onChange = { [weak self] badges in
                guard let self else { return }
                self.model.badges = badges
                for folder in self.model.folders { folder.state.badges = badges }
            }
            badgeReader.start()
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
            self?.layoutWindow()
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.mouseMoved() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in self?.mouseMoved(); return event } as Any)
    }

    func folders() -> [FolderController] { model.folders }

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
                  let index = self.model.pinned.firstIndex(where: { $0.id == "folder:" + id }) else { return }
            self.model.pinned.insert(.app(app), at: index + 1)
            self.model.saveOrder()
            self.model.refreshRunning()
        }
        folder.state.agents = model.agents
        folder.state.badges = model.badges
    }

    func layoutWindow() {
        model.screen = NSScreen.main ?? NSScreen.screens[0]
        let f = model.screen.frame
        panel.setFrame(NSRect(x: f.minX, y: f.minY, width: f.width, height: model.windowHeight), display: true)
    }

    // MARK: Cursor tracking: reveal, magnify, auto-hide

    func mouseMoved() {
        if menuOpen { return }
        let p = NSEvent.mouseLocation
        let screen = model.screen.frame
        guard NSMouseInRect(p, screen, false) else { return }
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

        if inMagnify || folderOpen || model.dragID != nil || !model.config.autohide {
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

    func scheduleHide() {
        guard model.config.autohide else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.menuOpen, !self.folders().contains(where: { $0.isOpen }) else { return }
            self.model.mouseX = nil
            self.model.revealed = false
            self.panel.ignoresMouseEvents = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: Actions

    func activate(_ entry: DockEntry, centerX: CGFloat) {
        switch entry {
        case .app(let app):
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
        case .separator:
            break
        }
    }

    func reorder(_ entry: DockEntry, _ phase: DragPhase, _ point: CGPoint) {
        let x = point.x + model.screen.frame.minX
        switch phase {
        case .began:
            peekWork?.cancel()
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
                model.pinned.removeAll { $0.id == entry.id }
                folder.add(app.id)
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

    /// Turns an app tile into a new folder containing it, then asks for a name.
    func newFolder(with app: FolderApp) {
        guard let index = model.pinned.firstIndex(where: { $0.id == app.id }) else { return }
        let slug = "folder-\(Int(Date().timeIntervalSince1970))"
        let path = "\(model.folderDir)/\(slug).json"
        let config = FolderConfig(name: "New Folder", columns: 4, apps: [app.id], labels: nil)
        saveConfig(config, to: path)
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
        entryMenu(entry) + themeMenu()
    }

    func themeMenu() -> [DockMenuItem] {
        [Theme.glass, .wallpaper, .ember].map { theme in
            let mark = theme == Theme.current ? "✓ " : "    "
            return DockMenuItem(title: "\(mark)Theme: \(theme.rawValue.capitalized)") { [weak self] in self?.setTheme(theme) }
        }
    }

    /// Switches theme live and remembers it in dock.json.
    func setTheme(_ theme: Theme) {
        if theme == .wallpaper { Theme.loadWallpaperTint(for: model.screen) }
        Theme.current = theme
        model.objectWillChange.send()
        for folder in model.folders { folder.state.objectWillChange.send() }
        model.saveSetting("theme", theme.rawValue)
    }

    func entryMenu(_ entry: DockEntry) -> [DockMenuItem] {
        switch entry {
        case .app(let app):
            guard model.isPinned(entry) else { return [] } // running-only tiles get the basic app menu
            return [
                DockMenuItem(title: "New Folder with \(app.name)") { [weak self] in self?.newFolder(with: app) },
                DockMenuItem(title: "Remove from Dock") { [weak self] in
                    guard let self, let slot = self.model.slots().first(where: { $0.entry.id == entry.id }) else { return }
                    self.removeFromDock(entry, at: CGPoint(x: slot.centerX - self.model.screen.frame.minX,
                                                           y: self.model.windowHeight - self.model.bottomMargin - self.model.barHeight / 2))
                    self.model.saveOrder()
                },
            ]
        case .folder(_, let folder):
            var items = [DockMenuItem(title: "Rename Folder…") { [weak self] in self?.rename(folder) }]
            items += folder.apps.filter { model.running.contains($0.id) }.map { app in
                DockMenuItem(title: "Quit \(app.name)") {
                    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }?.terminate()
                }
            }
            return items
        case .separator:
            return []
        }
    }
}

// MARK: - Entry

let resources = (Bundle.main.object(forInfoDictionaryKey: "BDConfigDir") as? String) ?? Bundle.main.resourcePath!
let configData = try! Data(contentsOf: URL(fileURLWithPath: "\(resources)/dock.json"))
let dockConfig = try! JSONDecoder().decode(DockConfig.self, from: configData)
Theme.current = Theme(rawValue: dockConfig.theme ?? "glass") ?? .glass

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot" {
    // Renders the dock over the bottom of your wallpaper with demo agent dots and badges.
    // Usage: --snapshot out.png [glass|ember|wallpaper]
    _ = NSApplication.shared
    if CommandLine.arguments.count >= 4 { Theme.current = Theme(rawValue: CommandLine.arguments[3]) ?? .glass }
    let screen = NSScreen.main!
    Theme.loadWallpaperTint(for: screen)
    GlassBackground.useMaterial = true
    let model = DockModel(config: dockConfig, folderDir: "\(resources)/folders")
    model.agents = ["/Applications/Claude.app": .working, "/Applications/Google Chrome.app": .done]
    model.badges = ["/Applications/WhatsApp.app": "3", "/Applications/Telegram.app": "12"]
    model.extras = []
    let slots = model.slots()
    model.mouseX = slots.first { if case .folder = $0.entry { return true } else { return false } }?.centerX
    let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
    MainActor.assumeIsolated {
        let height = model.windowHeight + 60
        let view = ZStack(alignment: .bottom) {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: screen.frame.width, height: screen.frame.height)
                    .frame(width: screen.frame.width, height: height, alignment: .bottom).clipped()
            }
            DockView(model: model, activate: { _, _ in }, menu: { _ in [] }, reorder: { _, _, _ in })
        }
        .frame(width: model.screen.frame.width, height: height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}
if Theme.current == .wallpaper, let screen = NSScreen.main { Theme.loadWallpaperTint(for: screen) }
let dockModel = DockModel(config: dockConfig, folderDir: "\(resources)/folders")
dockModel.configPath = "\(resources)/dock.json"
let controller = DockController(model: dockModel)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
