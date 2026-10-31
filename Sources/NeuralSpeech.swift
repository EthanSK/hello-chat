import AVFoundation
import CoreML
import FluidAudio
import Foundation

// Local recognition only. Model download belongs to the build, never listening.
// Core ML permits CPU and ANE; it has no public ANE-only execution mode. Refuse
// a CPU-only / CPU-majority encoder plan rather than silently ignoring ANE.
actor NeuralSpeech: SpeechBackend {
    private let configuration: MLModelConfiguration
    private let manager: StreamingEouAsrManager?
    private let nemotron: StreamingNemotronAsrManager?
    private let model: SpeechModel
    private let resampler = SpeechResampler()
    private var rollover = SpeechRollover()
    private var onset = SpeechOnset()
    private var recentAudio: [AVAudioPCMBuffer] = []
    private var recentSeconds = 0.0
    private var previousText = ""
    private var completedUtterance = false
    private var utteranceHasText = false

    init(model: SpeechModel = .defaultModel) {
        self.model = model
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        self.configuration = configuration
        manager = model == .nemotron560 ? nil : StreamingEouAsrManager(configuration: configuration,
            chunkSize: model == .parakeet160 ? .ms160 : .ms320,
            eouDebounceMs: .max)
        nemotron = model == .nemotron560 ? StreamingNemotronAsrManager(configuration: configuration, requestedChunkSize: .ms560) : nil
    }

    func prepare(directory: URL) async throws -> Double {
        try await SpeechPreparationGate.shared.withPermit {
            do { return try await self.loadAndPrime(directory: directory) }
            catch { await self.close(); throw error }
        }
    }
    private func loadAndPrime(directory: URL) async throws -> Double {
        guard MLComputeDevice.allComputeDevices.contains(where: { if case .neuralEngine = $0 { return true }; return false }) else {
            throw BridgeError.message("Neural Engine isn't available. Local listening stays off.")
        }
        let share = try await NeuralPlan.shared.check(directory: directory, encoder: model.encoderPath)
        try Task.checkCancellation()
        if let manager { try await manager.loadModels(from: directory) }
        if let nemotron { try await nemotron.loadModels(from: directory) }
        try Task.checkCancellation()
        try await prime()
        try Task.checkCancellation()
        return share
    }

    // One second of context prevents the streaming encoder losing words spoken
    // immediately after Start / rollover. The recorded check uses the same path.
    private func prime() async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000),
              let samples = buffer.floatChannelData?[0] else { throw BridgeError.message("Couldn't prepare local speech recognition.") }
        buffer.frameLength = 16000
        samples.initialize(repeating: 0, count: 16000)
        try await process(buffer)
    }

    func consume(_ mono: AVAudioPCMBuffer) async throws -> SpeechUpdate {
        try Task.checkCancellation()
        var reset = false
        let duration = Double(mono.frameLength) / mono.format.sampleRate
        let quiet = SpeechPCM.level(mono) < 0.02
        recentAudio.append(mono); recentSeconds += duration
        while recentAudio.count > 1, recentSeconds - Double(recentAudio[0].frameLength) / recentAudio[0].format.sampleRate >= 0.5 {
            let old = recentAudio.removeFirst()
            recentSeconds -= Double(old.frameLength) / old.format.sampleRate
        }
        let beginsAfterPause = onset.consumed(seconds: duration, quiet: quiet)
        if beginsAfterPause || (completedUtterance && !quiet) {
            // Re-prime at an utterance onset after a long quiet gap. Retain a
            // short lead-in so a quiet first consonant is never gated away.
            let leadIn = recentAudio
            try await resetForDiscontinuity()
            for buffer in leadIn { try await process(buffer) }
            reset = true
        } else if rollover.shouldReset {
            try await resetForDiscontinuity()
            reset = true
            try await process(mono)
        } else {
            try await process(mono)
        }
        rollover.consumed(seconds: duration, quiet: quiet)
        let text = await partial()
        if let manager, !utteranceHasText, !text.isEmpty {
            // The SDK latches EOU until reset. Silent priming / waiting must
            // not spend that one-shot signal before any words are recognized.
            await manager.setUtteranceEndDebounce(milliseconds: Int(StandaloneWake.endSilenceSeconds * 1000))
            utteranceHasText = true
        }
        var ended = false
        if let manager, !completedUtterance, !text.isEmpty, await manager.eouDetected {
            completedUtterance = true; ended = true
        }
        let changed = !text.isEmpty && text != previousText
        if changed { previousText = text }
        return SpeechUpdate(text: changed ? text : nil, reset: reset, utteranceEnded: ended)
    }
    func finish() async throws -> String {
        try await prime()
        if let manager { return try await manager.finish() }
        return try await nemotron!.finish()
    }
    func resetForDiscontinuity() async throws {
        try Task.checkCancellation()
        if let manager { await manager.reset() }
        if let nemotron { await nemotron.reset() }
        resampler.reset()
        if let manager { await manager.setUtteranceEndDebounce(milliseconds: .max) }
        try await prime()
        rollover = SpeechRollover(); previousText = ""
        onset = SpeechOnset(); recentAudio.removeAll(); recentSeconds = 0; completedUtterance = false; utteranceHasText = false
    }
    func close() async {
        resampler.reset()
        if let manager { await manager.cleanup() }
        if let nemotron { await nemotron.cleanup() }
        recentAudio.removeAll(); recentSeconds = 0; previousText = ""
        rollover = SpeechRollover(); onset = SpeechOnset(); completedUtterance = false; utteranceHasText = false
    }

    private func process(_ input: AVAudioPCMBuffer) async throws {
        guard let buffer = try resampler.convert(input) else { return }
        if let manager { _ = try await manager.process(audioBuffer: buffer) }
        if let nemotron { _ = try await nemotron.process(audioBuffer: buffer) }
    }
    private func partial() async -> String {
        if let manager { return await manager.getPartialTranscript() }
        return await nemotron!.getPartialTranscript()
    }
    static var modelDirectory: URL? { Bundle.main.resourceURL?.appendingPathComponent("LocalSpeech", isDirectory: true) }
}

// Isolated configuration keeps the SDK actor's public setting on its actor.
private extension StreamingEouAsrManager {
    func setUtteranceEndDebounce(milliseconds: Int) { eouDebounceMs = milliseconds }
}

// Keep only the checked scalar result, not a second loaded model/plan. It is
// valid for this process's signed model bundle and fixed compute configuration.
private actor NeuralPlan {
    static let shared = NeuralPlan()
    private var shares: [URL: Double] = [:]
    func check(directory: URL, encoder: String) async throws -> Double {
        let modelURL = directory.appendingPathComponent(encoder)
        if let share = shares[modelURL] { return share }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: configuration)
        var ane = 0.0, other = 0.0
        func inspect(_ operations: [MLModelStructure.Program.Operation]) {
            for operation in operations {
                let cost = plan.estimatedCost(of: operation)?.weight ?? 0
                if case .neuralEngine = plan.deviceUsage(for: operation)?.preferred { ane += cost }
                else { other += cost }
                for block in operation.blocks { inspect(block.operations) }
            }
        }
        if case .program(let program) = plan.modelStructure {
            for function in program.functions.values { inspect(function.block.operations) }
        }
        guard ane > other, ane > 0 else {
            throw BridgeError.message("Core ML hasn't assigned most encoder work to Neural Engine. Local listening stays off.")
        }
        let share = ane / (ane + other)
        shares[modelURL] = share
        return share
    }
}
