// Shared folder UI: config, motion tokens, the folder grid view and its floating panel.
import AppKit
import SwiftUI
// MARK: - Config

struct FolderConfig: Codable {
    var name: String
    var columns: Int
    var apps: [String]
    var labels: [String: String]?
}

struct FolderApp: Identifiable {
    let id: String
    let url: URL
    let name: String
    let icon: NSImage
}

func loadConfig(_ path: String) -> FolderConfig {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return try! JSONDecoder().decode(FolderConfig.self, from: data)
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
    var anchorX: CGFloat = 0.5
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
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
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
        .onHover { hovering = $0 }
        .onLongPressGesture(minimumDuration: 0, pressing: { pressed = $0 }, perform: { launch(app) })
        .contextMenu {
            AppMenu(app: app, running: state.running.contains(app.id), open: { launch(app) })
            if let remove {
                Divider()
                Button("Remove from Folder") { remove(app) }
            }
        }
        .help(app.name)
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
        let columns = max(1, min(state.columns, apps.count))
        let rows = stride(from: 0, to: apps.count, by: columns).map { Array(apps[$0..<min($0 + columns, apps.count)]) }
        VStack(spacing: 14) {
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.current.folderTitle)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row, rowApps in
                    GridRow {
                        ForEach(rowApps) { app in
                            AppCell(app: app, row: row, state: state, launch: launch, remove: remove)
                        }
                    }
                }
            }
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

struct GlassBackground: ViewModifier {
    static var useMaterial = false // snapshots can't render Liquid Glass

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
        panel.contentView = NSHostingView(rootView: view)
        reload()
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

    /// Opens the folder growing out of `anchor` (screen point at the top-centre of the trigger).
    func show(anchor: NSPoint) {
        closing = false
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main!
        let size = panel.frame.size
        var x = anchor.x - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.y - 24)) // 24pt shadow inset in FolderView

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

