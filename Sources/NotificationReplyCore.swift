/* ============================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-24: port of the command-window and safety decisions in
 speak-action-reminder/reply-companion/handsfree_core.py.
 New: H Chat's existing recognizer supplies both commands and body;
 no standalone capture, stored PCM or second transcription pass.
 This is a behavioral port, not a claim that the earlier tests cover it.
 Port/provenance comments — GPT-6.1 Sol
 ============================================================ */
import Foundation

/// One notification's bounded reply, driven only by the existing listener. — GPT-6.1 Sol
struct NotificationReplyCore {
    /// Frozen configured spellings for one attempt; nil uses built-ins, empty uses only the main phrase. — GPT-6.1 Sol
    struct Commands: Equatable {
        static let replyPhrase = "Reply", endReplyPhrase = "End reply"
        static let replySpellingKey = "notificationReply", endReplySpellingKey = "notificationEndReply"
        static let defaultReplySpellings: [String] = []
        static let defaultEndReplySpellings = ["And reply"]
        fileprivate static let canonicalEndForm = NotificationReplyCore.tokens(endReplyPhrase).map(\.word)
        let replyForms: [[String]], endReplyForms: [[String]]
        fileprivate let replyWordCounts: [Int], endWordCounts: [Int]
        private let replyIndex: [Int: Set<[String]>], endIndex: [Int: Set<[String]>]

        init(replySpellings: [String]? = nil, endReplySpellings: [String]? = nil, alternateSpellings: Bool = true) {
            replyForms = Self.forms(Self.replyPhrase, alternateSpellings ? replySpellings ?? Self.defaultReplySpellings : [])
            endReplyForms = Self.forms(Self.endReplyPhrase, alternateSpellings ? endReplySpellings ?? Self.defaultEndReplySpellings : [])
            replyIndex = Dictionary(grouping: replyForms, by: \.count).mapValues { Set($0) }
            endIndex = Dictionary(grouping: endReplyForms, by: \.count).mapValues { Set($0) }
            replyWordCounts = replyIndex.keys.sorted(by: >); endWordCounts = endIndex.keys.sorted(by: >)
        }
        fileprivate func matchesReply(_ words: [String]) -> Bool { replyIndex[words.count]?.contains(words) == true }
        fileprivate func matchesEnd(_ words: [String]) -> Bool { endIndex[words.count]?.contains(words) == true }
        private static func forms(_ main: String, _ additions: [String]) -> [[String]] {
            var seen = Set<[String]>()
            return ([main] + additions).compactMap {
                let words = NotificationReplyCore.tokens($0).map(\.word)
                return !words.isEmpty && seen.insert(words).inserted ? words : nil
            }
        }
    }
    static let maxSetupSeconds: Double = 180
    static let maxAnnouncementSeconds: Double = 45
    enum Phase: String, Codable {
        case preparing, announcing, waiting, composing, releasing, cancelled, unavailable, queued, delivered
    }
    struct Limits: Equatable, Codable {
        var idleSeconds: Double = 60
        var replySeconds: Double = 120
        var commandSeconds: Double { 2 }
        var confirmationSeconds: Double { 1.5 }
        // A finite allowance for the selected provider's native final decode.
        // Explicit notification End does not require whole-room quiet. — GPT-6.1 Sol
        var endConfirmationSeconds: Double { 3.5 }
        var commandDrainSeconds: Double { 0.6 + confirmationSeconds }
        var maxHoldSeconds: Double { commandSeconds + commandDrainSeconds + replySeconds + endConfirmationSeconds + 4 }
        init(idleSeconds: Double = 60, replySeconds: Double = 120) {
            self.idleSeconds = idleSeconds.isFinite ? min(180, max(10, idleSeconds)) : 60
            self.replySeconds = replySeconds.isFinite ? min(180, max(10, replySeconds)) : 120
        }
    }
    struct Word: Equatable {
        let text: String
        let start: Double
        let end: Double
    }
    struct Recognition {
        let batch: UUID
        let text: String
        let words: [Word]
        let stableWords: Int
        var confirmedStartWords = 0
    }
    let limits: Limits
    private static let retiredCommands = Commands(alternateSpellings: false)
    private var commands: Commands
    let preparedAt: Double
    private(set) var phase: Phase = .preparing
    private(set) var reason = ""
    private(set) var body: String?
    private(set) var audioEndedAt: Double?
    private(set) var acceptedAt: Double?
    private(set) var finalizeThrough: Double?
    private(set) var acceptedCount = 0
    private(set) var textRevision = 0
    private var batches: [Recognition] = []
    private var activation: CommandSpan?
    private var endCandidateSeenAt: Double?
    private var endCandidate: CommandSpan?
    private var endCandidatePrefix: [BatchPrefix] = []
    private var windowProcessedAt: Double?
    private var ownerSeenAt: Double?
    private var announcementStartedAt: Double?

