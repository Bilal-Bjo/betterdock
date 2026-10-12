// BetterDock: a replacement Dock with app folders. Apple's Dock stays running but hidden.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Config

struct DockConfig: Decodable {
    struct Item: Decodable {
        let app: String?
        let folder: String?
        let widget: String?
        let size: String?
    }
    let iconSize: CGFloat
    let magnifiedSize: CGFloat
    let autohide: Bool
    let items: [Item]
    let hidden: [String]? // apps that never get a tile, even while running
    let theme: String?    // glass | graphite | paper | midnight | wallpaper
    let badges: Bool?     // read unread badges from Apple's Dock (needs Accessibility)
    let iconStyle: String? // default | dark | clear | tinted
    let iconTint: String?  // wallpaper | yellow | blue | pink | green | purple | graphite
}

enum DockEntry: Identifiable {
    case app(FolderApp)
    case folder(id: String, FolderController)
    case widget(WidgetKind)
    case trash
    case separator(String)

    var id: String {
        switch self {
        case .app(let app): return app.id
        case .folder(let id, _): return "folder:" + id
        case .widget(let kind): return "widget:" + kind.rawValue
        case .trash: return "trash"
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
    let widgetData = WidgetData()
    var widgetSizes: [WidgetKind: WidgetSize] = [:]
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
            } else if let name = item.widget, let kind = WidgetKind(rawValue: name) {
                entries.append(.widget(kind))
                widgetSizes[kind] = WidgetSize(rawValue: item.size ?? "medium") ?? .medium
            }
        }
        pinned = entries
        widgetData.kinds = presentWidgets
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
        case .widget, .trash, .separator: return nil
        }
    }

    func badge(_ entry: DockEntry) -> String? {
        switch entry {
        case .app(let app): return badges[app.id]
        case .folder(_, let folder): return combinedBadge(folder.config.apps.compactMap { badges[$0] })
        case .widget, .trash, .separator: return nil
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

    /// Bytes this process last wrote, so the config watcher can ignore our own saves.
    var lastWritten: Data?

    func writeConfig(_ json: [String: Any]) {
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        lastWritten = out
        try? out.write(to: URL(fileURLWithPath: configPath))
    }

    func saveSetting(_ key: String, _ value: Any) {
        guard let data = FileManager.default.contents(atPath: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json[key] = value
        writeConfig(json)
    }

    /// Writes the pinned order back to dock.json, keeping every other setting.
    func saveOrder() {
        guard let data = FileManager.default.contents(atPath: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["items"] = pinned.compactMap { entry -> [String: String]? in
            switch entry {
            case .app(let app): return ["app": app.id]
            case .folder(let slug, _): return ["folder": slug]
            case .widget(let kind): return ["widget": kind.rawValue, "size": size(of: kind).rawValue]
            case .trash, .separator: return nil
            }
        }
        writeConfig(json)
    }

    @Published var trashFull = false
    @Published var fileDropTarget: String?
    /// The Dock window only spans the Dock at full magnification, not the whole screen.
    var originX: CGFloat = 0
    var windowWidth: CGFloat {
        let maxScale = config.magnifiedSize / config.iconSize
        return min(screen.frame.width, baseBarRect().width * maxScale + 240)
    }

    var entries: [DockEntry] {
        pinned + [.separator("running")] + extras.map { .app($0) } + [.trash]
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
        case .widget, .trash, .separator: return false
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
            return config.iconSize * span + spacing * max(span - 1, 0)
        }
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
            let height: CGFloat = { if case .separator = entry { return separatorWidth } else { return config.iconSize * scales[i] } }()
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
                                    StyledIcon(id: apps[i].id, image: apps[i].icon).frame(width: cell, height: cell)
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
    let reorder: (DockEntry, DragPhase, CGPoint) -> Void
    var dropHandler: (DockEntry) -> (([URL]) -> Void)? = { _ in nil }

    var body: some View {
        let slots = model.slots()
        let h = model.windowHeight
        let iconBottom = h - model.bottomMargin - model.padding
        let visible = slots.filter { $0.width > 0 }
        let barLeft = (visible.first?.centerX ?? 0) - (visible.first?.width ?? 0) / 2 - model.padding - model.originX
        let barRight = (visible.last?.centerX ?? 0) + (visible.last?.width ?? 0) / 2 + model.padding - model.originX
        let hovered = slots.first { slot in
            guard let x = model.mouseX else { return false }
            if case .separator = slot.entry { return false }
            return slot.width > 0 && abs(slot.centerX - x) <= (slot.width + model.spacing) / 2
        }

        ZStack(alignment: .topLeading) {
            DockBar()
                .frame(width: max(barRight - barLeft, 0), height: model.barHeight)
                .position(x: (barLeft + barRight) / 2, y: h - model.bottomMargin - model.barHeight / 2)

            ForEach(slots, id: \.entry.id) { slot in
                let dragged = slot.entry.id == model.dragID
                let x = (dragged ? model.dragX : slot.centerX) - model.originX
                switch slot.entry {
                case .separator:
                    Theme.current.separator(height: model.config.iconSize * 0.7)
                        .position(x: x, y: iconBottom - model.config.iconSize / 2)
                default:
                    let size = dragged && model.dragOut ? model.config.iconSize : slot.size
                    let width = dragged && model.dragOut ? model.width(of: slot.entry) : slot.width
                    let dropTarget = slot.entry.id == model.dropFolder
                    DockTile(entry: slot.entry, size: size, width: width, running: model.isRunning(slot.entry),
                             widget: widgetView(slot.entry, height: size, width: width),
                             bounceTick: model.bounceTick[slot.entry.id, default: 0],
                             agent: model.agentState(slot.entry), badge: model.badge(slot.entry),
                             trashFull: model.trashFull,
                             drag: canDrag(slot.entry) ? { phase, point in reorder(slot.entry, phase, point) } : nil) {
                        activate(slot.entry, slot.centerX)
                    }
                        .equatable()
                        .scaleEffect(dragged ? 1.08 : (dropTarget || model.fileDropTarget == slot.entry.id ? 1.15 : 1))
                        .opacity(dragged && model.dragOut ? 0.6 : 1)
                        .shadow(color: .black.opacity(dragged ? 0.3 : 0), radius: 8, y: 4)
                        .overlay(alignment: .top) {
                            if dragged && model.dragOut {
                                Text("Remove").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.current.labelText)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(LabelBackground())
                                    .fixedSize()
                                    .offset(y: -26)
                            }
                        }
                        .animation(.spring(duration: 0.25, bounce: 0.2), value: dropTarget || model.fileDropTarget == slot.entry.id)
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
                    .foregroundStyle(Theme.current.labelText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(LabelBackground())
                    .fixedSize()
                    .position(x: hovered.centerX - model.originX, y: iconBottom - hovered.size - 18)
            }
        }
        .frame(width: model.windowWidth, height: h, alignment: .topLeading)
        .environment(\.onScreen, model.revealed)
        .modifier(FileDrop(model: model, handler: dropHandler))
        .offset(y: model.revealed || Motion.reduce ? 0 : model.barHeight + model.bottomMargin + 12)
        .opacity(model.revealed || !Motion.reduce ? 1 : 0)
        .animation(model.revealed ? .spring(duration: 0.3, bounce: 0) : .spring(duration: 0.2, bounce: 0), value: model.revealed)
        // Magnification follows the cursor directly, like Apple's Dock; only entering and leaving animate.
        .animation(.spring(duration: 0.25, bounce: 0), value: model.mouseX == nil)
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
        case .widget(let kind): return kind == .nowPlaying ? (model.widgetData.track?.title ?? kind.title) : kind.title
        case .trash: return "Trash"
        case .separator: return ""
        }
    }

    /// Pinned tiles reorder; running apps can be dragged in to keep them.
    func canDrag(_ entry: DockEntry) -> Bool {
        if model.isPinned(entry) { return true }
        if case .app = entry { return true }
        return false
    }

    func widgetView(_ entry: DockEntry, height: CGFloat, width: CGFloat) -> AnyView? {
        guard case .widget(let kind) = entry else { return nil }
        return AnyView(WidgetTile(kind: kind, size: model.size(of: kind), height: height, width: width,
                                  data: model.widgetData, agents: model.agents))
    }
}

/// Pill behind tooltips, in the theme's colours.
struct LabelBackground: View {
    var body: some View {
        Capsule().fill(Theme.current.labelFill)
            .overlay(Capsule().strokeBorder(Theme.current.widgetStroke, lineWidth: 0.5))
    }
}

struct DockBar: View {
    var body: some View {
        Theme.current.surface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Snapshots skip the drop target: the image renderer draws it as an unsupported-view placeholder.
struct FileDrop: ViewModifier {
    let model: DockModel
    let handler: (DockEntry) -> (([URL]) -> Void)?

    func body(content: Content) -> some View {
        if Snapshot.active {
            content
        } else {
            content.onDrop(of: [UTType.fileURL], delegate: DockDrop(model: model, handler: handler))
        }
    }
}

/// One drop target for the whole Dock: files go to whatever tile is under the cursor.
struct DockDrop: DropDelegate {
    let model: DockModel
    let handler: (DockEntry) -> (([URL]) -> Void)?

    private func target(_ info: DropInfo) -> DockEntry? {
        let x = info.location.x + model.originX
        return model.slots().first { slot in
            if case .separator = slot.entry { return false }
            return slot.width > 0 && abs(slot.centerX - x) <= (slot.width + model.spacing) / 2 && handler(slot.entry) != nil
        }?.entry
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let id = target(info)?.id
        if model.fileDropTarget != id { model.fileDropTarget = id }
        return DropProposal(operation: id == nil ? .forbidden : (id == "trash" ? .move : .copy))
    }

    func dropExited(info: DropInfo) { model.fileDropTarget = nil }

    func performDrop(info: DropInfo) -> Bool {
        model.fileDropTarget = nil
        guard let entry = target(info), let handle = handler(entry) else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { handle(urls) }
        return true
    }
}

/// Builds a native menu from DockMenuItems at the moment of the click.
enum MenuBuilder {
    static func build(_ list: [DockMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in list {
            if item.title == "-" { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if !item.children.isEmpty {
                entry.submenu = build(item.children)
            } else {
                let action = MenuAction(item.action)
                entry.representedObject = action // keeps the action alive as long as the item
                entry.target = action
                entry.action = #selector(MenuAction.run)
            }
            if item.checked == true { entry.state = .on }
            menu.addItem(entry)
        }
        return menu
    }
}

final class MenuAction: NSObject {
    let run_: () -> Void
    init(_ run: @escaping () -> Void) { run_ = run }
    @objc func run() { run_() }
}

struct DockMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var checked: Bool? = nil
    var children: [DockMenuItem] = []
    var action: () -> Void = {}

    static func submenu(_ title: String, _ children: [DockMenuItem]) -> DockMenuItem {
        DockMenuItem(title: title, children: children)
    }
}

/// One level of menu items: buttons, checkmark toggles, and submenus.
struct DockMenuContent: View {
    let items: [DockMenuItem]

    var body: some View {
        ForEach(items) { item in
            if !item.children.isEmpty {
                Menu(item.title) { DockMenuLeaves(items: item.children) }
            } else {
                DockMenuLeaves(items: [item])
            }
        }
    }
}

struct DockMenuLeaves: View {
    let items: [DockMenuItem]

    var body: some View {
        ForEach(items) { item in
            if !item.children.isEmpty {
                Menu(item.title) {
                    ForEach(item.children) { child in leaf(child) }
                }
            } else {
                leaf(item)
            }
        }
    }

    @ViewBuilder
    func leaf(_ item: DockMenuItem) -> some View {
        if item.title == "-" {
            Divider()
        } else if let checked = item.checked {
            Toggle(item.title, isOn: Binding(get: { checked }, set: { _ in item.action() }))
        } else {
            Button(item.title, action: item.action)
        }
    }
}

enum DragPhase { case began, changed, ended }

struct DockTile: View, Equatable {
    /// Tiles whose size and state did not change skip their body while the cursor moves.
    static func == (a: DockTile, b: DockTile) -> Bool {
        a.entry.id == b.entry.id && a.size == b.size && a.width == b.width && a.running == b.running
            && a.bounceTick == b.bounceTick && a.agent == b.agent && a.badge == b.badge && a.trashFull == b.trashFull
            && a.widget == nil && b.widget == nil && a.folderKey == b.folderKey
    }

    /// Folder tiles redraw when their apps or the icon style change.
    var folderKey: String {
        guard case .folder(_, let folder) = entry else { return "" }
        return folder.config.apps.joined() + IconStyle.current.rawValue + IconTint.current.rawValue
    }

    let entry: DockEntry
    let size: CGFloat
    let width: CGFloat
    let running: Bool
    let widget: AnyView?
    let bounceTick: Int
    let agent: AgentState?
    let badge: String?
    var trashFull = false
    let drag: ((DragPhase, CGPoint) -> Void)?
    let tap: () -> Void
    @State private var pressed = false
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch entry {
                case .app(let app):
                    StyledIcon(id: app.id, image: app.icon)
                case .folder(_, let folder):
                    FolderTileIcon(apps: folder.apps, size: size)
                case .widget:
                    widget
                case .trash:
                    Image(nsImage: NSImage(named: trashFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage())
                        .resizable().interpolation(.high)
                case .separator:
                    EmptyView()
                }
            }
            .frame(width: width, height: size)
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
    var revealWatch: Any?
    var tileWatch: Any?
    var configWatch: DispatchSourceFileSystemObject?

    init(model: DockModel) { self.model = model }

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

        for case .folder(let id, let folder) in model.pinned { wire(folder, id: id) }

        // Widgets only poll while the Dock is on screen.
        revealWatch = model.$revealed.sink { [weak self] revealed in
            guard let self else { return }
            self.model.widgetData.active = revealed && self.model.hasWidgets
            self.badgeReader.visible = revealed
            if revealed {
                self.refreshTrash()
                self.badgeReader.poll()
            }
        }

        agentWatcher.onChange = { [weak self] agents in
            guard let self else { return }
            guard self.model.agents != agents else { return }
            self.model.agents = agents
            for folder in self.model.folders where folder.state.agents != agents { folder.state.agents = agents }
        }
        agentWatcher.start()
        watchConfig()
        if model.config.badges ?? true {
            badgeReader.onChange = { [weak self] badges in
                guard let self else { return }
                guard self.model.badges != badges else { return }
                self.model.badges = badges
                for folder in self.model.folders where folder.state.badges != badges { folder.state.badges = badges }
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
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            let x = NSEvent.mouseLocation.x
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
                if data != nil, data != self.model.lastWritten,
                   (try? JSONSerialization.jsonObject(with: data!)) != nil {
                    self.relaunch()
                } else {
                    self.watchConfig()
                }
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
                  let index = self.model.pinned.firstIndex(where: { $0.id == "folder:" + id }) else { return }
            self.model.pinned.insert(.app(app), at: index + 1)
            self.model.saveOrder()
            self.model.refreshRunning()
        }
        folder.onDragOutApp = { [weak self] path, point in
            guard let self, let app = appEntry(path) else { return }
            let others = self.model.slots().filter { self.model.isPinned($0.entry) }
            let index = min(others.filter { $0.centerX < point.x }.count, self.model.pinned.count)
            self.model.pinned.insert(.app(app), at: index)
            self.model.saveOrder()
            self.model.refreshRunning()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        folder.state.agents = model.agents
        folder.state.badges = model.badges
    }

    func layoutWindow() {
        model.screen = NSScreen.main ?? NSScreen.screens[0]
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
        let configURL = URL(fileURLWithPath: model.configPath)
        return .submenu("BetterDock", [
            .submenu("Theme", themes),
            .submenu("Icon Style", icons),
            .submenu("Icon Tint", tints),
            .submenu("Icon Size", iconSizes),
            .submenu("Magnification", magnifications),
            DockMenuItem(title: "Hide Automatically", checked: model.config.autohide) { [weak self] in self?.setLayout(autohide: !(self?.model.config.autohide ?? true)) },
            DockMenuItem(title: "-"),
            .submenu("Widgets", widgets),
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Edit Settings…") { NSWorkspace.shared.open(configURL) },
            DockMenuItem(title: "Show Settings in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) },
            DockMenuItem(title: "-"),
            DockMenuItem(title: "Quit BetterDock") { NSApp.terminate(nil) },
        ])
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

    /// Size, magnification and auto-hide shape the window, so the Dock restarts to apply them.
    func setLayout(iconSize: CGFloat? = nil, magnification: CGFloat? = nil, autohide: Bool? = nil) {
        let icon = iconSize ?? model.config.iconSize
        let factor = magnification ?? model.config.magnifiedSize / model.config.iconSize
        model.saveSetting("iconSize", icon)
        model.saveSetting("magnifiedSize", (icon * factor).rounded())
        if let autohide { model.saveSetting("autohide", autohide) }
        relaunch()
    }

    func setIconStyle(_ style: IconStyle) {
        IconStyle.current = style
        model.objectWillChange.send()
        for folder in model.folders { folder.state.objectWillChange.send() }
        model.saveSetting("iconStyle", style.rawValue)
    }

    /// Switches theme live and remembers it in dock.json.
    func setTheme(_ theme: Theme) {
        if theme == .wallpaper { Theme.loadWallpaperTint(for: model.screen) }
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
        case .trash:
            return [
                DockMenuItem(title: "Open") { [weak self] in self?.openTrash() },
                DockMenuItem(title: "-"),
                DockMenuItem(title: "Empty Trash…") { [weak self] in self?.emptyTrash() },
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
Theme.current = Theme(named: dockConfig.theme)
IconStyle.current = IconStyle(rawValue: dockConfig.iconStyle ?? "default") ?? .standard
IconTint.current = IconTint(rawValue: dockConfig.iconTint ?? "wallpaper") ?? .wallpaper

if let i = CommandLine.arguments.firstIndex(of: "--icon-test"), i + 1 < CommandLine.arguments.count {
    // Renders every app in the Dock and its folders in each icon style, one row per style.
    _ = NSApplication.shared
    if let screen = NSScreen.main { Theme.loadWallpaperTint(for: screen) }
    var paths = dockConfig.items.compactMap(\.app)
    for slug in dockConfig.items.compactMap(\.folder) { paths += loadConfig("\(resources)/folders/\(slug).json").apps }
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
    let model = DockModel(config: dockConfig, folderDir: "\(resources)/folders")
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
    let model = DockModel(config: dockConfig, folderDir: "\(resources)/folders")
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
if let screen = NSScreen.main { Theme.loadWallpaperTint(for: screen) }
let dockModel = DockModel(config: dockConfig, folderDir: "\(resources)/folders")
dockModel.configPath = "\(resources)/dock.json"
let controller = DockController(model: dockModel)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
