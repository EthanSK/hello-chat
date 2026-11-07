// H Chat's startup speech mailbox: the Voice skill reads this file instead of
// pasting into a focused chat. Only locally recognized words after the wake go
// here; consuming them leaves a receipt so a queued write cannot restore them.
// Replaces the earlier VoiceChatHandoff / WakeSpeechCapture UI-delivery path.
import Foundation
import Darwin
import CryptoKit

// Install only our namespaced skill. The signed app's VoiceStartup.md remains
// canonical; a receipt lets app updates distinguish our copy from user edits.
enum StartupSpeechSkillInstaller {
    static let name = "hello-chat-voice-startup"
    enum Result: String { case installed, updated, unchanged, conflict }
    private struct Receipt: Codable {
        let owner: String
        let formatVersion: Int
        let sha256: String
    }
    private static let owner = "com.ethansk.HeyChat.voice-startup"

    static func installBundled() throws -> Result {
        guard let source = Bundle.main.url(forResource: "VoiceStartup", withExtension: "md") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let codexHome = configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return try install(contract: source, skills: codexHome.appendingPathComponent("skills", isDirectory: true))
    }

    static func install(contract: URL, skills: URL) throws -> Result {
        let fm = FileManager.default
        let content = try Data(contentsOf: contract)
        guard content.count <= 65_536,
              String(decoding: content, as: UTF8.self).hasPrefix("---\nname: \(name)\n") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fm.createDirectory(at: skills, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isOwnedDirectory(skills) else { return .conflict }
        let destination = skills.appendingPathComponent(name, isDirectory: true)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let receiptData = try JSONEncoder().encode(Receipt(owner: owner, formatVersion: 1, sha256: digest))
        var info = stat()
        if lstat(destination.path, &info) != 0 {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            // Publish both files together; never claim an existing directory.
            let staging = skills.appendingPathComponent(".\(name)-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            try write(content, to: staging.appendingPathComponent("SKILL.md"))
            try write(receiptData, to: staging.appendingPathComponent(".hellochat-owner.json"))
            try fm.moveItem(at: staging, to: destination)
            return .installed
        }
        guard isOwnedDirectory(destination) else { return .conflict }
        let skill = destination.appendingPathComponent("SKILL.md")
        let receipt = destination.appendingPathComponent(".hellochat-owner.json")
        guard let existing = try ownedFile(skill), let metadata = try ownedFile(receipt),
              let record = try? JSONDecoder().decode(Receipt.self, from: metadata),
              record.owner == owner, record.formatVersion == 1 else { return .conflict }
        let currentDigest = SHA256.hash(data: existing).map { String(format: "%02x", $0) }.joined()
        // A failed receipt write after replacement is recoverable on the next
        // launch. A user's different edit must remain untouched.
        guard currentDigest == record.sha256 || existing == content else { return .conflict }
        if existing == content {
            if record.sha256 != digest { try write(receiptData, to: receipt) }
            return .unchanged
        }
        try write(content, to: skill)
        try write(receiptData, to: receipt)
        return .updated
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
    private static func ownedFile(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 65_536 else { return nil }
        return try Data(contentsOf: url)
    }
    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class StartupSpeechFile: @unchecked Sendable {
    static let directory = AppPaths.support.appendingPathComponent("VoiceStartup", isDirectory: true)
    static let textLimit = 8_000
    // A live capture finishes long before this: Start confirmation (15 s)
    // plus the post-open limit below. A request still `capturing` this long
    // after it was published may have lost its producer to a stop or crash;
    // the reader finalises that stale prefix once instead of leaving it open.
    static let abandonedAfter = 120.0
    enum Phase: String, Codable { case capturing, ready, consumed, cancelled }
    // A recognizer utterance boundary is stronger than text merely staying
    // unchanged. A pause, limit or interruption may leave an unfinished prefix.
    enum Boundary: String, Codable, CaseIterable {
        case utterance, pause, limit, interrupted
        var mayBeIncomplete: Bool { self != .utterance }
    }
    struct Document: Codable {
        var formatVersion = 1
        let id: UUID
        let requestedAt: Double
        var updatedAt: Double
        var phase: Phase
        var text: String
        var truncated: Bool
        var claimedBy: UUID?
        // Optional additions keep format 1: 1.0.6 documents still decode, and
        // 1.0.6 readers ignore these keys. `revision` changes with the text.
        var revision: Int? = nil
        var boundary: Boundary? = nil
    }
    struct Delivery: Codable {
        let status: String
        var request: Document? = nil
    }
    private let root: URL
    private let queue = DispatchQueue(label: "com.ethansk.HeyChat.startup-speech", qos: .utility)
    private let onError: @Sendable (Error) -> Void
    // A boundary marks the final, ready revision.
    private struct PendingUpdate { let text: String; let truncated: Bool; let boundary: Boundary? }
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
                                text: String(text.prefix(Self.textLimit)), truncated: truncated, revision: 0))
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

    // A non-nil boundary publishes the final revision as ready.
    func update(id: UUID, text: String, truncated: Bool, boundary: Boundary? = nil) {
        // Coalesce revisions already waiting for disk. Even a slow filesystem
        // retains only the latest bounded text, rather than one closure per frame.
        pendingLock.lock()
        let previous = pendingUpdates[id]
        pendingUpdates[id] = PendingUpdate(text: String(text.prefix(Self.textLimit)), truncated: truncated,
                                           boundary: boundary ?? previous?.boundary)
        pendingLock.unlock()
        guard previous == nil else { return }
        queue.async { [self] in
            pendingLock.lock()
            let update = pendingUpdates.removeValue(forKey: id)
            pendingLock.unlock()
            guard let update else { return }
            do {
                try locked(create: false, waitForReader: true) {
                    guard var value = try read(), value.id == id,
                          value.phase == .capturing else { return }
                    // Even stable text can be a mid-sentence pause or delayed
                    // recognition. Never report that cutoff as a full utterance.
                    let truncated = update.truncated || update.boundary?.mayBeIncomplete == true
                    let textChanged = value.text != update.text
                    let changed = textChanged || value.truncated != truncated
                    // Provisional readers compare revisions; skip no-op writes.
                    guard changed || update.boundary != nil else { return }
                    if changed {
                        value.text = update.text; value.truncated = truncated
                        if textChanged { value.revision = (value.revision ?? 0) &+ 1 }
                    }
                    value.updatedAt = max(Date().timeIntervalSince1970, value.requestedAt)
                    if let boundary = update.boundary { value.phase = .ready; value.boundary = boundary }
                    try write(value)
                }
            } catch { onError(error) }
        }
    }

    func cancel(id: UUID) {
        queue.async { [self] in
            do {
                try locked(create: false, waitForReader: true) {
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
            // The first matching coordinator to read owns this request, so a
            // second coordinator can't act on the same provisional words.
            if let owner = value.claimedBy, owner != threadID { return Delivery(status: "claimed") }
            let abandoned = value.phase == .capturing && now.timeIntervalSince1970 - value.requestedAt > Self.abandonedAfter
            if value.phase == .capturing && !abandoned {
                // Ethan (7 Nov): make the opening words available while they're
                // still being recognised. A nonempty hypothesis can still be
                // just "this is a", so this snapshot is labelled `capturing` and
                // never consumed; the final read must still see the whole request.
                if value.claimedBy == nil { value.claimedBy = threadID; try write(value) }
                return Delivery(status: "capturing", request: value.text.isEmpty ? nil : value)
            }
            var delivered = value
            if abandoned { delivered.phase = .ready; delivered.boundary = .interrupted; delivered.truncated = true }
            value.phase = .consumed; value.text = ""; value.claimedBy = threadID
            value.updatedAt = max(now.timeIntervalSince1970, value.updatedAt)
            try write(value)
            return Delivery(status: delivered.text.isEmpty ? "empty" : "speech", request: delivered.text.isEmpty ? nil : delivered)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func locked<T>(create: Bool, waitForReader: Bool = false, _ body: () throws -> T) throws -> T {
        let fm = FileManager.default
        if create { try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if !fm.fileExists(atPath: root.path), !create { return try body() }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        // Start and reads remain nonblocking. Queued background writes must
        // finish after a brief reader, especially the last ready/cancel update
        // which has no later recognition revision to retry it. This waits on
        // actual file work, not a timer, and never holds the main actor.
        guard flock(descriptor, LOCK_EX | (waitForReader ? 0 : LOCK_NB)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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
    // On 7 Nov no recognizer pause was reported; the exact sound level wasn't
    // retained. The opening stayed `capturing` for 96 s until the
    // 120 s context rollover and absorbed the assistant's replies. These
    // startup-only bounds count processed audio after Voice opened, so connection
    // alone never ends capture (that earlier cutoff lost words).
    // A pause is 2 s without a change in recognised opening text: the same
    // length as Nemotron's existing quiet-room utterance end
    // (`SpeechOnset.pauseSeconds`), but sound without words can't extend it.
    static let pauseSeconds = 2.0
    // Continuous recognised sound (a long request, TV, assistant playback
    // without a 2 s gap) stops here and is marked truncated. By then Voice's
    // own microphone is normally live, so later words reach it natively.
    static let openLimitSeconds = 30.0
    let id: UUID
    private let phrase: String
    private let similar: Bool
    private var anchorStart: Int?
    private var baseline: [String]?
    private var completed = ""
    private var current = ""
    private(set) var published = false
    private(set) var truncated = false
    private(set) var voiceOpened = false
    private var utteranceEnded = false
    private var unchangedSeconds = 0.0
    private(set) var openSeconds = 0.0
    var text: String { String([completed, current].filter { !$0.isEmpty }.joined(separator: " ").prefix(StartupSpeechFile.textLimit)) }

    init(id: UUID, text: String, wakeRange: Range<Int>?, phrase: String, similar: Bool) {
        self.id = id; self.phrase = phrase; self.similar = similar
        anchorStart = wakeRange?.lowerBound
        baseline = wakeRange == nil ? PhraseMatcher.words(text) : nil
        observe(text)
    }
    mutating func markPublished() { published = true }
    // Native connection is not an ASR completion signal. Either event may
    // arrive first; publish ready only once both have happened.
    mutating func markVoiceOpened() -> Bool { voiceOpened = true; return utteranceEnded }
    mutating func markUtteranceEnded() -> Bool { utteranceEnded = true; return voiceOpened }
    mutating func speechResumed() { utteranceEnded = false }
    mutating func boundary() { completed = text; current = ""; anchorStart = nil; baseline = nil }
    // Called once per processed audio frame, before that frame's text.
    mutating func audioProcessed(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        unchangedSeconds += seconds
        if voiceOpened { openSeconds += seconds }
    }
    // Startup-only end of capture, checked after each frame's text. The pause
    // must be after Voice opened and after some opening words arrived. Silence
    // before the first result must not discard delayed speech. The hard limit
    // still bounds an empty capture.
    var boundaryReached: StartupSpeechFile.Boundary? {
        guard voiceOpened else { return nil }
        if (!completed.isEmpty || !current.isEmpty), min(unchangedSeconds, openSeconds) >= Self.pauseSeconds { return .pause }
        if openSeconds >= Self.openLimitSeconds { return .limit }
        return nil
    }
    mutating func observe(_ text: String) {
        var ranges: [Range<String.Index>] = [], words: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let start = text.rangeOfCharacter(from: .alphanumerics, range: cursor..<text.endIndex)?.lowerBound {
            let end = text.rangeOfCharacter(from: .alphanumerics.inverted, range: start..<text.endIndex)?.lowerBound ?? text.endIndex
            for word in PhraseMatcher.words(String(text[start..<end])) { ranges.append(start..<end); words.append(word) }
            cursor = end
        }
        var offset = 0
        // A revision that can't be aligned is still recognizer activity: never
        // call it a pause while the HUD keeps changing. The limit still applies.
        if let anchorStart {
            let lower = max(0, anchorStart - 8), upper = min(words.count, anchorStart + 12)
            guard lower < upper,
                  let match = PhraseMatcher.matches(in: Array(words[lower..<upper]), phrase: phrase, similar: similar)
                    .min(by: { abs($0.start + lower - anchorStart) < abs($1.start + lower - anchorStart) }) else { unchangedSeconds = 0; return }
            offset = match.end + lower
        } else if let baseline {
            guard words.starts(with: baseline) else { unchangedSeconds = 0; return }
            offset = baseline.count
        }
        let start = offset == 0 ? text.startIndex : (offset <= ranges.count ? ranges[offset - 1].upperBound : text.endIndex)
        let tail = text[start...].drop(while: { $0.isWhitespace || ",.!?;:".contains($0) })
        if current != String(tail.prefix(StartupSpeechFile.textLimit)) { utteranceEnded = false; unchangedSeconds = 0 }
        current = String(tail.prefix(StartupSpeechFile.textLimit))
        truncated = truncated || completed.count + current.count + (completed.isEmpty ? 0 : 1) > StartupSpeechFile.textLimit || tail.count > StartupSpeechFile.textLimit
    }
}
