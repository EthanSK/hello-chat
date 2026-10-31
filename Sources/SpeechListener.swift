import AudioToolbox
import AVFoundation
import Foundation
import CoreAudio

@MainActor final class SpeechListener {
    var onText: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var onSession: (() -> Void)?
    var onWaiting: (() -> Void)?
    var onAudioActivity: ((Double, Double) -> Void)?
    var onFrame: (() -> Void)?
    var onUtteranceEnd: (() -> Void)?
    var onComputePlan: ((Double) -> Void)?
    var model: SpeechModel = .defaultModel
    var contextualPhrases = ["Hello Chat", "Bye Chat"]
    var inputDevice: (() throws -> AudioDeviceID)?
    var onConfigurationChange: (() -> Void)?
    var onDelay: (() -> Void)?
    var onRecovery: (() -> Void)?
    private let diagnostics: Diagnostics?
    private var recordingProducer: Task<Void, Never>?
    private(set) var resultAudioSeconds = 0.0
    private(set) var resultWasFlushed = false
    private(set) var recordingError: String?
    init(diagnostics: Diagnostics? = .shared) { self.diagnostics = diagnostics }
    // Live input, pinned to the selected microphone before its unit starts.
    // AVAudioEngine's input node followed default-input changes (the Bose
    // call-profile bug described in MicrophoneCapture), so each start builds a
    // fresh, already-pinned unit; that setup emits no route event to settle.
    private var capture: MicrophoneCapture?
    private var processing: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var progress = AudioProgressWatchdog(now: Diagnostics.now)
    private var watchdog: Task<Void, Never>?
    private var contextBoundary = SpeechContextBoundary()
    func discardPendingRecognition() { contextBoundary.invalidate(at: Diagnostics.now) }
    private struct Frame {
        let buffer: AVAudioPCMBuffer
        let sequence: UInt64
        let capturedAt: Double
        let audioEnd: Double?
    }
    private var continuation: AsyncStream<Frame>.Continuation?
    private var session = UUID()

