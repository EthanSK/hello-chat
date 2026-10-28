import Foundation

@main enum AppInstanceTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first: AppInstanceLock? = try AppInstanceLock(url: url)
        precondition(first!.acquired)
        let duplicate = try AppInstanceLock(url: url)
        precondition(!duplicate.acquired)
        first = nil
        let replacement = try AppInstanceLock(url: url)
        precondition(replacement.acquired)
        withExtendedLifetime(replacement) {}
        print("Passed single-instance exclusion and release checks.")
    }
}
