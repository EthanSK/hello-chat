import Foundation

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