    static func authorize() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw BridgeError.message("Allow Microphone for HelloChat in System Settings.")
        }
    }
    func start(recording: URL? = nil, channels: Int = 20, recoverBeforeAudio: Bool = false) async throws {
        let retryDelays: [Double] = [0.5, 1, 2]
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                try await startOnce(recording: recording, channels: channels, recoverBeforeAudio: recoverBeforeAudio)
                return
            } catch {
                let failure = error as NSError
                if !(error is CancellationError) { diagnostics?.failure("speech.capture.start_failed", error) }
                guard recording == nil, attempt < retryDelays.count, !Task.isCancelled,
                      failure.domain == NSOSStatusErrorDomain, failure.code == Int(kAudioUnitErr_FormatNotSupported) else { throw error }
                // The device format can change between reading it and starting
                // the unit. Retry only on this bounded recovery path, never on
                // every event; each attempt configures a fresh unit.
                diagnostics?.record("speech.capture.format_retry", numbers: ["attempt": Double(attempt + 1)])
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
            }
        }
    }
    private func startOnce(recording: URL?, channels: Int, recoverBeforeAudio: Bool) async throws {
        let selectedModel = model
        stop()
        let token = UUID(); session = token
        await cleanup?.value
        guard session == token else { throw CancellationError() }
        guard let directory = selectedModel.directory else { throw BridgeError.message("Local speech model is missing. Reinstall HelloChat.") }
        let worker: any SpeechBackend
        if selectedModel == .appleLocal {
            if #available(macOS 26.0, *) { worker = AppleLocalSpeech(phrases: contextualPhrases) }
            else { throw BridgeError.message("Apple local speech needs macOS 26 or later.") }
        } else { worker = NeuralSpeech(model: selectedModel) }
        let preparing = Diagnostics.now
        do {
            let share = try await worker.prepare(directory: directory)
            guard session == token else { throw CancellationError() }
            onComputePlan?(share)
            if recoverBeforeAudio { try await worker.resetForDiscontinuity() }
            guard session == token else { throw CancellationError() }
            var metrics = ["ms": (Diagnostics.now - preparing) * 1000]
            if selectedModel.neuralPlacementKnown { metrics["ane_plan_share"] = share }
            diagnostics?.record("speech.model.ready", numbers: metrics, info: ["model": selectedModel.rawValue])
        } catch { await worker.close(); throw error }
        // Live capture opens only the selected microphone, pinned before its
        // unit starts (see MicrophoneCapture). A recorded check opens none.
        let capture: MicrophoneCapture?
        do {
            if recording == nil {
                guard let device = try inputDevice?() else { throw BridgeError.message("No supported microphone is available.") }
                capture = try MicrophoneCapture(device: device)
            } else { capture = nil }
        } catch { await worker.close(); throw error }
        if let capture { diagnostics?.record("speech.capture.formats", numbers: capture.formatDiagnostics(), info: ["phase": "after_route"]) }
        let file: AVAudioFile?
        do { file = try recording.map { try AVAudioFile(forReading: $0) } }
        catch { await worker.close(); throw error }
        let format: AVAudioFormat
        if let capture { format = capture.format }
        else if let file { format = file.processingFormat }
        else { await worker.close(); throw BridgeError.message("No supported microphone is available.") }
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            await worker.close()
            throw BridgeError.message("No supported microphone is available.")
        }
        // Keep roughly one second of newest audio. A temporary scheduling stall
        // drops stale buffers; the consumer resets state across the sequence gap.
        let (stream, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(12))
        self.continuation = continuation
        var meterFrames = 0
        var sequence: UInt64 = 0
        let framesPerUpdate = max(1, Int(format.sampleRate / 10))
        var reportedBufferFormat = false
        let captureDiagnostics = diagnostics
        if let capture {
            // Runs on Core Audio's input thread with an owned buffer, like the
            // former engine tap: it touches only the stream, these counters
            // and main-actor hops.
            let deliver: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
                if !reportedBufferFormat {
                    reportedBufferFormat = true
                    captureDiagnostics?.record("speech.capture.first_buffer", numbers: ["sample_rate": buffer.format.sampleRate, "channels": Double(buffer.format.channelCount)])
                }
                guard let mono = SpeechPCM.mono(buffer) else { return }
                continuation.yield(Frame(buffer: mono, sequence: sequence, capturedAt: Diagnostics.now, audioEnd: nil))
                sequence &+= 1
                meterFrames += Int(mono.frameLength)
                if meterFrames >= framesPerUpdate {
                    meterFrames %= framesPerUpdate
                    let level = SpeechPCM.level(mono)
                    Task { @MainActor [weak self] in if self?.session == token {
                        self?.progress.captured(at: Diagnostics.now)
                        self?.onLevel?(level)
                    } }
                }
            }
            let sampleRate = format.sampleRate, channelCount = format.channelCount
            let configurationChanged: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self, self.session == token, let capture = self.capture else { return }
                    let hardware = capture.deviceFormat
                    self.diagnostics?.record("speech.capture.configuration_changed", numbers: ["sample_rate": hardware?.mSampleRate ?? 0, "channels": Double(hardware?.mChannelsPerFrame ?? 0), "device": Double(capture.currentDevice ?? 0)], info: ["engine_running": String(capture.isRunning)])
                    // Starting also reports its running state. A settled,
                    // running pinned route needs no stop/model reload.
                    let selected = try? self.inputDevice?()
                    if capture.isRunning, selected == capture.currentDevice,
                       hardware?.mSampleRate == sampleRate, hardware?.mChannelsPerFrame == channelCount {
                        self.diagnostics?.record("speech.capture.configuration_settled")
                        return
                    }
                    self.onConfigurationChange?()
                }
            }
            // Observe before starting: a stop/configuration event during start
            // must not leave a running-looking listener with no audio.
            self.capture = capture
            do { try capture.start(bufferFrames: 4096, onBuffer: deliver, onConfigurationChange: configurationChanged) }
            catch { stop(); await worker.close(); throw error }
            diagnostics?.record("speech.capture.formats", numbers: capture.formatDiagnostics(), info: ["phase": "after_start"])
        }
        resultAudioSeconds = 0; resultWasFlushed = false; recordingError = nil
        diagnostics?.record("speech.capture.started", numbers: ["sample_rate": format.sampleRate, "channels": Double(format.channelCount)])
        if let capture { diagnostics?.record("speech.capture.route", numbers: ["current_device": Double(capture.currentDevice ?? 0)], info: ["engine_running": String(capture.isRunning)]) }
        processing = Task(priority: .utility) { [weak self] in
            var continuity = SpeechContinuity()
            var frames = 0, textUpdates = 0, gaps = 0
            var queueMax = 0.0, processMax = 0.0, processTotal = 0.0, audioTotal = 0.0
            var summaryAt = Diagnostics.now
            do {
                for await frame in stream {
                    try Task.checkCancellation()
                    guard let self, self.session == token else { break }
                    guard self.contextBoundary.accepts(capturedAt: frame.capturedAt) else { continue }
                    let gap = continuity.hasGap(sequence: frame.sequence)
                    let boundaryReset = self.contextBoundary.takeReset()
                    if boundaryReset || gap {
                        if !boundaryReset {
                            gaps += 1
                            self.diagnostics?.record("speech.audio_gap")
                            self.onDelay?()
                        }
                        let resetting = Diagnostics.now
                        try await worker.resetForDiscontinuity()
                        guard self.session == token else { break }
                        self.onSession?()
                        if !boundaryReset { self.onRecovery?() }
                        self.diagnostics?.record(boundaryReset ? "speech.context.discarded" : "speech.recovered", numbers: ["ms": (Diagnostics.now - resetting) * 1000])
                    }
                    let consuming = Diagnostics.now
                    let queuedMS = (consuming - frame.capturedAt) * 1000
                    let result = try await worker.consume(frame.buffer)
                    guard self.session == token else { break }
                    guard self.contextBoundary.accepts(capturedAt: frame.capturedAt) else { continue }
                    let processMS = (Diagnostics.now - consuming) * 1000
                    frames += 1; queueMax = max(queueMax, queuedMS); processMax = max(processMax, processMS); processTotal += processMS
                    audioTotal += Double(frame.buffer.frameLength) / frame.buffer.format.sampleRate
                    self.resultAudioSeconds = frame.audioEnd ?? audioTotal
                    if result.reset { self.diagnostics?.record("speech.context.reset"); self.onSession?() }
                    self.onAudioActivity?(SpeechPCM.level(frame.buffer), Double(frame.buffer.frameLength) / frame.buffer.format.sampleRate)
                    if let text = result.text { textUpdates += 1; self.onText?(text) }
                    if result.utteranceEnded {
                        self.diagnostics?.record("speech.utterance.ended", info: ["source": "model_eou"])
                        self.onUtteranceEnd?()
                    }
                    self.progress.processed(at: Diagnostics.now)
                    self.onFrame?()
                    if Diagnostics.now - summaryAt >= 5 {
                        self.diagnostics?.record("speech.performance", numbers: ["frames": Double(frames), "text_updates": Double(textUpdates), "gaps": Double(gaps), "queue_max_ms": queueMax, "inference_max_ms": processMax, "inference_total_ms": processTotal, "audio_seconds": audioTotal])
                        summaryAt = Diagnostics.now; frames = 0; textUpdates = 0; gaps = 0; queueMax = 0; processMax = 0; processTotal = 0; audioTotal = 0
                    }
                }
                if recording != nil, !Task.isCancelled, let self, self.session == token {
                    let text = try await worker.finish()
                    self.resultWasFlushed = true
                    if !text.isEmpty { self.onText?(text) }
                }
            } catch is CancellationError { }
            catch {
                if let self, self.session == token {
                    self.recordingError = error.localizedDescription
                    self.diagnostics?.failure("speech.failed", error); self.onError?(error.localizedDescription)
                }
            }
            if let self, self.session == token { self.recordingProducer?.cancel() }
            await worker.close()
        }
        onSession?()
        if capture != nil {
            progress = AudioProgressWatchdog(now: Diagnostics.now)
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { return }
                    guard let self, self.session == token else { return }
                    guard let stage = self.progress.stalled(at: Diagnostics.now) else { continue }
                    self.diagnostics?.record("speech.pipeline.stalled", info: ["stage": stage])
                    self.onDelay?()
                    self.onConfigurationChange?()
                    return
                }
            }
        }
        if let file {
            let start = Diagnostics.now
            recordingProducer = Task { [weak self] in
                do {
                    var number: UInt64 = 0
                    var producedSeconds = 0.0
                    @MainActor func enqueue(_ buffer: AVAudioPCMBuffer) async throws {
                        let mono = try Self.recordedChannel(buffer, channels: channels)
                        producedSeconds += Double(buffer.frameLength) / file.processingFormat.sampleRate
                        continuation.yield(Frame(buffer: mono, sequence: number, capturedAt: Diagnostics.now, audioEnd: producedSeconds))
                        number &+= 1
                        let remaining = start + producedSeconds - Diagnostics.now
                        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    }
                    while file.framePosition < file.length {
                        try Task.checkCancellation()
                        guard self?.session == token else { break }
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw BridgeError.message("Couldn't read recorded speech.") }
                        try file.read(into: buffer)
                        try await enqueue(buffer)
                    }
                    // A live microphone continues after the last spoken word.
                    // Feed that quiet tail at real speed rather than depending
                    // on the recognizer's special end-of-file flush.
                    var tailFrames = Int(file.processingFormat.sampleRate)
                    while tailFrames > 0 {
                        try Task.checkCancellation()
                        guard self?.session == token else { break }
                        let count = min(4096, tailFrames)
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { throw BridgeError.message("Couldn't prepare recorded speech.") }
                        buffer.frameLength = AVAudioFrameCount(count)
                        for channel in 0..<Int(buffer.format.channelCount) { buffer.floatChannelData?[channel].initialize(repeating: 0, count: count) }
                        try await enqueue(buffer)
                        tailFrames -= count
                    }
                } catch is CancellationError { }
                catch { self?.recordingError = error.localizedDescription; self?.diagnostics?.failure("speech.recording.failed", error) }
                continuation.finish()
            }
        }
    }
    func waitForRecording() async { await recordingProducer?.value; await processing?.value }
    func waitUntilStopped() async { await cleanup?.value }
    private static func recordedChannel(_ buffer: AVAudioPCMBuffer, channels: Int) throws -> AVAudioPCMBuffer {
        guard (1...32).contains(channels), let source = buffer.floatChannelData?[0],
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AVAudioChannelCount(channels)) else { throw BridgeError.message("Couldn't prepare recorded speech channels.") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, interleaved: false, channelLayout: layout)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { throw BridgeError.message("Couldn't prepare recorded speech.") }
        input.frameLength = buffer.frameLength
        for channel in 0..<channels { input.floatChannelData?[channel].initialize(repeating: 0, count: Int(input.frameLength)) }
        input.floatChannelData?[0].update(from: source, count: Int(input.frameLength))
        guard let mono = SpeechPCM.mono(input) else { throw BridgeError.message("Couldn't select microphone channel 1.") }
        return mono
    }
    func stop() {
        watchdog?.cancel(); watchdog = nil
        onWaiting?()
        session = UUID()
        recordingProducer?.cancel(); recordingProducer = nil
        // Disposes the unit, ending its input callbacks before the stream finishes.
        capture?.stop(); capture = nil
        continuation?.finish(); continuation = nil
        let old = processing
        processing = nil; old?.cancel()
        if let old { cleanup = Task { await old.value } }
        onLevel?(0)
    }
}
