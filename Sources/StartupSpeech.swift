// H Chat's startup speech mailbox: the Voice skill reads this file instead of
// pasting into a focused chat. Only locally recognized words after the wake go
// here; consuming them leaves a receipt so a queued write cannot restore them.
// Replaces the earlier VoiceChatHandoff / WakeSpeechCapture UI-delivery path.
import Foundation
import Darwin

final class StartupSpeechFile: @unchecked Sendable {
    static let directory = AppPaths.support.appendingPathComponent("VoiceStartup", isDirectory: true)
    static let textLimit = 8_000
    enum Phase: String, Codable { case capturing, ready, consumed, cancelled }
    struct Document: Codable {
        var formatVersion = 1
        let id: UUID
        let requestedAt: Double
        var updatedAt: Double
        var phase: Phase
        var text: String
        var truncated: Bool
        var claimedBy: UUID?
    }
    struct Delivery: Codable {
        let status: String
        var request: Document? = nil
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.ethansk.HeyChat.startup-speech", qos: .utility)
    private let onError: @Sendable (Error) -> Void
    private struct PendingUpdate { let text: String; let truncated: Bool; let ready: Bool }
    private let pendingLock = NSLock()
    private var pendingUpdates: [UUID: PendingUpdate] = [:]

    init(directory: URL = StartupSpeechFile.directory, onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        root = directory; self.onError = onError
    }

