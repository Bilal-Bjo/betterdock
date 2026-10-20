// Shared folder UI: config, motion tokens, the folder grid view and its floating panel.
import AppKit
import SwiftUI
// MARK: - Config

struct FolderConfig: Codable {
    var name: String
    var columns: Int
    var apps: [String]
    var labels: [String: String]?
    var color: String?
}

/// Folder tile colours: graphite by default, or one of six tints.
enum FolderColor: String, CaseIterable {
    case graphite, red, orange, yellow, green, blue, purple

    init(named name: String?) { self = FolderColor(rawValue: name ?? "") ?? .graphite }

    var title: String { rawValue.capitalized }

    /// Top and bottom of the tile's gradient: deep enough that the small icons stay legible.
    var gradient: [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch self {
        case .graphite: return [Color(white: 0.38), Color(white: 0.2)]
        case .red: return [c(0.86, 0.33, 0.33), c(0.6, 0.15, 0.17)]
        case .orange: return [c(0.95, 0.56, 0.27), c(0.72, 0.33, 0.1)]
        case .yellow: return [c(0.95, 0.85, 0.31), c(0.75, 0.6, 0.1)]
        case .green: return [c(0.38, 0.75, 0.47), c(0.16, 0.48, 0.27)]
        case .blue: return [c(0.38, 0.6, 0.95), c(0.15, 0.33, 0.7)]
        case .purple: return [c(0.66, 0.48, 0.92), c(0.4, 0.24, 0.66)]
        }
    }
}

struct FolderApp: Identifiable {
    let id: String
    let url: URL
    let name: String
    let icon: NSImage
}

func loadConfig(_ path: String) -> FolderConfig? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(FolderConfig.self, from: data)
}

func saveConfig(_ config: FolderConfig, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(config) { try? data.write(to: URL(fileURLWithPath: path)) }
}

func resolveApps(_ config: FolderConfig) -> [FolderApp] {
    config.apps.compactMap { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = config.labels?[path]
            ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return FolderApp(id: path, url: url, name: name, icon: NSWorkspace.shared.icon(forFile: path))
    }
}

// MARK: - Motion tokens

enum Motion {
    static let easeOut = (0.23, 1.0, 0.32, 1.0)
    static let open = Animation.timingCurve(easeOut.0, easeOut.1, easeOut.2, easeOut.3, duration: 0.2)
    static let close = Animation.timingCurve(easeOut.0, easeOut.1, easeOut.2, easeOut.3, duration: 0.15)
    static let hover = Animation.easeInOut(duration: 0.15)
    static let rowStagger = 0.04
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - View

final class FolderState: ObservableObject {
    @Published var open = false
    @Published var title = ""
    @Published var apps: [FolderApp] = []
    @Published var columns = 4
    @Published var running: Set<String> = []
    @Published var agents: [String: AgentState] = [:]
    @Published var badges: [String: String] = [:]
    @Published var dragging: String?
    @Published var dragOffset: CGSize = .zero
    var anchorX: CGFloat = 0.5
    /// Where the dragged app sat when the drag began, and whether the order changed since.
    var dragStart: Int?
    var reordered = false
    /// Called when an app is dragged out of the panel and released: (app path, screen point).
    var onDragOut: (String, NSPoint) -> Void = { _, _ in }
    /// Called when a drag inside the folder changed the order: the new order of app paths.
    var onReorder: ([String]) -> Void = { _ in }
    /// Whether a screen point is over the folder panel.
    var contains: (NSPoint) -> Bool = { _ in true }

    /// Cells are 92×100 with 8/6 pt gaps.
    static let step = CGSize(width: 100, height: 106)
    var layoutColumns: Int { max(1, min(columns, apps.count)) }

