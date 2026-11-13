// Verify the supplementary private-schema reader against disposable metadata.
// No real Codex database or transcript content is opened by this test.
import Foundation
import SQLite3

@main enum VoiceTimelineTests {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) {
            precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK)
        }
        sql("CREATE TABLE thread_timeline_ledger(host_id TEXT, thread_id TEXT, sequence INTEGER, payload_json TEXT)")
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',1,'{\"type\":\"session-started\",\"sessionId\":\"old\",\"occurredAtMs\":1000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == false)
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',2,'{\"type\":\"session-started\",\"sessionId\":\"new\",\"occurredAtMs\":3000}')")
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',3,'{\"type\":\"transcript-segment\",\"text\":\"not selected\",\"occurredAtMs\":4000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == true)
        precondition(VoiceTimeline.activeSessions(database: url, since: Date(timeIntervalSince1970: 2)) == ["chat:new"])
        // An older close must not end a replacement call in the same thread.
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',4,'{\"type\":\"session-ended\",\"sessionId\":\"old\",\"occurredAtMs\":5000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == true)
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',5,'{\"type\":\"session-ended\",\"sessionId\":\"new\",\"occurredAtMs\":6000}')")
        sql("INSERT INTO thread_timeline_ledger VALUES('remote','chat',6,'{\"type\":\"session-started\",\"sessionId\":\"remote\",\"occurredAtMs\":7000}')")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == false)
        sql("INSERT INTO thread_timeline_ledger VALUES('local','chat',7,'{\"type\":\"session-started\",\"sessionId\":\"replacement\",\"occurredAtMs\":8000}')")
        precondition(VoiceTimeline.activeSessions(database: url, since: Date(timeIntervalSince1970: 2)) == ["chat:replacement"],
                     "Reader preserves changed identity when boolean active stays true")
        let thread = UUID(), session = UUID(), replacement = UUID()
        sql("INSERT INTO thread_timeline_ledger VALUES('local','\(thread)',8,'{\"type\":\"session-started\",\"sessionId\":\"\(session)\",\"occurredAtMs\":8000}')")
        sql("INSERT INTO thread_timeline_ledger VALUES('local','\(thread)',9,'{\"type\":\"session-ended\",\"sessionId\":\"\(session)\",\"occurredAtMs\":9000}')")
        sql("INSERT INTO thread_timeline_ledger VALUES('local','\(thread)',10,'{\"type\":\"session-started\",\"sessionId\":\"\(replacement)\",\"occurredAtMs\":10000}')")
        precondition(VoiceTimeline.hasEnded(database: url, thread: thread, session: session, since: Date(timeIntervalSince1970: 2)) == true)
        precondition(VoiceTimeline.hasEnded(database: url, thread: thread, session: replacement, since: Date(timeIntervalSince1970: 2)) == false)
        sql("DROP TABLE thread_timeline_ledger")
        precondition(VoiceTimeline.hasActiveCall(database: url, since: Date(timeIntervalSince1970: 2)) == nil,
                     "A private schema mismatch is unknown, not a confirmed End")
        print("Voice timeline metadata checks passed")
    }
}
