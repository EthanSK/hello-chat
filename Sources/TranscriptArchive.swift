import Foundation

// One bounded recognizer context per JSON document. Atomic replacements retain
// corrected text instead of appending every overlapping partial hypothesis.
final class TranscriptArchive: @unchecked Sendable {
    static let directory = AppPaths.support.appendingPathComponent("Transcripts", isDirectory: true)
    struct Phrase: Codable {
        var firstHeardAt: Date
        var lastUpdatedAt: Date
        var text: String
        var wordOffset: Int
    }
    struct Document: Codable {
        var formatVersion = 1
        let id: UUID
        let startedAt: Date
        var updatedAt: Date
        var endedAt: Date?
        let model: String
        let microphone: String
        var timing = "Approximate recognition times, not word-aligned audio times"
        var source = "Local microphone recognition; speaker identity is unknown; may include background speech"
        var text: String
        var phrases: [Phrase]
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.ethansk.HeyChat.transcripts", qos: .utility)
    private var document: Document?
    private var pending: DispatchWorkItem?
    private var currentURL: URL?
    private let onError: @Sendable (Error) -> Void
    init(directory: URL = TranscriptArchive.directory, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        root = directory; self.onError = onError
    }
    func update(_ text: String, model: String, microphone: String, at date: Date = Date()) {
        queue.async { [self] in
            guard document?.text != text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if document == nil {
                let id = UUID()
                document = Document(id: id, startedAt: date, updatedAt: date, model: model, microphone: microphone, text: "", phrases: [])
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
                currentURL = root.appendingPathComponent(formatter.string(from: date), isDirectory: true).appendingPathComponent("\(id.uuidString).json")
            }
            guard var value = document else { return }
            let old = value.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let new = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let common = zip(old, new).prefix { $0 == $1 }.count
            // Keep earlier phrase timings when the decoder revises its tail.
            // Remove obsolete phrases and replace only the affected suffix.
            let revised = value.phrases.firstIndex { $0.wordOffset >= common }
            let index = max(0, (revised ?? value.phrases.count) - (common < old.count ? 1 : 0))
            if common < old.count, !value.phrases.isEmpty {
                value.phrases = Array(value.phrases.prefix(index + 1))
            }
            if var last = value.phrases.last {
                if common == old.count, date.timeIntervalSince(value.updatedAt) >= 1.2, new.count > old.count {
                    value.phrases.append(Phrase(firstHeardAt: date, lastUpdatedAt: date, text: new.dropFirst(old.count).joined(separator: " "), wordOffset: old.count))
                } else {
                    last.text = new.dropFirst(min(last.wordOffset, new.count)).joined(separator: " ")
                    last.lastUpdatedAt = date; value.phrases[value.phrases.count - 1] = last
                }
            } else { value.phrases = [Phrase(firstHeardAt: date, lastUpdatedAt: date, text: text, wordOffset: 0)] }
            value.text = text; value.updatedAt = date; document = value
            // Throttle, not debounce: continuous speech must reach disk too.
            if pending == nil {
                let item = DispatchWorkItem { [weak self] in self?.pending = nil; self?.save() }
                pending = item; queue.asyncAfter(deadline: .now() + 1, execute: item)
            }
        }
    }
    func boundary(at date: Date = Date()) {
        queue.async { [self] in
            pending?.cancel(); pending = nil
            if document != nil { document?.endedAt = date; save() }
            document = nil; currentURL = nil
        }
    }
    // Used on orderly shutdown, never for live per-frame/UI updates.
    func flush() { queue.sync { pending?.cancel(); pending = nil; save() } }
    private func save() {
        guard let document, let url = currentURL else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            // .completeFileProtection isn't a macOS privacy control. Create a
            // private temporary file before the rename, with no public window.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? fm.removeItem(at: temporary) }
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: url) }
        } catch { onError(error) }
    }
}
