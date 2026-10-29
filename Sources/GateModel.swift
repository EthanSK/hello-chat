import AppKit
import AVFoundation
import SwiftUI

@MainActor final class GateModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Off"
    @Published private(set) var detail = "Start listening for Hello Chat."
    @Published var soundEffects = UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEffects, forKey: "soundEffects") }
    }
    @Published private(set) var voiceText = "Voice is off"
    @Published private(set) var microphone: MicrophoneState? = .muted
    let meter = AudioMeter()
    @Published private(set) var transcript = ""
    @Published private(set) var lastHeardAt: Date?
    @Published private(set) var archiveError: String?
    @Published var saveTranscripts = UserDefaults.standard.object(forKey: "saveTranscripts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(saveTranscripts, forKey: "saveTranscripts")
            archive.boundary()
        }
    }
    @Published private(set) var detectionRunning = false
    @Published private(set) var checkingSpeech = false
    @Published private(set) var speechCheckText = ""
    @Published private(set) var computeText = "Local speech · Neural Engine + CPU"
    @Published private(set) var computeDetail = "Checking local model…"
    let inputs = MicrophoneInputs()
    let dock = DockMonitor()
    @Published var automaticListening = UserDefaults.standard.bool(forKey: "automaticListening") {
        didSet {
            UserDefaults.standard.set(automaticListening, forKey: "automaticListening")
            dockDelay.invalidateStartup(); policy.resume(); applyAutomaticListening()
        }
    }
    @Published var speechModel = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "") ?? .parakeet320 {
        didSet {
            guard speechModel != oldValue else { return }
            UserDefaults.standard.set(speechModel.rawValue, forKey: "speechModel")
            selectSpeechModel()
        }
    }
    @Published private(set) var changingModel = false
    @Published var wakePhrase = UserDefaults.standard.string(forKey: "wakePhrase") ?? "Hello Chat" {
        didSet { UserDefaults.standard.set(wakePhrase, forKey: "wakePhrase"); updatePhrases() }
    }
    @Published var sleepPhrase = UserDefaults.standard.string(forKey: "sleepPhrase") ?? "Bye Chat" {
        didSet { UserDefaults.standard.set(sleepPhrase, forKey: "sleepPhrase"); updatePhrases() }
    }
    @Published var similarPhrases = UserDefaults.standard.object(forKey: "similarPhrases") as? Bool ?? true {
        didSet { UserDefaults.standard.set(similarPhrases, forKey: "similarPhrases"); matcher.reset() }
    }
    @Published var timeout = [30, 60, 120].contains(UserDefaults.standard.integer(forKey: "timeout")) ? UserDefaults.standard.integer(forKey: "timeout") : 60 {
        didSet { UserDefaults.standard.set(timeout, forKey: "timeout"); if microphone == .listening { scheduleMute() } }
    }
    @Published private(set) var error: String?
    @Published private(set) var lastEvent = ""
    @Published private(set) var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let voice = NativeVoice(diagnostics: .shared)
    private let feedback = FeedbackSounds()
    private let listener = SpeechListener()
    private var matcher = PhraseMatcher()
    private var standaloneWake = StandaloneWake()
    private lazy var archive = TranscriptArchive(onError: { [weak self] error in
        Diagnostics.shared.failure("transcript.write.failed", error)
        Task { @MainActor [weak self] in self?.archiveError = "Could not save transcript: \(error.localizedDescription)" }
    })
    private var generation = UUID()
    private var voiceTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var listeningTask: Task<Void, Never>?
    private var quitting = false
    // Wait for the output listener to be registered and checked before starting
    // capture, including the immediate already-docked startup path.
    private var playbackAllowed = false
    private var playbackChecked = false
    private var resumeAfterPlaybackPause = false
    private var policy = ListeningPolicy()
    private var dockDelay = DockListeningDelay()
    private var automaticStartTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var phraseUpdateTask: Task<Void, Never>?
    private var inputGeneration = UUID()
    private var captureRestartThrottle = CaptureRestartThrottle()

    init() {
        Diagnostics.shared.record("app.started", info: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
        do { try ShortcutLease().restore() } catch { self.error = "Could not restore Voice shortcut: \(error.localizedDescription)" }
        listener.onSession = { [weak self] in
            self?.archive.boundary(); self?.matcher.reset(); self?.standaloneWake.resetContext(); self?.detectionRunning = true
        }
        listener.onWaiting = { [weak self] in self?.archive.boundary(); self?.standaloneWake.reset(); self?.detectionRunning = false }
        listener.onAudioActivity = { [weak self] level, seconds in self?.standaloneWake.audio(level: level, seconds: seconds) }
        listener.onFrame = { [weak self] in self?.checkStandaloneWake() }
        listener.onLevel = { [weak self] in self?.meter.level = $0 }
        listener.onError = { [weak self] text in self?.failListening(text) }
        listener.onDelay = { [weak self] in
            self?.detectionRunning = false
            self?.detail = "Recovering after an audio delay…"
        }
        listener.onRecovery = { [weak self] in
            guard let self else { return }
            self.transcript = ""; self.lastHeardAt = nil
            self.lastEvent = "Listening resumed after an audio delay"
            self.detail = self.microphone == .listening ? "Say \(self.sleepPhrase) to end Voice." : "Say \(self.wakePhrase) to start Voice."
        }
        listener.onText = { [weak self] text in self?.heard(text) }
        listener.onComputePlan = { [weak self] share in
            guard let self else { return }
            guard self.speechModel.neuralPlacementKnown else {
                self.computeDetail = "Apple runs recognition locally and manages processor placement. Neural Engine use isn't verified. App CPU and memory exclude Apple's speech service."
                return
            }
            self.computeDetail = "Encoder: \(Int((share * 100).rounded()))% estimated work assigned to Neural Engine; CPU also used. GPU excluded. This is a compiler estimate, not measured usage."
        }
        listener.inputDevice = { [weak self] in
            guard let input = self?.inputs.selected else { throw BridgeError.message("Selected microphone is unavailable. Choose a microphone in Settings.") }
            return input.id
        }
        inputs.onRouteChange = { [weak self] in self?.restartMicrophone(settle: true) }
        listener.onConfigurationChange = { [weak self] in self?.restartMicrophone(settle: true) }
        dock.onChange = { [weak self] in
            guard let self else { return }
            self.dockDelay.invalidateStartup()
            self.applyAutomaticListening()
        }
        listener.model = speechModel
        updateComputeLabel()
        updatePhrases()
    }
    // Ethan's "always be" means keep the app running. Bose still pauses local
    // capture, but must not terminate the app or require manually reopening it.
    func playbackChanged(allowed: Bool) {
        if !playbackChecked {
            playbackChecked = true
            // Screen enumeration can settle after model construction. Take the
            // startup snapshot only when app launch and route registration finish.
            dock.refresh()
            dockDelay = DockListeningDelay(alreadyDockedAtStartup: automaticListening && dock.eligible)
        }
        guard allowed != playbackAllowed else { return }
        playbackAllowed = allowed
        Diagnostics.shared.record("playback.capture.allowed", info: ["allowed": String(allowed)])
        if !allowed {
            resumeAfterPlaybackPause = enabled || listeningTask != nil
            stopLocal(); busy = false; status = "Off"; detail = ""
        } else if !automaticListening, resumeAfterPlaybackPause {
            resumeAfterPlaybackPause = false
            listeningTask = Task { await turnOn() }
        } else { resumeAfterPlaybackPause = false; applyAutomaticListening() }
    }
    private func applyAutomaticListening() {
        guard playbackAllowed else { cancelAutomaticStart(reason: "playback_paused"); return }
        let shouldListen = policy.shouldListen(automatic: automaticListening, onPower: dock.onPower, externalDisplay: dock.externalDisplays > 0)
        guard automaticListening, !quitting else {
            cancelAutomaticStart(reason: "automatic_disabled_or_quitting")
            if status == "Waiting to listen" { showListening() }
            return
        }
        if !dock.eligible {
            // Dock policy owns local capture only; it does not hang up a native conversation.
            Diagnostics.shared.record("dock.listening.stopped", info: ["onPower": String(dock.onPower), "externalDisplays": String(dock.externalDisplays)])
            stopLocal(); busy = false
            status = "Waiting for dock"; detail = "Connect power and an external display to listen."
        } else if shouldListen, !enabled, !busy {
            guard let remaining = dockDelay.remaining(shouldListen: true, now: Diagnostics.now) else { return }
            guard remaining > 0 else {
                guard listeningTask == nil else { return }
                Diagnostics.shared.record("dock.listening.starting")
                listeningTask = Task { await turnOn() }
                return
            }
            guard automaticStartTask == nil else { return }
            status = "Waiting to listen"
            detail = "Listening starts 2 minutes after docking. Turn listening on to start now."
            Diagnostics.shared.record("dock.listening.scheduled", numbers: ["delay_seconds": remaining])
            automaticStartTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.automaticStartTask = nil
                self.dock.refresh()
                self.applyAutomaticListening()
            }
        } else if !shouldListen {
            cancelAutomaticStart(reason: "paused")
        }
    }
    private func cancelAutomaticStart(reason: String) {
        if automaticStartTask != nil {
            Diagnostics.shared.record("dock.listening.cancelled", info: ["reason": reason])
        }
        automaticStartTask?.cancel(); automaticStartTask = nil
        dockDelay.cancel()
    }
    private func updateComputeLabel() {
        computeText = speechModel.neuralPlacementKnown ? "Local speech · Neural Engine + CPU" : "Apple local speech"
        computeDetail = speechModel.neuralPlacementKnown ? "Checking local model…" : "Apple manages processor placement. Neural Engine use isn't verified. App CPU and memory exclude Apple's speech service."
    }
    private func selectSpeechModel() {
        phraseUpdateTask?.cancel()
        listener.model = speechModel
        updateComputeLabel()
        transcript = ""; lastHeardAt = nil; matcher.reset(); error = nil
        if enabled, !checkingSpeech {
            changingModel = true
            detail = "Preparing local speech recognition."
            restartMicrophone()
        }
    }
    private func restartMicrophone(settle: Bool = false) {
        guard enabled, !checkingSpeech, !quitting, playbackAllowed else { return }
        inputTask?.cancel()
        let token = UUID(); inputGeneration = token
        inputTask = Task {
            defer { if inputGeneration == token { changingModel = false } }
            do {
                if settle { try await Task.sleep(nanoseconds: 350_000_000) }
                try Task.checkCancellation()
                guard inputGeneration == token, enabled, !quitting else { return }
                if settle {
                    let delay = captureRestartThrottle.delay(at: Diagnostics.now)
                    if delay > 0 {
                        detectionRunning = false
                        detail = "Recovering after an audio delay…"
                        Diagnostics.shared.record("speech.capture.route_backoff", numbers: ["seconds": delay])
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        try Task.checkCancellation()
                        guard inputGeneration == token, enabled, !quitting else { return }
                    }
                    captureRestartThrottle.started(at: Diagnostics.now)
                }
                listener.stop(); detectionRunning = false; error = nil
                try await listener.start()
                guard inputGeneration == token, enabled else { return }
                transcript = ""; lastHeardAt = nil; matcher.reset()
                detectionRunning = true
                status = "Listening"
                detail = voice.connected ? (microphone == nil ? "Voice is open. Check the microphone in Codex." : "Say \(sleepPhrase) to end Voice.") : "Say \(wakePhrase) to turn Voice on."
            } catch {
                guard inputGeneration == token, enabled, !(error is CancellationError) else { return }
                Diagnostics.shared.failure("speech.restart.failed", error)
                self.error = error.localizedDescription; detectionRunning = false
                status = "Needs attention"
            }
        }
    }
    private func updatePhrases() {
        listener.contextualPhrases = [wakePhrase, sleepPhrase]
        matcher.reset()
        standaloneWake.reset()
        phraseUpdateTask?.cancel()
        if speechModel == .appleLocal, enabled {
            phraseUpdateTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self, self.enabled,
                      self.speechModel == .appleLocal else { return }
                self.restartMicrophone()
            }
        }
    }
    func refreshPermissions() {
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    func requestAudioPermissions() {
        Task {
            do { try await SpeechListener.authorize(); refreshPermissions() }
            catch { self.error = error.localizedDescription; refreshPermissions() }
        }
    }
    func previewSound(_ cue: FeedbackSounds.Cue) { feedback.play(cue) }
    func checkSpeech() {
        guard !busy, !checkingSpeech, !voice.connected, playbackAllowed else { return }
        let resumeListening = enabled
        stopLocal()
        busy = true; checkingSpeech = true; speechCheckText = "Checking recorded speech locally…"
        Task {
            await voice.stop()
            await listener.waitUntilStopped()
            do {
                guard let url = Bundle.main.url(forResource: "SpeechCheck", withExtension: "wav"),
                      let negativeURL = Bundle.main.url(forResource: "SpeechNegative", withExtension: "wav") else {
                    throw BridgeError.message("The speech sample is missing. Reinstall HelloChat.")
                }
                let normalized = await SpeechCheck().run(url: url, channels: 20, similar: similarPhrases, model: speechModel)
                let negative = await SpeechCheck().run(url: negativeURL, channels: 20, similar: similarPhrases, model: speechModel)
                let wake = normalized.commands.contains(.wake), mute = normalized.commands.contains(.sleep)
                let ignored = negative.commands.isEmpty && PhraseMatcher.words(negative.text).contains("weather")
                let placement = speechModel.neuralPlacementKnown ? "Encoder plan: \(Int((normalized.neuralShare * 100).rounded()))% Neural Engine; CPU also used" : "Apple manages processor placement; Neural Engine use isn't verified."
                speechCheckText = "Sample: \(normalized.text)\nRecorded wake phrase: \(wake ? "detected" : "not detected")\nRecorded end phrase: \(mute ? "detected" : "not detected")\nOther speech: \(negative.text)\nFalse activation: \(ignored ? "none" : "check failed")\n\(placement)"
            } catch { speechCheckText = error.localizedDescription }
            checkingSpeech = false; busy = false
            if resumeListening, !quitting { await turnOn() }
            else { applyAutomaticListening() }
        }
    }
    func toggle() {
        if enabled || (busy && status == "Starting") { policy.pause(); turnOff() }
        else if !busy { policy.resume(); listeningTask = Task { await turnOn() } }
    }

    // Starting wake detection is local only. Do not open a remote Voice call
    // until the user explicitly wakes it or presses its Voice control.
    func turnOn() async {
        guard playbackAllowed else { resumeAfterPlaybackPause = true; return }
        guard !enabled, !busy, !quitting else { return }
        cancelAutomaticStart(reason: "starting")
        guard !automaticListening || dock.eligible else {
            status = "Waiting for dock"; detail = "Connect power and an external display to listen."; return
        }
        busy = true; error = nil; status = "Starting"; detail = "Preparing local speech recognition."
        let token = UUID(); generation = token
        defer { if generation == token { busy = false } }
        do {
            guard !PhraseMatcher.words(wakePhrase).isEmpty, !PhraseMatcher.words(sleepPhrase).isEmpty,
                  PhraseMatcher.words(wakePhrase) != PhraseMatcher.words(sleepPhrase) else {
                throw BridgeError.message("Use different wake and end phrases.")
            }
            try await SpeechListener.authorize()
            guard generation == token, !quitting, playbackAllowed else { return }
            refreshPermissions(); updatePhrases(); matcher.reset()
            transcript = ""; lastHeardAt = nil; lastEvent = ""
            try await listener.start()
            guard generation == token, !quitting else { listener.stop(); return }
            enabled = true; detectionRunning = true
            showListening()
        } catch { if generation == token {
            Diagnostics.shared.failure("speech.start.failed", error)
            failListening(error.localizedDescription)
        } }
    }
    private func showListening() {
        status = enabled ? "Listening" : "Off"
        detail = enabled ? "Say \(wakePhrase) to turn Voice on." : "Start listening for \(wakePhrase)."
        voiceText = voice.connected ? "Check Codex Voice" : "Codex Voice is off"
        if !voice.connected { microphone = .muted }
    }
    private func stopLocal() {
        cancelAutomaticStart(reason: "stopping")
        inputGeneration = UUID(); inputTask?.cancel(); inputTask = nil
        captureRestartThrottle = CaptureRestartThrottle()
        phraseUpdateTask?.cancel(); phraseUpdateTask = nil
        generation = UUID(); listeningTask?.cancel(); listeningTask = nil
        voiceTask?.cancel(); timeoutTask?.cancel(); timeoutTask = nil
        listener.stop(); enabled = false; detectionRunning = false; changingModel = false; meter.level = 0
    }
    func turnOff() {
        let previous = voiceTask
        stopLocal(); busy = true; error = nil
        status = "Off"; detail = "Start listening for \(wakePhrase)."; lastEvent = "Listening stopped"
        let token = generation
        Task {
            await voice.stop(); await previous?.value
            guard generation == token else { return }
            if !voice.connected { microphone = .muted }
            voiceText = voice.connected ? "Check Codex Voice" : "Codex Voice is off"
            if let text = voice.lastError { error = text }
            busy = false; voiceTask = nil
        }
    }
    private func failListening(_ text: String) {
        let previous = voiceTask
        stopLocal(); busy = true
        status = "Needs attention"; detail = "Wake detection stopped."; error = text
        let token = generation
        Task {
            await voice.stop(); await previous?.value
            guard generation == token else { return }
            if !voice.connected { microphone = .muted }
            voiceText = voice.connected ? "Check Codex Voice" : "Codex Voice is off"
            if let text = voice.lastError { error = text }
            busy = false; voiceTask = nil
        }
    }
    func manualTalk() {
        if enabled { beginVoice(trigger: "Voice turned on with button") }
        else if !busy {
            listeningTask = Task {
                await turnOn()
                beginVoice(trigger: "Voice turned on with button")
            }
        }
    }
    func manualMute() {
        guard enabled || voice.connected, !quitting else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        if busy {
            let previous = voiceTask
            previous?.cancel()
            let token = generation
            Task {
                await voice.stop(); await previous?.value
                guard generation == token, enabled else { return }
                showListening(); busy = false; voiceTask = nil; lastEvent = "Voice connection cancelled"
            }
        } else {
            voiceTask = Task { await muteVoice(event: "Codex Voice ended") }
        }
    }
    private func beginVoice(trigger: String) {
        guard enabled, detectionRunning, !busy, !quitting else { return }
        // Reserve synchronously so an end phrase arriving before this Task's
        // first turn cancels the queued opening instead of starting a second action.
        busy = true
        voiceTask = Task { await openVoice(trigger: trigger) }
    }
    private func openVoice(trigger: String) async {
        guard enabled, !quitting, !Task.isCancelled else { busy = false; return }
        let token = generation
        busy = true; error = nil; status = "Connecting"; detail = "Opening Voice in Codex."; lastEvent = trigger
        defer { if generation == token { busy = false } }
        do {
            // Refresh native state on each explicit wake, including after a
            // call was closed in Codex, rather than trusting our cached state.
            let openedMicrophone = try await voice.start(onNewCall: { [weak self] in self?.feedback.play(.wake) })
            try Task.checkCancellation()
            guard enabled, generation == token else { return }
            if let openedMicrophone, openedMicrophone != .listening { try await voice.setMicrophone(.listening) }
            try Task.checkCancellation()
            guard enabled, generation == token else { return }
            microphone = openedMicrophone == nil ? nil : .listening; voiceText = "Codex Voice is on"; status = "Voice on"
            detail = openedMicrophone == nil ? "Voice is open. Check the microphone in Codex." : "Say \(sleepPhrase) to turn Voice off."; lastEvent = trigger
            scheduleMute()
        } catch {
            Diagnostics.shared.failure("voice.open.failed", error)
            await voice.recoverFromStartFailure(error)
            guard generation == token, enabled else { return }
            showListening()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func muteVoice(event: String, feedbackAlreadyPlayed: Bool = false) async {
        guard enabled || voice.connected, !busy else { return }
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        do {
            let ended = try await voice.endIfPresent()
            guard generation == token else { return }
            showListening(); lastEvent = ended ? event : "Heard \(sleepPhrase) · Codex Voice is already off"
            if ended, !feedbackAlreadyPlayed { feedback.play(.ended) }
        } catch {
            Diagnostics.shared.failure("voice.end.failed", error)
            // NativeVoice already retried its exact End control. Starting a
            // second whole stop cycle delays the error and doubles the wait.
            guard generation == token else { return }
            showListening(); self.error = error.localizedDescription
        }
    }
    private func scheduleMute() {
        timeoutTask?.cancel()
        guard enabled, microphone == .listening else { return }
        let token = generation
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeout) * 1_000_000_000)
            guard !Task.isCancelled, self.enabled, self.generation == token else { return }
            await self.muteVoice(event: "Codex Voice ended after silence")
        }
    }
    private func heard(_ text: String) {
        guard enabled else { return }
        standaloneWake.update(text, at: Diagnostics.now)
        if saveTranscripts { archive.update(text, model: speechModel.rawValue, microphone: inputs.selectedName) }
        if transcript != text {
            transcript = text; lastHeardAt = Date()
            if microphone == .listening { scheduleMute() }
        }
        guard !PhraseMatcher.words(wakePhrase).isEmpty, !PhraseMatcher.words(sleepPhrase).isEmpty,
              PhraseMatcher.words(wakePhrase) != PhraseMatcher.words(sleepPhrase),
              matcher.consume(text, wake: "", sleep: sleepPhrase, similar: similarPhrases) == .sleep else { return }
        standaloneWake.cancelPending(phrase: wakePhrase, endPhrase: sleepPhrase, similar: similarPhrases)
        Diagnostics.shared.record("phrase.end.detected", info: ["busy": String(busy), "voice": microphone?.rawValue ?? "unknown"])
        // Ethan's "buy chat" / Bye Chat gets an immediate detection cue even
        // while cancelling an opening or when Voice is already off. Native
        // status and errors still report the actual ending outcome separately.
        feedback.play(.ended)
        if busy { manualMute() }
        else {
            timeoutTask?.cancel(); voiceTask = Task { await muteVoice(event: "Heard \(sleepPhrase)", feedbackAlreadyPlayed: true) }
        }
    }
    private func checkStandaloneWake() {
        guard enabled, detectionRunning,
              standaloneWake.poll(at: Diagnostics.now, phrase: wakePhrase, similar: similarPhrases) else { return }
        Diagnostics.shared.record("phrase.wake.detected", info: ["contextChecked": "true", "busy": String(busy)])
        if busy { lastEvent = "Heard \(wakePhrase) · finishing the current Voice action" }
        else { beginVoice(trigger: "Heard \(wakePhrase)") }
    }
    func quit() { NSApp.terminate(nil) }
    func prepareToQuit() async -> Bool {
        guard !quitting else { return false }
        Diagnostics.shared.record("app.quit.requested")
        quitting = true
        let previous = voiceTask
        stopLocal()
        await voice.stop(); await previous?.value
        archive.flush()
        return true
    }
}
