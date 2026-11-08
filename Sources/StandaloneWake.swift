import Foundation

// Ethan reinstated a 600 ms pause after every keyword on 8 November 2026.
// Use word timestamps and the recognizer's audio clock, not room volume or
// transcript arrival time. Ambient noise is not the same as continuing speech.
struct StandaloneWake {
    static let commandPauseSeconds = 0.6
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
    mutating func pollEnd(at time: Double, phrase: String, similar: Bool) -> Bool {
        poll(at: time, phrase: phrase, similar: similar, rejectNegated: true, ending: true)
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
    private var heardSpeech = false
    private var revision = 0
    private var checkedRevision = -1
    private var waitingForPause = false
    private var configuration = ""
    private(set) var acceptedRange: Range<Int>?

    mutating func reset() { self = StandaloneWake() }
    mutating func resetContext() {
        context = []; sentenceStarts = []; audioBoundary = 0
        wordTimings = nil
        consumed = 0; revision += 1; quiet = 0
        waitingForPause = false
        audioTime = nil
        acceptedRange = nil
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
    mutating func poll(at time: Double, phrase: String, similar: Bool, alternatives: [String] = [], rejectNegated: Bool = false, ending: Bool = false,
                       onDecision: ((String, Double, Double) -> Void)? = nil) -> Bool {
        let key = "\(phrase)|\(similar)|\(alternatives)|\(rejectNegated)|\(ending)"
        if configuration != key { configuration = key; checkedRevision = -1 }
        guard heardSpeech, checkedRevision != revision || waitingForPause else { return false }
        // Alternative command wording shares one occurrence count, so a revised
        // hypothesis from "mute chat" to "silent chat" cannot toggle twice.
        var candidates: [(start: Int, end: Int)] = []
        for candidatePhrase in [phrase] + alternatives {
            candidates.append(contentsOf: matches(phrase: candidatePhrase, similar: similar, allowEndAddressEdit: ending))
        }
        candidates.sort { left, right in left.start == right.start ? left.end < right.end : left.start < right.start }
        waitingForPause = false
        var accepted: (start: Int, end: Int)?
        for (index, match) in candidates.enumerated() where index + 1 > consumed {
            let weakSplit = !ending && similar && PhraseMatcher.words(phrase) == ["hello", "chat"]
                && PhraseMatcher.isWeakWakeVariant(context[match.start..<match.end].joined())
                && sentenceStarts.contains { $0 > match.start && $0 < match.end }
            if isMention(start: match.start, end: match.end, rejectNegated: rejectNegated) || weakSplit {
                consumed = index + 1
                continue
            }
            if match.end < context.count {
                // A late transcript can already contain words after the pause.
                // Never infer that gap from punctuation or ASR arrival time.
                guard let timings = wordTimings, timings.map(\.word) == context,
                      timings[match.end].start.isFinite,
                      timings[match.end].start - timings[match.end - 1].end + 1e-9 >= Self.commandPauseSeconds else { // Avoid rounding an exact 600 ms gap below the boundary.
                    consumed = index + 1
                    continue
                }
            } else {
                let elapsed: Double
                if let audioTime, let timings = wordTimings, timings.map(\.word) == context {
                    elapsed = audioTime - timings[match.end - 1].end
                } else {
                    elapsed = quiet // Text-only diagnostics have no model clock; live backends supply it for every frame.
                }
                if !elapsed.isFinite || elapsed + 1e-9 < Self.commandPauseSeconds {
                    waitingForPause = true
                    break // Keep this occurrence pending; another audio frame can satisfy its pause.
                }
            }
            accepted = match
            break
        }
        acceptedRange = accepted.map { $0.start..<$0.end }
        let directAddress = accepted != nil
        checkedRevision = revision
        // Monotonic occurrence counts prevent corrections to an old sentence
        // from replaying either a rejected mention or an accepted address.
        if !waitingForPause { consumed = max(consumed, candidates.count) }
        if !candidates.isEmpty {
            onDecision?(directAddress ? "accepted_after_pause" : (waitingForPause ? "waiting_for_pause" : "rejected_context_or_consumed"), quiet, time - changedAt)
        }
        return directAddress
    }

    mutating func cancelPending(phrase: String, endPhrase: String, similar: Bool, alternatives: [String] = []) {
        // An end command can arrive before this settled-text poll. Do not let
        // that earlier greeting reopen Voice after the end was handled.
        guard let end = matches(phrase: endPhrase, similar: similar, allowEndAddressEdit: true).last?.end else { return }
        consumed = max(consumed, ([phrase] + alternatives).flatMap { matches(phrase: $0, similar: similar) }.filter { $0.end <= end }.count)
        checkedRevision = -1
    }

    private func matches(phrase: String, similar: Bool, allowEndAddressEdit: Bool = false) -> [(start: Int, end: Int)] {
        PhraseMatcher.matches(in: context, phrase: phrase, similar: similar, ending: allowEndAddressEdit, timings: wordTimings)
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
}
