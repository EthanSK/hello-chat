import Foundation

@main struct SpeechContinuityTests {
    static func main() async {
        var timing = SpeechTimingTracker()
        _ = timing.update("hello", at: 1, supplied: nil)
        let later = timing.update("hello chat", at: 30, supplied: nil)
        precondition(later[0].start == 1 && later[1].start == 30, "Do not renew an earlier word when text grows")
        let correction = timing.update("hallo chat", at: 31, supplied: nil)
        precondition(correction[1].start == 30, "Earlier corrections preserve the suffix time")
        let native = timing.update("hello chat", at: 40, supplied: [("hello", 10, 10.3), ("chat", 10.5, 10.8)])
        precondition(native[0].start == 10 && native[1].start == 10.5, "Prefer model audio times to delayed callback time")
        let mismatch = timing.update("hello chat", at: 50, supplied: [("other", 49, 50)])
        precondition(mismatch.count == 2 && mismatch[0].word == "hello", "Misaligned timing cannot change recognized words")
        var boundary = SpeechContextBoundary()
        precondition(boundary.accepts(capturedAt: 0) && !boundary.takeReset())
        boundary.invalidate(at: 10)
        precondition(!boundary.accepts(capturedAt: 9), "Discard audio captured during Agent Flow recording")
        precondition(boundary.accepts(capturedAt: 10) && boundary.takeReset())
        precondition(!boundary.takeReset(), "Reset only once before fresh audio")
        boundary.invalidate(at: 12)
        precondition(!boundary.accepts(capturedAt: 11), "Reject an old inference that finishes after the ownership change")
        boundary.invalidate(at: 15)
        precondition(!boundary.accepts(capturedAt: 14) && boundary.accepts(capturedAt: 15))
        var silent = AudioProgressWatchdog(now: 0)
        for time in stride(from: 1.0, through: 120.0, by: 1) {
            silent.captured(at: time); silent.processed(at: time)
            precondition(silent.stalled(at: time) == nil, "Silent audio is not a stalled pipeline")
        }
        var lostCapture = AudioProgressWatchdog(now: 10)
        precondition(lostCapture.stalled(at: 24.9) == nil)
        precondition(lostCapture.stalled(at: 25) == "capture")
        precondition(lostCapture.stalled(at: 45) == nil, "Only one recovery per session")
        var stalledWorker = AudioProgressWatchdog(now: 0)
        stalledWorker.captured(at: 14)
        precondition(stalledWorker.stalled(at: 15) == "processing")
        var resumed = AudioProgressWatchdog(now: 50)
        resumed.captured(at: 60); resumed.processed(at: 60)
        precondition(resumed.stalled(at: 64) == nil, "New session resets timeout")
        var continuity = SpeechContinuity()
        precondition(!continuity.hasGap(sequence: 0))
        precondition(!continuity.hasGap(sequence: 1))
        precondition(continuity.hasGap(sequence: 9))
        precondition(!continuity.hasGap(sequence: 10))
        // Exercise the same queue policy with an actual dropped-buffer event.
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(2))
        continuation.yield(0); continuation.yield(1)
        if case .dropped(let old) = continuation.yield(2) { precondition(old == 0) }
        else { fatalError("Expected stale audio to be dropped") }
        continuation.finish()
        var detector = SpeechContinuity(), resets = 0, received: [UInt64] = []
        for await value in stream {
            if detector.hasGap(sequence: value) { resets += 1 }
            received.append(value)
        }
        precondition(received == [1, 2] && resets == 1)
        // Reproduce the live failure: resetting takes long enough for more
        // input to overflow. Those queued gaps belong to the same recovery.
        var slowReset = SpeechContinuity()
        precondition(!slowReset.hasGap(sequence: 0))
        precondition(slowReset.hasGap(sequence: 15))
        slowReset.resetCompleted(at: 3)
        for capturedAt in [1.0, 1.5, 2.9] {
            precondition(!slowReset.accepts(capturedAt: capturedAt), "Do not decode stale recovery backlog")
        }
        precondition(slowReset.accepts(capturedAt: 3))
        precondition(!slowReset.hasGap(sequence: 42), "First fresh frame must not trigger another reset")
        precondition(!slowReset.hasGap(sequence: 43))
        precondition(slowReset.hasGap(sequence: 47), "A later independent drop must still reset recognition")
        slowReset.resetCompleted(at: 5)
        precondition(!slowReset.accepts(capturedAt: 4.9) && slowReset.accepts(capturedAt: 5.1))
        precondition(!slowReset.hasGap(sequence: 60) && !slowReset.hasGap(sequence: 61))
        var throttle = CaptureRestartThrottle()
        for time in [0.0, 0.5, 1.0] {
            precondition(throttle.delay(at: time) == 0)
            throttle.started(at: time)
        }
        precondition(throttle.delay(at: 1.5) == 8.5)
        precondition(throttle.delay(at: 2) == 8, "A cancelled request must not push the deadline out")
        precondition(throttle.delay(at: 10) == 0)
        throttle.started(at: 10)
        precondition(throttle.delay(at: 10.1) > 0)
        precondition(throttle.delay(at: 20) == 0)
        let timeout = NSError(domain: "com.apple.CoreML", code: 0)
        precondition(SpeechRecovery.isTransient(timeout))
        precondition(SpeechRecovery.isTransient(NSError(domain: "wrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: timeout])))
        precondition(!SpeechRecovery.isTransient(NSError(domain: "configuration", code: 1)))
        var recovery = SpeechRecovery()
        for _ in 0..<3 { precondition(recovery.retry()) }
        precondition(!recovery.retry(), "Persistent failure must not cause unlimited model reloads")
        // A successful prepare alone is insufficient: a model can fail on its
        // first prediction. Only sustained processed audio restores retries.
        recovery.processed(at: 100)
        recovery.processed(at: 114.9)
        precondition(recovery.attempts == 3)
        recovery.processed(at: 115)
        precondition(recovery.attempts == 0 && recovery.retry())
        precondition(!SpeechRecovery.isTransient(CancellationError()))
        recovery = SpeechRecovery() // Eligible dock/wake/manual restart.
        precondition(recovery.retry())
        print("Passed audio backlog recovery checks: bounded newest buffers, dropped-frame detection, one reset and continued processing. No capture, playback or Voice calls used.")
    }
}
