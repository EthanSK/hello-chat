import AVFoundation
import Foundation
import Speech

// SpeechAnalyzer processes on-device. Its public API does not expose which
// processor executes recognition; never describe this as verified ANE use.
@available(macOS 26.0, *)
actor AppleLocalSpeech: SpeechBackend {
    private let phrases: [String]
    init(phrases: [String] = []) { self.phrases = phrases }
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var latest = "", emitted = "", finalized = ""
    private var failure: Error?
    private var duration = 0.0
    private var quiet = 0.0
    private var generation = UUID()

    func prepare(directory: URL) async throws -> Double {
        try await SpeechPreparationGate.shared.withPermit {
            do { try await self.load(); return 0 }
            catch { await self.close(); throw error }
        }
    }
    private func load() async throws {
        guard SpeechTranscriber.isAvailable else { throw BridgeError.message("Apple local speech isn't available.") }
        let locales = await SpeechTranscriber.installedLocales
        guard let locale = locales.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == "en-gb" }) ?? locales.first(where: { $0.language.languageCode?.identifier == "en" }) else {
            throw BridgeError.message("Apple's English speech model isn't installed. Install it in macOS before selecting Apple Speech.")
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw BridgeError.message("Apple local speech has no supported audio format.") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer; targetFormat = format
        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        try await analyzer.setContext(context)
        let token = UUID(); generation = token
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.receive(String(result.text.characters), final: result.isFinal, token: token)
                }
            } catch { await self?.failed(error, token: token) }
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(12))
        self.continuation = continuation
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: stream)
    }
    private func receive(_ text: String, final: Bool, token: UUID) {
        guard token == generation else { return }
        latest = [finalized, text].filter { !$0.isEmpty }.joined(separator: " ")
        if final { finalized = latest }
    }
    private func failed(_ error: Error, token: UUID) { if token == generation { failure = error } }
    func consume(_ mono: AVAudioPCMBuffer) async throws -> SpeechUpdate {
        try Task.checkCancellation()
        if let failure { throw failure }
        let seconds = Double(mono.frameLength) / mono.format.sampleRate
        duration += seconds
        quiet = SpeechPCM.level(mono) < 0.02 ? quiet + seconds : 0
        var reset = false
        if duration >= 120 || (duration >= 45 && quiet >= 0.8) {
            try await resetForDiscontinuity(); reset = true
        }
        guard let targetFormat, let continuation else { throw BridgeError.message("Apple local speech isn't ready.") }
        let buffer: AVAudioPCMBuffer
        if mono.format == targetFormat { buffer = mono }
        else {
            if converter?.inputFormat != mono.format { converter = AVAudioConverter(from: mono.format, to: targetFormat) }
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(ceil(Double(mono.frameLength) * targetFormat.sampleRate / mono.format.sampleRate)) + 32) else { throw BridgeError.message("Couldn't convert microphone audio for Apple Speech.") }
            var sent = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if sent { state.pointee = .noDataNow; return nil }
                sent = true; state.pointee = .haveData; return mono
            }
            if let error { throw error }
            guard status != .error else { throw BridgeError.message("Couldn't convert microphone audio for Apple Speech.") }
            buffer = converted
        }
        if buffer.frameLength > 0 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) {
                // Never silently feed discontinuous audio to the analyzer.
                try await resetForDiscontinuity()
                return SpeechUpdate(text: nil, reset: true)
            }
        }
        await Task.yield()
        guard latest != emitted, !latest.isEmpty else { return SpeechUpdate(text: nil, reset: reset) }
        emitted = latest
        return SpeechUpdate(text: latest, reset: reset)
    }
    func finish() async throws -> String {
        continuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        if let failure { throw failure }
        return latest
    }
    func resetForDiscontinuity() async throws {
        await close()
        try Task.checkCancellation()
        try await load()
    }
    func close() async {
        generation = UUID()
        continuation?.finish(); continuation = nil
        await analyzer?.cancelAndFinishNow()
        results?.cancel(); await results?.value; results = nil
        analyzer = nil; targetFormat = nil; converter = nil
        latest = ""; emitted = ""; finalized = ""; failure = nil; duration = 0; quiet = 0
    }
}
