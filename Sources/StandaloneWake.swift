import Foundation

// Fixed-phrase commands outside Voice (browser video, zoom) share these rules: one occurrence
// counter per command, mention/negation rejection, and consumption independent of the action.
struct CommandPhraseDetectors<Command: CaseIterable & Hashable> {
    private var detectors = Dictionary(uniqueKeysWithValues: Command.allCases.map { ($0, StandaloneWake()) })
    // Different keyword spellings can be a revision of the same audio ("five" becoming "ten").
    private var usedOccurrences: [(Command, StandaloneWake.Occurrence)] = []
    mutating func reset() {
        usedOccurrences.removeAll()
        for command in Command.allCases { detectors[command] = StandaloneWake() }
    }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        for command in Command.allCases { detectors[command, default: StandaloneWake()].audio(level: level, seconds: seconds, at: time) }
    }
    mutating func update(_ text: String, at time: Double, timings: [(word: String, start: Double, end: Double)]? = nil) {
        for command in Command.allCases { detectors[command, default: StandaloneWake()].update(text, at: time, timings: timings) }
    }
    // End wins over these commands in the same transcript, as it does over audio commands.
    mutating func cancelPending(patterns: [Command: PhrasePattern], endPattern: PhrasePattern) {
        cancelPending(aliases: patterns.mapValues { [$0] }, endPatterns: [endPattern])
    }
    // Every phrase listed for a command shares that command's one occurrence count.
    mutating func cancelPending(aliases: [Command: [PhrasePattern]], endPatterns: [PhrasePattern]) {
        for (command, list) in aliases {
            let usable = list.filter { !PhraseMatcher.words($0.text).isEmpty }
            if !usable.isEmpty { detectors[command, default: StandaloneWake()].cancelPending(patterns: usable, endPatterns: endPatterns) }
        }
    }
    // Accepted commands in spoken order. Each occurrence is consumed once.
    mutating func poll(at time: Double, patterns: [Command: PhrasePattern], directOnly: Bool = false,
                       onDecision: ((Command, String) -> Void)? = nil) -> [(command: Command, range: Range<Int>)] {
        poll(at: time, aliases: patterns.mapValues { [$0] }, directOnly: directOnly, onDecision: onDecision)
    }
    mutating func poll(at time: Double, aliases: [Command: [PhrasePattern]], directOnly: Bool = false, directCommands: Set<Command> = [], embeddedCommands: Set<Command> = [],
                       onDecision: ((Command, String) -> Void)? = nil) -> [(command: Command, range: Range<Int>)] {
        var matches: [(command: Command, range: Range<Int>)] = []
        for command in Command.allCases {
            guard let list = aliases[command]?.filter({ !PhraseMatcher.words($0.text).isEmpty }), let pattern = list.first,
                  detectors[command, default: StandaloneWake()].poll(at: time, phrase: pattern.text, similar: pattern.similar,
                      rejectNegated: true, ending: pattern.ending, patterns: list, directOnly: directOnly || directCommands.contains(command), embeddedCommand: embeddedCommands.contains(command),
                      collectOccurrences: true, onDecision: { decision, _, _ in onDecision?(command, decision) })
            else { continue }
            for occurrence in detectors[command]?.occurrences ?? [] {
                if usedOccurrences.contains(where: { $0.0 != command && $0.1.overlaps(occurrence) }) { continue }
                usedOccurrences.append((command, occurrence))
                matches.append((command, occurrence.words))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

// Ethan removed the command pause: YouTube keeps supplying words, so waiting for
// silence prevents commands during playback (reaffirmed 17 November 2026).
// Explain that reason before proposing a delay again. Model utterance/reset timing is separate.
struct StandaloneWake {
    static let commandPauseSeconds = 0.0
    private let requiredPause: TimeInterval
    private let speakerRoute: Bool
    init(requiredPause: TimeInterval = Self.commandPauseSeconds, speakerRoute: Bool = false) {
        self.requiredPause = requiredPause
        self.speakerRoute = speakerRoute
    }
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
    private(set) var sentenceStarts: [Int] = []
    private var desktopBoundaries: [Int] = []
    private var audioBoundary = 0
    private var directAudioBoundaries: [Int] = []
    private var quiet = 1.0
    private var audioTime: Double?
    private var changedAt = 0.0
    private var consumed = 0
    private var consumedUntimed = 0
    private var consumedAudioRanges: [Range<Double>] = []
    private var heardSpeech = false
    private var revision = 0
    private var checkedRevision = -1
    private var waitingForPause = false
    private var configuration: [PhrasePattern] = []
    private var rejectsNegated = false
    struct Occurrence {
        let words: Range<Int>
        let audio: Range<Double>?
        var timed = true
        func overlaps(_ other: Self) -> Bool {
            if timed && other.timed, let audio, let compared = other.audio { return audio.overlaps(compared) }
            return words.overlaps(other.words)
        }
    }
    private(set) var occurrences: [Occurrence] = []
    private(set) var acceptedRange: Range<Int>?
    private(set) var acceptedPatternIndex: Int?

    mutating func reset() { self = StandaloneWake(requiredPause: requiredPause, speakerRoute: speakerRoute) }
    mutating func resetContext() {
        context = []; sentenceStarts = []; desktopBoundaries = []; audioBoundary = 0
        directAudioBoundaries = []
        wordTimings = nil
        consumed = 0; revision += 1; quiet = 0
        consumedUntimed = 0
        consumedAudioRanges.removeAll()
        waitingForPause = false
        audioTime = nil
        occurrences.removeAll()
        acceptedRange = nil
        acceptedPatternIndex = nil
    }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        audioTime = time
        if level < 0.02 { quiet += seconds }
        else {
            if quiet >= 0.35, heardSpeech {
                audioBoundary = context.count
                if directAudioBoundaries.last != context.count {
                    directAudioBoundaries.append(context.count)
                    if directAudioBoundaries.count > 64 { directAudioBoundaries.removeFirst() }
                }
            }
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
        let boundaries = DesktopSpeechBoundaries.indices(words: words, timings: timings, gap: 0.35)
        guard words != context || starts != sentenceStarts || boundaries != desktopBoundaries else { return }
        if audioBoundary > 0 {
            let common = zip(context, words).prefix { $0 == $1 }.count
            audioBoundary = min(audioBoundary, common)
            var clamped: [Int] = []
            for boundary in directAudioBoundaries.map({ min($0, common) }) where clamped.last != boundary { clamped.append(boundary) }
            directAudioBoundaries = clamped
        }
        context = words; sentenceStarts = starts; desktopBoundaries = boundaries; changedAt = time; revision += 1
    }
    mutating func poll(at time: Double, phrase: String, similar: Bool, alternatives: [String] = [], rejectNegated: Bool = false, ending: Bool = false, dictionaries: PhraseDictionaries = .init(), patterns: [PhrasePattern]? = nil, directOnly: Bool = false, embeddedCommand: Bool = false, collectOccurrences: Bool = false, utteranceEnded: Bool = false,
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
        if speakerRoute {
            // "Kitchen speakers" may extend "Kitchen" in a streaming revision. Nested names
            // at one start refer to the same output by SpeakerOutputSettings validation.
            var starts = Set<Int>()
            candidates = candidates.reversed().filter { starts.insert($0.start).inserted }.reversed()
        }
        let alignedTimings = wordTimings.flatMap { $0.map(\.word) == context ? $0 : nil }
        let audioRanges: [Range<Double>?] = candidates.map { match in
            guard let alignedTimings else { return nil }
            let start = alignedTimings[match.start].start, end = alignedTimings[match.end - 1].end
            return start.isFinite && end.isFinite && start <= end ? start..<max(end, start.nextUp) : nil // Fallback words may share one instant; keep their consumed identity.
        }
        waitingForPause = false
        occurrences.removeAll(keepingCapacity: true)
        var accepted: (start: Int, end: Int)?
        var evaluatedFreshOccurrence = false
        var rejection = "rejected_context"
        for (index, match) in candidates.enumerated() {
            if index < consumedUntimed { continue }
            if let range = audioRanges[index] {
                if consumedAudioRanges.contains(where: { $0.overlaps(range) }) {
                    rememberConsumed(range)
                    continue
                }
            } else if index + 1 <= consumed { continue }
            evaluatedFreshOccurrence = true
            let weakSplit = patterns.contains { !$0.ending && $0.similar && PhraseMatcher.words($0.text) == ["hello", "chat"]
                && $0.dictionaries[PhraseMatcher.words($0.text).joined()] == nil }
                && PhraseMatcher.isWeakWakeVariant(context[match.start..<match.end].joined())
                && sentenceStarts.contains { $0 > match.start && $0 < match.end }
            let range = match.start..<match.end
            let pattern = patternByRange[range].map { patterns[$0.index] }
            let bareSpeakerRestore = pattern?.isBareSpeakerRestore(context[range]) ?? false
            let bareSpeakerHush = pattern?.isBareSpeakerHush ?? false
            let bareNavigation = pattern?.isBareNavigation ?? false
            if bareSpeakerRestore || bareSpeakerHush || bareNavigation || pattern?.needsStandaloneUnsilence(context[range]) == true {
                let (_, end) = contextBounds(start: match.start, end: match.end, directOnly: true)
                var trailing = Array(context[match.end..<(bareSpeakerRestore ? context.count : end)])
                // Shush and Unshush stay immediate, including the existing explicit repeat syntax; unlike
                // bare restore it never waits for an utterance-end signal. — GPT-6.1 Sol
                if bareSpeakerHush || bareNavigation, case .value(_, let used) = CommandRepetition.count(in: trailing, after: 0) {
                    trailing.removeFirst(used)
                }
                if !isDirectCommand(start: match.start, end: match.end, allowEmbedded: embeddedCommand) || !trailing.allSatisfy({ $0 == "please" || $0 == "now" }) {
                    consumed = index + 1
                    rememberConsumed(audioRanges[index])
                    continue
                }
            }
            if directOnly && !isDirectCommand(start: match.start, end: match.end, allowEmbedded: embeddedCommand) {
                rejection = "rejected_context"
                consumed = index + 1
                rememberConsumed(audioRanges[index])
                continue
            }
            // A bare "unmute" may still become "unmute chat" in the next recognition update.
            // Use the existing utterance boundary only for these short speaker commands. — GPT-6.2 Sol
            if bareSpeakerRestore && !utteranceEnded {
                waitingForPause = true
                break
            }
            if isMention(start: match.start, end: match.end, rejectNegated: rejectNegated, directOnly: directOnly) || weakSplit {
                rejection = "rejected_mention"
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
                    rejection = "rejected_pause"
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
            // If one delayed hypothesis contains two physical output requests, the last destination wins.
            if collectOccurrences { occurrences.append(Occurrence(words: match.start..<match.end, audio: audioRanges[index],
                timed: DesktopSpeechBoundaries.hasAudioSpans(alignedTimings, in: match.start..<match.end))) }
            if !speakerRoute && !collectOccurrences { break }
        }
        acceptedRange = accepted.map { $0.start..<$0.end }
        acceptedPatternIndex = acceptedRange.flatMap { patternByRange[$0]?.index }
        let directAddress = accepted != nil
        checkedRevision = revision
        // Monotonic occurrence counts prevent corrections to an old sentence
        // from replaying either a rejected mention or an accepted address.
        if !waitingForPause {
            consumed = max(consumed, candidates.count)
            for (index, match) in candidates.enumerated() where !DesktopSpeechBoundaries.hasAudioSpans(alignedTimings, in: match.start..<match.end) {
                consumedUntimed = max(consumedUntimed, index + 1)
            }
            audioRanges.forEach { rememberConsumed($0) }
        }
        if evaluatedFreshOccurrence {
            onDecision?(directAddress ? (requiredPause > 0 ? "accepted_after_pause" : "accepted_without_pause") : (waitingForPause ? "waiting_for_pause" : rejection), quiet, time - changedAt)
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
        cancelPending(patterns: patterns, endPatterns: [endPattern])
    }
    mutating func cancelPending(patterns: [PhrasePattern], endPatterns: [PhrasePattern]) {
        // End and audio commands consume earlier wakes using the same slot rules that accepted them.
        // With several phrases for one command, the latest heard one bounds the consumed wakes.
        guard let end = endPatterns.compactMap({ $0.matches(in: context, timings: wordTimings).last?.end }).max() else { return }
        let earlier = Array(Set(patterns.flatMap { $0.matches(in: context, timings: wordTimings) }.filter { $0.end <= end }.map { $0.start..<$0.end })) // Count the same ranges as poll when two spellings share one action.
        consumed = max(consumed, earlier.count)
        let alignedTimings = wordTimings.flatMap { $0.map(\.word) == context ? $0 : nil }
        if earlier.contains(where: { !DesktopSpeechBoundaries.hasAudioSpans(alignedTimings, in: $0) }) {
            consumedUntimed = max(consumedUntimed, earlier.count)
        }
        if let wordTimings, wordTimings.map(\.word) == context {
            for match in earlier {
                let start = wordTimings[match.lowerBound].start, finish = wordTimings[match.upperBound - 1].end
                if start.isFinite, finish.isFinite, start <= finish { rememberConsumed(start..<max(finish, start.nextUp)) }
            }
        }
        checkedRevision = -1
    }

    private func contextBounds(start: Int, end: Int, directOnly: Bool) -> (Int, Int) {
        // Only desktop direct commands use timed context slicing. Preserve the
        // tuned wake, End, audio and browser rules verbatim.
        let boundaries = directOnly ? (sentenceStarts + desktopBoundaries).sorted() : sentenceStarts
        return (boundaries.last(where: { $0 <= start }) ?? 0,
                boundaries.first(where: { $0 >= end }) ?? context.count)
    }
    private func isMention(start: Int, end: Int, rejectNegated: Bool, directOnly: Bool) -> Bool {
        if DesktopSpeechBoundaries.introducesQuotation(words: context, before: start, sentences: sentenceStarts) { return true }
        let (sentenceStart, sentenceEnd) = contextBounds(start: start, end: end, directOnly: directOnly)
        let boundary = directOnly ? (directAudioBoundaries.last(where: { $0 <= start }) ?? 0) : min(audioBoundary, start)
        let left = Array(context[max(boundary, sentenceStart)..<start].suffix(3))
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

    private func isDirectCommand(start: Int, end: Int, allowEmbedded: Bool = false) -> Bool {
        let (sentenceStart, sentenceEnd) = contextBounds(start: start, end: end, directOnly: true)
        // A hesitation inside a command cannot erase its preceding negation/reference.
        // Preserve the established non-direct wake/End rules. Found by Claude Opus 5.5.
        // Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
        let boundary = directAudioBoundaries.last(where: { $0 <= start }) ?? 0
        let left = context[max(boundary, sentenceStart)..<start]
        let right = context[end..<sentenceEnd].drop(while: { $0 == "please" || $0 == "now" })
        let politeOpeners: Set<String> = ["please", "can", "could", "would", "you", "okay", "ok", "now", "and", "then"]
        // A fixed command is complete at its last keyword. Requiring an empty tail made
        // continued playback act like a silence gate. Preserve explicit plans and zoom's
        // target-taking prose; ordinary mention/negation checks still run in isMention.
        let deferredOrQualified: Set<String> = ["later", "tomorrow", "tonight", "after", "when", "if", "unless", "on", "into"]
        guard !(right.first.map(deferredOrQualified.contains) ?? false) else { return false }
        if allowEmbedded, let first = right.first,
           ["never", "did", "didn", "didnt", "won", "wont"].contains(first) { return false }
        if left.allSatisfy(politeOpeners.contains) { return true }
        // Ethan's "also switch speaker kitchen" and "but switch audio kitchen" arrived
        // inside a single recognition segment with other speech. A conjunction can start a
        // fresh imperative. Keep the ordinary quote, negation and qualified-command guards.
        if speakerRoute, let conjunction = left.lastIndex(where: { $0 == "also" || $0 == "but" }),
           left[left.index(after: conjunction)...].allSatisfy(politeOpeners.contains) {
            let previous = left[..<conjunction].last
            let governed: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "ll", "can", "could", "may",
                                         "might", "must", "should", "will", "would", "to", "not", "never", "t",
                                         "anything", "nothing", "all", "everything", "only"]
            return previous.map { !governed.contains($0) } ?? true
        }
        // Exact absolute playback and configured speaker requests can interrupt narration.
        // Preserve the contrast rule above (“anything but…”), plus plans and mention checks;
        // no silence gap or post-keyword wait is added. Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
        if allowEmbedded {
            let governed: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "ll", "will", "would", "should",
                "can", "could", "might", "may", "must", "to", "want", "wanna", "need", "try", "trying",
                "think", "thinking", "thought", "mean", "means", "meant", "pressed", "pressing", "clicked", "clicking",
                "except", "avoid", "without", "rather", "instead", "because", "cause", "why", "how", "come",
                "command", "typing", "typed", "type", "didn", "didnt", "won", "wont", "wouldn", "couldn",
                "shouldn", "isn", "wasn", "aren", "wouldnt", "couldnt", "shouldnt", "isnt", "wasnt", "arent"]
            if !left.suffix(3).contains(where: governed.contains) { return true }
        }
        return false
    }

    // Value commands retain their prefix's occurrence while ASR completes the
    // argument. Recheck the same context rules for the whole revised value.
    func permitsDirectCommand(in range: Range<Int>, allowEmbedded: Bool = false) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= context.count, !range.isEmpty else { return false }
        return isDirectCommand(start: range.lowerBound, end: range.upperBound, allowEmbedded: allowEmbedded)
            && !isMention(start: range.lowerBound, end: range.upperBound, rejectNegated: true, directOnly: true)
    }

    // Settings must reject a control that could fire before a destination arrives.
    // Preserve punctuation/leading context, but do not let later words hide that
    // partial-command conflict. Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    func permitsDirectCommandPrefix(in range: Range<Int>) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= context.count, !range.isEmpty else { return false }
        var prefix = self
        prefix.context = Array(context.prefix(range.upperBound))
        prefix.sentenceStarts.removeAll { $0 >= range.upperBound }
        prefix.desktopBoundaries.removeAll { $0 >= range.upperBound }
        prefix.directAudioBoundaries.removeAll { $0 >= range.upperBound }
        return prefix.permitsDirectCommand(in: range)
    }
}