    init(at now: Double, limits: Limits = .init(), commands: Commands = .init()) {
        preparedAt = now; self.limits = limits; self.commands = commands
    }

    var interceptsSpeech: Bool {
        [.preparing, .announcing, .waiting, .composing, .releasing].contains(phase)
    }
    var releaseRequested: Bool { [.releasing, .cancelled, .unavailable, .queued, .delivered].contains(phase) }
    var canDispatch: Bool { phase == .releasing && reason == "end-reply" && body?.isEmpty == false }

    mutating func audioStarted(at time: Double? = nil) {
        guard phase == .preparing else { return }
        announcementStartedAt = time ?? preparedAt
        phase = .announcing
    }
    // Only the instance-bound client that received prepare can acknowledge its bounded pre-audio setup. — GPT-6.1 Sol
    mutating func ownerSeen(at time: Double) {
        if phase == .preparing, time.isFinite { ownerSeenAt = time }
    }
    mutating func audioEnded(at time: Double, completed: Bool, now: Double) {
        guard phase == .preparing || phase == .announcing else { return }
        guard completed, time.isFinite, time >= preparedAt, time <= now + 0.05 else {
            cancel("announcement-not-completed"); return
        }
        if let started = announcementStartedAt, time - started > Self.maxAnnouncementSeconds {
            cancel("announcement-limit"); return
        }
        audioEndedAt = time; phase = .waiting
        evaluate(now: now)
    }

