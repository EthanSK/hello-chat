import Foundation

// Refactor of SpotifyVolumePhrase: share its existing occurrence/revision handling
// with typed spoken values. Value parsing stays with each command; no new silence
// or utterance-end gate is added. — GPT-6.1 Sol
struct SpokenValuePhrase<Value: Equatable> {
    struct Command {
        let id: UUID
        let value: Value
        let range: Range<Int>
        let pattern: PhrasePattern
        var count = 1
        var revised = false
        var invalid = false
    }
    private struct Occurrence { let id = UUID(); var prefix: Range<Int>; var audio: Range<Double>?; var value: Value?; var count = 1; var range: Range<Int>?; var finalized = false; var cancelled = false }
    private var detector = StandaloneWake()
    private var text = ""
    private var words: [String] = []
    private var checkedText: String?
    private var admitted: [Occurrence] = []
    private var timings: [(word: String, start: Double, end: Double)]?

    private let parse: (String, [String], Int) -> (value: Value, end: Int)?
    init(parse: @escaping (String, [String], Int) -> (value: Value, end: Int)?) { self.parse = parse }
    mutating func reset() { self = Self(parse: parse) }
    mutating func audio(level: Double, seconds: Double, at time: Double) { detector.audio(level: level, seconds: seconds, at: time) }
    mutating func update(_ text: String, at time: Double, timings: [(word: String, start: Double, end: Double)]?) {
        let next = PhraseMatcher.words(text)
        let common = zip(words, next).prefix { $0 == $1 }.count
        var suffix = 0
        while suffix < min(words.count, next.count) - common,
              words[words.count - suffix - 1] == next[next.count - suffix - 1] { suffix += 1 }
        let suffixStart = words.count - suffix, shift = next.count - words.count
        let timed = timings?.map(\.word) == next && timings?.contains(where: { $0.end > $0.start }) == true
        let ambiguousRemoval = next.count < words.count && admitted.filter({ !$0.cancelled && !$0.finalized }).count > 1 && !timed
        for index in admitted.indices {
            if ambiguousRemoval { admitted[index].cancelled = true; continue }
            if admitted[index].audio != nil, timed { continue }
            let prefix = admitted[index].prefix
            if prefix.upperBound <= common { continue }
            if prefix.lowerBound >= suffixStart {
                admitted[index].prefix = (prefix.lowerBound + shift)..<(prefix.upperBound + shift)
                admitted[index].range = nil
            } else { admitted[index].cancelled = true }
        }
        self.text = text; words = next; self.timings = timings
        detector.update(text, at: time, timings: timings)
    }
    mutating func endUtterance() { for index in admitted.indices { admitted[index].finalized = true } }
    mutating func cancelPending(prefixes: [PhrasePattern], endPatterns: [PhrasePattern]) {
        let prefixes = recognitionPrefixes(prefixes)
        detector.cancelPending(patterns: prefixes, endPatterns: endPatterns)
        guard let end = endPatterns.flatMap({ $0.matches(in: words, timings: timings) }).map(\.end).max() else { return }
        for index in admitted.indices where admitted[index].prefix.upperBound <= end { admitted[index].cancelled = true }
    }
    mutating func poll(at time: Double, prefixes: [PhrasePattern]) -> [Command] {
        guard checkedText != text else { return [] }
        let prefixes = recognitionPrefixes(prefixes)
        guard let first = prefixes.first else { return [] }
        checkedText = text
        let prefixesByPosition = ranges(prefixes)
        for index in admitted.indices where !admitted[index].cancelled {
            if let audio = admitted[index].audio, timings?.map(\.word) == words {
                let matches = prefixesByPosition.filter { prefixAudio($0).map { $0.overlaps(audio) } == true }
                guard matches.count == 1 else { admitted[index].cancelled = true; continue }
                if admitted[index].prefix != matches[0] { admitted[index].range = nil }
                admitted[index].prefix = matches[0]
            }
            if let range = prefixesByPosition.first(where: { $0.lowerBound == admitted[index].prefix.lowerBound && $0.overlaps(admitted[index].prefix) }) {
                admitted[index].prefix = range
            }
        }
        if detector.poll(at: time, phrase: first.text, similar: first.similar, rejectNegated: true,
                         patterns: prefixes, directOnly: true, collectOccurrences: true) {
            for occurrence in detector.occurrences {
                if let prefix = prefixesByPosition.first(where: { $0.overlaps(occurrence.words) }),
                   !admitted.contains(where: { !$0.cancelled && $0.prefix.overlaps(prefix) }) {
                    admitted.append(Occurrence(prefix: prefix, audio: prefixAudio(prefix)))
                }
            }
        }
        let candidates = commands(prefixes: prefixes)
        var result: [Command] = []
        for index in admitted.indices {
            var occurrence = admitted[index]
            guard !occurrence.cancelled, !occurrence.finalized else { continue }
            guard let candidate = candidates.first(where: { $0.range.lowerBound == occurrence.prefix.lowerBound }),
                  detector.permitsDirectCommand(in: candidate.range) else {
                if let previous = occurrence.value {
                    admitted[index].cancelled = true
                    result.append(Command(id: occurrence.id, value: previous, range: occurrence.prefix,
                        pattern: PhrasePattern(text: words[occurrence.prefix].joined(separator: " "), similar: false), revised: true, invalid: true))
                }
                continue
            }
            guard
                  occurrence.value != candidate.value || occurrence.count != candidate.count || occurrence.range != candidate.range else { continue }
            let revised = occurrence.value != nil
            occurrence.value = candidate.value; occurrence.count = candidate.count; occurrence.range = candidate.range; admitted[index] = occurrence
            result.append(Command(id: occurrence.id, value: candidate.value, range: candidate.range, pattern: candidate.pattern, count: candidate.count, revised: revised))
        }
        return result
    }

