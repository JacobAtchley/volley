import Foundation

/// Volley used to be sandboxed, so its database and preferences lived in its container. Without the sandbox
/// macOS looks in the normal locations; copy the old data over once so pairing and history survive.
enum SandboxMigration {
    private static let doneKey = "sandboxMigrated"

    static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser, bundleId: String,
                    defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let container = home.appendingPathComponent("Library/Containers/\(bundleId)/Data/Library")

        let oldDb = container.appendingPathComponent("Application Support/Volley/volley.sqlite")
        let newDb = home.appendingPathComponent("Library/Application Support/Volley/volley.sqlite")
        if fileManager.fileExists(atPath: oldDb.path), !fileManager.fileExists(atPath: newDb.path) {
            try? fileManager.createDirectory(at: newDb.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: oldDb, to: newDb)
        }

        let oldPrefs = container.appendingPathComponent("Preferences/\(bundleId).plist")
        if let data = try? Data(contentsOf: oldPrefs),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