    /// Revisions replace their own batch; stable prefixes and timed controls are never counted twice. — GPT-6.1 Sol
    mutating func observe(_ value: Recognition, now: Double) {
        guard interceptsSpeech, phase != .releasing else { return }
        let tokens = Self.tokens(value.text)
        guard value.words.count == tokens.count,
              zip(value.words, tokens).allSatisfy({ $0.text == $1.word && $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              (0...value.words.count).contains(value.stableWords),
              (0...value.words.count).contains(value.confirmedStartWords) else {
            cancel("recognition-timing-unavailable"); return
        }
        if let index = batches.firstIndex(where: { $0.batch == value.batch }) {
            let previous = batches[index]
            let stable = previous.stableWords
            guard value.words.count >= stable,
                  Array(value.words.prefix(stable).map(\.text)) == Array(previous.words.prefix(stable).map(\.text)) else {
                cancel("finalized-recognition-changed"); return
            }
            if previous.text != value.text { textRevision += 1 }
            batches[index] = value
        } else { batches.append(value); textRevision += 1 }
        if let activation, activation.tokens.contains(where: {
            $0.position.batch == value.batch &&
                (!value.words.indices.contains($0.position.index) || value.words[$0.position.index].text != $0.word.text)
        }) {
            cancel("reply-prefix-revised"); return
        }
        if activation == nil, let end = audioEndedAt {
            // TTS heard before the opportunity is only context for standalone-command admission.
            batches.removeAll { $0.words.last.map { $0.end < end - 3 } ?? true }
        }
        guard batches.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768, batches.count <= 256 else {
            cancel("reply-size-limit"); return
        }
        evaluate(now: now)
    }

    mutating func tick(now: Double) {
        guard interceptsSpeech, phase != .releasing else { return }
        if phase == .preparing {
            if now - preparedAt > Self.maxSetupSeconds { cancel("announcement-setup-limit"); return }
            if now - (ownerSeenAt ?? preparedAt) > 10 { cancel("announcement-not-started"); return }
        }
        if phase == .announcing, let started = announcementStartedAt, now - started > Self.maxAnnouncementSeconds {
            cancel("announcement-limit"); return
        }
        if let ended = audioEndedAt, now - ended > limits.maxHoldSeconds { cancel("session-limit"); return }
        evaluate(now: now)
        if phase == .waiting, let passed = windowProcessedAt,
           now - passed >= limits.confirmationSeconds { cancel("no-command") }
        if phase == .composing, let accepted = acceptedAt {
            if let firstSeen = endCandidateSeenAt, now - firstSeen > limits.endConfirmationSeconds {
                cancel("end-command-unconfirmed"); return
            }
            if now - accepted >= limits.replySeconds,
               endCandidateSeenAt == nil { cancel("reply-limit"); return }
            let last = flattened().drop { !isAfterActivation($0.position) }.map { $0.word.end }.max() ?? accepted
            if now - max(accepted, last) >= limits.idleSeconds { cancel("idle-safety-limit") }
        }
    }

    mutating func processed(through time: Double, now: Double) {
        if phase == .waiting, let ended = audioEndedAt, time >= ended + limits.commandSeconds + 0.6,
           windowProcessedAt == nil { windowProcessedAt = now }
    }

    mutating func cancel(_ value: String, unavailable: Bool = false) {
        guard phase != .queued && phase != .delivered else { return }
        phase = unavailable ? .unavailable : .cancelled
        reason = value; body = nil; retireRecognition()
    }
    mutating func queued() {
        guard canDispatch else { return }
        phase = .queued; body = nil; retireRecognition()
    }
    mutating func delivered() { if phase == .queued { phase = .delivered } }

    // Terminal records keep their outcome, not the active attempt's compiled dictionary or word spans. — GPT-6.1 Sol
    private mutating func retireRecognition() {
        commands = Self.retiredCommands; batches.removeAll(); activation = nil; finalizeThrough = nil
        endCandidatePrefix.removeAll(); endCandidate = nil; endCandidateSeenAt = nil
    }

    private mutating func evaluate(now: Double) {
        let all = flattened()
        if phase == .waiting, let ended = audioEndedAt {
            for (index, item) in all.enumerated() {
                let word = item.word
                guard word.start >= ended - 0.05, word.start <= ended + limits.commandSeconds else { continue }
                let previous = index > 0 ? all[index - 1].word : nil
                let standalone = previous.map { Self.fillers.contains($0.text) || word.start - $0.end >= 0.25 } ?? true
                guard standalone else { continue }
                guard let span = replySpan(in: all, at: index) else { continue }
                if span.tokens.allSatisfy({ $0.stable || $0.confirmedStart }) {
                    activation = span; acceptedAt = span.last.word.end; acceptedCount += 1
                    phase = .composing; finalizeThrough = nil
                } else { finalizeThrough = span.last.word.end + 0.15 }
                break
            }
        }
        guard phase == .composing, let accepted = acceptedAt else { return }
        let content = all.filter { isAfterActivation($0.position) }
        // The user has already requested End at this timed boundary. A real
        // native final may include later room speech; validate the unchanged
        // prefix and finish HERE rather than swallowing End into later words.
        if let candidate = endCandidate {
            let prefixMatches = endCandidatePrefix.allSatisfy { prefix in
                guard let batch = batches.first(where: { $0.batch == prefix.batch }) else { return false }
                return batch.words.count >= prefix.words.count && Array(batch.words.prefix(prefix.words.count).map(\.text)) == prefix.words
            }
            // "And reply" may be ordinary sentence text. Unlike the canonical End,
            // an alias must remain at the end of current recognition. — GPT-6.1 Sol
            let stillEnds = candidate.canonicalEnd || candidate.last.position == content.last?.position
            if prefixMatches && stillEnds,
               let current = currentSpan(candidate, in: content), current.contiguous {
                if current.tokens.allSatisfy(\.stable), let through = finalizeThrough,
                   current.last.word.end <= through {
                    finishReply(at: current.first.position)
                }
                return
            }
            endCandidate = nil; endCandidateSeenAt = nil; endCandidatePrefix = []; finalizeThrough = nil
            textRevision += 1
        }
        // Lookup only recognized suffix lengths, independent of the number of configured spellings. — GPT-6.1 Sol
        for length in commands.endWordCounts where length <= content.count {
            let span = CommandSpan(tokens: Array(content.suffix(length)))
            let first = span.first
            guard commands.matchesEnd(span.tokens.map { $0.word.text }), span.contiguous,
                  first.word.start <= accepted + limits.replySeconds else { continue }
            let preceding = content.prefix { $0.position != first.position }.suffix(2).map { $0.word.text }
            if !beginsSentence(first.position) {
                guard !preceding.suffix(1).contains(where: { ["not", "never", "say", "saying", "phrase", "command"].contains($0) }),
                      Array(preceding) != ["don", "t"] else { continue }
            }
            if span.tokens.allSatisfy(\.stable) {
                finishReply(at: first.position)
                return
            }
            if endCandidate?.first.position != span.first.position || endCandidate?.last.position != span.last.position {
                endCandidate = span; endCandidateSeenAt = now
                endCandidatePrefix = prefixes(for: span)
                textRevision += 1
            }
            finalizeThrough = span.last.word.end + 0.15
            return
        }
        endCandidate = nil; endCandidateSeenAt = nil; endCandidatePrefix.removeAll()
    }

    private func replySpan(in all: [TimedToken], at index: Int) -> CommandSpan? {
        for length in commands.replyWordCounts where index + length <= all.count {
            let span = CommandSpan(tokens: Array(all[index..<(index + length)]))
            if commands.matchesReply(span.tokens.map { $0.word.text }) && span.contiguous { return span }
        }
        return nil
    }
    private func currentSpan(_ candidate: CommandSpan, in content: [TimedToken]) -> CommandSpan? {
        guard let first = content.firstIndex(where: { $0.position == candidate.first.position }),
              first + candidate.tokens.count <= content.count else { return nil }
        let span = CommandSpan(tokens: Array(content[first..<(first + candidate.tokens.count)]))
        return span.last.position == candidate.last.position ? span : nil
    }
    private func prefixes(for span: CommandSpan) -> [BatchPrefix] {
        batches.compactMap { batch in
            guard let last = span.tokens.last(where: { $0.position.batch == batch.batch }) else { return nil }
            return BatchPrefix(batch: batch.batch, words: Array(batch.words.prefix(last.position.index + 1).map(\.text)))
        }
    }

    private mutating func finishReply(at end: Position) {
        let text = renderBody(endingAt: end)
        guard Self.tokens(text).contains(where: { !Self.hesitations.contains($0.word) }) else {
            cancel("no-reply-content"); return
        }
        body = text; phase = .releasing; reason = "end-reply"; finalizeThrough = nil
        endCandidatePrefix.removeAll()
    }

    private struct Position: Equatable { let batch: UUID; let index: Int }
    private struct BatchPrefix { let batch: UUID; let words: [String] }
    private struct CommandSpan {
        let tokens: [TimedToken]
        var first: TimedToken { tokens[0] }
        var last: TimedToken { tokens[tokens.count - 1] }
        var canonicalEnd: Bool { tokens.map { $0.word.text } == Commands.canonicalEndForm }
        var contiguous: Bool { zip(tokens, tokens.dropFirst()).allSatisfy { $1.word.start - $0.word.end <= 0.6 } }
    }
    private func beginsSentence(_ position: Position) -> Bool {
        guard let batch = batches.first(where: { $0.batch == position.batch }) else { return false }
        if position.index == 0 { return true }
        let words = Self.tokens(batch.text)
        guard words.indices.contains(position.index) else { return false }
        return batch.text[words[position.index - 1].range.upperBound..<words[position.index].range.lowerBound]
            .contains(where: { ".!?\n".contains($0) })
    }
    private struct TimedToken { let position: Position; let word: Word; let stable: Bool; let confirmedStart: Bool }
    private func flattened() -> [TimedToken] {
        batches.flatMap { batch in batch.words.enumerated().map {
            TimedToken(position: .init(batch: batch.batch, index: $0.offset), word: $0.element,
                       stable: $0.offset < batch.stableWords, confirmedStart: $0.offset < batch.confirmedStartWords)
        } }
    }
    private func isAfterActivation(_ value: Position) -> Bool {
        guard let activation, let first = batches.firstIndex(where: { $0.batch == activation.last.position.batch }),
              let current = batches.firstIndex(where: { $0.batch == value.batch }) else { return false }
        return current > first || (current == first && value.index > activation.last.position.index)
    }
    // Ethan's "same text from H Chat" is a read-only rendering of this shared
    // recognition state, not another editable transcript or recognizer.
    var draftText: String { body ?? renderBody(endingAt: endCandidate?.first.position) }
    private func renderBody(endingAt end: Position?) -> String {
        guard let activation else { return "" }
        var parts: [String] = [], started = false
        for batch in batches {
            if batch.batch == activation.last.position.batch { started = true }
            guard started else { continue }
            let tokens = Self.tokens(batch.text)
            let first = batch.batch == activation.last.position.batch ? activation.last.position.index + 1 : 0
            let last = batch.batch == end?.batch ? end!.index : tokens.count
            if first < last, first < tokens.count {
                let upper = last < tokens.count ? tokens[last].range.lowerBound : batch.text.endIndex
                let part = String(batch.text[tokens[first].range.lowerBound..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { parts.append(part) }
            }
            if batch.batch == end?.batch { break }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func tokens(_ value: String) -> [(word: String, range: Range<String.Index>)] {
        let expression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            guard let range = Range($0.range, in: value) else { return nil }
            return (String(value[range]).lowercased(), range)
        }
    }
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "ok", "okay", "so", "oh", "right", "well"]
    private static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm"]
}
