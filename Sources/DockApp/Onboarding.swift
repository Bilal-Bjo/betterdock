// First-run setup: hide Apple's Dock, pick a theme, suggested folders and optional permissions.
import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Folder suggestions

struct FolderSuggestion: Identifiable {
    let name: String
    let color: FolderColor
    let apps: [FolderApp]
    var on = true
    var id: String { name }

    /// App names that belong in each suggested folder; a trailing * also matches versioned names.
    private static let groups: [(String, FolderColor, [String])] = [
        ("Code", .blue, ["Xcode", "Visual Studio Code", "Cursor", "Windsurf", "Zed", "Nova", "Sublime Text", "Terminal", "iTerm*",
                         "Warp", "Ghostty", "cmux", "GitHub Desktop*", "Tower", "Fork", "Claude", "ChatGPT", "Codex", "OpenCode",
                         "T3 Code*", "Postman", "Docker", "Termius"]),
        ("Messages", .green, ["Messages", "WhatsApp", "Telegram", "Signal", "Discord", "Slack", "Messenger", "Microsoft Teams",
                              "Zoom", "FaceTime"]),
        ("Design", .purple, ["Figma", "Sketch", "Framer", "Pixelmator Pro", "Affinity*", "Adobe Photoshop*", "Adobe Illustrator*",
                             "Adobe InDesign*", "Adobe Lightroom*", "Blender", "Canva", "Freeform"]),
        ("Media", .red, ["Music", "Spotify", "Podcasts", "TV", "Photos", "IINA", "VLC", "QuickTime Player", "Final Cut Pro*",
                         "Logic Pro*", "GarageBand", "Audacity"]),
        ("Office", .orange, ["Pages", "Numbers", "Keynote", "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint",
                             "Microsoft Outlook", "Notion", "Obsidian"]),
    ]

    /// Installed apps grouped into folders, leaving out apps that are already in one.
    static func scan(excluding taken: Set<String>) -> [FolderSuggestion] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var installed: [String: String] = [:] // name -> path
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    installed[String(entry.dropLast(4))] = installed[String(entry.dropLast(4))] ?? path
                } else {
                    // Suites like Adobe install each app one folder down.
                    for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        installed[String(inner.dropLast(4))] = installed[String(inner.dropLast(4))] ?? path + "/" + inner
                    }
                }
            }
        }
        var used = taken
        return groups.compactMap { name, color, wanted in
            let paths = wanted.flatMap { want in
                let prefix = want.hasSuffix("*") ? String(want.dropLast()) : nil
                return installed.filter { name, _ in prefix.map { name.hasPrefix($0) } ?? (name == want) }.values.sorted()
            }
            let apps = paths.filter { !used.contains($0) }.compactMap(appEntry)
            guard apps.count >= 2 else { return nil }
            used.formUnion(apps.map(\.id))
            return FolderSuggestion(name: name, color: color, apps: Array(apps.prefix(16)))
        }
    }
}

// MARK: - Model

final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var hideDock: Bool
    @Published var openAtLogin: Bool
    @Published var theme: Theme
    @Published var suggestions: [FolderSuggestion]
    @Published var accessibility = AXIsProcessTrusted()
    @Published var automation = Automation.finderAllowed
    let loginManaged = LoginItem.managedByLaunchAgent
    let wallpaper: NSImage?
    let icons: [NSImage]
    var onTheme: (Theme) -> Void = { _ in }

    static let steps = 4

    init(hideDock: Bool, openAtLogin: Bool, suggestions: [FolderSuggestion], wallpaper: NSImage?, icons: [NSImage]) {
        self.hideDock = hideDock
        self.openAtLogin = openAtLogin
        self.theme = Theme.current
        self.suggestions = suggestions
        self.wallpaper = wallpaper
        self.icons = icons
    }

    func refreshPermissions() {
        accessibility = AXIsProcessTrusted()
        automation = Automation.finderAllowed
    }
}

/// Apple Events permission for Finder (Trash), Spotify and Music (Now Playing).
enum Automation {
    static var finderAllowed: Bool { status("com.apple.finder", ask: false) == noErr }