    /// Moves the dragged app to the slot under the cursor, so the others slide aside, and returns
    /// the offset that keeps it under the cursor from its new slot.
    func drag(_ id: String, by translation: CGSize, at point: NSPoint) -> CGSize {
        guard let from = apps.firstIndex(where: { $0.id == id }) else { return translation }
        if dragStart == nil { dragStart = from; reordered = false }
        let start = dragStart ?? from
        let cols = layoutColumns, rows = (apps.count + cols - 1) / cols
        let startCol = start % cols, startRow = start / cols
        var target = from
        // Only rearrange while over the folder; dragging out leaves the order alone.
        if contains(point) {
            let col = min(max(startCol + Int((translation.width / Self.step.width).rounded()), 0), cols - 1)
            let row = min(max(startRow + Int((translation.height / Self.step.height).rounded()), 0), rows - 1)
            target = min(row * cols + col, apps.count - 1)
        }
        if target != from {
            withAnimation(.spring(duration: 0.3, bounce: 0.12)) {
                apps.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
            }
            reordered = true
        }
        let shift = CGSize(width: CGFloat(target % cols - startCol) * Self.step.width,
                           height: CGFloat(target / cols - startRow) * Self.step.height)
        return CGSize(width: translation.width - shift.width, height: translation.height - shift.height)
    }
}

struct AppCell: View {
    let app: FolderApp
    let row: Int
    @ObservedObject var state: FolderState
    let launch: (FolderApp) -> Void
    let remove: ((FolderApp) -> Void)?
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 6) {
            StyledIcon(id: app.id, image: app.icon)
                .frame(width: 64, height: 64)
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        if let badge = state.badges[app.id] {
                            UnreadBadge(text: badge, height: 18).offset(x: 6, y: -4)
                        } else if let agent = state.agents[app.id] {
                            AgentDot(state: agent, size: 12).offset(x: 1, y: 1)
                        }
                    }
                }
                .scaleEffect(pressed ? 0.94 : (hovering ? 1.06 : 1))
                .animation(Motion.hover, value: hovering)
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: pressed)
            Circle()
                .fill(Theme.current.runningDot)
                .frame(width: 4, height: 4)
                .opacity(state.running.contains(app.id) ? 1 : 0)
                .padding(.top, -3)
            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84)
        }
        .frame(width: 92, height: 100)
        .contentShape(Rectangle())
        .opacity(state.open ? 1 : 0)
        .offset(y: state.open || Motion.reduce ? 0 : 6)
        .animation(
            state.open
                ? Motion.open.delay(Motion.reduce ? 0 : Double(row) * Motion.rowStagger)
                : Motion.close,
            value: state.open
        )
        .offset(state.dragging == app.id ? state.dragOffset : .zero)
        // The dragged icon stays glued to the cursor while the others slide around it.
        .transaction { if state.dragging == app.id { $0.animation = nil } }
        .zIndex(state.dragging == app.id ? 1 : 0)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if hypot(value.translation.width, value.translation.height) > 5 || state.dragging == app.id {
                        pressed = false
                        state.dragging = app.id
                        state.dragOffset = state.drag(app.id, by: value.translation, at: NSEvent.mouseLocation)
                    } else if state.dragging == nil {
                        pressed = true
                    }
                }
                .onEnded { value in
                    pressed = false
                    let wasDragging = state.dragging == app.id
                    let point = NSEvent.mouseLocation
                    state.dragging = nil
                    state.dragStart = nil
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) { state.dragOffset = .zero }
                    if wasDragging, !state.contains(point) {
                        state.onDragOut(app.id, point)
                    } else if wasDragging {
                        if state.reordered { state.onReorder(state.apps.map(\.id)) }
                    } else if hypot(value.translation.width, value.translation.height) <= 5 {
                        launch(app)
                    }
                }
        )
        .contextMenu {
            AppMenu(app: app, running: state.running.contains(app.id), open: { launch(app) })
            if let remove {
                Divider()
                Button("Remove from Folder") { remove(app) }
            }
        }
        .tooltip(app.name)
    }
}

/// Right-click menu for an app tile, shared by the folder and the dock.
struct AppMenu: View {
    let app: FolderApp
    let running: Bool
    let open: () -> Void

    var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.id }
    }

    var body: some View {
        Button(running ? "Show" : "Open", action: open)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
        if running {
            Divider()
            Button("Hide") { runningApp?.hide() }
            Button("Quit") { runningApp?.terminate() }
        }
    }
}

struct FolderView: View {
    @ObservedObject var state: FolderState
    let launch: (FolderApp) -> Void
    let remove: ((FolderApp) -> Void)?

    var body: some View {
        let apps = state.apps
        let columns = state.layoutColumns
        VStack(spacing: 14) {
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.current.folderTitle)
            // One container for every cell, so a reorder slides cells between rows.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 8, alignment: .leading), count: columns),
                      alignment: .leading, spacing: 6) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    AppCell(app: app, row: index / columns, state: state, launch: launch, remove: remove)
                }
            }
            .frame(width: CGFloat(columns) * 92 + CGFloat(columns - 1) * 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .modifier(GlassBackground())
        .scaleEffect(state.open || Motion.reduce ? 1 : 0.92, anchor: UnitPoint(x: state.anchorX, y: 1))
        .opacity(state.open ? 1 : 0)
        // Spring pop out of the tile (interruptible on rapid clicks), quick ease-out back in.
        .animation(state.open ? .spring(duration: 0.32, bounce: 0.15) : Motion.close, value: state.open)
        .padding(24) // room for the shadow
    }
}

/// Set while rendering --snapshot images: ImageRenderer can't draw glass, AppKit-backed views or tooltips.
enum Snapshot {
    static var active = false
}

