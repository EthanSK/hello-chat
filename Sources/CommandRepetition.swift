// Ethan's “every single command” can take a trailing count. One shared scheduler owns
// the total across streaming revisions, so “five” never becomes five more. — GPT-6.1 Sol
import Foundation

// One number vocabulary serves repeat counts and absolute command values. The
// caller owns units and limits; zero is a volume, never a repeat count. — GPT-6.1 Sol
enum CommandNumber {
    static func read(_ words: [String], at start: Int) -> (value: Int, words: Int)? {
        guard words.indices.contains(start) else { return nil }
        let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let first = words[start]
        let next = words.indices.contains(start + 1) ? words[start + 1] : nil
        if (first == "one" || first == "a"), next == "hundred" { return (100, 2) }
        if let value = Int(first) { return (value, 1) }
        if let value = units.firstIndex(of: first) { return (value, 1) }
        if let index = tens.firstIndex(of: first) {
            if let next, let unit = units.firstIndex(of: next), (1...9).contains(unit) {
                return ((index + 2) * 10 + unit, 2)
            }
            return ((index + 2) * 10, 1)
        }
        return nil
    }
}

enum CommandRepetition {
    static let preferencePrefix = "repeatCount."
    static let maximum = 100
    private static let tokenizer = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+|[.!?;\\n]+")
    static func tokens(_ text: String) -> (words: [String], boundaries: Set<Int>) {
        let text = text.lowercased() as NSString
        var words: [String] = [], boundaries: Set<Int> = []
        for match in tokenizer.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let value = text.substring(with: match.range)
            if value.rangeOfCharacter(from: .alphanumerics) != nil { words.append(value) }
            else { boundaries.insert(words.count) }
        }
        return (words, boundaries)
    }
    enum Count: Equatable { case absent, value(Int, words: Int), invalid }
    static func enabled(_ command: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferencePrefix + command) as? Bool ?? true
    }
    static func setEnabled(_ enabled: Bool, command: String, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: preferencePrefix + command)
    }
    // Only number words are count aliases: “to” and “for” stay ordinary speech.
    // Existing command arguments are excluded by the caller's accepted range. — GPT-6.1 Sol
    static func count(in words: [String], after end: Int) -> Count {
        guard words.indices.contains(end) else { return .absent }
        let first = words[end]
        if ["zero", "minus", "negative"].contains(first) { return .invalid }
        guard let number = CommandNumber.read(words, at: end) else { return .absent }
        var used = number.words
        let value = number.value
        guard (1...maximum).contains(value) else { return .invalid }
        let explicitTimes = words.indices.contains(end + used) && words[end + used] == "times"
        if explicitTimes { used += 1 }
        if words.indices.contains(end + used) {
            let next = words[end + used]
            if Int(next) != nil || ["hundred", "thousand", "point", "percent", "second", "seconds", "sec", "secs", "minute", "minutes", "min", "mins", "hour", "hours", "day", "days",
                "later", "tomorrow", "after", "when", "if", "unless"].contains(next) { return .invalid }
            // A bare count ends the command. “Hello Chat, three ideas for dinner” keeps
            // “three ideas” as the opening request; “three times, ...” is explicit repetition.
            if !explicitTimes && !(next == "please" && end + used + 1 == words.count) { return .absent }
        }
        return .value(value, words: used)
    }
}

