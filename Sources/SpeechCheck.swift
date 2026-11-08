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
    var startupBoundary = ""
}
@MainActor final class SpeechCheck {
    func run(url: URL, channels: Int = 20, similar: Bool = true, recoverBeforeAudio: Bool = false, model: SpeechModel = .defaultModel, standalone: Bool = false, captureStartup: Bool = false) async -> SpeechCheckResult {
        let listener = SpeechListener(diagnostics: nil)
        listener.model = model
        var matcher = PhraseMatcher()
        var standaloneWake = StandaloneWake()
        var standaloneEnd = StandaloneWake()
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
        var startupBoundary = ""
        listener.onDelay = { gaps += 1 }
        listener.onSession = {
            // Same startup policy as GateModel: a context reset continues capture.
            if !startupReady { startup?.boundary() }
            sessions += 1
            if !text.isEmpty { segments.append(text); if segments.count > 8 { segments.removeFirst() }; text = "" }
            matcher.reset()
            standaloneWake.resetContext()
            standaloneEnd.resetContext()
        }
        listener.onComputePlan = { share = $0 }
        listener.onAudioActivity = { level, seconds, audioTime in
            standaloneWake.audio(level: level, seconds: seconds, at: audioTime)
            standaloneEnd.audio(level: level, seconds: seconds, at: audioTime)
            if !startupReady {
                if level >= 0.02 { startup?.speechResumed() }
                startup?.audioProcessed(seconds: seconds)
            }
        }
        listener.onUtteranceEnd = {
            utteranceEnds += 1
            if !startupReady, var capture = startup {
                startupReady = capture.markUtteranceEnded(); startup = capture
                if startupReady { startupBoundary = StartupSpeechFile.Boundary.utterance.rawValue }
            }
        }
        listener.onFrame = { [weak listener] in
            if !startupReady, let boundary = startup?.boundaryReached {
                startupReady = true; startupBoundary = boundary.rawValue
            }
            if standalone || captureStartup, standaloneEnd.pollEnd(at: Diagnostics.now, phrase: "Bye Chat", similar: similar) {
                standaloneWake.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: similar)
                commands.append(.sleep)
                detections.append(["command": "end", "elapsed_ms": (Diagnostics.now - started) * 1000,
                                   "audio_seconds": listener?.resultAudioSeconds ?? 0, "after_flush": listener?.resultWasFlushed ?? false])
            } else if standalone || captureStartup, standaloneWake.poll(at: Diagnostics.now, phrase: "Hello Chat", similar: similar) {
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
            standaloneEnd.update(value, at: Diagnostics.now, timings: timings)
            if !standalone && !captureStartup, let command = matcher.consume(value, wake: "Hello Chat", sleep: "Bye Chat", similar: similar, timings: timings) { // Recognition-only checks remain distinct from the paused command path above.
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
                         startupSpeech: startup?.text ?? "", startupReady: startupReady, startupAtVoiceOpen: startupAtVoiceOpen,
                         startupBoundary: startupBoundary)
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
