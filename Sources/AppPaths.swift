import Foundation

// Previously Hey Chat's data folders. The signing identity and instance lock
// deliberately stay stable; visible data/log locations now use HelloChat.
enum AppPaths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HelloChat", isDirectory: true)

    static func migrateLegacyData(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let fm = FileManager.default
        let old = home.appendingPathComponent("Library/Application Support/Hey Chat", isDirectory: true)
        let new = home.appendingPathComponent("Library/Application Support/HelloChat", isDirectory: true)
        if fm.fileExists(atPath: old.path) {
            try fm.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for item in try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) where item.lastPathComponent != "instance.lock" {
                let destination = new.appendingPathComponent(item.lastPathComponent)
                // Existing new data wins; keep any collision recoverable at its old path.
                if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: item, to: destination) }
            }
        }
        let oldLogs = home.appendingPathComponent("Library/Logs/Hey Chat", isDirectory: true)
        let newLogs = home.appendingPathComponent("Library/Logs/HelloChat", isDirectory: true)
        if fm.fileExists(atPath: oldLogs.path), !fm.fileExists(atPath: newLogs.path) {
            try fm.moveItem(at: oldLogs, to: newLogs)
        }
    }
}