    @discardableResult
    static func status(_ bundle: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, bundle.utf8.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    /// Shows the system prompts; music players are only asked while running, so none is launched.
    static func request(done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            status("com.apple.finder", ask: true)
            for bundle in ["com.spotify.client", "com.apple.Music"]
            where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
                status(bundle, ask: true)
            }
            DispatchQueue.main.async(execute: done)
        }
    }
}

// MARK: - Window

/// The bottom of the wallpaper, small: the backdrop for the Dock previews.
func wallpaperSlice(for screen: NSScreen) -> NSImage? {
    guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) else { return nil }
    let size = NSSize(width: 640, height: 240)
    let slice = NSImage(size: size)
    slice.lockFocus()
    let source = image.size
    let scale = size.width / source.width
    let height = size.height / scale
    image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(x: 0, y: 0, width: source.width, height: min(height, source.height)),
               operation: .copy, fraction: 1)
    slice.unlockFocus()
    return slice
}

/// Owns the setup window; the Dock drops its reference when the window closes, which frees it.
final class OnboardingWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: OnboardingModel
    var onFinish: (OnboardingModel) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var activeObserver: Any?

    init(model: OnboardingModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "BetterDock Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Onboard.background)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, finish: { [weak self] in
            guard let self else { return }
            self.onFinish(self.model)
            self.window.close()
        }))
        // Permissions are granted in System Settings; re-check when the user comes back.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.model.refreshPermissions() }
    }

    func show() {
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refreshPermissions() }

    func windowWillClose(_ notification: Notification) {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        onClose()
    }
}

// MARK: - Views

private enum Onboard {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let card = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(red: 0.953, green: 0.851, blue: 0.306) // #f3d94e
    static let secondary = Color.white.opacity(0.58)
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: WelcomeStep(model: model)
                case 1: ThemeStep(model: model)
                case 2: FoldersStep(model: model)
                default: PermissionsStep(model: model)
                }
            }
            .id(model.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 40)

            HStack(spacing: 6) {
                ForEach(0..<OnboardingModel.steps, id: \.self) { i in
                    Capsule()
                        .fill(i == model.step ? Onboard.accent : Color.white.opacity(0.18))
                        .frame(width: i == model.step ? 18 : 6, height: 6)
                }
                Spacer()
                if model.step > 0 {
                    Button("Back") { go(-1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Onboard.secondary)
                        .padding(.trailing, 14)
                }
                Button(model.step == OnboardingModel.steps - 1 ? "Start Using BetterDock" : "Continue") {
                    if model.step == OnboardingModel.steps - 1 { finish() } else { go(1) }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .animation(.spring(duration: 0.3, bounce: 0), value: model.step)
            .padding(.horizontal, 40)
            .padding(.vertical, 22)
            .overlay(alignment: .top) { Rectangle().fill(Onboard.line).frame(height: 1) }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .background(Onboard.background)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(Onboard.accent)
    }

    func go(_ delta: Int) {
        withAnimation(Motion.reduce ? nil : .spring(duration: 0.35, bounce: 0)) { model.step += delta }
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(Onboard.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.12), value: configuration.isPressed)
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .semibold)).tracking(-0.3)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Onboard.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Onboard.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Onboard.line))
    }
}

private struct Row<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Onboard.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Onboard.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Onboard.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A slice of the user's wallpaper with a small Dock on it, drawn in a theme.
private struct DockPreview: View {
    let theme: Theme
    let wallpaper: NSImage?
    let icons: [NSImage]
    let iconSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.overlay {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.08, green: 0.1, blue: 0.2)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
            HStack(spacing: iconSize * 0.22) {
                ForEach(Array(icons.enumerated()), id: \.offset) { i, icon in
                    VStack(spacing: iconSize * 0.08) {
                        Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
                        Circle().fill(theme.runningDot).frame(width: 3, height: 3).opacity(i < 2 ? 1 : 0)
                    }
                }
            }
            .padding(.horizontal, iconSize * 0.28)
            .padding(.top, iconSize * 0.24)
            .padding(.bottom, iconSize * 0.1)
            .background(theme.surface(RoundedRectangle(cornerRadius: iconSize * 0.48, style: .continuous)))
            .environment(\.colorScheme, theme.scheme)
            .padding(.bottom, iconSize * 0.3)
        }
        .clipped()
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DockPreview(theme: model.theme, wallpaper: model.wallpaper, icons: model.icons, iconSize: 34)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Onboard.line))
            StepHeader(title: "Welcome to BetterDock",
                       subtitle: "A calmer Dock with folders, widgets and agent status. Setup takes under a minute.")
            Card {
                Row(symbol: "dock.rectangle", title: "Hide Apple's Dock",
                    detail: "BetterDock takes its place. Your Dock settings are saved and can be restored any time.") {
                    Toggle("", isOn: $model.hideDock).toggleStyle(.switch).labelsHidden()
                }
                Rectangle().fill(Onboard.line).frame(height: 1).padding(.leading, 62)
                Row(symbol: "power", title: "Open at Login",
                    detail: model.loginManaged ? "Already started at login by install.sh." : "Start BetterDock when you log in.") {
                    Toggle("", isOn: $model.openAtLogin).toggleStyle(.switch).labelsHidden().disabled(model.loginManaged)
                }
            }
        }
    }
}

