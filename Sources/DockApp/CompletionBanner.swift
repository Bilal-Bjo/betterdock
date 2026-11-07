import AppKit
import SwiftUI

/// A local completion notice works even when Notification Center permission is unavailable.
enum CompletionBanner {
    private static var panel: NSPanel?
    static func show() {
        NSSound(named: "Glass")?.play()
        panel?.orderOut(nil)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 6) {
                Label("Focus session complete", systemImage: "checkmark.circle.fill").font(.headline)
                Text("Time for a break.").foregroundStyle(.secondary)
            }.padding(20).frame(width: 320, height: 100).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        )
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        window.setFrameOrigin(NSPoint(x: screen.maxX - 340, y: screen.maxY - 120))
        window.orderFrontRegardless()
        panel = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if panel === window { window.orderOut(nil); panel = nil }
        }
    }
}