    // Publish before the global Start command, so even a fast first Voice
    // handoff sees the new request. Disk failure must never prevent Voice.
    func begin(id: UUID, text: String, truncated: Bool, at date: Date = Date()) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    try locked(create: true) {
                        do {
                            try write(Document(id: id, requestedAt: date.timeIntervalSince1970,
                                updatedAt: date.timeIntervalSince1970, phase: .capturing,
                                text: String(text.prefix(Self.textLimit)), truncated: truncated))
                        } catch {
                            // A failed new publication must not leave the old
                            // call's words looking like the newest request.
                            _ = unlink(root.appendingPathComponent("pending.json").path)
                            throw error
                        }
                    }
                    continuation.resume(returning: true)
                } catch { onError(error); continuation.resume(returning: false) }
            }
        }
    }

    func update(id: UUID, text: String, truncated: Bool, ready: Bool = false) {
        // Coalesce revisions already waiting for disk. Even a slow filesystem
        // retains only the latest bounded text, rather than one closure per frame.
        pendingLock.lock()
        let enqueue = pendingUpdates[id] == nil
        let wasReady = pendingUpdates[id]?.ready ?? false
        pendingUpdates[id] = PendingUpdate(text: String(text.prefix(Self.textLimit)), truncated: truncated, ready: ready || wasReady)
        pendingLock.unlock()
        guard enqueue else { return }
        queue.async { [self] in
            pendingLock.lock()
            let update = pendingUpdates.removeValue(forKey: id)
            pendingLock.unlock()
            guard let update else { return }
            do {
                try locked(create: false) {
                    guard var value = try read(), value.id == id,
                          value.phase == .capturing else { return }
                    value.text = update.text; value.truncated = update.truncated
                    value.updatedAt = Date().timeIntervalSince1970
                    if update.ready { value.phase = .ready }
                    try write(value)
                }
            } catch { onError(error) }
        }
    }

    func cancel(id: UUID) {
        queue.async { [self] in
            do {
                try locked(create: false) {
                    guard var value = try read(), value.id == id,
                          value.phase != .consumed, value.phase != .cancelled else { return }
                    value.phase = .cancelled; value.text = ""; value.updatedAt = Date().timeIntervalSince1970
                    try write(value)
                }
            } catch { onError(error) }
        }
    }

    // Run only at a new Voice coordinator's startup. Its creation timestamp
    // rejects a mailbox left by an earlier call without deleting that evidence.
    // The window tolerates thread creation during the existing Start deadline;
    // it adds no sleep or delay. This is a local latest-start mailbox, not a
    // desktop message API or a guarantee about simultaneous manually made calls.
    func consume(voiceCreatedAt: Date, threadID: UUID, now: Date = Date()) throws -> Delivery {
        try locked(create: false) {
            guard var value = try read() else { return Delivery(status: "empty") }
            guard value.requestedAt >= voiceCreatedAt.timeIntervalSince1970 - 30,
                  value.requestedAt <= voiceCreatedAt.timeIntervalSince1970 + 2,
                  value.updatedAt <= now.timeIntervalSince1970 + 5 else { return Delivery(status: "unrelated") }
            guard value.phase == .capturing || value.phase == .ready else { return Delivery(status: "empty") }
            // An initial tool handoff can arrive before the next ASR result.
            // Leave an empty in-progress request for the first substantive one.
            if value.phase == .capturing, value.text.isEmpty { return Delivery(status: "capturing") }
            let delivered = value
            value.phase = .consumed; value.text = ""; value.claimedBy = threadID
            value.updatedAt = now.timeIntervalSince1970
            try write(value)
            return Delivery(status: delivered.text.isEmpty ? "empty" : "speech", request: delivered.text.isEmpty ? nil : delivered)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func locked<T>(create: Bool, _ body: () throws -> T) throws -> T {
        let fm = FileManager.default
        if create { try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if !fm.fileExists(atPath: root.path), !create { return try body() }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        // No lock-wait padding on the wake path. A busy mailbox is a soft
        // failure; the next recognition revision/reader can try its real work.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func read() throws -> Document? {
        let file = root.appendingPathComponent("pending.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              opened.st_size == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard value.formatVersion == 1, value.requestedAt.isFinite, value.updatedAt.isFinite,
              value.updatedAt >= value.requestedAt, value.text.count <= Self.textLimit else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private func write(_ document: Document) throws {
        let file = root.appendingPathComponent("pending.json")
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let data = try JSONEncoder().encode(document)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

// Preserve partial-transcript corrections, including joined/fuzzy wake spellings.
// Only the accepted occurrence is stripped; earlier background speech stays out.
struct StartupSpeechBuffer {
    let id: UUID
    private let phrase: String
    private let similar: Bool
    private var anchorStart: Int?
    private var baseline: [String]?
    private var completed = ""
    private var current = ""
    private(set) var published = false
    private(set) var truncated = false
    var text: String { String([completed, current].filter { !$0.isEmpty }.joined(separator: " ").prefix(StartupSpeechFile.textLimit)) }

    init(id: UUID, text: String, wakeRange: Range<Int>?, phrase: String, similar: Bool) {
        self.id = id; self.phrase = phrase; self.similar = similar
        anchorStart = wakeRange?.lowerBound
        baseline = wakeRange == nil ? PhraseMatcher.words(text) : nil
        observe(text)
    }
    mutating func markPublished() { published = true }
    mutating func boundary() { completed = text; current = ""; anchorStart = nil; baseline = nil }
    mutating func observe(_ text: String) {
        var ranges: [Range<String.Index>] = [], words: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let start = text.rangeOfCharacter(from: .alphanumerics, range: cursor..<text.endIndex)?.lowerBound {
            let end = text.rangeOfCharacter(from: .alphanumerics.inverted, range: start..<text.endIndex)?.lowerBound ?? text.endIndex
            for word in PhraseMatcher.words(String(text[start..<end])) { ranges.append(start..<end); words.append(word) }
            cursor = end
        }
        var offset = 0
        if let anchorStart {
            let lower = max(0, anchorStart - 8), upper = min(words.count, anchorStart + 12)
            guard lower < upper,
                  let match = PhraseMatcher.matches(in: Array(words[lower..<upper]), phrase: phrase, similar: similar)
                    .min(by: { abs($0.start + lower - anchorStart) < abs($1.start + lower - anchorStart) }) else { return }
            offset = match.end + lower
        } else if let baseline {
            guard words.starts(with: baseline) else { return }
            offset = baseline.count
        }
        let start = offset == 0 ? text.startIndex : (offset <= ranges.count ? ranges[offset - 1].upperBound : text.endIndex)
        let tail = text[start...].drop(while: { $0.isWhitespace || ",.!?;:".contains($0) })
        current = String(tail.prefix(StartupSpeechFile.textLimit))
        truncated = truncated || completed.count + current.count + (completed.isEmpty ? 0 : 1) > StartupSpeechFile.textLimit || tail.count > StartupSpeechFile.textLimit
    }
}
