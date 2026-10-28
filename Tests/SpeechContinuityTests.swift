import Foundation

@main struct SpeechContinuityTests {
    static func main() async {
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
        print("Passed audio backlog recovery checks: bounded newest buffers, dropped-frame detection, one reset and continued processing. No capture, playback or Voice calls used.")
    }
}
