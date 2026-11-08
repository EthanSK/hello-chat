import Foundation

// A direct address may follow other speech. It wakes as soon as it is heard,
// so Ethan can keep talking straight into Voice. On 1 Nov he turned off the
// earlier "EOU afterwards" wait (0.6 s of quiet, 1.2 s of stable text over
// noise, or Parakeet's native EOU): it delayed Voice, and with constant room
// noise a wake followed by more words never completed at all. Don't bring
// the wait back. The trade-off is that words after the phrase can no longer
// cancel a wake, so only words already heard filter out mentions.
struct StandaloneWake {
    // Parakeet's end-of-utterance debounce. It no longer gates waking.
    static let endSilenceSeconds = 0.6
    static let microphonePhrases = PhraseMatcher.microphonePhrases

    mutating func pollMicrophone(at time: Double) -> Bool {
        poll(at: time, phrase: Self.microphonePhrases[0], similar: false,
             alternatives: Array(Self.microphonePhrases.dropFirst()), rejectNegated: true)
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
    private var changedAt = 0.0
    private var consumed = 0
    private var heardSpeech = false
    private var revision = 0
    private var checkedRevision = -1
    private var configuration = ""
    private(set) var acceptedRange: Range<Int>?

    mutating func reset() { self = StandaloneWake() }
    mutating func resetContext() {
        context = []; sentenceStarts = []; audioBoundary = 0
        wordTimings = nil
        consumed = 0; revision += 1; quiet = 0
        acceptedRange = nil
    }
    mutating func audio(level: Double, seconds: Double) {
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
        guard heardSpeech, checkedRevision != revision else { return false }
        // Alternative command wording shares one occurrence count, so a revised
        // hypothesis from "mute chat" to "silent chat" cannot toggle twice.
        var candidates: [(start: Int, end: Int)] = []
        for candidatePhrase in [phrase] + alternatives {
            candidates.append(contentsOf: matches(phrase: candidatePhrase, similar: similar, allowEndAddressEdit: ending))
        }
        candidates.sort { left, right in left.start == right.start ? left.end < right.end : left.start < right.start }
        let accepted = candidates.enumerated().first { index, match in
            index + 1 > consumed
                && !isMention(start: match.start, end: match.end, rejectNegated: rejectNegated)
                && !(!ending && similar && PhraseMatcher.words(phrase) == ["hello", "chat"]
                     && PhraseMatcher.isWeakWakeVariant(context[match.start..<match.end].joined())
                     && sentenceStarts.contains { $0 > match.start && $0 < match.end })
        }
        acceptedRange = accepted.map { $0.element.start..<$0.element.end }
        let directAddress = accepted != nil
        checkedRevision = revision
        // Monotonic occurrence counts prevent corrections to an old sentence
        // from replaying either a rejected mention or an accepted address.
        consumed = max(consumed, candidates.count)
        if !candidates.isEmpty {
            onDecision?(directAddress ? "accepted_immediately" : "rejected_context_or_consumed", quiet, time - changedAt)
        }
        return directAddress
    }

    mutating func cancelPending(phrase: String, endPhrase: String, similar: Bool) {
        // An end command can arrive before this settled-text poll. Do not let
        // that earlier greeting reopen Voice after the end was handled.
        guard let end = matches(phrase: endPhrase, similar: similar, allowEndAddressEdit: true).last?.end else { return }
        consumed = max(consumed, matches(phrase: phrase, similar: similar).prefix { $0.end <= end }.count)
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
