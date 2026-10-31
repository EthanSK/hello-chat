import AVFoundation
import Foundation
import Darwin

struct SpeechCheckResult {
    var text: String
    var commands: [PhraseCommand]
    var neuralShare: Double
    var cpuSeconds = 0.0
    var audioSeconds = 0.0
    var detections: [[String: Any]] = []
    var segments: [String] = []
    var gaps = 0
    var resets = 0
    var utteranceEnds = 0
}
@MainActor final class SpeechCheck {
    func run(url: URL, channels: Int = 20, similar: Bool = true, recoverBeforeAudio: Bool = false, model: SpeechModel = .parakeet320, standalone: Bool = false) async -> SpeechCheckResult {
        let listener = SpeechListener(diagnostics: nil)
        listener.model = model
        var matcher = PhraseMatcher()
        var standaloneWake = StandaloneWake()
        var commands: [PhraseCommand] = []
        var text = ""
        var share = 0.0
        var started = Diagnostics.now
        var detections: [[String: Any]] = []
        var segments: [String] = []
        var gaps = 0, sessions = 0
        var utteranceEnds = 0
        listener.onDelay = { gaps += 1 }
        listener.onSession = {
            sessions += 1
            if !text.isEmpty { segments.append(text); if segments.count > 8 { segments.removeFirst() }; text = "" }
            matcher.reset()
            standaloneWake.resetContext()
        }
        listener.onComputePlan = { share = $0 }
        listener.onAudioActivity = { level, seconds in standaloneWake.audio(level: level, seconds: seconds) }
        listener.onUtteranceEnd = {
            utteranceEnds += 1
            standaloneWake.utteranceEnded()
        }
        listener.onFrame = { [weak listener] in
            if standalone, standaloneWake.poll(at: Diagnostics.now, phrase: "Hello Chat", similar: similar,
                                               requireModelEnd: model.hasNativeUtteranceEnd) {
                commands.append(.wake)
                detections.append(["command": "wake", "elapsed_ms": (Diagnostics.now - started) * 1000,
                                   "audio_seconds": listener?.resultAudioSeconds ?? 0, "after_flush": listener?.resultWasFlushed ?? false,
                                   "completion": model.hasNativeUtteranceEnd ? "model_eou" : "audio_silence"])
            }
        }
        listener.onText = { [weak listener] value in
            text = value
            standaloneWake.update(value, at: Diagnostics.now)
            if let command = matcher.consume(value, wake: standalone ? "" : "Hello Chat", sleep: "Bye Chat", similar: similar) {
                if standalone, command == .sleep {
                    standaloneWake.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: similar)
                }
                commands.append(command)
                detections.append(["command": command == .wake ? "wake" : "end", "elapsed_ms": (Diagnostics.now - started) * 1000,
                                   "audio_seconds": listener?.resultAudioSeconds ?? 0, "after_flush": listener?.resultWasFlushed ?? false])
            }
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate + 1
            try await listener.start(recording: url, channels: channels, recoverBeforeAudio: recoverBeforeAudio)
            let cpuStart = Self.cpuTime()
            started = Diagnostics.now
            await listener.waitForRecording()
            let failure = listener.recordingError
            listener.stop(); listener.onText = nil; listener.onSession = nil
            await listener.waitUntilStopped()
            return .init(text: failure ?? text, commands: failure == nil ? commands : [], neuralShare: share,
                         cpuSeconds: Self.cpuTime() - cpuStart, audioSeconds: audioSeconds, detections: detections, segments: segments + [text], gaps: gaps, resets: max(0, sessions - 1), utteranceEnds: utteranceEnds)
        } catch {
            listener.stop(); listener.onText = nil; listener.onSession = nil
            await listener.waitUntilStopped()
            return .init(text: error.localizedDescription, commands: [], neuralShare: share)
        }
    }
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
