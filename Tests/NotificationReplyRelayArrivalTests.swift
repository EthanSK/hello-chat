// Check native relay arrival with disposable files and an injected queue; never send to Desktop. — GPT-6.1 Sol
import Foundation
import SQLite3

@main struct NotificationReplyRelayArrivalTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1; if !value() { fatalError(name) }
    }
    static func stale(_ operation: () throws -> Void, _ name: String) {
        do { try operation(); fatalError(name) }
        catch NotificationReplyOrigin.Failure.originStale { checks += 1 }
        catch { fatalError("Wrong failure for \(name): \(error)") }
    }
    static func append(_ row: [String: Any], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
    }
    static func fixture(body: String) throws -> (home: URL, origin: NotificationReplyOrigin, message: String, identity: NotificationReplyOrigin.ReplyIdentity) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HChatRelayArrival-" + UUID().uuidString)
        let root = home.appendingPathComponent(".codex"), sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = UUID(), turn = UUID(), file = sessions.appendingPathComponent("fixture.jsonl")
        try Data().write(to: file)
        try append(["type":"turn_context", "payload":["turn_id":turn.uuidString.lowercased()]], to: file)
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else { fatalError("fixture database") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER NOT NULL DEFAULT 0); INSERT INTO threads(id,rollout_path) VALUES ('\(thread.uuidString.lowercased())','\(file.path)');", nil, nil, nil) == SQLITE_OK else { fatalError("fixture metadata") }
        let origin = try NotificationReplyOrigin.capture(thread: thread, turn: turn, question: "", home: home)
        let event = UUID(); var message = ""
        try origin.dispatch(event: event, spokenText: "The task is ready.", body: body,
                            executable: URL(fileURLWithPath: "/never-run-codex"), claims: home.appendingPathComponent("claims"),
                            valid: { true }, run: { arguments in
            message = String(arguments.last!.dropFirst("--message=".count)); return 0
        })
        return (home, origin, message, try origin.replyIdentity(event: event, spokenText: "The task is ready.", body: body))
    }
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    static func output(source: UUID, encoded: String) -> String {
        "<codex_delegation>\n  <source_thread_id>\(source.uuidString.lowercased())</source_thread_id>\n  <input>" + encoded + "</input>\n</codex_delegation>"
    }
    // Observed Desktop record layout; identifiers and adversarial bodies below are synthetic. — GPT-6.1 Sol
    static func native(source: UUID, message: String) -> [String: Any] {
        ["type":"response_item", "payload":["type":"function_call_output", "id":"fco_" + UUID().uuidString.lowercased(),
            "namespace":"codex_app", "name":"send_message_to_thread", "output":output(source: source, encoded: escaped(message)),
            "internal_chat_message_metadata_passthrough":["turn_id":UUID().uuidString.lowercased(), "create_time":"synthetic"]]]
    }
    static func replacing(_ row: [String: Any], key: String, value: Any?) -> [String: Any] {
        var result = row, payload = row["payload"] as! [String: Any]
        payload[key] = value; result["payload"] = payload; return result
    }
    static func main() throws {
        for body in ["A simple reply.", "Use A & B <tag>, literal &lt;, amp &amp;, quotes \" and 🦊."] {
            let f = try fixture(body: body); defer { try? FileManager.default.removeItem(at: f.home) }
            let relay = UUID(), identity = f.identity.acceptingRelay(from: relay)
            let row = native(source: relay, message: f.message)
            let file = f.origin.rollout
            let before = try f.origin.hasArrived(reply: identity)
            check(!before, "admission is not arrival")
            try append(row, to: file)
            let arrived = try f.origin.hasArrived(reply: identity)
            check(arrived, "exact native record establishes complete relay arrival")
            try f.origin.validate(reply: identity); checks += 1
            let legacyArrived = try f.origin.hasArrived(reply: f.identity)
            check(!legacyArrived, "legacy identity does not accept relay records")

            let textRow: [String: Any] = ["type":"response_item", "payload":["role":"user", "content":[["type":"input_text", "text":f.message]]]]
            let fresh = try NotificationReplyOrigin.capture(thread: f.origin.thread, turn: f.origin.turn, question: "", home: f.home)
            try append(textRow, to: file)
            let copiedLegacy = try fresh.hasArrived(reply: f.identity)
            let copiedRelay = try fresh.hasArrived(reply: identity)
            check(copiedLegacy, "legacy complete-user arrival remains accepted")
            check(!copiedRelay, "even an exact human copy is not relay arrival")
            stale({ try fresh.validate(reply: identity) }, "human copy stays newer input in relay mode")

            var cases: [(String, [String: Any])] = []
            cases.append(("wrong source", native(source: UUID(), message: f.message)))
            cases.append(("body changed", native(source: relay, message: f.message + " extra")))
            cases.append(("same-byte-length body changed", native(source: relay, message: "{" + f.message.dropFirst())))
            cases.append(("body truncated", native(source: relay, message: String(f.message.dropLast()))))
            let payloadChanges: [(String, Any?)] = [
                ("namespace", "other"), ("name", "read_thread"), ("type", "function_call"), ("id", nil),
                ("id", ""), ("output", ["text":f.message]), ("role", "user"), ("content", []),
                ("message", f.message), ("images", ["new-image"]), ("local_images", ["new-image"]),
                ("text_elements", ["new-element"])
            ]
            for (key, value) in payloadChanges { cases.append(("wrong payload \(key)", replacing(row, key: key, value: value))) }
            var wrongKind = row; wrongKind["type"] = "event_msg"; cases.append(("wrong row type", wrongKind))
            for changed in [
                "quoted " + output(source: relay, encoded: escaped(f.message)),
                output(source: relay, encoded: escaped(f.message)) + " new content",
                "\n" + output(source: relay, encoded: escaped(f.message)),
                output(source: relay, encoded: escaped(f.message)) + "\n",
                output(source: relay, encoded: escaped(f.message)).replacingOccurrences(of: "  <input>", with: "  <!-- comment --><input>"),
                output(source: relay, encoded: "<![CDATA[" + f.message + "]]>"),
                output(source: relay, encoded: escaped(f.message)).replacingOccurrences(of: "<input>", with: "<input mode=\"extra\">"),
                output(source: relay, encoded: escaped(f.message)).replacingOccurrences(of: "<source_thread_id>", with: "<source_thread_id><nested>"),
                output(source: relay, encoded: escaped(f.message)).replacingOccurrences(of: "</source_thread_id>", with: "</source_thread_id>\n  <source_orbit_id>other</source_orbit_id>")
            ] { cases.append(("noncanonical wrapper", replacing(row, key: "output", value: changed))) }
            // Each negative is isolated from the earlier positive saved row. — GPT-6.1 Sol
            for (name, bad) in cases {
                let clean = try NotificationReplyOrigin.capture(thread: f.origin.thread, turn: f.origin.turn, question: "", home: f.home)
                try append(bad, to: file)
                let accepted = try clean.hasArrived(reply: identity)
                check(!accepted, name)
            }
            if body.contains("&") {
                for encoded in [f.message, escaped(f.message).replacingOccurrences(of: "&lt;", with: "&#60;") ] {
                    let clean = try NotificationReplyOrigin.capture(thread: f.origin.thread, turn: f.origin.turn, question: "", home: f.home)
                    try append(replacing(row, key: "output", value: output(source: relay, encoded: encoded)), to: file)
                    let accepted = try clean.hasArrived(reply: identity)
                    check(!accepted, "unescaped or alternate entities are not canonical host output")
                }
            }
            let newest = try NotificationReplyOrigin.capture(thread: f.origin.thread, turn: f.origin.turn, question: "", home: f.home)
            try append(row, to: file)
            try append(["type":"event_msg", "payload":["type":"user_message", "message":"A newer human request"]], to: file)
            stale({ try newest.validate(reply: identity) }, "new human input remains stale after native arrival")
            let priorArrival = try newest.hasArrived(reply: identity)
            check(priorArrival, "observed arrival does not retract on subsequent input")
        }
        print("Notification reply relay arrival: \(checks) checks passed")
    }
}
