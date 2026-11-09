import AppKit

// MARK: - Config

struct DockConfig: Codable {
    struct Item: Codable {
        var app: String?
        var folder: String?
        var widget: String?
        var size: String?
    }
    var iconSize: CGFloat
    var magnifiedSize: CGFloat
    var autohide: Bool
    var items: [Item]
    var hidden: [String]? // apps that never get a tile, even while running
    var theme: String?    // glass | graphite | paper | midnight | wallpaper
    var badges: Bool?     // read unread badges from Apple's Dock (needs Accessibility)
    var iconStyle: String? // default | dark | clear | tinted
    var iconTint: String?  // wallpaper | yellow | blue | pink | green | purple | graphite
    var onboarded: Bool?
    var agentSound: String? // attention | all | off
    var agentSounds: [String: String]? // "done" / "attention": a macOS sound name or a file in sounds/
    var profile: String?
    var profileRules: [ProfileRule]?
    var weatherCity: String?
    var timerMinutes: Int?
    var autoProfile: Bool?
}

