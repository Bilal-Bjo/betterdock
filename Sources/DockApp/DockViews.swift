import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Views

struct FolderTileIcon: View {
    let apps: [FolderApp]
    let size: CGFloat
    var color: FolderColor = .graphite

    var body: some View {
        let body = size * 0.84            // macOS icon body sits inside an 84% grid
        let gap = body * 0.07
        let cell = (body - body * 0.17 * 2 - gap * 2) / 3 // 17% inner padding keeps icons off the edges
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: color.gradient, startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
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
                             wiggleTick: model.wiggleTick[slot.entry.id, default: 0],
                             pulse: model.pulses[slot.entry.id],
                             agent: model.agentState(slot.entry), badge: model.badge(slot.entry),
                             trashFull: model.trashFull,
                             renderingKey: renderingKey(slot.entry),
                             drag: canDrag(slot.entry) ? { phase, point in reorder(slot.entry, phase, point) } : nil) {
                        activate(slot.entry, slot.centerX)
                    }
                        .equatable()
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: keyboardSelected(slot.entry.id) ? 2 : 0))
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

    func keyboardSelected(_ id: String) -> Bool {
        guard let index = model.keyboardIndex, model.entries.indices.contains(index) else { return false }
        return model.entries[index].id == id
    }

    func renderingKey(_ entry: DockEntry) -> String {
        var key = Theme.current.rawValue + IconStyle.current.rawValue + IconTint.current.rawValue + String(Theme.wallpaperTint.hashValue)
        if case .folder(_, let folder) = entry {
            key += folder.config.apps.joined(separator: "|") + (folder.config.color ?? "")
        }
        return key
    }

    func title(of entry: DockEntry) -> String {
        switch entry {
        case .app(let app): return app.name
        case .folder(_, let folder): return folder.config.name
        case .widget(let kind): return kind == .nowPlaying ? (model.widgetData.track?.title ?? kind.title) : kind.title
        case .trash: return "Trash"
        case .overflow: return "More apps"
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
                action.preview = item.preview
                entry.representedObject = action // keeps the action alive as long as the item
                entry.target = action
                entry.action = #selector(MenuAction.run)
            }
            if item.checked == true { entry.state = .on }
            entry.isEnabled = item.enabled
            menu.addItem(entry)
        }
        if list.contains(where: { $0.preview != nil }) {
            let delegate = PreviewDelegate()
            menu.delegate = delegate
            objc_setAssociatedObject(menu, &PreviewDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        }
        return menu
    }
}

/// Runs an item's preview a moment after it is highlighted, so skimming down a menu stays quiet.
final class PreviewDelegate: NSObject, NSMenuDelegate {
    static var key = 0
    private var pending: DispatchWorkItem?

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        pending?.cancel()
        guard let preview = (item?.representedObject as? MenuAction)?.preview else { return }
        let work = DispatchWorkItem(block: preview)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func menuDidClose(_ menu: NSMenu) { pending?.cancel() }
}

final class MenuAction: NSObject {
    let run_: () -> Void
    var preview: (() -> Void)?
    init(_ run: @escaping () -> Void) { run_ = run }
    @objc func run() { run_() }
}

struct DockMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var checked: Bool? = nil
    var enabled = true
    var children: [DockMenuItem] = []
    var preview: (() -> Void)? = nil // runs when the item is highlighted in a native menu
    var action: () -> Void = {}

    init(title: String, checked: Bool? = nil, enabled: Bool = true, children: [DockMenuItem] = [], action: @escaping () -> Void = {}) {
        self.title = title; self.checked = checked; self.enabled = enabled; self.children = children; self.action = action
    }

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

/// A quick shake that says "drop it here"; the swell comes from the drop-target scale.
/// Only folder tiles carry the animator, so app tiles stay as cheap as before.
struct Wiggle: ViewModifier {
    let tick: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled && !Motion.reduce {
            content.keyframeAnimator(initialValue: 0.0, trigger: tick) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                CubicKeyframe(-7, duration: 0.07)
                CubicKeyframe(6, duration: 0.1)
                CubicKeyframe(-3, duration: 0.09)
                SpringKeyframe(0, duration: 0.28, spring: .init(duration: 0.28, bounce: 0.35))
            }
        } else {
            content
        }
    }
}

struct DockTile: View, Equatable {
    /// Tiles whose size and state did not change skip their body while the cursor moves.
    static func == (a: DockTile, b: DockTile) -> Bool {
        a.entry.id == b.entry.id && a.size == b.size && a.width == b.width && a.running == b.running
            && a.bounceTick == b.bounceTick && a.wiggleTick == b.wiggleTick && a.pulse == b.pulse && a.agent == b.agent && a.badge == b.badge && a.trashFull == b.trashFull
            && a.widget == nil && b.widget == nil && a.renderingKey == b.renderingKey
    }

    let entry: DockEntry
    let size: CGFloat
    let width: CGFloat
    let running: Bool
    let widget: AnyView?
    let bounceTick: Int
    let wiggleTick: Int
    let pulse: AgentState?
    let agent: AgentState?
    let badge: String?
    var trashFull = false
    let renderingKey: String
    let drag: ((DragPhase, CGPoint) -> Void)?
    private var isFolder: Bool { if case .folder = entry { return true } else { return false } }
    let tap: () -> Void
    @State private var pressed = false
    @State private var dragging = false

    var accessibleName: String {
        switch entry {
        case .app(let app): return app.name + (FileManager.default.fileExists(atPath: app.id) ? "" : " — unavailable")
        case .folder(_, let folder): return folder.config.name + " folder"
        case .widget(let kind): return kind.title
        case .trash: return "Trash"
        case .overflow: return "More apps"
        case .separator: return "Separator"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch entry {
                case .app(let app):
                    StyledIcon(id: app.id, image: app.icon)
                case .folder(_, let folder):
                    FolderTileIcon(apps: folder.apps, size: size, color: FolderColor(named: folder.config.color))
                case .widget:
                    widget
                case .overflow:
                    Image(systemName: "ellipsis.circle.fill").resizable().foregroundStyle(Theme.current.labelText)
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
            .modifier(Wiggle(tick: wiggleTick, enabled: isFolder))
            .overlay {
                if let pulse { PulseRing(color: pulse.color, size: size).allowsHitTesting(false) }
            }

            Circle()
                .fill(Theme.current.runningDot)
                .frame(width: 4, height: 4)
                .offset(y: 6)
                .opacity(running ? 1 : 0)
                .animation(Motion.hover, value: running)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleName)
        .accessibilityValue([running ? "Running" : nil, agent?.label, badge.map { "Unread: \($0)" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap() }
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

