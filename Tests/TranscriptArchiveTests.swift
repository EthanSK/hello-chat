import Foundation

@main enum TranscriptArchiveTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeyChatArchiveTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = TranscriptArchive(directory: directory)
        let date = Date(timeIntervalSince1970: 1_792_300_000)
        archive.update("Hello", model: "test", microphone: "test", at: date)
        archive.update("Hello Chad", model: "test", microphone: "test", at: date.addingTimeInterval(0.2))
        archive.update("Hello Chat", model: "test", microphone: "test", at: date.addingTimeInterval(0.4))
        archive.update("Hello Chat another phrase", model: "test", microphone: "test", at: date.addingTimeInterval(3))
        archive.flush()
        func files() -> [URL] {
            (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
        }
        precondition(files().count == 1, "Partial updates must replace one document, not duplicate every hypothesis")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var value = try decoder.decode(TranscriptArchive.Document.self, from: Data(contentsOf: files()[0]))
        precondition(value.text == "Hello Chat another phrase" && value.phrases.count == 2)
        precondition(value.phrases.map(\.text) == ["Hello Chat", "another phrase"], "Paused phrases retain distinct rough timestamps")
        precondition(value.phrases[0].firstHeardAt == date)
        archive.update("Hello Chat another corrected phrase", model: "test", microphone: "test", at: date.addingTimeInterval(3.2))
        archive.boundary(at: date.addingTimeInterval(4)); archive.flush()
        value = try decoder.decode(TranscriptArchive.Document.self, from: Data(contentsOf: files()[0]))
        precondition(value.phrases.map(\.text).joined(separator: " ") == value.text, "Revised text and phrase timeline cannot diverge")
        precondition(value.endedAt == date.addingTimeInterval(4))
        let permission = try FileManager.default.attributesOfItem(atPath: files()[0].path)[.posixPermissions] as? NSNumber
        precondition(permission?.intValue == 0o600)
        archive.update("next context", model: "other", microphone: "test", at: date.addingTimeInterval(86_400))
        archive.flush()
        precondition(files().count == 2, "Context and day boundaries preserve the earlier file")
        // Throttling must persist continuous updates before an explicit stop.
        let automatic = TranscriptArchive(directory: directory.appendingPathComponent("automatic"))
        automatic.update("ongoing speech", model: "test", microphone: "test", at: date)
        Thread.sleep(forTimeInterval: 1.2)
        precondition(files().count == 3, "Continuous speech is saved without waiting for silence or shutdown")
        print("Transcript archive: revision, phrase timing, finalization, day boundary, permissions and timed persistence passed")
    }
}
