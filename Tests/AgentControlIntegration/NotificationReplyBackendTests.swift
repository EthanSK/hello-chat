// Opt-in recorded-input proof of the REAL selected backend; never opens a microphone or plays audio.
import AVFoundation
import XCTest
@testable import HelloChat

final class NotificationReplyBackendTests: XCTestCase {
    private actor MissingFinalizer: SpeechBackend {
        let real: NeuralSpeech
        init(_ real: NeuralSpeech) { self.real = real }
        func prepare(directory: URL) async throws -> Double { try await real.prepare(directory: directory) }
        func consume(_ buffer: AVAudioPCMBuffer) async throws -> SpeechUpdate { try await real.consume(buffer) }
        func finish() async throws -> String { try await real.finish() }
        func resetForDiscontinuity() async throws { try await real.resetForDiscontinuity() }
        func close() async { await real.close() }
        // Deliberately inherits the old no-op finalization behavior.
    }
    func testRecordedNemotronEndWithoutQuiet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HCHAT_NOTIFICATION_END_WAV"],
              let directory = environment["HCHAT_NOTIFICATION_MODEL_DIR"] else {
            throw XCTSkip("Opt-in local recorded backend check; no live microphone.")
        }
        let backend = NeuralSpeech(model: .nemotron560)
        addTeardownBlock { await backend.close() }
        _ = try await backend.prepare(directory: URL(fileURLWithPath: directory))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let base = 1000.0
        var core = NotificationReplyCore(at: base - 10)
        core.audioEnded(at: base, completed: true, now: base)
        var adapter = NotificationReplySpeech(), elapsed = 0.0, endedNaturally = false
        var completed = false
        var continuingFrames = Int(file.processingFormat.sampleRate * 0.8)
        var toneFrame = 0
        while file.framePosition < file.length || continuingFrames > 0 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
            if file.framePosition < file.length { try file.read(into: buffer) }
            else {
                // Real continuing (nonquiet) input drains the final speech chunk;
                // do not satisfy the test with Nemotron's room-quiet fallback.
                let count = min(1024, continuingFrames)
                buffer.frameLength = AVAudioFrameCount(count)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                for index in 0..<count {
                    channel[index] = Float(sin(Double(toneFrame + index) * 2 * .pi * 300 / buffer.format.sampleRate)) * 0.05
                }
                toneFrame += count; continuingFrames -= count
            }
            guard buffer.frameLength > 0 else { break }
            let mono = try XCTUnwrap(SpeechPCM.mono(buffer))
            elapsed += Double(mono.frameLength) / mono.format.sampleRate
            let update = try await backend.consume(mono)
            if update.reset { adapter.boundary() }
            endedNaturally = endedNaturally || update.utteranceEnded
            if let recognition = adapter.observe(text: update.text, timings: update.wordTimings,
                inputTime: update.inputAudioTime, capturedAt: base + elapsed,
                finalWords: update.finalizedWordCount, ended: update.utteranceEnded, revision: update.recognitionRevision) {
                core.observe(recognition, now: base + elapsed)
            }
            if let text = update.text {
                print("Recorded partial: \(text) · phase=\(core.phase.rawValue) · input=\(update.inputAudioTime ?? -1) · end=\(String(describing: core.finalizeThrough))")
            }
            guard core.phase == .composing, let through = core.finalizeThrough,
                  let modelTime = adapter.modelTime(for: through) else { continue }
            XCTAssertFalse(endedNaturally, "The regression must not depend on room silence/EOU.")
            let missing: any SpeechBackend = MissingFinalizer(backend)
            let absent = try await missing.finalizeNotificationEnd(through: modelTime)
            XCTAssertNil(absent, "Negative control reproduces the old no-op.")
            XCTAssertFalse(core.canDispatch)
            let startedFinal = ProcessInfo.processInfo.systemUptime
            let nativeFinal = try await backend.finalizeNotificationEnd(through: modelTime)
            let finishSeconds = ProcessInfo.processInfo.systemUptime - startedFinal
            print("Recorded native End finish seconds: \(finishSeconds)")
            XCTAssertLessThan(finishSeconds, core.limits.endConfirmationSeconds)
            let final = try XCTUnwrap(nativeFinal)
            XCTAssertGreaterThan(final.finalizedWordCount ?? 0, 0)
            let recognition = try XCTUnwrap(adapter.observe(text: final.text, timings: final.wordTimings,
                inputTime: final.inputAudioTime, capturedAt: base + elapsed,
                finalWords: final.finalizedWordCount, ended: final.utteranceEnded))
            var delayed = core
            delayed.tick(now: base + elapsed + 4)
            delayed.observe(recognition, now: base + elapsed + 4)
            XCTAssertFalse(delayed.canDispatch, "A late real final cannot revive a cancelled reply.")
            core.observe(recognition, now: base + elapsed)
            XCTAssertTrue(core.canDispatch, "The real native final must confirm End reply.")
            XCTAssertFalse(core.body?.lowercased().contains("end reply") ?? true)
            let body = core.body
            core.observe(recognition, now: base + elapsed + 0.1)
            XCTAssertEqual(core.body, body, "Duplicate finalization cannot append or replay.")
            let following = try await backend.consume(mono)
            XCTAssertTrue(following.reset, "SDK padding/tokens must not leak into ordinary following input.")
            XCTAssertLessThan(following.inputAudioTime ?? 100, 2)
            completed = true; break
        }
        XCTAssertTrue(completed, "Recorded fixture must reach an actual partial End candidate.")
    }
}
