// Verify exact-origin and duplicate dispatch with disposable local fixtures; never call Desktop's live queue. — GPT-6.1 Sol
import Foundation
import SQLite3

@main struct NotificationReplyOriginTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1; if !condition() { fatalError(name) }
    }
    static func fails(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError(name) } catch { checks += 1 }
    }
    static func append(_ value: [String: Any], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    }
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HChatReplyOriginTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex"), sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = UUID(), turn = UUID(), file = sessions.appendingPathComponent("test.jsonl")
        try Data().write(to: file)
        try append(["type":"turn_context", "payload":["turn_id":turn.uuidString.lowercased()]], to: file)
        let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?; sqlite3_open(database.path, &db)
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);", nil, nil, nil) == SQLITE_OK, "fixture table")
        check(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(thread.uuidString.lowercased())','\(file.path)');", nil, nil, nil) == SQLITE_OK, "fixture row")
        let origin = try NotificationReplyOrigin.capture(thread: thread, turn: turn, question: "", home: home)
        try origin.validate(); checks += 1
        fails("unknown thread cannot select latest") { _ = try NotificationReplyOrigin.capture(thread: UUID(), turn: nil, question: "", home: home) }
        fails("different source turn is stale") { _ = try NotificationReplyOrigin.capture(thread: thread, turn: UUID(), question: "", home: home) }
        fails("closed or missing question is stale") { _ = try NotificationReplyOrigin.capture(thread: thread, turn: turn, question: "question-1", home: home) }

        var calls: [[String]] = []
        let event = UUID(), claims = home.appendingPathComponent("claims")
        try origin.dispatch(event: event, spokenText: "The task is ready.", body: "Reply to Sunny.", executable: URL(fileURLWithPath: "/not-a-real-codex"), claims: claims, valid: { true }, run: { calls.append($0); return 0 })
        check(calls.count == 1, "exactly one injected dispatch")
        check(Array(calls[0].dropFirst().prefix(3)) == ["queue", "--thread", thread.uuidString.lowercased()], "exact target queue arguments")
        check(!calls[0].contains("--resume"), "never create a second writer")
        check(calls[0].last?.contains("Reply to Sunny.") == true, "genuine leading reply preserved")
        fails("same event cannot dispatch twice") { try origin.dispatch(event: event, spokenText: "The task is ready.", body: "again", executable: URL(fileURLWithPath: "/unused"), claims: claims, valid: { true }, run: { calls.append($0); return 0 }) }
        check(calls.count == 1, "duplicate claim sends no command")
        let beforeArrival = try origin.hasArrived(event: event)
        check(!beforeArrival, "queue acceptance is not arrival")
        let unknown = UUID()
        fails("unknown submission remains claimed") { try origin.dispatch(event: unknown, spokenText: "Ready", body: "yes", executable: URL(fileURLWithPath: "/unused"), claims: claims, valid: { true }, run: { _ in 1 }) }
        fails("unknown submission is not replayed") { try origin.dispatch(event: unknown, spokenText: "Ready", body: "yes", executable: URL(fileURLWithPath: "/unused"), claims: claims, valid: { true }, run: { _ in fatalError("replayed") }) }
        fails("empty content never dispatches") { try origin.dispatch(event: UUID(), spokenText: "Ready", body: " ", executable: URL(fileURLWithPath: "/unused"), claims: claims, valid: { true }, run: { _ in fatalError("empty dispatch") }) }
        fails("failed live guard never dispatches") { try origin.dispatch(event: UUID(), spokenText: "Ready", body: "yes", executable: URL(fileURLWithPath: "/unused"), claims: claims, valid: { false }, run: { _ in fatalError("invalid dispatch") }) }

        try append(["type":"response_item", "payload":["role":"assistant", "content":[["type":"output_text", "text":"Not a user reply"]]]], to: file)
        try origin.validate(); checks += 1
        try append(["type":"response_item", "payload":["role":"user", "content":[["type":"input_text", "text":"[H CHAT NOTIFICATION REPLY \(event.uuidString.lowercased())]"]]]], to: file)
        let afterArrival = try origin.hasArrived(event: event)
        check(afterArrival, "only exact saved user marker establishes arrival")
        fails("new user input cancels pending capture") { try origin.validate() }
        print("Notification reply origin: \(checks) checks passed")
    }
}