extension View {
    /// A tooltip, skipped in snapshots where it renders as a placeholder.
    @ViewBuilder
    func tooltip(_ text: String) -> some View {
        if Snapshot.active { self } else { help(text) }
    }
}

struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        content
            .background(Theme.current.surface(shape))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

// MARK: - Folder panel

final class FolderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns one folder's floating panel: positioning, open/close motion, dismissal, and edits.
final class FolderController {
    private(set) var config: FolderConfig
    let path: String?
    let state = FolderState()
    let panel: FolderPanel
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onChange: () -> Void = {}
    /// Set by the dock: "Remove from Folder" hands the app back to it.
    var onRemoveApp: ((String) -> Void)?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var closing = false

    var apps: [FolderApp] { state.apps }
    var isOpen: Bool { panel.isVisible && !closing }

    /// Set by the dock: an app dragged out of the folder lands at this screen point.
    var onDragOutApp: ((String, NSPoint) -> Void)?

    init(config: FolderConfig, path: String? = nil) {
        self.config = config
        self.path = path
        panel = FolderPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = FolderView(state: state, launch: { [weak self] app in self?.launch(app) },
                              remove: { [weak self] app in self?.removeFromFolder(app.id) })
            .environment(\.onScreen, true)
        panel.contentView = NSHostingView(rootView: view)
        reload()
        state.contains = { [weak self] point in
            self?.panel.frame.insetBy(dx: 20, dy: 20).contains(point) ?? true
        }
        state.onReorder = { [weak self] order in
            guard let self else { return }
            // Keep apps that are missing from disk (not shown) at the end, rather than dropping them.
            self.config.apps = order + self.config.apps.filter { !order.contains($0) }
            self.commit()
        }
        state.onDragOut = { [weak self] path, point in
            guard let self, !self.panel.frame.insetBy(dx: 20, dy: 20).contains(point) else { return }
            self.config.apps.removeAll { $0 == path }
            self.commit()
            self.hide()
            self.onDragOutApp?(path, point)
        }
    }

    private func reload() {
        state.title = config.name
        state.columns = config.columns
        state.apps = resolveApps(config)
        if let host = panel.contentView { panel.setContentSize(host.fittingSize) }
    }

    private func commit() {
        if let path { saveConfig(config, to: path) }
        reload()
        onChange()
    }

    func add(_ appPath: String) {
        guard !config.apps.contains(appPath) else { return }
        config.apps.append(appPath)
        commit()
    }

    func removeFromFolder(_ appPath: String) {
        config.apps.removeAll { $0 == appPath }
        commit()
        onRemoveApp?(appPath)
        if config.apps.isEmpty { hide() }
    }

    func rename(_ name: String) {
        config.name = name
        commit()
    }

    func setColor(_ color: FolderColor) {
        config.color = color == .graphite ? nil : color.rawValue
        commit()
    }

    /// Opens the folder growing out of `anchor` (screen point at the top-centre of the trigger).
    func show(anchor: NSPoint) {
        closing = false
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main!
        let size = panel.frame.size
        var x = anchor.x - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.y - 24)) // 24pt shadow inset in FolderView

        panel.appearance = Theme.current.appearance
        state.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        state.anchorX = min(max((anchor.x - x) / size.width, 0), 1)
        state.open = false
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.async { self.state.open = true }
        installMonitors()
        onOpen()
    }

    func hide() {
        guard panel.isVisible, !closing else { return }
        closing = true
        removeMonitors()
        onClose()
        state.open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard self.closing else { return }
            self.panel.orderOut(nil)
            self.closing = false
        }
    }

    func toggle(anchor: NSPoint) {
        if isOpen { hide() } else { show(anchor: anchor) }
    }

    func launch(_ app: FolderApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        hide()
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide(); return nil } // Esc
            return event
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Folder icon (iOS-style 3x3 preview)

func renderFolderIcon(apps: [FolderApp], to path: String) {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    // macOS icon grid: 824pt body with 100pt margins.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(white: 0.36, alpha: 1), ending: NSColor(white: 0.18, alpha: 1))!
        .draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    bg.lineWidth = 4
    bg.stroke()

    let cell: CGFloat = 176, gap: CGFloat = 46 // ~13% inner padding keeps icons off the edges
    let gridWidth = cell * 3 + gap * 2
    let origin = NSPoint(x: body.midX - gridWidth / 2, y: body.midY - gridWidth / 2)
    for (i, app) in apps.prefix(9).enumerated() {
        let col = CGFloat(i % 3), row = CGFloat(2 - i / 3)
        let rect = NSRect(x: origin.x + col * (cell + gap), y: origin.y + row * (cell + gap), width: cell, height: cell)
        app.icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

