// Run from scripts/test.sh. A private temporary mailbox and fake handler exercise dispatch without opening H Chat or Voice.
import Foundation
import Darwin

@main struct AgentControlTests {
    @MainActor final class Recorder { var operations = [UUID]() }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkMailbox(root: root.appendingPathComponent("mail"))
        try checkArchive(root: root.appendingPathComponent("archive"))
        print("Agent control mailbox, expiry, replay, instance change, receipts and archive fixtures passed.")
    }

    @MainActor static func checkMailbox(root: URL) async throws {
        let recorder = Recorder()
        let request = try make()
        do { _ = try HControlMailbox.submit(request, directory: root); fatalError("A stopped desktop was started") }
        catch HControlFailure.unavailable { }
        var mailbox: HControlMailbox? = HControlMailbox(directory: root) { request in
            recorder.operations.append(request.id)
            if request.operation == "slow" { try await Task.sleep(nanoseconds: 3_400_000_000) }
            return .init(.sent, ["kind": request.operation])
        }
        try mailbox?.start()
        async let a = submit(request, root: root)
        async let b = submit(request, root: root)
        let (first, duplicate) = try await (a,b)
        precondition(first["state"] as? String == "sent" && duplicate["state"] as? String == "sent")
        precondition(first["id"] as? String == request.id.uuidString.lowercased())
        precondition(recorder.operations == [request.id])
        let changed = try make(id: request.id, operation: "another", expires: request.expires)
        do { _ = try await submit(changed, root: root); fatalError("Conflicting request reused the receipt") }
        catch HControlFailure.conflict { }
        let slow = try make(operation: "slow", expires: Date().timeIntervalSince1970 + 15)
        let accepted = try await submit(slow, root: root)
        precondition(accepted["state"] as? String == "accepted")
        let done = try await submit(slow, root: root)
        precondition(done["state"] as? String == "sent" && recorder.operations.filter({ $0 == slow.id }).count == 1)
        let expired = try make(expires: Date().timeIntervalSince1970 - 1)
        let distant = try make(expires: Date().timeIntervalSince1970 + 300)
        for rejected in [expired, distant] {
            do { _ = try await submit(rejected, root: root); fatalError("Out of bounds expiry accepted") }
            catch HControlFailure.invalid { }
        }
        let oldOwner = try owner(root)
        mailbox = nil
        let replacement = HControlMailbox(directory: root) { received in
            recorder.operations.append(received.id); return .init(.confirmed)
        }
        let queued = try make()
        try (Data((oldOwner + "\n").utf8) + queued.canonical).write(to: root.appendingPathComponent(queued.id.uuidString.lowercased() + ".request"), options: .atomic)
        try replacement.start()
        let stale = try await submit(queued, root: root)
        precondition(stale["state"] as? String == "unavailable" && !recorder.operations.contains(queued.id))
        let afterRestart = try await submit(request, root: root)
        precondition(afterRestart["state"] as? String == "sent" && recorder.operations.filter({ $0 == request.id }).count == 1)
        let crashed = try make()
        let entry = root.appendingPathComponent(crashed.id.uuidString.lowercased())
        let bytes = Data((oldOwner + "\n").utf8) + crashed.canonical
        try bytes.write(to: entry.appendingPathExtension("claim"), options: .atomic)
        try bytes.write(to: entry.appendingPathExtension("request"), options: .atomic)
        do { _ = try await submit(crashed, root: root); fatalError("A prior instance's claimed action was replayed") }
        catch HControlFailure.unknown { }
        let nowOwner = try owner(root)
        let delayed = try make(expires: Date().timeIntervalSince1970 - 1)
        try (Data((nowOwner + "\n").utf8) + delayed.canonical).write(to: root.appendingPathComponent(delayed.id.uuidString.lowercased() + ".request"), options: .atomic)
        let deadline = ContinuousClock.now + .seconds(3)
        let lateURL = root.appendingPathComponent(delayed.id.uuidString.lowercased() + ".reply")
        while !FileManager.default.fileExists(atPath: lateURL.path) && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let late = try JSONSerialization.jsonObject(with: Data(contentsOf: lateURL).dropFirst(delayed.receiptPrefix.count)) as? [String: Any]
        precondition(late?["state"] as? String == "invalid" && !recorder.operations.contains(delayed.id))
        withExtendedLifetime(replacement) {}
        for bad: Any in [true, "1", 1.25] {
            guard var badObject = try JSONSerialization.jsonObject(with: request.canonical) as? [String: Any] else { fatalError("Missing fixture") }
            badObject["version"] = bad
            do { _ = try HControlRequest(JSONSerialization.data(withJSONObject: badObject)); fatalError("Invalid version accepted") }
            catch HControlFailure.invalid { }
        }
    }

    static func checkArchive(root: URL) throws {
        let day = "2026-01-01", folder = root.appendingPathComponent(day), id = UUID()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data("{\"text\":\"☀️\"}".utf8)
        try data.write(to: folder.appendingPathComponent(id.uuidString + ".json"))
        let link = root.appendingPathComponent("2026-01-02")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let listed = try HControlArchive.days(before: "", limit: 5, root: root)
        precondition(listed == [day])
        let ids = try HControlArchive.documents(day: day, after: "", limit: 5, root: root)
        precondition(ids == [id.uuidString])
        let part = try HControlArchive.read(day: day, id: id.uuidString.lowercased(), offset: 3, limit: 5, root: root)
        precondition(part["data"] as? String == data.subdata(in: 3..<8).base64EncodedString())
        do { _ = try HControlArchive.read(day: "../archive", id: id.uuidString, offset: 0, limit: 1, root: root); fatalError("A path was accepted") }
        catch HControlFailure.invalid { }
        do { _ = try HControlArchive.read(day: "2026-01-02", id: id.uuidString, offset: 0, limit: 1, root: root); fatalError("A symlink was followed") }
        catch HControlFailure.unavailable { }
    }

    static func submit(_ request: HControlRequest, root: URL) async throws -> [String: Any] {
        let data = try await Task.detached { try HControlMailbox.submit(request, directory: root) }.value
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return result
    }
    static func owner(_ root: URL) throws -> String {
        let file = try Data(contentsOf: root.appendingPathComponent("owner"))
        guard let dict = try JSONSerialization.jsonObject(with: file) as? [String: Any], let instance = dict["instance"] as? String else { throw CocoaError(.coderInvalidValue) }
        return instance
    }
    static func make(id: UUID = UUID(), operation: String = "test", expires: Double = Date().timeIntervalSince1970 + 20) throws -> HControlRequest {
        try HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": id.uuidString, "operation": operation,
            "arguments": ["message": "a fragment with Unicode and\na newline."], "expiresAt": expires]))
    }
}
