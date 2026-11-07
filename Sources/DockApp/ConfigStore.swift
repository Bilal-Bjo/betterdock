import AppKit

/// Owns validation, atomic persistence, recovery, and profile folder identity.
final class ConfigStore {
    let path: String
    var folderDir: String { URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("folders").path }
    var backup: String { path + ".last-good" }
    static let fallback: [String: Any] = [
        "iconSize": 52, "magnifiedSize": 84, "autohide": true,
        "items": [["app": "/System/Library/CoreServices/Finder.app"]], "theme": "glass"
    ]
    init(path: String) { self.path = path }

    static func decode(_ data: Data) throws -> DockConfig {
        let config = try JSONDecoder().decode(DockConfig.self, from: data)
        guard (32...96).contains(config.iconSize),
              (config.iconSize...192).contains(config.magnifiedSize) else {
            throw Failure("Icon sizes must be between 32 and 96, with magnification between the icon size and 192.")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var layouts = [config.items]
        if let profiles = json["profiles"] as? [String: Any] {
            for value in profiles.values {
                let bytes = try JSONSerialization.data(withJSONObject: value)
                layouts.append(try JSONDecoder().decode([DockConfig.Item].self, from: bytes))
            }
        }
        for layout in layouts {
            var ids = Set<String>()
            for item in layout {
                let values = [item.app, item.folder, item.widget].compactMap { $0 }
                guard values.count == 1 else { throw Failure("Every tile needs exactly one app, folder, or widget.") }
                let identity = item.app.map { "app:\($0)" } ?? item.folder.map { "folder:\($0)" } ?? "widget:\(item.widget!)"
                guard ids.insert(identity).inserted else { throw Failure("A layout contains duplicate tiles.") }
                if let app = item.app, !app.hasPrefix("/") || !app.hasSuffix(".app") { throw Failure("App paths must be absolute .app paths.") }
                if let folder = item.folder, folder.isEmpty || folder.contains("/") || folder == "." || folder == ".." {
                    throw Failure("Folder identifiers must be simple filenames.")
                }
                if let widget = item.widget, WidgetKind(rawValue: widget) == nil { throw Failure("Unknown widget: \(widget).") }
            }
        }
        if let minutes = config.timerMinutes, !(1...180).contains(minutes) { throw Failure("Timer length must be between 1 and 180 minutes.") }
        if let rules = config.profileRules {
            for rule in rules {
                guard rule.valid else { throw Failure("Invalid profile time rule for \(rule.profile). Use HH:mm and a valid day.") }
            }
        }
        return config
    }

    func read() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try Self.decode(data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Settings must be a JSON object.") }
        return json
    }

    @discardableResult func write(_ json: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _ = try Self.decode(data)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Preserve the previous valid generation first, even if the candidate write fails.
        if let previous = try? Data(contentsOf: url), (try? Self.decode(previous)) != nil {
            if previous != data { try previous.write(to: URL(fileURLWithPath: path + ".previous"), options: .atomic) }
            try previous.write(to: URL(fileURLWithPath: backup), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        do { try data.write(to: URL(fileURLWithPath: backup), options: .atomic) }
        catch { AppNotice.message = "Settings were saved, but the backup could not be updated: " + error.localizedDescription }
        return data
    }

    func recover() throws -> DockConfig {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try Self.decode(data)
            do { try data.write(to: URL(fileURLWithPath: backup), options: .atomic) }
            catch { AppNotice.message = "Settings loaded, but the recovery backup could not be updated: " + error.localizedDescription }
            return config
        } catch {
            let original = error
            if let bad = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                let archive = path + ".invalid-" + UUID().uuidString + ".json"
                try bad.write(to: URL(fileURLWithPath: archive), options: .atomic)
            }
            let data = try? Data(contentsOf: URL(fileURLWithPath: backup))
            let recovered = data.flatMap { try? Self.decode($0) }
            if let data, recovered != nil {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else {
                try write(Self.fallback)
            }
            AppNotice.message = "Settings were invalid: \(original.localizedDescription)\n\nRestored \(recovered == nil ? "a safe starter layout" : "your last working layout"). The invalid file was kept next to dock.json."
            return try Self.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        }
    }

    func cloneLayout(_ layout: [[String: String]]) throws -> [[String: String]] {
        var copies: [String: String] = [:]
        return try layout.map { item in
            guard let slug = item["folder"] else { return item }
            let source = "\(folderDir)/\(slug).json"
            guard FileManager.default.fileExists(atPath: source) else { return item }
            let target = copies[slug] ?? "folder-\(UUID().uuidString.lowercased())"
            if copies[slug] == nil {
                let data = try Data(contentsOf: URL(fileURLWithPath: source))
                let folder = try JSONDecoder().decode(FolderConfig.self, from: data)
                guard folder.isValid else { throw Failure("Invalid folder: \(slug).") }
                try data.write(to: URL(fileURLWithPath: "\(folderDir)/\(target).json"), options: .atomic)
                copies[slug] = target
            }
            var result = item
            result["folder"] = target
            return result
        }
    }

    /// Existing profiles used to share mutable folders. Copy them once, before any edits.
    func isolateProfiles() throws {
        var json = try read()
        guard (json["schemaVersion"] as? Int ?? 1) < 2 else { return }
        if var profiles = json["profiles"] as? [String: [[String: String]]], !profiles.isEmpty {
            let current = json["profile"] as? String ?? "Default"
            profiles[current] = json["items"] as? [[String: String]] ?? []
            for name in profiles.keys.sorted() where name != current {
                profiles[name] = try cloneLayout(profiles[name] ?? [])
            }
            json["profiles"] = profiles
        }
        json["schemaVersion"] = 2
        try write(json)
    }

    func referencedElsewhere(_ slug: String, current: String?) -> Bool {
        guard let json = try? read(), let profiles = json["profiles"] as? [String: [[String: String]]] else { return false }
        return profiles.contains { name, layout in name != (current ?? "Default") && layout.contains { $0["folder"] == slug } }
    }

    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}

enum AppNotice {
    static var message: String?
    static func report(_ error: Error) {
        message = error.localizedDescription
        NSLog("BetterDock: %@", error.localizedDescription)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "BetterDock needs attention"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
