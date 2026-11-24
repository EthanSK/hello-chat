import Foundation

// Prefer audio timestamps. If a backend omits them, retain the first observed
// time of unchanged words across revisions so appending "chat" cannot renew
// an old "hello". Context resets discard this bounded transcript state.
struct SpeechTimingTracker {
    private var previous: [(word: String, start: Double, end: Double)] = []
    mutating func update(_ text: String, at time: Double,
                         supplied: [(word: String, start: Double, end: Double)]?) -> [(word: String, start: Double, end: Double)] {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if let supplied, supplied.map(\.word) == words {
            previous = supplied
            return supplied
        }
        let prefix = zip(words, previous).prefix { $0.0 == $0.1.word }.count
        var result = Array(previous.prefix(prefix))
        result += words.dropFirst(prefix).map { (word: $0, start: time, end: time) }
        // Preserve a stable suffix when an earlier word is corrected.
        var index = words.count - 1, oldIndex = previous.count - 1
        while index >= prefix, oldIndex >= prefix, words[index] == previous[oldIndex].word {
            result[index] = previous[oldIndex]; index -= 1; oldIndex -= 1
        }
        previous = result
        return result
    }
}

// Ethan's "self recover": retry transient local model failures, but do not
// spin forever when Core ML is unavailable. Real audio progress replenishes
// the budget; a dock/wake or explicit user change can start another episode.
struct SpeechRecovery {
    private(set) var attempts = 0
    private var healthySince: Double?
    mutating func retry() -> Bool {
        healthySince = nil
        guard attempts < 3 else { return false }
        attempts += 1
        return true
    }
    mutating func processed(at now: Double) {
        if healthySince == nil { healthySince = now }
        if now - healthySince! >= 15 { attempts = 0 }
    }
    static func isTransient(_ error: Error) -> Bool {
        var error = error as NSError
        // Core ML can wrap the device-service timeout in an underlying error.
        for _ in 0..<8 {
            if error.domain == "com.apple.CoreML" { return true }
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying !== error else { return false }
            error = underlying
        }
        return false
    }
}

// Changing recording ownership invalidates both queued audio and an inference
// already in flight. Reset once at the first new frame, without reloading models.
struct SpeechContextBoundary {
    private var cutoff = -Double.infinity
    private var resetPending = false
    private(set) var nextSequence: UInt64?
    mutating func invalidate(at time: Double, nextSequence: UInt64? = nil) {
        cutoff = time; resetPending = true; self.nextSequence = nextSequence
    }
    func accepts(capturedAt time: Double) -> Bool { time >= cutoff }
    func accepts(sequence: UInt64, capturedAt time: Double) -> Bool {
        accepts(capturedAt: time) && nextSequence.map { sequence >= $0 } != false
    }
    mutating func takeReset() -> Bool {
        let value = resetPending; resetPending = false; return value
    }
}

// Snapshot the existing producer's clock and next frame together. A frame published
// after a boundary can otherwise be mistaken for deliberately discarded old audio. — GPT-6.1 Sol
final class SpeechCaptureCursor: @unchecked Sendable {
    struct Mark { let sequence: UInt64; let capturedAt: Double }
    private let lock = NSLock()
    private var next: UInt64 = 0
    private let clock: () -> Double
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    func capture() -> Mark {
        lock.lock(); defer { lock.unlock() }
        let mark = Mark(sequence: next, capturedAt: clock())
        next &+= 1
        return mark
    }
    func boundary() -> Mark {
        lock.lock(); defer { lock.unlock() }
        return Mark(sequence: next, capturedAt: clock())
    }
}

// Watch frame progress, never recognized words: silence is valid live audio.
// One recovery per session prevents a stalled source from spamming restarts.
struct AudioProgressWatchdog {
    private var captureAt: Double
    private var processedAt: Double
    private var reported = false
    init(now: Double) { captureAt = now; processedAt = now }
    mutating func captured(at now: Double) { captureAt = now }
    mutating func processed(at now: Double) { processedAt = now }
    mutating func stalled(at now: Double, timeout: Double = 15) -> String? {
        guard !reported, now - processedAt >= timeout else { return nil }
        reported = true
        return now - captureAt >= timeout ? "capture" : "processing"
    }
}

// A bounded newest-audio queue can skip buffers when the Mac is temporarily
// busy. Reset recognition across that gap rather than combining unrelated
// pieces of speech or permanently disabling the detector.
struct SpeechContinuity {
    struct Admission { let contextReset: Bool; let audioGap: Bool }
    // Hold two seconds of already captured live audio during brief CPU stalls.
    // An empty queue delivers immediately. Longer overruns still reset recognition.
    static let captureFrames: UInt32 = 4096
    static func liveBufferCount(sampleRate: Double) -> Int {
        Int(min(128, max(2, ceil(sampleRate * 2 / Double(captureFrames)))))
    }
    private(set) var missingFrames: UInt64 = 0
    private var next: UInt64? = 0
    private var discardBefore = -Double.infinity
    // Intentional context disposal is not capture loss. Rebase to the boundary's
    // exact producer cursor, so real loss AFTER that boundary still cancels replies.
    // Found and fixed by GPT-6.1 Sol.
    mutating func admit(sequence: UInt64, capturedAt: Double, boundary: inout SpeechContextBoundary) -> Admission? {
        guard boundary.accepts(sequence: sequence, capturedAt: capturedAt), accepts(capturedAt: capturedAt) else { return nil }
        let reset = boundary.takeReset()
        if reset, let expected = boundary.nextSequence { next = expected }
        return Admission(contextReset: reset, audioGap: hasGap(sequence: sequence))
    }
    func accepts(capturedAt time: Double) -> Bool { time >= discardBefore }
    mutating func resetCompleted(at time: Double) {
        // A slow model reset can itself overflow the bounded input queue.
        // Discard that backlog and rebase on the first fresh frame, rather
        // than repeatedly resetting for audio lost during the same recovery.
        discardBefore = time
        next = nil
    }
    mutating func hasGap(sequence: UInt64) -> Bool {
        defer { next = sequence &+ 1 }
        missingFrames = next.flatMap { sequence >= $0 ? sequence - $0 : nil } ?? 0
        guard let next else { return false }
        return sequence != next
    }
}

// Bound model reloads even if the OS keeps changing its default audio route.
// A cancelled/debounced request does not consume an attempt.
struct CaptureRestartThrottle {
    private var starts: [Double] = []
    mutating func delay(at now: Double) -> Double {
        starts.removeAll { $0 <= now - 10 }
        return starts.count < 3 ? 0 : max(0, starts[0] + 10 - now)
    }
    mutating func started(at now: Double) {
        starts.removeAll { $0 <= now - 10 }
        starts.append(now)
    }
}
