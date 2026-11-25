// Verify H Chat's speed-only contract with injected controls and a temporary metadata database;
// these tests never operate Codex, change settings or start a call. — GPT-6.1 Sol
import Foundation
import SQLite3

@main enum CodexChatSpeedTests {
    final class Fake: CodexChatSpeed.Picker {
        var state = CodexChatSpeed.Selection(model: "GPT-6.2 Sol High", speed: .standard, draft: "Keep this unsent draft")
        var choices: [CodexChatSpeed.Speed] = []
        var readFailure: CodexChatSpeed.Failure?
        var afterSelect: (() -> Void)?
        var finishFailure = false
        func read() throws -> CodexChatSpeed.Selection {
            if let readFailure { throw readFailure }
            return state
        }
        func select(_ speed: CodexChatSpeed.Speed) throws {
            choices.append(speed)
            state = .init(model: state.model, speed: speed, draft: state.draft)
            afterSelect?()
        }
        func finish() throws { if finishFailure { throw CodexChatSpeed.Failure.unconfirmed } }
    }

    @MainActor static func main() async throws {
        let thread = UUID()
        let normal = Fake()
        let changed = CodexChatSpeed.perform(thread: thread, speed: .ultrafast, picker: normal)
        precondition(changed.status == "confirmed" && changed.speed == .ultrafast)
        precondition(normal.choices == [.ultrafast] && normal.state.draft == "Keep this unsent draft")
        let repeated = CodexChatSpeed.perform(thread: thread, speed: .ultrafast, picker: normal)
        precondition(repeated.status == "unchanged" && normal.choices == [.ultrafast])
        let observed = CodexChatSpeed.perform(thread: thread, speed: nil, picker: normal)
        precondition(observed.status == "observed" && normal.choices.count == 1)

        for failure in [CodexChatSpeed.Failure.wrongChat, .multiplePanes, .interrupted, .busy] {
            let fake = Fake(); fake.readFailure = failure
            let result = CodexChatSpeed.perform(thread: thread, speed: .ultrafast, picker: fake)
            precondition(result.status == failure.rawValue && result.speed == nil && fake.choices.isEmpty)
        }
        for changedField in ["model", "draft", "interrupted"] {
            let fake = Fake()
            fake.afterSelect = {
                if changedField == "interrupted" { fake.readFailure = .interrupted }
                else { fake.state = .init(model: changedField == "model" ? "GPT-6.1 Sol Max" : fake.state.model,
                                         speed: .ultrafast, draft: changedField == "draft" ? "New typing" : fake.state.draft) }
            }
            let result = CodexChatSpeed.perform(thread: thread, speed: .ultrafast, picker: fake)
            precondition(result.speed == nil && fake.choices == [.ultrafast])
        }
        let cleanup = Fake(); cleanup.finishFailure = true
        precondition(CodexChatSpeed.perform(thread: thread, speed: .ultrafast, picker: cleanup).status == "unconfirmed")

        let database = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSpeed-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }
        var db: OpaquePointer?
        precondition(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE local_thread_catalog(host_id TEXT DEFAULT 'local', thread_id TEXT, display_title TEXT, missing_candidate INTEGER DEFAULT 0); INSERT INTO local_thread_catalog(thread_id,display_title) VALUES('\(thread.uuidString.lowercased())','Exact chat');", nil, nil, nil) == SQLITE_OK)
        let unique = try CodexChatSpeed.uniqueTitle(thread: thread, database: database)
        precondition(unique == "Exact chat")
        precondition(sqlite3_exec(db, "INSERT INTO local_thread_catalog(host_id,thread_id,display_title,missing_candidate) VALUES('remote','ignored','Exact chat',0),('local','missing','Exact chat',1);", nil, nil, nil) == SQLITE_OK)
        let localUnique = try CodexChatSpeed.uniqueTitle(thread: thread, database: database)
        precondition(localUnique == "Exact chat", "Remote and missing titles do not own the local composer")
        precondition(sqlite3_exec(db, "INSERT INTO local_thread_catalog(thread_id,display_title) VALUES('\(UUID().uuidString)','Exact chat');", nil, nil, nil) == SQLITE_OK)
        do { _ = try CodexChatSpeed.uniqueTitle(thread: thread, database: database); preconditionFailure("Duplicate names must be rejected") }
        catch CodexChatSpeed.Failure.ambiguousChat {}
        do { _ = try CodexChatSpeed.uniqueTitle(thread: UUID(), database: database); preconditionFailure("Missing target must be rejected") }
        catch CodexChatSpeed.Failure.wrongChat {}
        let call = VoicePeerCall(token: "\(thread):\(UUID()):123")!
        let other = VoicePeerCall(token: "\(UUID()):\(UUID()):123")!
        var opened = 0, applied = 0
        let inactive = await CodexChatSpeed.currentVoice(resolve: { .init(status: .inactive) },
            open: { _, _ in opened += 1; return true }, apply: { _ in fatalError("Inactive call cannot apply speed") })
        precondition(inactive.status == "inactive" && inactive.thread == nil && opened == 0)
        var reads = 0
        let replaced = await CodexChatSpeed.currentVoice(resolve: {
            reads += 1; return .init(status: .active, call: reads == 1 ? call : other)
        }, open: { pid, link in
            precondition(pid == 123 && link.absoluteString == "codex://threads/" + thread.uuidString.lowercased())
            opened += 1; return true
        }, apply: { _ in fatalError("Replaced call cannot apply speed") })
        precondition(replaced.status == "changed" && opened == 1)
        let active = await CodexChatSpeed.currentVoice(resolve: { .init(status: .active, call: call) },
            open: { _, _ in opened += 1; return true }, apply: { received in
                precondition(received == call); applied += 1
                return .init(status: "unchanged", thread: received.thread, speed: .ultrafast, model: "GPT-6.2 Sol High")
            })
        precondition(active.succeeded && active.thread == thread && applied == 1)
        reads = 0
        let ended = await CodexChatSpeed.currentVoice(resolve: {
            reads += 1; return reads < 3 ? .init(status: .active, call: call) : .init(status: .inactive)
        }, open: { _, _ in true }, apply: { received in
            .init(status: "confirmed", thread: received.thread, speed: .ultrafast, model: "GPT-6.2 Sol High")
        })
        precondition(ended.status == "changed" && !ended.succeeded && ended.speed == nil)
        print("Passed exact-chat speed, no-op, draft/model preservation, interrupted-action, ambiguous-title and current-Voice ownership checks.")
    }
}
