import Foundation

@main struct AppPathsTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("HelloChatMigration-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let old = home.appendingPathComponent("Library/Application Support/Hey Chat")
        let new = home.appendingPathComponent("Library/Application Support/HelloChat")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("lock".utf8).write(to: old.appendingPathComponent("instance.lock"))
        try Data("transcript".utf8).write(to: old.appendingPathComponent("saved.json"))
        try AppPaths.migrateLegacyData(home: home)
        precondition(fm.fileExists(atPath: old.appendingPathComponent("instance.lock").path))
        let saved = try Data(contentsOf: new.appendingPathComponent("saved.json"))
        precondition(saved == Data("transcript".utf8))
        try Data("older".utf8).write(to: old.appendingPathComponent("saved.json"))
        try AppPaths.migrateLegacyData(home: home)
        let collision = try Data(contentsOf: old.appendingPathComponent("saved.json"))
        precondition(collision == Data("older".utf8))
        let preserved = try Data(contentsOf: new.appendingPathComponent("saved.json"))
        precondition(preserved == Data("transcript".utf8))
        print("Data migration: preservation, stable lock, collision, and repeat checks passed")
    }
}
