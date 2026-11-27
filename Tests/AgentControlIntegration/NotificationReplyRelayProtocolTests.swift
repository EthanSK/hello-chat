// Provision real disposable metadata through the production protocol function; never run a model, wake Desktop or control media. — GPT-6.1 Sol
import Foundation
import XCTest
@testable import HelloChat

final class NotificationReplyRelayProtocolTests: XCTestCase {
    private struct Fixture {
        let origin: NotificationReplyOrigin, relay: UUID, firstTurn: UUID, path: URL, root: URL
        var metadata: [String: Any] {
            ["id": relay.uuidString.lowercased(), "path": path.path, "section": NSNull(), "ephemeral": false,
             "attachedToThreadId": NSNull(), "parentThreadId": NSNull(), "status": ["type": "idle"], "turns": []]
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HChatRelayProtocol-" + UUID().uuidString)
        let sessions = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let relay = UUID(), original = sessions.appendingPathComponent("source.jsonl")
        let origin = NotificationReplyOrigin(thread: UUID(), turn: UUID(), question: "", rollout: original, inode: 0, offset: 0,
            home: root, database: root.appendingPathComponent(".codex/state_5.sqlite"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(origin: origin, relay: relay, firstTurn: UUID(), path: sessions.appendingPathComponent("relay-" + relay.uuidString.lowercased() + ".jsonl"), root: root)
    }
    private func persist(_ f: Fixture, extra: [[String: Any]] = []) throws {
        let rows: [[String: Any]] = [["type": "session_meta", "payload": ["id": f.relay.uuidString.lowercased()]],
            ["type": "event_msg", "payload": ["type": "thread_settings_applied"]]] + extra
        var bytes = Data()
        for row in rows { bytes += try JSONSerialization.data(withJSONObject: row) + Data([10]) }
        try bytes.write(to: f.path)
    }
    func testUsesAuthoritativeEarliestTurnAndPersistsBlankBeforeReturning() throws {
        let f = try fixture(); var methods: [String] = [], finished = false
        let relay = try NotificationReplyRelay.provision(origin: f.origin, request: { method, arguments in
            methods.append(method)
            switch method {
            case "thread/turns/list":
                XCTAssertEqual(arguments["sortDirection"] as? String, "asc"); XCTAssertEqual(arguments["limit"] as? Int, 1)
                if arguments["threadId"] as? String == f.origin.thread.uuidString.lowercased() {
                    return ["data": [["id": f.firstTurn.uuidString.lowercased()]], "nextCursor": "there-are-later-turns"]
                }
                return ["data": [], "nextCursor": NSNull()]
            case "thread/fork":
                XCTAssertEqual(arguments["beforeTurnId"] as? String, f.firstTurn.uuidString.lowercased())
                XCTAssertNotEqual(arguments["beforeTurnId"] as? String, f.origin.turn?.uuidString.lowercased())
                XCTAssertEqual(arguments["deferGoalContinuation"] as? Bool, true)
                XCTAssertNil(arguments["model"]); XCTAssertNil(arguments["serviceTier"])
                return ["thread": f.metadata]
            case "thread/goal/get": return ["goal": NSNull()]
            default: XCTFail("Unexpected headless operation " + method); return [:]
            }
        }, finish: { finished = true; try self.persist(f) }, valid: { true })
        XCTAssertTrue(finished); XCTAssertEqual(relay.thread, f.relay)
        XCTAssertEqual(methods, ["thread/turns/list", "thread/fork", "thread/turns/list", "thread/goal/get"])
        XCTAssertFalse(try relay.completed())
        let prompt = try relay.brokerPrompt(event: UUID(), instance: UUID(), appExecutable: URL(fileURLWithPath: "/fixture/H Chat"), expiresAt: 123)
        XCTAssertTrue(prompt.contains("UNPINNED")); XCTAssertTrue(prompt.contains("ONE functions.exec"))
        XCTAssertTrue(prompt.contains("claimRelaySend")); XCTAssertFalse(prompt.contains("observedReply"))
    }
    func testInheritedGoalIsClearedOnlyOnOwnedDeferredFork() throws {
        for inherited in [false, true] {
            let f = try fixture(); var reads = 0, cleared: [String] = []
            _ = try NotificationReplyRelay.provision(origin: f.origin, request: { method, arguments in
                switch method {
                case "thread/turns/list": return ["data": arguments["threadId"] as? String == f.origin.thread.uuidString.lowercased() ? [["id": f.firstTurn.uuidString]] : []]
                case "thread/fork": XCTAssertEqual(arguments["deferGoalContinuation"] as? Bool, true); return ["thread": f.metadata]
                case "thread/goal/get":
                    XCTAssertEqual(arguments["threadId"] as? String, f.relay.uuidString.lowercased()); reads += 1
                    return inherited && reads == 1 ? ["goal": ["objective": "Must never run inherited work"]] : [:] // Schema permits an omitted null goal.
                case "thread/goal/clear":
                    cleared.append(arguments["threadId"] as! String); XCTAssertEqual(arguments["origin"] as? String, "automatic"); return ["cleared": true]
                default: XCTFail(method); return [:]
                }
            }, finish: { try self.persist(f) }, valid: { true })
            XCTAssertEqual(cleared, inherited ? [f.relay.uuidString.lowercased()] : [])
            XCTAssertEqual(reads, inherited ? 2 : 1)
        }
    }
    func testPinnedNonemptyAmbiguousAndUnconfirmedForksNeverBecomeBrokers() throws {
        for defect in ["pinned", "ephemeral", "parent", "attached", "busy", "returned-history", "listed-history", "cursor", "persisted-history", "wrong-session", "goal-remains"] {
            let f = try fixture(); var finished = false
            XCTAssertThrowsError(try NotificationReplyRelay.provision(origin: f.origin, request: { method, arguments in
                switch method {
                case "thread/turns/list":
                    if arguments["threadId"] as? String == f.origin.thread.uuidString.lowercased() { return ["data": [["id": f.firstTurn.uuidString]]] }
                    if defect == "listed-history" { return ["data": [["id": UUID().uuidString]]] }
                    return ["data": [], "nextCursor": defect == "cursor" ? "more-hidden-turns" : NSNull()]
                case "thread/fork":
                    var m = f.metadata
                    switch defect {
                    case "pinned": m["section"] = "pinned"
                    case "ephemeral": m["ephemeral"] = true
                    case "parent": m["parentThreadId"] = f.origin.thread.uuidString
                    case "attached": m["attachedToThreadId"] = f.origin.thread.uuidString
                    case "busy": m["status"] = ["type": "active"]
                    case "returned-history": m["turns"] = [["id": UUID().uuidString]]
                    default: break
                    }
                    return ["thread": m]
                case "thread/goal/get": return defect == "goal-remains" ? ["goal": ["objective": "inherited"]] : ["goal": NSNull()]
                case "thread/goal/clear": return ["cleared": false]
                default: XCTFail(method); return [:]
                }
            }, finish: {
                finished = true
                try self.persist(f, extra: defect == "persisted-history" ? [["type": "turn_context", "payload": ["turn_id": UUID().uuidString]]] : [])
                if defect == "wrong-session" { try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong\"}}\n".utf8).write(to: f.path) }
            }, valid: { true }), defect)
            if !["persisted-history", "wrong-session"].contains(defect) { XCTAssertFalse(finished, defect) }
        }
    }
    func testInvalidLeaseDoesNotForkAndTerminalRequiresSameTurn() throws {
        let f = try fixture(); var calls = 0
        XCTAssertThrowsError(try NotificationReplyRelay.provision(origin: f.origin, request: { _, _ in calls += 1; return [:] }, finish: {}, valid: { false }))
        XCTAssertEqual(calls, 0)
        try persist(f)
        let relay = try NotificationReplyRelay.verifyBlank(thread: f.relay, rollout: f.path), turn = UUID().uuidString
        let h = try FileHandle(forWritingTo: f.path); try h.seekToEnd()
        for (kind, id) in [("task_started", turn), ("task_complete", UUID().uuidString)] {
            try h.write(contentsOf: JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": kind, "turn_id": id]]) + Data([10]))
        }
        try h.close(); XCTAssertEqual(try relay.ownership(), .relinquished)
    }
    func testCleanupScansPastFirstCompletionAndPreservesUserTakeoverAndPin() throws {
        for takeover in ["none", "new-human", "second-turn", "pinned", "custom-section", "new-goal", "during-metadata-read"] {
            let f = try fixture(), broker = "Exact fixed broker fixture", turn = UUID().uuidString
            try persist(f)
            let relay = try NotificationReplyRelay.verifyBlank(thread: f.relay, rollout: f.path).bindingBroker(broker)
            func append(_ row: [String: Any]) throws {
                let h = try FileHandle(forWritingTo: f.path); defer { try? h.close() }; try h.seekToEnd()
                try h.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
            }
            try append(["type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]])
            try append(["type": "response_item", "payload": ["role": "user", "content": [
                ["type": "input_text", "text": "# AGENTS.md instructions\nfixture"],
                ["type": "input_text", "text": "<environment_context>fixture</environment_context>"]]]])
            try append(["type": "response_item", "payload": ["role": "user", "content": [["type": "input_text", "text": broker]]]])
            XCTAssertTrue(try relay.isActiveBroker()); XCTAssertFalse(try relay.completed())
            try append(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn]])
            XCTAssertTrue(try relay.completed()); XCTAssertFalse(try relay.isActiveBroker())
            let newHuman: [String: Any] = ["type": "event_msg", "payload": ["type": "user_message", "message": "User took over this chat"]]
            if takeover == "new-human" { try append(newHuman) }
            if takeover == "second-turn" { try append(["type": "event_msg", "payload": ["type": "task_started", "turn_id": UUID().uuidString]]) }
            if ["new-human", "second-turn"].contains(takeover) { XCTAssertEqual(try relay.ownership(), .relinquished) }
            var archived = 0
            let request: (String, [String: Any]) throws -> [String: Any] = { method, arguments in
                XCTAssertEqual(arguments["threadId"] as? String, f.relay.uuidString.lowercased())
                if method == "thread/read" {
                    if takeover == "during-metadata-read" { try append(newHuman) }
                    let section: Any = takeover == "pinned" ? "pinned" : takeover == "custom-section" ? "custom" as Any : NSNull()
                    return ["thread": ["id": f.relay.uuidString.lowercased(), "section": section, "status": ["type": "idle"]]]
                }
                if method == "thread/goal/get" { return takeover == "new-goal" ? ["goal": ["objective": "new user work"]] : [:] }
                XCTAssertEqual(method, "thread/archive"); archived += 1; return [:]
            }
            if takeover == "none" { try relay.archiveIfOwned(request: request); XCTAssertEqual(archived, 1) }
            else { XCTAssertThrowsError(try relay.archiveIfOwned(request: request), takeover); XCTAssertEqual(archived, 0) }
        }
    }
    func testCleanupRecordIsPrivateMetadataAndCannotAuthorizeAnotherSend() throws {
        let f = try fixture(); try persist(f)
        let relay = try NotificationReplyRelay.verifyBlank(thread: f.relay, rollout: f.path).bindingBroker("Fixed broker fixture")
        let file = f.root.appendingPathComponent("cleanup.json")
        let data = try JSONEncoder().encode(NotificationReplyRelay.CleanupRecord(relay: relay, executable: URL(fileURLWithPath: "/fixture/codex")))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Fixed broker fixture"))
        try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try NotificationReplyRelay.CleanupRecord.read(file, home: f.root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let read = try NotificationReplyRelay.CleanupRecord.read(file, home: f.root)
        XCTAssertEqual(read.thread, f.relay); XCTAssertEqual(try read.relay.ownership(), .running)
    }
    func testUnstartedCleanupRechecksCurrentEmptyHistoryQueueAndPin() throws {
        for takeover in ["none", "pinned", "running", "turn", "queued", "input"] {
            let f = try fixture(); try persist(f, extra: takeover == "input" ? [["type": "event_msg", "payload": ["type": "user_message", "message": "new work"]]] : [])
            var archived = 0
            let request: (String, [String: Any]) throws -> [String: Any] = { method, arguments in
                XCTAssertEqual(arguments["threadId"] as? String, f.relay.uuidString.lowercased())
                switch method {
                case "thread/read":
                    var metadata = f.metadata
                    if takeover == "pinned" { metadata["section"] = "pinned" }
                    if takeover == "running" { metadata["status"] = ["type": "active"] }
                    return ["thread": metadata]
                case "thread/turns/list": return ["data": takeover == "turn" ? [["id": UUID().uuidString]] : []]
                case "thread/queue/list": return ["data": takeover == "queued" ? [["id": UUID().uuidString]] : []]
                case "thread/archive": archived += 1; return [:]
                default: XCTFail("Must not clear or reject an inherited goal in the empty cleanup path: " + method); return [:]
                }
            }
            if takeover == "none" { try NotificationReplyRelay.archiveUnstartedIfOwned(f.relay, home: f.root, request: request); XCTAssertEqual(archived, 1) }
            else { XCTAssertThrowsError(try NotificationReplyRelay.archiveUnstartedIfOwned(f.relay, home: f.root, request: request)); XCTAssertEqual(archived, 0) }
        }
    }
    func testSharedClientFlushesOnEOFBeforeReturningPersistence() throws {
        let f = try fixture(), script = f.root.appendingPathComponent("metadata-server"), marker = f.root.appendingPathComponent("eof-flushed")
        let source = """
        #!/usr/bin/python3
        import sys,json,pathlib
        for line in sys.stdin:
            row=json.loads(line)
            if 'id' in row: print(json.dumps({'id':row['id'],'result':{'metadataOnly':True}}),flush=True)
        pathlib.Path(\(String(decoding: try JSONSerialization.data(withJSONObject: marker.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self))).write_text('finished')
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let began = ProcessInfo.processInfo.systemUptime
        let client = CodexConfigClient(); try client.start(script, environment: nil); defer { client.close() }
        _ = try client.request("initialize", ["clientInfo": ["name": "inert-test", "version": "1"]])
        let beforeFinish = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        do { try client.finishPersisting() }
        catch {
            print("INERT EOF lifecycle: startup=\(beforeFinish - began) total=\(ProcessInfo.processInfo.systemUptime - began) marker=\(FileManager.default.fileExists(atPath: marker.path))")
            throw error
        }
        XCTAssertEqual(try String(contentsOf: marker), "finished")
    }
}
