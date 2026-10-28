import Foundation

// Historical name: this used to require a whole isolated utterance. A direct
// address may now follow other speech; only clear discussion of the phrase is
// filtered. Audio pauses help scope context but never gate a wake on silence.
struct StandaloneWake {
    private static let tokenizer = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+|[.!?;\\n]+")
    private var context: [String] = []
    private var sentenceStarts: [Int] = []
    private var audioBoundary = 0
    private var quiet = 1.0
    private var changedAt = 0.0
    private var consumed = 0
    private var heardSpeech = false
    private var revision = 0
    private var checkedRevision = -1
    private var configuration = ""

    mutating func reset() { self = StandaloneWake() }
    mutating func resetContext() {
        context = []; sentenceStarts = []; audioBoundary = 0
        consumed = 0; revision += 1
    }
    mutating func audio(level: Double, seconds: Double) {
        if level < 0.02 { quiet += seconds }
        else {
            if quiet >= 0.35, heardSpeech { audioBoundary = context.count }
            heardSpeech = true; quiet = 0
        }
    }
    mutating func update(_ text: String, at time: Double) {
        var words: [String] = [], starts: [Int] = []
        let source = text.lowercased() as NSString
        for match in Self.tokenizer.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range)
            if token.rangeOfCharacter(from: .alphanumerics) != nil { words.append(token) }
            else { starts.append(words.count) }
        }
        guard words != context || starts != sentenceStarts else { return }
        if audioBoundary > 0 {
            let common = zip(context, words).prefix { $0 == $1 }.count
            audioBoundary = min(audioBoundary, common)
        }
        context = words; sentenceStarts = starts; changedAt = time; revision += 1
    }
    mutating func poll(at time: Double, phrase: String, similar: Bool) -> Bool {
        let key = "\(phrase)|\(similar)"
        if configuration != key { configuration = key; checkedRevision = -1 }
        // Check each settled revision once, rather than re-scanning on every
        // audio frame. No model, network request or extra microphone is needed.
        guard heardSpeech, time - changedAt >= 0.45, checkedRevision != revision else { return false }
        checkedRevision = revision
        let candidates = matches(phrase: phrase, similar: similar)
        let directAddress = candidates.enumerated().contains { index, match in
            index + 1 > consumed && !isMention(start: match.start, end: match.end)
                && !(similar && PhraseMatcher.words(phrase) == ["hello", "chat"]
                     && PhraseMatcher.isWeakWakeVariant(context[match.start..<match.end].joined())
                     && sentenceStarts.contains { $0 > match.start && $0 < match.end })
        }
        // Monotonic occurrence counts prevent corrections to an old sentence
        // from replaying either a rejected mention or an accepted address.
        consumed = max(consumed, candidates.count)
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
        PhraseMatcher.matches(in: context, phrase: phrase, similar: similar, ending: allowEndAddressEdit)
    }

    private func isMention(start: Int, end: Int) -> Bool {
        let sentenceStart = sentenceStarts.last(where: { $0 <= start }) ?? 0
        let sentenceEnd = sentenceStarts.first(where: { $0 >= end }) ?? context.count
        let left = Array(context[max(min(audioBoundary, start), sentenceStart)..<start].suffix(3))
        let right = Array(context[end..<sentenceEnd].prefix(3))
        let referenceWords: Set<String> = ["say", "says", "said", "saying", "mention", "mentions", "mentioned",
            "mentioning", "called", "named", "phrase", "word", "words", "spell", "spelling", "spelled",
            "detect", "detects", "detected", "detecting", "recognize", "recognise", "recognizing", "recognising",
            "match", "matches", "matched", "matching"]
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