// UI-independent ownership and scheduling. The owner supplies the existing action and receipt;
// this type neither chooses an app/device nor emits a key, toggle, speech or call. — GPT-6.1 Sol
@MainActor final class RepeatedCommands {
    enum Outcome: String { case confirmed, submitted, failedBeforeDispatch, unknown, superseded }
    struct Progress: Equatable {
        let id: UUID
        let requested: Int
        let completed: Int
        let outcome: Outcome?
    }
    private final class Record {
        let id: UUID
        let command: String?
        var words: [String]
        var range: Range<Int>
        var audio: Range<Double>?
        let repeats: Bool
        let requiresTimes: Bool
        let valueArgument: Bool
        let run: (UUID) -> Void
        var requested: Int
        var completed = 0
        var activeStep: UUID?
        var firstStep: UUID?
        var executing: Bool { activeStep != nil }
        var stopped = false
        var stopOutcome = Outcome.superseded
        var confirmed = true
        var published: Progress?
        var acceptsRevisions = true
        var valueChanged = false
        init(id: UUID, command: String?, words: [String], range: Range<Int>, audio: Range<Double>?, repeats: Bool,
             requiresTimes: Bool, valueArgument: Bool, requested: Int, run: @escaping (UUID) -> Void) {
            self.id = id; self.command = command; self.words = words; self.range = range; self.audio = audio
            self.repeats = repeats; self.requiresTimes = requiresTimes; self.requested = requested; self.run = run
            self.valueArgument = valueArgument
        }
    }
    private var records: [Record] = []
    private var steps: [UUID: Record] = [:]
    private var words: [String] = []
    private var timings: [(word: String, start: Double, end: Double)]?
    private var boundaries: Set<Int> = []
    private var contextFinal = false
    var onProgress: (Progress) -> Void = { _ in }
    func contains(_ id: UUID) -> Bool { records.contains { $0.id == id } }
    func root(for step: UUID) -> UUID? { steps[step]?.id }
    func isFirst(_ step: UUID) -> Bool { steps[step].map { $0.firstStep == step } ?? true }
    // App identity is resolved before its first dispatch, so a numeric app name wins over a count.
    func setArgumentRange(_ range: Range<Int>, for step: UUID) -> Bool {
        guard let record = steps[step], record.firstStep == step, record.completed == 0 else { return false }
        let removed = record.range.upperBound - range.upperBound
        guard removed > 0, record.words.count > removed,
              case .value(let count, let used) = CommandRepetition.count(in: record.words, after: record.words.count - removed),
              used == removed else { return false }
        // The catalog can finish after ASR resets. Use this receipt's accepted words,
        // never a later transcript, when resolving its already-finalized app argument.
        record.words = Array(record.words.dropLast(removed)); record.range = range
        record.acceptsRevisions = false
        if record.repeats { record.requested = count }
        publish(record, nil)
        return true
    }
    func shouldRun(_ step: UUID) -> Bool { steps[step].map { $0.activeStep == step && !$0.stopped } ?? false }
    func invalidateValue(_ root: UUID) {
        guard let record = records.first(where: { $0.id == root }), record.valueArgument, !record.stopped else { return }
        record.stopped = true; record.stopOutcome = .unknown
        if !record.executing { publish(record, .unknown) }
    }

    // Only absolute, idempotent value commands use this: ASR's “forty” →
    // “forty five” completes the same logical action and durable receipt.
    // Relative actions and toggles retain their existing no-replay policy. — GPT-6.1 Sol
    @discardableResult func reviseValue(_ root: UUID, range: Range<Int>, reapply: Bool = true, finishingUtterance: Bool = false, authorize: () -> Bool) -> Bool {
        guard let record = records.first(where: { $0.id == root }), record.valueArgument, !record.stopped,
              record.acceptsRevisions || (finishingUtterance && contextFinal),
              range.lowerBound >= 0, range.upperBound <= words.count, !range.isEmpty else { return false }
        if record.repeats, count(after: range.upperBound, requiresTimes: record.requiresTimes) == .invalid { return false }
        guard authorize() else { return false }
        record.range = range; record.words = Array(words[range])
        if let timings, timings[range.lowerBound].start < timings[range.upperBound - 1].end {
            record.audio = timings[range.lowerBound].start..<timings[range.upperBound - 1].end
        } else { record.audio = nil }
        if reapply {
            if record.executing { record.valueChanged = true }
            else if record.completed > 0 { record.completed -= 1 }
        }
        if record.repeats { revise(record, after: range.upperBound) }
        publish(record, nil)
        if !record.executing { advance(record) }
        return true
    }

