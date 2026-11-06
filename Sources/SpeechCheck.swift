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
    var startupSpeech = ""
    var startupReady = false
    var startupAtVoiceOpen = ""
}
@MainActor final class SpeechCheck {
    func run(url: URL, channels: Int = 20, similar: Bool = true, recoverBeforeAudio: Bool = false, model: SpeechModel = .defaultModel, standalone: Bool = false, captureStartup: Bool = false) async -> SpeechCheckResult {
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
        var startup: StartupSpeechBuffer?
        var startupReady = false
        var startupAtVoiceOpen = ""
        listener.onDelay = { gaps += 1 }
        listener.onSession = {
            if startup != nil { startupReady = true }
            sessions += 1
            if !text.isEmpty { segments.append(text); if segments.count > 8 { segments.removeFirst() }; text = "" }
            matcher.reset()
            standaloneWake.resetContext()
        }
        listener.onComputePlan = { share = $0 }
        listener.onAudioActivity = { level, seconds in standaloneWake.audio(level: level, seconds: seconds) }
        listener.onUtteranceEnd = {
            utteranceEnds += 1
            if var capture = startup { startupReady = capture.markUtteranceEnded(); startup = capture }
        }
        listener.onFrame = { [weak listener] in
            if standalone || captureStartup, standaloneWake.poll(at: Diagnostics.now, phrase: "Hello Chat", similar: similar) {
                commands.append(.wake)
                if captureStartup, startup == nil {
                    // Simulate the fastest possible native connection. Later
                    // real ASR hypotheses must still complete this same buffer.
                    var capture = StartupSpeechBuffer(id: UUID(), text: text, wakeRange: standaloneWake.acceptedRange, phrase: "Hello Chat", similar: similar)
                    startupAtVoiceOpen = capture.text
                    _ = capture.markVoiceOpened()
                    startup = capture
                }
                detections.append(["command": "wake", "elapsed_ms": (Diagnostics.now - started) * 1000,
                                   "audio_seconds": listener?.resultAudioSeconds ?? 0, "after_flush": listener?.resultWasFlushed ?? false])
            }
        }
        listener.onText = { [weak listener] value, timings in
            text = value
            if !startupReady { startup?.observe(value) }
            standaloneWake.update(value, at: Diagnostics.now, timings: timings)
            if let command = matcher.consume(value, wake: standalone ? "" : "Hello Chat", sleep: "Bye Chat", similar: similar, timings: timings) {
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
                         cpuSeconds: Self.cpuTime() - cpuStart, audioSeconds: audioSeconds, detections: detections, segments: segments + [text], gaps: gaps, resets: max(0, sessions - 1), utteranceEnds: utteranceEnds,
                         startupSpeech: startup?.text ?? "", startupReady: startupReady, startupAtVoiceOpen: startupAtVoiceOpen)
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
