// Verify the supplementary private-schema reader against disposable metadata.
// No real Codex database or transcript content is opened by this test.
import Foundation
import SQLite3

@main enum VoiceTimelineTests {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Inert collector evidence: a passing read stays silent; an incomplete
        // read retains its actual failure without native UI or transcript data. — GPT-6.1 Sol
        let diagnosticURL = url.deletingLastPathComponent().appendingPathComponent("voice-read-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }
        let diagnostics = Diagnostics(directory: diagnosticURL)
        var snapshot = VoiceSnapshot(pid: 123, inputRunning: false, recorderRunning: false,
                                     microphone: nil, accessibilityAllowed: true)
        VoiceCallMonitor.recordIncompleteRead(snapshot, readAudio: false, diagnostics: diagnostics)
        _ = try diagnostics.commandHistory(limit: 1) // Flush the existing serialized writer.
        precondition(!FileManager.default.fileExists(atPath: diagnosticURL.appendingPathComponent("events.jsonl").path))
        snapshot.controlsComplete = false
        snapshot.scanFailure = "attribute:AXRole:-25204"
        snapshot.scanNodes = 12; snapshot.scanTimeouts = 1; snapshot.scanDepth = 8
        VoiceCallMonitor.recordIncompleteRead(snapshot, readAudio: true, diagnostics: diagnostics)
        _ = try diagnostics.commandHistory(limit: 1)
        let recorded = try Data(contentsOf: diagnosticURL.appendingPathComponent("events.jsonl"))
        let entry = try JSONSerialization.jsonObject(with: recorded) as! [String: Any]
        precondition(entry["event"] as? String == "voice.controls.incomplete")
        precondition(entry["failure"] as? String == snapshot.scanFailure)
        precondition(entry["read_audio"] as? String == "true")
        precondition(entry["codex_pid"] as? Int == 123 && entry["scan_nodes"] as? Int == 12)
        precondition(entry["scan_timeouts"] as? Int == 1 && entry["scan_depth"] as? Int == 8)
        precondition(Set(entry.keys) == ["time", "event", "codex_pid", "scan_nodes", "scan_timeouts", "scan_depth",
                                         "failure", "accessibility_allowed", "application_ready", "application_has_window", "read_audio"])
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) {
            precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK)
        }
        sql("CREATE TABLE thread_timeline_ledger(host_id TEXT, thread_id TEXT, sequence INTEGER, payload_json TEXT)")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',1,'{\"type\":\"session-started\",\"sessionId\":\"old\",\"occurredAtMs\":1000}')")
        sql("ALTER TABLE thread_timeline_ledger ADD COLUMN record_id TEXT")
        sql("CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT, missing_candidate INTEGER)")
        precondition(VoiceTimeline.mostRecentChat(database: url) == .none)
        func saved(_ id: UUID, _ stamp: Int, host: String = "local", missing: Int = 0) {
            let sid = UUID().uuidString
            sql("INSERT INTO local_thread_catalog VALUES ('\(host)','\(id)',\(missing))")
            sql("INSERT INTO thread_timeline_ledger VALUES ('\(host)','\(id)',1,'{\"type\":\"session-started\",\"sessionId\":\"\(sid)\",\"occurredAtMs\":\(stamp)}','session:\(sid):started')")
        }
        let first = UUID(), newer = UUID()
        saved(first, 11)
        saved(newer, 12)
        saved(UUID(), 15, host: "remote")
        saved(UUID(), 20, missing: 1)
        precondition(VoiceTimeline.mostRecentChat(database: url) == .thread(newer))
        saved(UUID(), 12)
        precondition(VoiceTimeline.mostRecentChat(database: url) == .unknown)
        sql("DELETE FROM thread_timeline_ledger WHERE record_id IS NOT NULL")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == false)
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',2,'{\"type\":\"session-started\",\"sessionId\":\"new\",\"occurredAtMs\":3000}')")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',3,'{\"type\":\"transcript-segment\",\"text\":\"not selected\",\"occurredAtMs\":4000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == true)
        precondition(VoiceTimeline.activeSessions(database: url, since: Date(timeIntervalSince1970: 2)) == ["chat:new"])
        precondition(VoiceTimeline.sessions(database: url, since: Date(timeIntervalSince1970: 2))
                     == VoiceLedgerSessions(startedAtMilliseconds: ["chat:new": 3000], ended: []),
                     "The active session supplies its original start time, not the latest read time")
        // A cutoff after the start is a valid empty read, but no End record.
        precondition(VoiceTimeline.sessions(database: url, since: Date(timeIntervalSince1970: 9))
                     == VoiceLedgerSessions(startedAtMilliseconds: [:], ended: []))
        // An older close must not end a replacement call in the same thread.
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',4,'{\"type\":\"session-ended\",\"sessionId\":\"old\",\"occurredAtMs\":5000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == true)
        precondition(VoiceTimeline.sessions(database: url, since: Date(timeIntervalSince1970: 2))?.ended == ["chat:old"])
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',5,'{\"type\":\"session-ended\",\"sessionId\":\"new\",\"occurredAtMs\":6000}')")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('remote','chat',6,'{\"type\":\"session-started\",\"sessionId\":\"remote\",\"occurredAtMs\":7000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == false)
        precondition(VoiceTimeline.sessions(database: url, since: Date(timeIntervalSince1970: 2))
                     == VoiceLedgerSessions(startedAtMilliseconds: [:], ended: ["chat:old", "chat:new"]),
                     "The exact session's own End record is reported, never a remote host's")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','chat',7,'{\"type\":\"session-started\",\"sessionId\":\"replacement\",\"occurredAtMs\":8000}')")
        precondition(VoiceTimeline.activeSessions(database: url, since: Date(timeIntervalSince1970: 2)) == ["chat:replacement"],
                     "Reader preserves changed identity when boolean active stays true")
        // The observed thread move: a temporary thread's session ends, then
        // the original thread starts a new one. Both boundaries are real.
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','temporary',1,'{\"type\":\"session-started\",\"sessionId\":\"moved\",\"occurredAtMs\":8100}')")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','temporary',2,'{\"type\":\"session-ended\",\"sessionId\":\"moved\",\"occurredAtMs\":8200}')")
        let moved = VoiceTimeline.sessions(database: url, since: Date(timeIntervalSince1970: 2))
        precondition(moved?.active == ["chat:replacement"] && moved?.ended.contains("temporary:moved") == true)
        let thread = UUID(), session = UUID(), replacement = UUID()
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','\(thread)',8,'{\"type\":\"session-started\",\"sessionId\":\"\(session)\",\"occurredAtMs\":8000}')")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','\(thread)',9,'{\"type\":\"session-ended\",\"sessionId\":\"\(session)\",\"occurredAtMs\":9000}')")
        sql("INSERT INTO thread_timeline_ledger(host_id,thread_id,sequence,payload_json) VALUES('local','\(thread)',10,'{\"type\":\"session-started\",\"sessionId\":\"\(replacement)\",\"occurredAtMs\":10000}')")
        precondition(VoiceTimeline.hasEnded(database: url, thread: thread, session: session, since: Date(timeIntervalSince1970: 2)) == true)
        precondition(VoiceTimeline.hasEnded(database: url, thread: thread, session: replacement, since: Date(timeIntervalSince1970: 2)) == false)
        sql("DROP TABLE thread_timeline_ledger")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == nil,
                     "A private schema mismatch is unknown, not a confirmed End")
        print("Voice timeline metadata checks passed")
    }
}
