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
    @MainActor func testRecordedInitialReplyThroughActualListener() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HCHAT_NOTIFICATION_END_WAV"], let directory = environment["HCHAT_NOTIFICATION_MODEL_DIR"] else {
            throw XCTSkip("Opt-in local recorded listener check; no live microphone.")
        }
        let listener = SpeechListener(diagnostics: nil)
        listener.model = .nemotron560
        let start = Diagnostics.now
        var core = NotificationReplyCore(at: start - 10)
        var initialRequests = 0, resets = 0, bodySeen = false, nativeConfirmed = false
        var requestedAt: Double?, finalSeconds: Double?
        var failure: Error?
        listener.needsReplyRecognition = { core.interceptsSpeech }
        listener.onSession = {
            resets += 1
            if resets == 1 { let now = Diagnostics.now; core.audioEnded(at: now, completed: true, now: now) }
        }
        listener.onError = { failure = $0 }
        listener.onReplyRecognition = { value in
            let wasWaiting = core.phase == .waiting
            core.observe(value, now: Diagnostics.now)
            if wasWaiting, core.confirmingReply, let through = core.finalizeThrough {
                initialRequests += 1
                if requestedAt == nil { requestedAt = Diagnostics.now }
                listener.finalizeReplyRecognition(through: through)
            }
            if wasWaiting, core.acceptedCount == 1, value.stableWords > 0, let at = requestedAt {
                nativeConfirmed = true; finalSeconds = Diagnostics.now - at
            }
            if core.acceptedCount == 1, !core.draftText.isEmpty || core.body?.isEmpty == false { bodySeen = true }
        }
        try await listener.start(recording: URL(fileURLWithPath: path), channels: 1,
                                 recordedModelDirectory: URL(fileURLWithPath: directory))
        await listener.waitForRecording()
        listener.stop(); await listener.waitUntilStopped()
        XCTAssertNil(failure)
        XCTAssertGreaterThan(initialRequests, 0, "The actual listener must receive a partial timely Reply and invoke initial native finalization")
        XCTAssertTrue(nativeConfirmed, "Generic no-op finalization cannot satisfy this real listener regression")
        XCTAssertEqual(core.acceptedCount, 1)
        XCTAssertTrue(bodySeen, "Following reply words survive the native final and next reset")
        XCTAssertGreaterThan(resets, 1, "Subsequent real frames pass the provider reset boundary")
        let duration = try XCTUnwrap(finalSeconds)
        print("Actual listener initial native confirmation seconds: \(duration)")
        XCTAssertLessThan(duration, core.limits.confirmationSeconds)
    }
    func testRecordedNemotronEndWithoutQuiet() async throws { try await recordedCommand(initial: false) }
    func testRecordedNemotronInitialReplyWithoutQuiet() async throws { try await recordedCommand(initial: true) }
    private func recordedCommand(initial: Bool) async throws {
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
            guard initial ? core.confirmingReply : core.phase == .composing, let through = core.finalizeThrough,
                  let modelTime = adapter.modelTime(for: through) else { continue }
            XCTAssertFalse(endedNaturally, "The regression must not depend on room silence/EOU.")
            let missing: any SpeechBackend = MissingFinalizer(backend)
            let absent = try await missing.finalizeNotificationCommand(through: modelTime)
            XCTAssertNil(absent, "Negative control reproduces the old no-op.")
            XCTAssertFalse(core.canDispatch)
            let startedFinal = ProcessInfo.processInfo.systemUptime
            let nativeFinal = try await backend.finalizeNotificationCommand(through: modelTime)
            let finishSeconds = ProcessInfo.processInfo.systemUptime - startedFinal
            print("Recorded native \(initial ? "Reply" : "End") finish seconds: \(finishSeconds)")
            XCTAssertLessThan(finishSeconds, initial ? core.limits.confirmationSeconds : core.limits.endConfirmationSeconds)
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
            if initial {
                XCTAssertEqual(core.acceptedCount, 1, "The actual native final must confirm initial Reply through its full-input clock")
                XCTAssertTrue(core.phase == .composing || core.canDispatch)
                XCTAssertFalse(core.draftText.isEmpty, "Words already following Reply in that real final must remain captured")
            } else { XCTAssertTrue(core.canDispatch, "The real native final must confirm End reply.") }
            XCTAssertFalse(core.body?.lowercased().contains("end reply") ?? true)
            let body = core.body
            core.observe(recognition, now: base + elapsed + 0.1)
            XCTAssertEqual(core.body, body, "Duplicate finalization cannot append or replay.")
            let following = try await backend.consume(mono)
            XCTAssertTrue(following.reset, "SDK padding/tokens must not leak into ordinary following input.")
            XCTAssertLessThan(following.inputAudioTime ?? 100, 2)
            completed = true; break
        }
        XCTAssertTrue(completed, "Recorded fixture must reach an actual partial command candidate.")
    }
}