private struct ThemeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Pick a look", subtitle: "Shown on your own wallpaper. Change it any time from BetterDock ▸ Theme.")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(176), spacing: 12), count: 3), alignment: .leading, spacing: 16) {
                ForEach(Theme.allCases, id: \.self) { theme in
                    let selected = theme == model.theme
                    Button {
                        model.theme = theme
                        model.onTheme(theme)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            DockPreview(theme: theme, wallpaper: model.wallpaper, icons: Array(model.icons.prefix(4)), iconSize: 24)
                                .frame(width: 176, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(selected ? Onboard.accent : Onboard.line, lineWidth: selected ? 2 : 1))
                            HStack(spacing: 6) {
                                Text(theme.title).font(.system(size: 12, weight: .medium))
                                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Onboard.accent) }
                            }
                            .foregroundStyle(selected ? .white : Onboard.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(Motion.hover, value: selected)
                }
            }
        }
    }
}

private struct FoldersStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Tidy up with folders",
                       subtitle: "Apps that belong together, found on your Mac. Apps in a folder never take a spot in the Dock, even while they run.")
            if model.suggestions.isEmpty {
                Card {
                    Row(symbol: "checkmark.circle", title: "Nothing to tidy",
                        detail: "Your apps are already in folders. Make new ones from any app's right-click menu.") { EmptyView() }
                }
            } else {
                ScrollView {
                    Card {
                        ForEach($model.suggestions) { $suggestion in
                            if suggestion.id != model.suggestions.first?.id {
                                Rectangle().fill(Onboard.line).frame(height: 1).padding(.leading, 74)
                            }
                            HStack(spacing: 14) {
                                FolderTileIcon(apps: suggestion.apps, size: 44, color: suggestion.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.name).font(.system(size: 13, weight: .semibold))
                                    Text(suggestion.apps.map(\.name).joined(separator: ", "))
                                        .font(.system(size: 12)).foregroundStyle(Onboard.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 12)
                                Toggle("", isOn: $suggestion.on).toggleStyle(.switch).labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "A few optional permissions",
                       subtitle: "BetterDock works without them; each one turns on a feature. Change them later in System Settings.")
            Card {
                Row(symbol: "app.badge", title: "Accessibility",
                    detail: "Shows unread badges from Messages, Mail and chat apps on their icons.") {
                    if model.accessibility {
                        Granted()
                    } else {
                        Button("Allow…") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            if !AXIsProcessTrustedWithOptions(options) { openPane("Privacy_Accessibility") }
                        }
                    }
                }
                Rectangle().fill(Onboard.line).frame(height: 1).padding(.leading, 62)
                Row(symbol: "music.note", title: "Automation",
                    detail: "Lets Now Playing control Spotify and Music, and the Trash show when it's full.") {
                    if model.automation {
                        Granted()
                    } else {
                        HStack(spacing: 10) {
                            Button("Settings") { openPane("Privacy_Automation") }.buttonStyle(.plain).foregroundStyle(Onboard.secondary)
                            Button("Allow…") {
                                asking = true
                                Automation.request {
                                    asking = false
                                    model.refreshPermissions()
                                }
                            }
                            .disabled(asking)
                        }
                    }
                }
            }
        }
    }

    func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

private struct Granted: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
            .transition(.opacity)
    }
}