    func reset() { cancelPending(); boundary() }
    func endUtterance() { contextFinal = true; records.forEach { $0.acceptsRevisions = false } }
    func boundary() {
        records.forEach { $0.acceptsRevisions = false }
        words = []; timings = nil; boundaries = []; contextFinal = false
    }
    func cancelPending(command: String? = nil) {
        for record in records where !record.stopped && (command == nil || record.command == command) {
            record.stopped = true
            if !record.executing && record.completed < record.requested { publish(record, .superseded) }
        }
    }
    // Poll after ordinary End priority checks. A partial update must not send an earlier repeat
    // before a new End in that same transcript has had a chance to cancel it. — GPT-6.1 Sol
    func poll() { for record in records where !record.executing && !record.stopped && record.completed < record.requested { advance(record) } }
    func update(_ words: [String], timings: [(word: String, start: Double, end: Double)]?, boundaries: Set<Int> = []) {
        if words != self.words { contextFinal = false }
        self.words = words
        self.boundaries = boundaries
        self.timings = timings?.map(\.word) == words ? timings : nil
        for record in records where !record.stopped && record.repeats && record.acceptsRevisions && !record.valueArgument {
            guard let range = relocated(record) else { continue }
            revise(record, after: range.upperBound)
        }
    }

    @discardableResult func begin(id: UUID, range: Range<Int>, repeats: Bool, requiresTimes: Bool = false,
                                 valueArgument: Bool = false,
                                 discard: Bool = false, command: String? = nil, run: @escaping (UUID) -> Void) -> UUID? {
        guard !records.contains(where: { $0.id == id }), range.lowerBound >= 0,
              range.upperBound <= words.count, !range.isEmpty else { return nil }
        // Keep all requested actions in spoken order; a later request cannot silently turn
        // two three-step rewinds into four steps. Explicit End still cancels the queue. — GPT-6.1 Sol
        records.forEach { $0.acceptsRevisions = false }
        let count = repeats ? count(after: range.upperBound, requiresTimes: requiresTimes) : .absent
        // An invalid supplied count must not become one live action. Found and fixed by GPT-6.1 Sol.
        guard count != .invalid else { return nil }
        let requested: Int
        if case .value(let value, _) = count { requested = value } else { requested = 1 }
        let audio: Range<Double>?
        if let timings, timings[range.lowerBound].start < timings[range.upperBound - 1].end {
            audio = timings[range.lowerBound].start..<timings[range.upperBound - 1].end
        } else { audio = nil }
        let record = Record(id: id, command: command, words: Array(words[range]), range: range, audio: audio,
                            repeats: repeats, requiresTimes: requiresTimes, valueArgument: valueArgument, requested: requested, run: run)
        record.acceptsRevisions = !contextFinal
        records.append(record)
        if records.count > 256, let retired = records.firstIndex(where: { !$0.executing && ($0.stopped || $0.completed >= $0.requested) }) {
            let removed = records.remove(at: retired)
            steps = steps.filter { $0.value !== removed }
        }
        if discard {
            record.stopped = true
            publish(record, .superseded)
            return nil
        }
        publish(record, nil)
        advance(record)
        return record.firstStep
    }

    // Returns true only for a step owned here; ordinary button/shortcut results stay independent.
    @discardableResult func finish(_ id: UUID, _ outcome: Outcome) -> Bool {
        guard let record = steps[id] else { return false }
        // Native completion and its teardown can both report a result. Each physical run has
        // its own token, while all runs still share one user-facing ownership receipt. — GPT-6.1 Sol
        guard record.activeStep == id else { return true }
        record.activeStep = nil
        if record.valueChanged, !record.stopped, outcome == .confirmed || outcome == .submitted {
            record.valueChanged = false
            // The completed native value is obsolete. Confirm the latest value
            // before counting this logical run; never start a second owner.
            advance(record)
            return true
        }
        if record.stopped {
            let successful = outcome == .confirmed || outcome == .submitted
            if successful {
                record.completed += 1
                record.confirmed = record.confirmed && outcome == .confirmed
            }
            // Cancelling unstarted repeats cannot erase the physical action's actual result.
            // Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
            let result: Outcome
            if outcome == .unknown || record.stopOutcome == .unknown { result = .unknown }
            else if successful && record.completed >= record.requested { result = record.confirmed ? .confirmed : .submitted }
            else { result = record.stopOutcome }
            publish(record, result)
            poll()
            return true
        }
        switch outcome {
        case .confirmed, .submitted:
            record.completed += 1
            record.confirmed = record.confirmed && outcome == .confirmed
            if record.stopped { publish(record, .superseded) }
            else { advance(record) }
        default:
            record.stopped = true
            publish(record, record.completed > 0 ? .unknown : outcome)
        }
        poll()
        return true
    }

