import Foundation

// Fixed-phrase commands outside Voice (browser video, zoom) share these rules: one occurrence
// counter per command, mention/negation rejection, and consumption independent of the action.
struct CommandPhraseDetectors<Command: CaseIterable & Hashable> {
    private var detectors = Dictionary(uniqueKeysWithValues: Command.allCases.map { ($0, StandaloneWake()) })
    mutating func reset() { for command in Command.allCases { detectors[command] = StandaloneWake() } }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        for command in Command.allCases { detectors[command, default: StandaloneWake()].audio(level: level, seconds: seconds, at: time) }
    }
    mutating func update(_ text: String, at time: Double, timings: [(word: String, start: Double, end: Double)]? = nil) {
        for command in Command.allCases { detectors[command, default: StandaloneWake()].update(text, at: time, timings: timings) }
    }
    // End wins over these commands in the same transcript, as it does over audio commands.
    mutating func cancelPending(patterns: [Command: PhrasePattern], endPattern: PhrasePattern) {
        for (command, pattern) in patterns where !PhraseMatcher.words(pattern.text).isEmpty {
            detectors[command, default: StandaloneWake()].cancelPending(patterns: [pattern], endPattern: endPattern)
        }
    }
    // Accepted commands in spoken order. Each occurrence is consumed once.
    mutating func poll(at time: Double, patterns: [Command: PhrasePattern], directOnly: Bool = false) -> [(command: Command, range: Range<Int>)] {
        Command.allCases.compactMap { command -> (command: Command, range: Range<Int>)? in
            guard let pattern = patterns[command], !PhraseMatcher.words(pattern.text).isEmpty,
                  detectors[command, default: StandaloneWake()].poll(at: time, phrase: pattern.text, similar: pattern.similar,
                      rejectNegated: true, ending: pattern.ending, patterns: [pattern], directOnly: directOnly),
                  let range = detectors[command]?.acceptedRange else { return nil }
            return (command, range)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    // Directional commands are idempotent, so the last one spoken decides the final state.
    static func admitted(_ accepted: [(command: Command, range: Range<Int>)]) -> Command? { accepted.last?.command }
}

// Ethan temporarily disabled the command pause on 8 November 2026 to try
// immediate recognition. Keep the former timing path available for a requested
// reversal, without changing the model's own utterance/reset timing.
struct StandaloneWake {
    static let commandPauseSeconds = 0.0
    private let requiredPause: TimeInterval
    init(requiredPause: TimeInterval = Self.commandPauseSeconds) { self.requiredPause = requiredPause }
    // Keep the model's existing utterance boundary independent of command gating.
    static let endSilenceSeconds = 0.6
    static let microphonePhrases = PhraseMatcher.microphonePhrases

    mutating func pollMicrophone(at time: Double, phrases: [String] = Self.microphonePhrases, similar: Bool = false) -> Bool {
        guard let first = phrases.first else { return false }
        return poll(at: time, phrase: first, similar: similar,
             alternatives: Array(phrases.dropFirst()), rejectNegated: true)
    }
    // End uses the same direct-address filter as wake and mute. B Chat is
    // only a safe discussion name, never an extra command alias.
    mutating func pollEnd(at time: Double, phrase: String, similar: Bool, dictionaries: PhraseDictionaries = .init()) -> Bool {
        poll(at: time, phrase: phrase, similar: similar, rejectNegated: true, ending: true, dictionaries: dictionaries)
    }
    private static let tokenizer = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+|[.!?;\\n]+")
    private var context: [String] = []
    private var wordTimings: [(word: String, start: Double, end: Double)]?
    private var sentenceStarts: [Int] = []
    private var audioBoundary = 0
    private var quiet = 1.0
    private var audioTime: Double?
    private var changedAt = 0.0
    private var consumed = 0
    private var consumedAudioRanges: [Range<Double>] = []
    private var heardSpeech = false
    private var revision = 0
    private var checkedRevision = -1
    private var waitingForPause = false
    private var configuration: [PhrasePattern] = []
    private var rejectsNegated = false
    private(set) var acceptedRange: Range<Int>?
    private(set) var acceptedPatternIndex: Int?

    mutating func reset() { self = StandaloneWake(requiredPause: requiredPause) }
    mutating func resetContext() {
        context = []; sentenceStarts = []; audioBoundary = 0
        wordTimings = nil
        consumed = 0; revision += 1; quiet = 0
        consumedAudioRanges.removeAll()
        waitingForPause = false
        audioTime = nil
        acceptedRange = nil
        acceptedPatternIndex = nil
    }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        audioTime = time
        if level < 0.02 { quiet += seconds }
        else {
            if quiet >= 0.35, heardSpeech { audioBoundary = context.count }
            heardSpeech = true; quiet = 0
        }
    }
    mutating func update(_ text: String, at time: Double,
                         timings: [(word: String, start: Double, end: Double)]? = nil) {
        var words: [String] = [], starts: [Int] = []
        let source = text.lowercased() as NSString
        for match in Self.tokenizer.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range)
            if token.rangeOfCharacter(from: .alphanumerics) != nil { words.append(token) }
            else { starts.append(words.count) }
        }
        wordTimings = timings
        guard words != context || starts != sentenceStarts else { return }
        if audioBoundary > 0 {
            let common = zip(context, words).prefix { $0 == $1 }.count
            audioBoundary = min(audioBoundary, common)
        }
        context = words; sentenceStarts = starts; changedAt = time; revision += 1
    }
    mutating func poll(at time: Double, phrase: String, similar: Bool, alternatives: [String] = [], rejectNegated: Bool = false, ending: Bool = false, dictionaries: PhraseDictionaries = .init(), patterns: [PhrasePattern]? = nil, directOnly: Bool = false,
                       onDecision: ((String, Double, Double) -> Void)? = nil) -> Bool {
        let patterns = patterns ?? ([phrase] + alternatives).map { PhrasePattern(text: $0, similar: similar, ending: ending, dictionaries: dictionaries) }
        if configuration != patterns || rejectsNegated != rejectNegated {
            configuration = patterns; rejectsNegated = rejectNegated; checkedRevision = -1
        }
        guard heardSpeech, checkedRevision != revision || waitingForPause else { return false }
        // Alternative command wording shares one occurrence count, so a revised
        // hypothesis from "mute chat" to "silent chat" cannot toggle twice.
        var patternByRange: [Range<Int>: (index: Int, exact: Bool)] = [:]
        for (index, pattern) in patterns.enumerated() {
            let phraseWords = PhraseMatcher.words(pattern.text)
            for match in pattern.matches(in: context, timings: wordTimings) {
                let range = match.start..<match.end
                let exact = context[range].elementsEqual(phraseWords)
                // Keep one occurrence for a shared action. The exact wording
                // owns its sound when another slot's dictionary also matches.
                if let previous = patternByRange[range], previous.exact || !exact { continue }
                patternByRange[range] = (index, exact)
            }
        }
        var candidates = patternByRange.keys.map { (start: $0.lowerBound, end: $0.upperBound) }
        candidates.sort { left, right in left.start == right.start ? left.end < right.end : left.start < right.start }
        let alignedTimings = wordTimings.flatMap { $0.map(\.word) == context ? $0 : nil }
        let audioRanges: [Range<Double>?] = candidates.map { match in
            guard let alignedTimings else { return nil }
            let start = alignedTimings[match.start].start, end = alignedTimings[match.end - 1].end
            return start.isFinite && end.isFinite && start <= end ? start..<max(end, start.nextUp) : nil // Fallback words may share one instant; keep their consumed identity.
        }
        waitingForPause = false
        var accepted: (start: Int, end: Int)?
        for (index, match) in candidates.enumerated() {
            if let range = audioRanges[index] {
                if consumedAudioRanges.contains(where: { $0.overlaps(range) }) {
                    rememberConsumed(range)
                    continue
                }
            } else if index + 1 <= consumed { continue }
            let weakSplit = patterns.contains { !$0.ending && $0.similar && PhraseMatcher.words($0.text) == ["hello", "chat"]
                && $0.dictionaries[PhraseMatcher.words($0.text).joined()] == nil }
                && PhraseMatcher.isWeakWakeVariant(context[match.start..<match.end].joined())
                && sentenceStarts.contains { $0 > match.start && $0 < match.end }
            if (directOnly && !isDirectCommand(start: match.start, end: match.end)) ||
                isMention(start: match.start, end: match.end, rejectNegated: rejectNegated) || weakSplit {
                consumed = index + 1
                rememberConsumed(audioRanges[index])
                continue
            }
            if requiredPause > 0, match.end < context.count {
                // A late transcript can already contain words after the pause.
                // Never infer that gap from punctuation or ASR arrival time.
                guard let timings = wordTimings, timings.map(\.word) == context,
                      timings[match.end].start.isFinite,
                      timings[match.end].start - timings[match.end - 1].end + 1e-9 >= requiredPause else { // Avoid rounding an exact configured gap below the boundary.
                    consumed = index + 1
                    rememberConsumed(audioRanges[index])
                    continue
                }
            } else if requiredPause > 0 {
                let elapsed: Double
                if let audioTime, let timings = wordTimings, timings.map(\.word) == context {
                    elapsed = audioTime - timings[match.end - 1].end
                } else {
                    elapsed = quiet // Text-only diagnostics have no model clock; live backends supply it for every frame.
                }
                if !elapsed.isFinite || elapsed + 1e-9 < requiredPause {
                    waitingForPause = true
                    break // Keep this occurrence pending; another audio frame can satisfy its pause.
                }
            }
            accepted = match
            break
        }
        acceptedRange = accepted.map { $0.start..<$0.end }
        acceptedPatternIndex = acceptedRange.flatMap { patternByRange[$0]?.index }
        let directAddress = accepted != nil
        checkedRevision = revision
        // Monotonic occurrence counts prevent corrections to an old sentence
        // from replaying either a rejected mention or an accepted address.
        if !waitingForPause {
            consumed = max(consumed, candidates.count)
            audioRanges.forEach { rememberConsumed($0) }
        }
        if !candidates.isEmpty {
            onDecision?(directAddress ? (requiredPause > 0 ? "accepted_after_pause" : "accepted_without_pause") : (waitingForPause ? "waiting_for_pause" : "rejected_context_or_consumed"), quiet, time - changedAt)
        }
        return directAddress
    }

    private mutating func rememberConsumed(_ range: Range<Double>?) {
        guard let range else { return }
        // ASR can delete earlier words and renumber every later match. Audio
        // spans retain occurrence identity without replaying a corrected word.
        if let index = consumedAudioRanges.firstIndex(where: { $0.overlaps(range) }) {
            let old = consumedAudioRanges[index]
            consumedAudioRanges[index] = min(old.lowerBound, range.lowerBound)..<max(old.upperBound, range.upperBound)
        } else { consumedAudioRanges.append(range) }
    }

    mutating func cancelPending(phrase: String, endPhrase: String, similar: Bool, alternatives: [String] = [], dictionaries: PhraseDictionaries = .init()) {
        cancelPending(patterns: ([phrase] + alternatives).map { PhrasePattern(text: $0, similar: similar, dictionaries: dictionaries) },
            endPattern: PhrasePattern(text: endPhrase, similar: similar, ending: true, dictionaries: dictionaries))
    }
    mutating func cancelPending(patterns: [PhrasePattern], endPattern: PhrasePattern) {
        // End and audio commands consume earlier wakes using the same slot rules that accepted them.
        guard let end = endPattern.matches(in: context, timings: wordTimings).last?.end else { return }
        let earlier = Array(Set(patterns.flatMap { $0.matches(in: context, timings: wordTimings) }.filter { $0.end <= end }.map { $0.start..<$0.end })) // Count the same ranges as poll when two spellings share one action.
        consumed = max(consumed, earlier.count)
        if let wordTimings, wordTimings.map(\.word) == context {
            for match in earlier {
                let start = wordTimings[match.lowerBound].start, finish = wordTimings[match.upperBound - 1].end
                if start.isFinite, finish.isFinite, start <= finish { rememberConsumed(start..<max(finish, start.nextUp)) }
            }
        }
        checkedRevision = -1
    }

    private func isMention(start: Int, end: Int, rejectNegated: Bool) -> Bool {
        let sentenceStart = sentenceStarts.last(where: { $0 <= start }) ?? 0
        let sentenceEnd = sentenceStarts.first(where: { $0 >= end }) ?? context.count
        let left = Array(context[max(min(audioBoundary, start), sentenceStart)..<start].suffix(3))
        let right = Array(context[end..<sentenceEnd].prefix(3))
        // Mute requests are reversible toggles, so "don't mute chat" is not a
        // command. Leave the already-tuned wake behavior unchanged.
        if rejectNegated, left.contains(where: { ["not", "never", "don", "dont", "don’t", "stop"].contains($0) }) { return true }
        let referenceWords: Set<String> = ["say", "says", "said", "saying", "mention", "mentions", "mentioned",
            "mentioning", "called", "named", "phrase", "word", "words", "spell", "spelling", "spelled",
            "detect", "detects", "detected", "detecting", "recognize", "recognise", "recognizing", "recognising",
            "match", "matches", "matched", "matching", "register", "registers", "registered", "registering"]
        if left.contains(where: referenceWords.contains) { return true }
        if left.contains(where: { ["does", "doesn", "doesnt"].contains($0) }) { return true }
        if let last = left.last, ["about", "the", "your", "my", "configured", "literal"].contains(last) { return true }
        // These describe the wake feature, rather than addressing Chat. Leave
        // requests such as "Hello Chat, can you help?" deliberately permissive.
        if let first = right.first, ["is", "was", "does"].contains(first), right.count > 1,
           ["it", "there", "this", "that"].contains(right[1]) { return false }
        if let first = right.first, ["phrase", "detection", "detector", "trigger", "keyword", "command",
            "setting", "settings", "button", "feature", "app", "works", "worked", "working", "fails", "failed",
            "opens", "starts", "closes", "ends", "activates", "triggers", "detects", "hears", "listens", "uses",
            "is", "isn", "isnt", "was", "wasn", "does", "doesn", "doesnt"].contains(first) { return true }
        if right.first == "should", right.dropFirst().first == "work" { return true }
        return false
    }

    private func isDirectCommand(start: Int, end: Int) -> Bool {
        let sentenceStart = sentenceStarts.last(where: { $0 <= start }) ?? 0
        let sentenceEnd = sentenceStarts.first(where: { $0 >= end }) ?? context.count
        let left = context[max(min(audioBoundary, start), sentenceStart)..<start]
        let right = context[end..<sentenceEnd]
        let politeOpeners: Set<String> = ["please", "can", "could", "would", "you", "okay", "ok", "now", "and", "then"]
        return left.allSatisfy(politeOpeners.contains) && right.allSatisfy { $0 == "please" || $0 == "now" }
    }
}