    private func ranges(_ prefixes: [PhrasePattern]) -> [Range<Int>] {
        var unique: Set<Range<Int>> = []
        for prefix in prefixes {
            for match in prefix.matches(in: words, timings: timings) { unique.insert(match.start..<match.end) }
        }
        let matches: [Range<Int>] = unique.sorted {
            if $0.lowerBound == $1.lowerBound { return $0.upperBound > $1.upperBound }
            return $0.lowerBound < $1.lowerBound
        }
        var result: [Range<Int>] = []
        for range in matches where !result.contains(where: { $0.overlaps(range) }) { result.append(range) }
        return result
    }
    private func prefixAudio(_ range: Range<Int>) -> Range<Double>? {
        guard let timings, timings.map(\.word) == words, DesktopSpeechBoundaries.hasAudioSpans(timings, in: range) else { return nil }
        return timings[range.lowerBound].start..<timings[range.upperBound - 1].end
    }
    // Match configured spelling forms individually. The general matcher prefers
    // an exact short prefix, which can otherwise hide its longer “… to” form.
    private func recognitionPrefixes(_ prefixes: [PhrasePattern]) -> [PhrasePattern] {
        var seen = Set<String>()
        return prefixes.flatMap { prefix -> [PhrasePattern] in
            let variants = prefix.similar ? prefix.dictionaries[PhraseList.key(prefix.text)] ?? [] : []
            return [prefix] + variants.map { PhrasePattern(text: $0, similar: false) }
        }.filter { seen.insert(PhraseList.key($0.text)).inserted }
    }

    private func commands(prefixes: [PhrasePattern]) -> [Command] {
        var seen = Set<Range<Int>>()
        return prefixes.flatMap { $0.matches(in: words, timings: timings) }.compactMap { match in
            guard let parsed = parse(text, words, match.end), parsed.end > match.end, parsed.end <= words.count else { return nil }
            let range = match.start..<parsed.end
            guard seen.insert(range).inserted else { return nil }
            let requested: Int
            if case .value(let value, let used) = CommandRepetition.count(in: words, after: parsed.end), words[parsed.end + used - 1] == "times" { requested = value }
            else { requested = 1 }
            return Command(id: UUID(), value: parsed.value, range: range,
                           pattern: PhrasePattern(text: words[range].joined(separator: " "), similar: false), count: requested)
        }
    }
}

typealias SpotifyVolumePhrase = SpokenValuePhrase<Int>

extension SpokenValuePhrase.Command where Value == Int {
    var volume: Int { value }
}

extension SpokenValuePhrase where Value == Int {
    // Extraction of the original Spotify numeric/unit/sign validation; existing
    // callers keep SpotifyVolumePhrase() and its volume result. — GPT-6.1 Sol
    init() { self.init(parse: Self.parseVolume) }
    private static func parseVolume(_ text: String, _ words: [String], _ start: Int) -> (value: Int, end: Int)? {
        let source = text as NSString
        let raw = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        let spans = raw.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        guard spans.count == words.count else { return nil }
            var valueStart = start
            if ["to", "two", "too"].contains(words[safe: valueStart] ?? ""), CommandNumber.read(words, at: valueStart + 1) != nil { valueStart += 1 }
            guard let number = CommandNumber.read(words, at: valueStart), (0...100).contains(number.value) else { return nil }
            var end = valueStart + number.words
            // Minus signs are discarded by the shared word tokenizer; inspect
            // the original value boundary rather than accidentally setting +5.
            let start = spans[valueStart].location
            if start > 0, ["-", "−", "+"].contains(source.substring(with: NSRange(location: start - 1, length: 1))) { return nil }
            var hasUnit = false
            if words[safe: end] == "percent" { end += 1; hasUnit = true }
            else if words[safe: end] == "per", words[safe: end + 1] == "cent" { end += 2; hasUnit = true }
            else if words[safe: end] == "per", end + 1 == words.count { end += 1 }
            if end < words.count {
                let repeated: Bool
                if case .value(_, let used) = CommandRepetition.count(in: words, after: end) {
                    repeated = words[end + used - 1] == "times"
                } else { repeated = false }
                // Do not turn “forty point five”, “one hundred five”, a planned
                // action, or an unsupported unit into a different volume.
                let invalidUnits: Set<String> = ["hundred", "thousand", "point", "times", "percent", "per", "of", "second", "seconds", "sec", "secs", "minute", "minutes", "hour", "hours", "dollars", "pounds", "euros", "decibels", "db"]
                let pendingCount = hasUnit && CommandNumber.read(words, at: end).map { end + $0.words == words.count } == true
                guard repeated || pendingCount || (CommandNumber.read(words, at: end) == nil && !invalidUnits.contains(words[end])) else { return nil }
            }
        return (number.value, end)
    }
}


typealias ChatSpeedPhrase = SpokenValuePhrase<CodexSpeed>

extension SpokenValuePhrase where Value == CodexSpeed {
    // “Set speed” takes a named choice, never a model change or an implicit default.
    // Revisions share the original command receipt just like Spotify volume. — GPT-6.1 Sol
    init() { self.init { _, words, start in
        var at = start
        if ["to", "two", "too"].contains(words[safe: at] ?? "") { at += 1 }
        let speed: CodexSpeed, end: Int
        switch words[safe: at] {
        case "standard": speed = .standard; end = at + 1
        case "fast": speed = .fast; end = at + 1
        case "ultrafast": speed = .ultrafast; end = at + 1
        case "ultra" where words[safe: at + 1] == "fast": speed = .ultrafast; end = at + 2
        default: return nil
        }
        return (speed, end)
    } }
}