    private func relocated(_ record: Record) -> Range<Int>? {
        guard record.words.count <= words.count else { return nil }
        if let audio = record.audio, let timings {
            let matches = (0...(words.count - record.words.count)).compactMap { start -> Range<Int>? in
                let range = start..<(start + record.words.count)
                guard words[range].elementsEqual(record.words), timings[start].start < audio.upperBound,
                      timings[range.upperBound - 1].end > audio.lowerBound else { return nil }
                return range
            }
            return matches.count == 1 ? matches[0] : nil
        }
        return record.range.upperBound <= words.count && words[record.range].elementsEqual(record.words) ? record.range : nil
    }
    private func revise(_ record: Record, after end: Int) {
        let count = count(after: end, requiresTimes: record.requiresTimes)
        let value: Int
        switch count {
        case .absent: value = 1
        case .value(let requested, _): value = requested
        case .invalid:
            record.stopped = true; record.stopOutcome = .unknown
            // The first run may still be in flight: never label it failed-before-dispatch.
            if !record.executing { publish(record, .unknown) }
            return
        }
        guard value != record.requested else { return }
        guard value >= record.completed + (record.executing ? 1 : 0) else {
            // A later lower ASR count cannot undo an already-sent action. Stop; never compensate.
            record.stopped = true; record.stopOutcome = .unknown; publish(record, .unknown); return
        }
        record.requested = value
    }
    private func advance(_ record: Record) {
        guard !record.executing, !record.stopped else { return }
        // Explicit multi-step requests retain their ordering. A single running action belongs
        // to its existing executor (e.g. latest-wins speaker queue), rather than freezing all
        // unrelated controls. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
        guard let index = records.firstIndex(where: { $0 === record }),
              !records[..<index].contains(where: { !$0.stopped && $0.requested > 1 && ($0.executing || $0.completed < $0.requested) }) else { return }
        guard record.completed < record.requested else {
            publish(record, record.confirmed ? .confirmed : .submitted); return
        }
        let step = UUID()
        record.activeStep = step
        if record.firstStep == nil { record.firstStep = step }
        steps[step] = record
        publish(record, nil)
        record.run(step)
    }
    private func count(after end: Int, requiresTimes: Bool) -> CommandRepetition.Count {
        let limit = boundaries.filter { $0 >= end }.min() ?? words.count
        let count = CommandRepetition.count(in: Array(words.prefix(limit)), after: end)
        guard case .value(_, let used) = count else { return count }
        if requiresTimes && words[end + used - 1] != "times" { return .absent }
        // Use the existing speech-boundary distance, not a new post-keyword timer.
        if let timings, end > 0 {
            for i in end..<(end + used) where timings[i - 1].end > timings[i - 1].start && timings[i].end > timings[i].start {
                if timings[i].start - timings[i - 1].end >= 0.35 { return .absent }
            }
        }
        return count
    }
    private func publish(_ record: Record, _ outcome: Outcome?) {
        let progress = Progress(id: record.id, requested: record.requested, completed: record.completed, outcome: outcome)
        guard record.published != progress else { return }
        if outcome == nil, let old = record.published, old.outcome == nil,
           old.requested == progress.requested, progress.completed % 10 != 0 { return }
        record.published = progress
        onProgress(progress)
    }
}
