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
    mutating func invalidate(at time: Double) { cutoff = time; resetPending = true }
    func accepts(capturedAt time: Double) -> Bool { time >= cutoff }
    mutating func takeReset() -> Bool {
        let value = resetPending; resetPending = false; return value
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
    private var next: UInt64 = 0
    mutating func hasGap(sequence: UInt64) -> Bool {
        defer { next = sequence &+ 1 }
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
