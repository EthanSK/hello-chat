// Hand the words said after a wake to the new Codex Voice chat.
import AppKit
import Foundation
import SQLite3

// Ethan's 5 Nov request: send "the text ... that happened between the trigger
// phrase and now", with "some overlap" being fine. Local recognition restarts
// its text at most pauses, so finished pieces are kept and later pieces are
// added whole. Only the piece holding the accepted wake is cut after it.
struct WakeSpeechCapture {
    private let phrase: String
    private let similar: Bool
    private var finished: [String] = []
    private var current = ""
    private var wakeOccurrence: Int? // The accepted wake's match in the current piece; nil once recognition restarts.

    init(text: String, phrase: String, similar: Bool) {
        self.phrase = phrase; self.similar = similar
        // The accepted wake is the newest match at detection. Later repeats in
        // the same piece stay in the text instead of moving the cut.
        wakeOccurrence = max(Self.phraseEnds(in: text, phrase: phrase, similar: similar).count - 1, 0)
        update(text)
    }

    /// Replaces the current recognition piece with its latest revision.
    mutating func update(_ text: String) {
        guard let wakeOccurrence else { current = text; return }
        let ends = Self.phraseEnds(in: text, phrase: phrase, similar: similar)
        // A revision can drop the matched words. Keep the whole piece then, since overlap is fine.
        current = wakeOccurrence < ends.count ? String(text[ends[wakeOccurrence]...]) : text
    }

    /// Keeps the current piece when recognition starts a new one.
    mutating func boundary() {
        if !current.isEmpty { finished.append(current) }
        current = ""; wakeOccurrence = nil
    }

    /// Everything heard after the wake phrase so far, without leading punctuation.
    var text: String {
        (finished + [current]).map { piece in
            String(piece.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) })
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Reuse the Heard panel's phrase spans, so the cut matches the highlighted wake.
    private static func phraseEnds(in text: String, phrase: String, similar: Bool) -> [String.Index] {
        var index = text.startIndex, ends: [String.Index] = []
        for run in PhraseHighlights.runs(in: text, phrase: phrase, similar: similar, limit: text.count) {
            index = text.index(index, offsetBy: run.text.count)
            if run.kind != nil { ends.append(index) }
        }
        return ends
    }
}

// Ethan's 5 Nov "activate Codex. Go to the chat that you just created ... and
// send it". Codex's own codex://threads/<id>?prompt= link opens that chat,
// fills its message box and focuses it, so the clipboard is never touched.
// Rejected: pasting with Command-V like Agent Flow; the link needs no clipboard lease.
@MainActor struct VoiceChatHandoff {
    enum Outcome: String { case noChat = "no_chat", opened, sent, unconfirmed }
    struct Transport {
        var newVoiceChat: (Date) async -> String?
        var open: (URL) async throws -> Void
        var composerHolds: (String) async -> Bool
        var pressReturn: () async throws -> Void
        var now: () -> Date = Date.init
        var wait: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        static var live: Self {
            Self(newVoiceChat: { since in await Task.detached(priority: .utility) { VoiceChatHandoff.newestVoiceChat(since: since) }.value },
                 open: { url in
                    guard let bundle = VoiceBridge.currentApplication()?.bundleURL else { throw BridgeError.message("Open Codex, then try again.") }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration)
                 },
                 composerHolds: { text in await Task.detached(priority: .userInitiated) { VoiceBridge.focusedComposerHolds(text) }.value },
                 pressReturn: { try await Task.detached(priority: .userInitiated) { try VoiceBridge.pressComposerReturn() }.value })
        }
    }
    private let transport: Transport
    private let lookupTimeout: TimeInterval
    private let composerTimeout: TimeInterval

    // Codex created its Voice chat about a second after the call connected on 5 Nov.
    init(transport: Transport = .live, lookupTimeout: TimeInterval = 8, composerTimeout: TimeInterval = 3) {
        self.transport = transport; self.lookupTimeout = lookupTimeout; self.composerTimeout = composerTimeout
    }

    /// Opens the Voice chat created after `startedAt` and sends `words()`, read once the chat exists.
    func run(startedAt: Date, words: () -> String) async throws -> Outcome {
        let lookupDeadline = transport.now().addingTimeInterval(lookupTimeout)
        var chat = await transport.newVoiceChat(startedAt.addingTimeInterval(-1))
        while chat == nil {
            guard transport.now() < lookupDeadline else { return .noChat }
            try await transport.wait(0.25)
            chat = await transport.newVoiceChat(startedAt.addingTimeInterval(-1))
        }
        let text = words()
        guard let chat, let url = Self.url(chat: chat, prompt: text) else { return .noChat }
        try Task.checkCancellation()
        try await transport.open(url)
        guard !text.isEmpty else { return .opened }
        // Return goes to whatever is focused. Send only when the focused Codex
        // message box holds these words, so another chat's draft is never sent.
        let composerDeadline = transport.now().addingTimeInterval(composerTimeout)
        while !(await transport.composerHolds(text)) {
            guard transport.now() < composerDeadline else { return .unconfirmed }
            try await transport.wait(0.15)
        }
        try Task.checkCancellation() // Bye Chat or a newer wake may have cancelled during the wait.
        try await transport.pressReturn()
        return .sent
    }

    /// Builds Codex's link that opens `chat` with `prompt` in its message box.
    static func url(chat: String, prompt: String) -> URL? {
        guard let id = UUID(uuidString: chat) else { return nil }
        var components = URLComponents()
        components.scheme = "codex"; components.host = "threads"; components.path = "/" + id.uuidString.lowercased()
        // Codex reads this with URLSearchParams, which turns a bare + into a space.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))
        if !prompt.isEmpty, let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed) {
            components.percentEncodedQuery = "prompt=" + encoded
        }
        return components.url
    }

    // Read-only lookup in Codex's local thread list. Codex marks Voice-created
    // chats with thread_source voice_chat. The file name carries a schema
    // version (state_5.sqlite on 5 Nov), so the newest version is used.
    nonisolated static func newestVoiceChat(since: Date) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let version = names.compactMap({ name -> Int? in
                  guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
                  return Int(name.dropFirst(6).dropLast(7))
              }).max() else { return nil }
        var database: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_open_v2(folder.appendingPathComponent("state_\(version).sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(database, 200)
        let query = "SELECT id FROM threads WHERE thread_source = 'voice_chat' AND created_at_ms >= ? ORDER BY created_at_ms DESC LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        guard sqlite3_step(statement) == SQLITE_ROW, let id = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: id)
    }
}
