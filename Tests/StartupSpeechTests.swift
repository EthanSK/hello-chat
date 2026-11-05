// Offline checks for the real startup buffer and cross-process mailbox contract.
// No microphone, playback, Codex UI, message injection or Voice calls are used.
import Foundation
import Darwin

@main enum StartupSpeechTests {
    static func main() async throws {
        func expect(_ value: Bool, _ message: String = "Startup speech check failed") { precondition(value, message) }
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a task-owned fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        expect(root.path.contains(".noindex"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = StartupSpeechFile(directory: fixture)
        let now = Date(), consumer = UUID()

        var capture = StartupSpeechBuffer(id: UUID(), text: "The video said hello chat. Hello chat, turn the kitchen light on?",
            wakeRange: 5..<7, phrase: "Hello Chat", similar: true)
        expect(capture.text == "turn the kitchen light on?")
        capture.observe("The video said hello chat. HelloChat, turn the kitchen lights blue.")
        expect(capture.text == "turn the kitchen lights blue.", "Joined wake corrections must not drop the first request word")
        capture.observe("The video said hello chat. Hello chat, turn the kitchen lights red.")
        expect(capture.text == "turn the kitchen lights red.", "Partial hypotheses replace instead of duplicating speech")
        capture.boundary(); capture.observe("And dim them to fifty percent.")
        expect(capture.text == "turn the kitchen lights red. And dim them to fifty percent.")

        var custom = StartupSpeechBuffer(id: UUID(), text: "Good morning computer, open the calendar.",
            wakeRange: 0..<3, phrase: "Good morning computer", similar: true)
        expect(custom.text == "open the calendar.")
        custom.observe("Good morning computer, open tomorrow's calendar.")
        expect(custom.text == "open tomorrow's calendar.")
        var manual = StartupSpeechBuffer(id: UUID(), text: "Earlier conversation", wakeRange: nil, phrase: "Hello Chat", similar: true)
        manual.observe("Earlier conversation What time is it?")
        expect(manual.text == "What time is it?")
        manual.boundary(); manual.observe(String(repeating: "🎵", count: 9_000))
        expect(manual.text.count == StartupSpeechFile.textLimit && manual.truncated)

        let first = UUID()
        expect(await store.begin(id: first, text: "", truncated: false, at: now))
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "capturing")
        store.update(id: first, text: "RequestPrefix: switch on the lamp.", truncated: false, ready: true)
        await store.flush()
        let delivery = try store.consume(voiceCreatedAt: now, threadID: consumer)
        expect(delivery.status == "speech" && delivery.request?.text == "RequestPrefix: switch on the lamp.")
        let pending = fixture.appendingPathComponent("pending.json")
        let receipt = try JSONDecoder().decode(StartupSpeechFile.Document.self, from: Data(contentsOf: pending))
        expect(receipt.phase == .consumed && receipt.text.isEmpty && receipt.claimedBy == consumer)
        let permissions = try FileManager.default.attributesOfItem(atPath: pending.path)[.posixPermissions] as! NSNumber
        expect(permissions.intValue == 0o600)
        store.update(id: first, text: "Late ASR result must never reappear", truncated: false, ready: true)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: UUID()).status == "empty")

        let second = UUID()
        expect(await store.begin(id: second, text: "The next request", truncated: false, at: now))
        store.update(id: first, text: "Old writer", truncated: false, ready: true); store.cancel(id: first)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now.addingTimeInterval(60), threadID: UUID()).status == "unrelated")
        // The same original coordinator can consume later; no arbitrary expiry
        // deletes a request which the user wanted retained until it is read.
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer, now: now.addingTimeInterval(3600)).request?.id == second)

        let cancelled = UUID()
        expect(await store.begin(id: cancelled, text: "Cancelled request", truncated: false, at: now))
        store.cancel(id: cancelled); store.update(id: cancelled, text: "Late cancel result", truncated: false)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "empty")

        let racing = UUID()
        expect(await store.begin(id: racing, text: "Read once", truncated: false, at: now))
        let contenders = (0..<2).map { _ in Task.detached { try? store.consume(voiceCreatedAt: now, threadID: UUID()).status } }
        var winners = 0
        for contender in contenders { if await contender.value == "speech" { winners += 1 } }
        expect(winners == 1, "Concurrent consumers must deliver once")

        expect(await store.begin(id: UUID(), text: "Locked request", truncated: false, at: now))
        let lock = open(fixture.appendingPathComponent(".lock").path, O_RDWR)
        expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Busy lock was ignored") }
        catch { expect((error as NSError).code == Int(EWOULDBLOCK)) }
        flock(lock, LOCK_UN); close(lock)
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "speech")

        func reject(_ data: Data) throws {
            try data.write(to: pending)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Malformed mailbox accepted") }
            catch { expect(error is CocoaError || error is DecodingError) }
        }
        try reject(Data("{broken".utf8))
        try reject(Data(repeating: 65, count: 65_537))
        try FileManager.default.removeItem(at: pending)
        let outside = root.appendingPathComponent("outside-\(UUID().uuidString).json")
        try Data("private outside content".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: outside)
        do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Symlink accepted") }
        catch { expect(error is CocoaError) }
        expect(try String(contentsOf: outside, encoding: .utf8) == "private outside content")
        print("Startup speech: revision, custom wake, boundaries, bounded text, read-once, overwrite, cancellation, stale-call, lock and malformed-file checks passed")
    }
}
