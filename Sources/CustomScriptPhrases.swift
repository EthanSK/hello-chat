import Foundation
import Darwin

struct CustomScriptPhrases {
    struct Command: Codable, Equatable {
        let name: String
        let phrases: [String]
        let executable: String
        let arguments: [String]?
        let workingDirectory: String?
    }

    static let file = AppPaths.support.appendingPathComponent("CustomPhrases.json")
    private let commands: [String: Command]
    let entries: [Command]
    var count: Int { entries.count }

    init(data: Data = Data("[]".utf8)) throws {
        try self.init(entries: JSONDecoder().decode([Command].self, from: data))
    }

    init(entries: [Command]) throws {
        var commands: [String: Command] = [:]
        for entry in entries {
            let keys = Set(entry.phrases.map(PhraseList.key))
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !keys.isEmpty, !keys.contains(""), entry.executable.hasPrefix("/"),
                  entry.workingDirectory?.hasPrefix("/") != false else { throw ConfigError.invalidEntry }
            for key in keys {
                guard commands[key] == nil else { throw ConfigError.duplicatePhrase }
                commands[key] = entry
            }
        }
        self.commands = commands
        self.entries = entries
    }

    func command(for utterance: String) -> Command? {
        commands[PhraseList.key(utterance)]
    }

    static func load(from file: URL = file) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return try .init() }
        return try .init(data: Data(contentsOf: file))
    }

    // An editor may be open while the JSON file is changed or reloaded elsewhere.
    // Keep the old file intact if its current entries differ or fail to decode.
    func save(replacing expected: [Command], to file: URL = file) throws {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".custom-phrases-\(UUID().uuidString)")
        let manager = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entries) + Data([0x0a])
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        guard try Self.load(from: file).entries == expected else { throw ConfigError.changed }
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func openableFile() throws -> URL {
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[]\n".utf8).write(to: file, options: .withoutOverwriting)
        }
        return file
    }

    enum ConfigError: LocalizedError {
        case invalidEntry, duplicatePhrase, changed
        var errorDescription: String? {
            switch self {
            case .invalidEntry: return "Give each command a name, a phrase and a full executable path."
            case .duplicatePhrase: return "Two custom commands use the same phrase."
            case .changed: return "Custom commands changed while you were editing. Close this editor and try again."
            }
        }
    }
}

extension CustomScriptPhrases.Command {
    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments ?? []
        process.currentDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        return process
    }
}

struct CustomSpeechFinals {
    private var lastEnd = -Double.infinity

    // Apple final results may be repeated or revised for the same span. Only a new span can run a script. — GPT-6.2 Sol
    mutating func accept(start: Double, end: Double) -> Bool {
        guard start.isFinite, end.isFinite, end > start, start + 1e-6 >= lastEnd else { return false }
        lastEnd = end
        return true
    }
}

struct CustomCommandUtterance: Equatable {
    let text: String
    let wordRange: Range<Int>

    init(_ text: String, wordRange: Range<Int>? = nil) {
        self.text = text
        self.wordRange = wordRange ?? 0..<PhraseMatcher.words(text).count
    }
}

struct TimedCustomSpeech {
    // Nemotron emits word spans on an encoder clock. Live-style fixtures put
    // up to 640 ms between the two words of one command. Punctuation can still
    // close the sentence when it shares a frame with the first following word.
    private static let groupGap = 0.72
    private struct Segment {
        let utterance: CustomCommandUtterance?
        let start: Double
        let end: Double
    }

    private var pending: [Segment] = []
    private var finals = CustomSpeechFinals()
    private var hasTimings = false
    private var usedFallback = false
    private var emittedMatch = false

    // Nemotron's token clock can identify a pause when room noise prevents the
    // microphone from going quiet. Keep the same standalone pause and require real spans. — GPT-6.2 Sol
    mutating func update(_ text: String, timings: [(word: String, start: Double, end: Double)]?) {
        let words = PhraseMatcher.words(text)
        let range = words.indices
        guard let timings, timings.map(\.word) == words,
              DesktopSpeechBoundaries.hasAudioSpans(timings, in: range) else {
            pending.removeAll()
            return
        }
        hasTimings = true
        var context = StandaloneWake()
        context.update(text, at: 0, timings: timings)
        let audioBoundaries = DesktopSpeechBoundaries.indices(words: words, timings: timings, gap: Self.groupGap)
        let boundaries = Set([0, words.count] + audioBoundaries + context.sentenceStarts).sorted()
        pending = zip(boundaries, boundaries.dropFirst()).map { start, end in
            let spans = timings[start..<end]
            let lead = words.prefix(start)
            let negated = lead.last.map(["no", "not", "never", "dont"].contains) == true
                || lead.suffix(2).elementsEqual(["don", "t"])
            // A hesitation in a reference is shorter than a new utterance.
            let leftReference = start > 0 && timings[start].start - timings[start - 1].end < SpeechOnset.pauseSeconds
                && ["say", "said", "saying", "called", "named", "mention", "mentioned",
                    "example", "phrase", "word", "words", "spelling", "the", "your", "my"].contains(words[start - 1])
            let rightReference = end < words.count && timings[end].start - timings[end - 1].end < SpeechOnset.pauseSeconds
                && (["phrase", "command", "spelling", "is", "was", "works", "worked", "should"].contains(words[end])
                    || words[end - 1] == "but"
                    || (words[end - 1] == "both" && words[end] == "times"))
            let direct = context.permitsDirectCommand(in: start..<end)
                && !negated && !leftReference && !rightReference
                && !DesktopSpeechBoundaries.introducesQuotation(words: words, before: start, sentences: [])
            let utterance = direct ? CustomCommandUtterance(words[start..<end].joined(separator: " "), wordRange: start..<end) : nil
            return Segment(utterance: utterance,
                           start: spans.first!.start, end: spans.map(\.end).max()!)
        }
    }

    mutating func completed(through decodedTime: Double, quietFinals: [CustomCommandUtterance],
                            matches: (String) -> Bool = { _ in true }) -> [CustomCommandUtterance] {
        guard !usedFallback else { return [] }
        // The recognizer's quiet final can contain one exact command even when the
        // token clock split its words. Never re-run a previously emitted
        // matching group from the same recognition context.
        if !emittedMatch, let exact = quietFinals.first(where: { matches($0.text) }) {
            var context = StandaloneWake()
            context.update(exact.text, at: 0)
            let wordCount = PhraseMatcher.words(exact.text).count
            if !context.sentenceStarts.contains(where: { $0 > 0 && $0 < wordCount }) {
                usedFallback = true
                return [exact]
            }
        }
        if !hasTimings {
            usedFallback = !quietFinals.isEmpty
            return []
        }
        var outputs: [CustomCommandUtterance] = []
        while let first = pending.first,
              !quietFinals.isEmpty || decodedTime - first.end + 1e-9 >= SpeechOnset.pauseSeconds {
            pending.removeFirst()
            if let utterance = first.utterance, matches(utterance.text),
               finals.accept(start: first.start, end: first.end) {
                emittedMatch = true
                outputs.append(utterance)
            }
        }
        return outputs
    }
}
