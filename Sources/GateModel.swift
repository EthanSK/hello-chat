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
    let spotifyVolume = SpotifyVoiceVolume()
    @Published var lowerSpotifyDuringChat = UserDefaults.standard.bool(forKey: "lowerSpotifyDuringChat") {
        didSet {
            UserDefaults.standard.set(lowerSpotifyDuringChat, forKey: "lowerSpotifyDuringChat")
            spotifyVolume.setEnabled(lowerSpotifyDuringChat)
        }
    }
    @Published private(set) var voiceText = "Chat is off"
    @Published private(set) var microphone: MicrophoneState? = .muted
    let meter = AudioMeter()
    @Published private(set) var transcript = ""
    @Published private(set) var transcriptHistory = TranscriptHistory()
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
    private let listeningPreferences = ListeningPreferences()
    @Published private(set) var manualListeningEnabled = ListeningPreferences().manualEnabled {
        didSet {
            listeningPreferences.manualEnabled = manualListeningEnabled
            if oldValue != manualListeningEnabled { updateListeningDelay = nil }
        }
    }
    // Manual On is remembered independently of docking and playback pauses.
    // An automatic dock start also appears On, without saving a manual override.
    var listeningToggleOn: Bool {
        manualListeningEnabled || enabled || (busy && status == "Starting")
    }
    @Published var automaticListening = ListeningPreferences().automatic {
        didSet {
            listeningPreferences.automatic = automaticListening
            if oldValue != automaticListening { updateListeningDelay = nil }
            if oldValue, !automaticListening {
                manualListeningEnabled = enabled || (busy && status == "Starting") || resumeAfterPlaybackPause
            }
            dockDelay.invalidateStartup(); policy.resume(); applyAutomaticListening()
        }
    }
    @Published var speechModel = SpeechModel.saved() {
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
    @Published var mutePhrase = UserDefaults.standard.string(forKey: "mutePhrase") ?? PhraseMatcher.mutePhrase {
        didSet { UserDefaults.standard.set(mutePhrase, forKey: "mutePhrase"); updatePhrases() }
    }
    @Published var silentPhrase = UserDefaults.standard.string(forKey: "silentPhrase") ?? PhraseMatcher.silentPhrase {
        didSet { UserDefaults.standard.set(silentPhrase, forKey: "silentPhrase"); updatePhrases() }
    }
    @Published var silencePhrase = UserDefaults.standard.string(forKey: "silencePhrase") ?? PhraseMatcher.silencePhrase {
        didSet { UserDefaults.standard.set(silencePhrase, forKey: "silencePhrase"); updatePhrases() }
    }
    @Published var unmutePhrase = UserDefaults.standard.string(forKey: "unmutePhrase") ?? PhraseMatcher.unmutePhrase {
        didSet { UserDefaults.standard.set(unmutePhrase, forKey: "unmutePhrase"); updatePhrases() }
    }
    @Published var unsilencePhrase = UserDefaults.standard.string(forKey: "unsilencePhrase") ?? PhraseMatcher.unsilencePhrase {
        didSet { UserDefaults.standard.set(unsilencePhrase, forKey: "unsilencePhrase"); updatePhrases() }
    }
    var controlPhrases: [String] { VoiceAudioAction.allCases.flatMap { phrases(for: $0) } }
    private func phrases(for action: VoiceAudioAction) -> [String] {
        let values: [String]
        switch action {
        case .muteMicrophone: values = [mutePhrase]
        case .unmuteMicrophone: values = [unmutePhrase]
        case .silenceSpeakers: values = [silentPhrase, silencePhrase]
        case .unsilenceSpeakers: values = [unsilencePhrase]
        }
        return values.filter { !PhraseMatcher.words($0).isEmpty }
    }
    @Published var similarPhrases = UserDefaults.standard.object(forKey: "similarPhrases") as? Bool ?? true {
        didSet { UserDefaults.standard.set(similarPhrases, forKey: "similarPhrases"); updatePhrases() }
    }
    @Published private(set) var error: String?
    // Shortcut activation is independent of microphone/model preparation, which
    // clears ordinary errors. Keep the restart notice until an explicit refresh.
    @Published private(set) var shortcutNotice: String?
    @Published private(set) var lastEvent = ""
    @Published private(set) var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let voice = NativeVoice(diagnostics: .shared)
    // Ethan calls this conversation "Chat" in the UI. It is still the same
    // native Codex Voice session; both menu and window use one action/state.
    var chatActionTitle: String {
        status == "Connecting" ? "Cancel" : (voice.connected ? "End chat" : "Start chat")
    }
    func toggleChat() {
        if voice.connected || status == "Connecting" { manualMute() } else { manualTalk() }
    }
    private let desktopSession = DesktopSessionMonitor()
    private let feedback = FeedbackSounds()
    private let listener = SpeechListener()
    private var endPhrase = StandaloneWake() // End shares the direct-address filter; discussion must not hang up.
    private var standaloneWake = StandaloneWake()
    private var audioPhraseDetectors = Dictionary(uniqueKeysWithValues: VoiceAudioAction.allCases.map { ($0, StandaloneWake()) }) // One occurrence counter per directional action; the two silence aliases share one.
    private lazy var archive = TranscriptArchive(onError: { [weak self] error in
        Diagnostics.shared.failure("transcript.write.failed", error)
        Task { @MainActor [weak self] in self?.archiveError = "Could not save transcript: \(error.localizedDescription)" }
    })
    private var generation = UUID()
    private var voiceTask: Task<Void, Never>?
    private var endingVoice = false // Repeated End requests share the current teardown instead of queuing another one.
    private var voiceStartContext: VoiceStartContext?
    private var startupSpeech: StartupSpeechBuffer?
    var capturingStartupSpeech: Bool { startupSpeech != nil }
    private var lastStartupSpeechID: UUID?
    private let startupSpeechFile = StartupSpeechFile(onError: { Diagnostics.shared.failure("voice.startup_speech.file_failed", $0) },
        onEvent: { Diagnostics.shared.record($0.name, numbers: $0.numbers, info: $0.info) })
    // At most one later revision is logged per capture, never its words.
    private var finishedStartupObservation: (id: UUID, at: Double)?
    private var listeningTask: Task<Void, Never>?
    private var quitting = false
    // Wait for the output listener to be registered and checked before starting
    // capture, including the immediate already-docked startup path.
    private var playbackAllowed = false
    private var playbackChecked = false
    private var resumeAfterPlaybackPause = false
    private var policy = ListeningPolicy()
    private var dockDelay = DockListeningDelay()
    private var updateListeningDelay: DockListeningDelay?
    private var automaticStartTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var phraseUpdateTask: Task<Void, Never>?
    private var inputGeneration = UUID()
    private var captureRestartThrottle = CaptureRestartThrottle()
    private var speechRecovery = SpeechRecovery()

    // The meter diagnostic constructs this model before normal app ownership;
    // it must not start the optional Spotify side effect.
    init(enableSpotifyControl: Bool = true) {
        Diagnostics.shared.record("app.started", info: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
        desktopSession.onChange = { [weak self] state in
            guard let self else { return }
            // A lock or session switch cannot carry a queued wake into the
            // next desktop. Preserve any late call and require a fresh phrase.
            self.endPhrase.reset(); self.standaloneWake.reset(); self.resetAudioPhrases()
            self.listener.discardPendingRecognition()
            self.finishStartupSpeech(preserveRequested: true)
            if let opening = self.voiceStartContext {
                opening.preserveCallOnCancellation = true
                self.voiceTask?.cancel(); self.voiceTask = nil
                self.voiceStartContext = nil; self.generation = UUID(); self.busy = false
                self.showListening()
            }
            if state == .interactive, [DesktopSessionState.locked.message, DesktopSessionState.inactive.message].contains(self.error ?? "") {
                self.error = nil
            }
            Diagnostics.shared.record("voice.session.changed", info: ["state": state.rawValue])
        }
        do { try ShortcutLease().restore() } catch { self.error = "Could not restore Voice shortcut: \(error.localizedDescription)" }
        do {
            let added = try VoiceBridge.prepareShortcuts()
            if !added.isEmpty { Diagnostics.shared.record("voice.shortcuts.saved", info: ["commands": added.joined(separator: ",")]) }
            shortcutNotice = VoiceBridge.shortcutSetupMessage()
        } catch {
            self.error = error.localizedDescription
            Diagnostics.shared.failure("voice.shortcuts.failed", error)
        }
        listener.onSession = { [weak self] in
            self?.transcriptHistory.boundary()
            self?.archive.boundary(); self?.endPhrase.resetContext(); self?.standaloneWake.resetContext(); self?.resetAudioPhrases(); self?.detectionRunning = true
            // A context reset is not the end of the opening. Keep both the M5's
            // startup capture and the independent command detector resets.
            self?.startupSpeech?.boundary()
        }
        listener.onUtteranceEnd = { [weak self] in
            guard let self, var capture = self.startupSpeech else { return }
            let complete = capture.markUtteranceEnded()
            self.startupSpeech = capture
            if complete { self.finishStartupSpeech(preserveRequested: true, boundary: .utterance) }
        }
        listener.onWaiting = { [weak self] in self?.archive.boundary(); self?.standaloneWake.reset(); self?.resetAudioPhrases(); self?.detectionRunning = false }
        listener.onAudioActivity = { [weak self] level, seconds, audioTime in
            self?.standaloneWake.audio(level: level, seconds: seconds, at: audioTime)
            for action in VoiceAudioAction.allCases { self?.audioPhraseDetectors[action, default: StandaloneWake()].audio(level: level, seconds: seconds, at: audioTime) }
            self?.endPhrase.audio(level: level, seconds: seconds, at: audioTime)
            // Raw speech can resume before its first text hypothesis arrives.
            if level >= 0.02 { self?.startupSpeech?.speechResumed() }
            self?.startupSpeech?.audioProcessed(seconds: seconds)
        }
        listener.onFrame = { [weak self] in
            self?.speechRecovery.processed(at: Diagnostics.now)
            // After this frame's text; before a new wake can replace the capture.
            if let boundary = self?.startupSpeech?.boundaryReached {
                self?.finishStartupSpeech(preserveRequested: true, boundary: boundary)
            }
            self?.checkStandaloneWake()
        }
        listener.onLevel = { [weak self] in self?.meter.level = $0 }
        listener.onError = { [weak self] error in
            guard let self else { return }
            if SpeechRecovery.isTransient(error) { self.recoverSpeech(error) }
            else { self.failListening(error.localizedDescription) }
        }
        listener.onDelay = { [weak self] in
            self?.detectionRunning = false
            self?.detail = "Recovering after an audio delay…"
        }
        listener.onRecovery = { [weak self] in
            guard let self else { return }
            self.transcript = ""
            self.lastEvent = "Listening resumed after an audio delay"
            self.detail = self.microphone == .listening ? "Say \(self.sleepPhrase) to end chat." : "Say \(self.wakePhrase) to start chat."
        }
        listener.onText = { [weak self] text, timings in self?.heard(text, timings: timings) }
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
            self.updateListeningDelay = nil
            if self.automaticListening {
                self.dockDelay.invalidateStartup()
                self.applyAutomaticListening()
            }
            self.retrySpeechAfterEnvironmentChange()
        }
        dock.onWake = { [weak self] in self?.retrySpeechAfterEnvironmentChange() }
        listener.model = speechModel
        updateComputeLabel()
        updatePhrases()
        if enableSpotifyControl { spotifyVolume.setEnabled(lowerSpotifyDuringChat) }
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
        updateListeningDelay = nil
        playbackAllowed = allowed
        Diagnostics.shared.record("playback.capture.allowed", info: ["allowed": String(allowed)])
        if !allowed {
            resumeAfterPlaybackPause = enabled || listeningTask != nil
            stopLocal(preservingCall: true); busy = false; status = "Off"; detail = ""
        } else if !automaticListening, resumeAfterPlaybackPause, manualListeningEnabled {
            resumeAfterPlaybackPause = false
            listeningTask = Task { await turnOn() }
        } else { resumeAfterPlaybackPause = false; applyAutomaticListening() }
    }
    private func applyAutomaticListening() {
        guard playbackAllowed else { cancelAutomaticStart(reason: "playback_paused"); return }
        guard !quitting else { cancelAutomaticStart(reason: "quitting"); return }
        let shouldListen = policy.shouldListen(automatic: automaticListening, onPower: dock.onPower,
            externalDisplay: dock.externalDisplays > 0, manualEnabled: manualListeningEnabled)
        guard automaticListening, !manualListeningEnabled else {
            cancelAutomaticStart(reason: "manual_listening")
            if shouldListen, !enabled, !busy, listeningTask == nil {
                listeningTask = Task { await turnOn() }
            } else if status == "Waiting to listen" || status == "Waiting for dock" { showListening() }
            return
        }
        if !dock.eligible {
            // Dock policy owns local capture only; it does not hang up a native conversation.
            Diagnostics.shared.record("dock.listening.stopped", info: ["onPower": String(dock.onPower), "externalDisplays": String(dock.externalDisplays)])
            stopLocal(preservingCall: true); busy = false
            status = "Waiting for dock"; detail = "Turn listening on now, or connect power and an external display to start automatically."
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
        transcript = ""; endPhrase.reset(); error = nil
        if enabled, !checkingSpeech {
            speechRecovery = SpeechRecovery()
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
            defer { if inputGeneration == token { changingModel = false; inputTask = nil } }
            var settling = settle
            while !Task.isCancelled {
                do {
                    if settling { try await Task.sleep(nanoseconds: 350_000_000) }
                    try Task.checkCancellation()
                    guard inputGeneration == token, enabled, !quitting else { return }
                    if settling {
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
                    transcript = ""; endPhrase.reset()
                    detectionRunning = true
                    status = "Listening"
                    detail = voice.connected ? (microphone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(sleepPhrase) to end chat.") : "Say \(wakePhrase) to start chat."
                    Diagnostics.shared.record("speech.restart.ready")
                    return
                } catch {
                    guard inputGeneration == token, enabled, !(error is CancellationError) else { return }
                    Diagnostics.shared.failure("speech.restart.failed", error)
                    self.error = error.localizedDescription; detectionRunning = false
                    status = "Needs attention"
                    guard SpeechRecovery.isTransient(error), speechRecovery.retry() else {
                        listener.stop()
                        // No more frames will arrive to end the opening; keep its words.
                        finishStartupSpeech(preserveRequested: true)
                        Diagnostics.shared.record("speech.recovery.exhausted", numbers: ["attempts": Double(speechRecovery.attempts)])
                        return
                    }
                    Diagnostics.shared.record("speech.recovery.retry", numbers: ["attempt": Double(speechRecovery.attempts)])
                    settling = true // Reuse the existing route-restart throttle.
                }
            }
        }
    }
    private func recoverSpeech(_ error: Error) {
        guard enabled, !quitting, !checkingSpeech, playbackAllowed else { return }
        self.error = error.localizedDescription
        detectionRunning = false
        listener.stop()
        guard speechRecovery.retry() else {
            finishStartupSpeech(preserveRequested: true)
            status = "Needs attention"
            detail = "Wake detection stopped."
            Diagnostics.shared.record("speech.recovery.exhausted", numbers: ["attempts": Double(speechRecovery.attempts)])
            return
        }
        Diagnostics.shared.record("speech.recovery.retry", numbers: ["attempt": Double(speechRecovery.attempts)])
        // Local model recovery must not cancel or hang up native Codex Voice.
        restartMicrophone(settle: true)
    }
    private func retrySpeechAfterEnvironmentChange() {
        guard enabled, !detectionRunning, inputTask == nil, !busy,
              playbackAllowed, !quitting, !checkingSpeech else { return }
        speechRecovery = SpeechRecovery()
        Diagnostics.shared.record("speech.recovery.environment_changed")
        restartMicrophone(settle: true)
    }
    private func resetAudioPhrases() {
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action] = StandaloneWake() }
    }
    private func updatePhrases() {
        listener.contextualPhrases = [wakePhrase, sleepPhrase] + controlPhrases
        endPhrase.reset()
        standaloneWake.reset()
        resetAudioPhrases()
        if enabled { listener.discardPendingRecognition() } // Apply edited phrases to fresh audio; resetting counters must not replay a keyword from the old transcript.
        if status == "Listening" || status == "Off" { showListening() }
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
        shortcutNotice = VoiceBridge.shortcutSetupMessage() // A Codex restart can apply the saved keys while H Chat stays running.
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    func requestAudioPermissions() {
        Task {
            do { try await SpeechListener.authorize(); refreshPermissions() }
            catch { self.error = error.localizedDescription; refreshPermissions() }
        }
    }
    func previewSound(_ cue: FeedbackSounds.Cue) { feedback.play(cue) }
    var speechCheckUnavailableReason: String? {
        if checkingSpeech { return "Checking recorded speech locally…" }
        if busy || quitting { return "Available when the current action finishes." }
        if capturingStartupSpeech { return "Available after the opening message is captured." }
        return nil
    }
    func checkSpeech() {
        guard speechCheckUnavailableReason == nil else { return }
        let requestedGeneration = generation
        busy = true; checkingSpeech = true; speechCheckText = "Checking Voice status…"
        Task {
            _ = await voice.refresh() // An ended call must not leave this diagnostic disabled by a stale cached state.
            guard generation == requestedGeneration, !quitting else { checkingSpeech = false; speechCheckText = ""; return }
            guard !voice.connected else {
                speechCheckText = "End the Voice chat before checking speech recognition."
                checkingSpeech = false; busy = false; return
            }
            let resumeListening = enabled
            stopLocal()
            let checkGeneration = generation
            speechCheckText = "Checking recorded speech locally…"
            // A recorded test must never send End, even if cached Voice status is stale.
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
            checkingSpeech = false
            guard generation == checkGeneration, !quitting else { return }
            busy = false
            if resumeListening { await turnOn(preservingTranscript: true) }
            else { applyAutomaticListening() }
        }
    }
    func toggle() {
        if listeningToggleOn {
            manualListeningEnabled = false
            policy.pause(); turnOff()
        } else if !busy {
            manualListeningEnabled = true
            policy.resume(); listeningTask = Task { await turnOn() }
        }
    }

    // Starting wake detection is local only. Do not open a remote Voice call
    // until the user explicitly wakes it or presses its Voice control.
    func turnOn(preservingTranscript: Bool = false) async {
        guard playbackAllowed else { resumeAfterPlaybackPause = true; return }
        guard !enabled, !busy, !quitting else { return }
        cancelAutomaticStart(reason: "starting")
        busy = true; error = nil; status = "Starting"; detail = "Preparing local speech recognition."
        let token = UUID(); generation = token
        defer {
            if generation == token { busy = false; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
        }
        do {
            guard !PhraseMatcher.words(wakePhrase).isEmpty, !PhraseMatcher.words(sleepPhrase).isEmpty,
                  PhraseMatcher.words(wakePhrase) != PhraseMatcher.words(sleepPhrase) else {
                throw BridgeError.message("Use different wake and end phrases.")
            }
            try await SpeechListener.authorize()
            guard generation == token, !quitting, playbackAllowed else { return }
            refreshPermissions(); updatePhrases(); endPhrase.reset()
            transcript = ""; lastEvent = ""
            if preservingTranscript { transcriptHistory.boundary() } // A resumed recognizer must not replace the words heard before its diagnostic.
            else { transcriptHistory = TranscriptHistory() }
            try await listener.start()
            guard generation == token, !quitting else { listener.stop(); return }
            enabled = true; detectionRunning = true
            showListening()
        } catch { if generation == token {
            Diagnostics.shared.failure("speech.start.failed", error)
            if SpeechRecovery.isTransient(error), !(error is CancellationError), !quitting {
                enabled = true
                recoverSpeech(error)
            } else { failListening(error.localizedDescription) }
        } }
    }
    private func showListening() {
        status = enabled ? "Listening" : "Off"
        detail = enabled ? "Say \(wakePhrase) to start chat." : "Start listening for \(wakePhrase)."
        if enabled, voice.connected {
            detail = microphone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(sleepPhrase) to end chat."
        }
        voiceText = voice.connected ? "Check chat" : "Chat is off"
        if !voice.connected { microphone = .muted }
    }
    private func stopLocal(preservingCall: Bool = false) {
        finishStartupSpeech(preserveRequested: preservingCall || quitting)
        if !preservingCall, !quitting { cancelStartupSpeech() }
        // Undocking and playback pauses own local capture, not the conversation.
        // Mark this exact opening before cancellation; do not permanently detach
        // NativeVoice, since a later wake must still work after capture resumes.
        if preservingCall { voiceStartContext?.preserveCallOnCancellation = true }
        cancelAutomaticStart(reason: "stopping")
        inputGeneration = UUID(); inputTask?.cancel(); inputTask = nil
        captureRestartThrottle = CaptureRestartThrottle()
        speechRecovery = SpeechRecovery()
        phraseUpdateTask?.cancel(); phraseUpdateTask = nil
        generation = UUID(); listeningTask?.cancel(); listeningTask = nil
        voiceTask?.cancel()
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
            voiceText = voice.connected ? "Check chat" : "Chat is off"
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
            voiceText = voice.connected ? "Check chat" : "Chat is off"
            if let text = voice.lastError { error = text }
            busy = false; voiceTask = nil
        }
    }
    func manualTalk() {
        if enabled { beginVoice(trigger: "Voice turned on with button") }
        else if !busy {
            manualListeningEnabled = true
            listeningTask = Task {
                await turnOn()
                beginVoice(trigger: "Voice turned on with button")
            }
        }
    }
    func manualMute(feedbackAlreadyPlayed: Bool = false) {
        guard enabled || voice.connected, !quitting, !endingVoice else { return }
        cancelStartupSpeech()
        if busy, voiceStartContext != nil {
            let previous = voiceTask
            previous?.cancel()
            let token = generation
            Task {
                await voice.stop(); await previous?.value
                guard generation == token, enabled else { return }
                showListening(); busy = false; voiceTask = nil; lastEvent = "Voice connection cancelled"
            }
        } else if busy {
            let previous = voiceTask
            let token = UUID(); generation = token // The cancelled audio task must not clear the End request's busy state or show a cancellation error.
            previous?.cancel()
            voiceTask = Task {
                await previous?.value
                guard generation == token, !quitting else { return }
                await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed, reserved: true)
            }
        } else {
            voiceTask = Task { await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed) }
        }
    }
    // Ethan's 2 Nov "have like a refresh button ... so I can toggle it on and
    // off": re-read Codex on request after Voice was opened or closed there.
    // It also clears a stale error. HelloChat still never scans in the background.
    func refreshVoice() {
        guard !busy, !quitting else { return }
        shortcutNotice = VoiceBridge.shortcutSetupMessage()
        busy = true; error = nil
        let token = generation
        voiceTask = Task {
            defer { if generation == token { busy = false; voiceTask = nil } }
            let found = await voice.refresh()
            guard generation == token else { return }
            microphone = found
            showListening()
            if voice.connected { voiceText = "Chat is on" }
            lastEvent = voice.connected ? "Chat is on" : "Chat is off"
        }
    }
    private func beginVoice(trigger: String, wakeRange: Range<Int>? = nil) {
        guard enabled, detectionRunning, !busy, !quitting else { return }
        // Reserve synchronously so an end phrase arriving before this Task's
        // first turn cancels the queued opening instead of starting a second action.
        busy = true
        // Acknowledge the request before scheduling Voice work. The sound does
        // not mean Codex connected, and the busy reservation prevents reentry.
        feedback.play(.wake)
        // A repeated wake may reuse the current call. Finish its previous
        // opening first; an unpublished reuse buffer must not strand that file.
        finishStartupSpeech(preserveRequested: true)
        finishedStartupObservation = nil
        let context = VoiceStartContext()
        voiceStartContext = context
        startupSpeech = StartupSpeechBuffer(id: context.id, text: transcript, wakeRange: wakeRange, phrase: wakePhrase, similar: similarPhrases)
        context.prepareNewCall = { [weak self, weak context] in
            guard let self, let context, self.voiceStartContext === context,
                  var capture = self.startupSpeech, capture.id == context.id else { return }
            capture.markPublished(); self.startupSpeech = capture
            self.lastStartupSpeechID = context.id
            let saved = await self.startupSpeechFile.begin(id: context.id, text: capture.text, truncated: capture.truncated)
            if !saved, self.startupSpeech?.id == context.id { self.startupSpeech = nil }
            if saved { Diagnostics.shared.record("voice.startup_speech.started", info: ["request": context.id.uuidString]) }
        }
        voiceTask = Task { await openVoice(trigger: trigger, context: context) }
    }
    private func openVoice(trigger: String, context: VoiceStartContext) async {
        guard enabled, !quitting, !Task.isCancelled else { busy = false; return }
        shortcutNotice = VoiceBridge.shortcutSetupMessage()
        let token = generation
        busy = true; error = nil; status = "Connecting"; detail = "Opening chat…"; lastEvent = trigger
        defer {
            // The native window appeared, but ASR may only have produced the
            // beginning of the request. Keep capturing through its utterance
            // boundary. Ordinary confirmation errors can also leave a call alive.
            if var capture = startupSpeech, capture.id == context.id {
                if context.requestedNewCall && (!Task.isCancelled || context.preserveCallOnCancellation) {
                    let complete = capture.markVoiceOpened()
                    startupSpeech = capture
                    recordStartupSnapshot(capture, event: "opened", inputCharacters: transcript.count)
                    if complete { finishStartupSpeech(preserveRequested: true, boundary: .utterance) }
                } else { finishStartupSpeech(preserveRequested: false) }
            }
            if voiceStartContext === context { voiceStartContext = nil }
            if generation == token { busy = false; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
        }
        do {
            // Refresh native state on each explicit wake, including after a
            // call was closed in Codex, rather than trusting our cached state.
            let openedMicrophone = try await voice.start(context: context)
            try Task.checkCancellation()
            guard enabled, generation == token else { return }
            if let openedMicrophone, openedMicrophone != .listening { try await voice.setMicrophone(.listening) }
            try Task.checkCancellation()
            guard enabled, generation == token else { return }
            microphone = openedMicrophone == nil ? nil : .listening; voiceText = "Chat is on"; status = "Chat on"
            detail = openedMicrophone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(sleepPhrase) to end chat."; lastEvent = trigger
        } catch {
            Diagnostics.shared.failure("voice.open.failed", error)
            await voice.recoverFromStartFailure(error, context: context)
            guard generation == token, enabled else { return }
            showListening()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func muteVoice(event: String, feedbackAlreadyPlayed: Bool = false, reserved: Bool = false) async {
        guard enabled || voice.connected, !busy || reserved else { return }
        cancelStartupSpeech()
        let token = generation
        busy = true; endingVoice = true
        defer {
            endingVoice = false
            if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
        }
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
            if case BridgeError.endUnconfirmed = error {
                microphone = nil
                voiceText = "Codex Voice status unknown"
            }
        }
    }
    private func heard(_ text: String, timings: [(word: String, start: Double, end: Double)]) {
        guard enabled else { return }
        if saveTranscripts { archive.update(text, model: speechModel.rawValue, microphone: inputs.selectedName) }
        let changed = transcript != text
        if changed {
            transcript = text
        }
        transcriptHistory.update(text)
        // Use the same phrase and mention rules while Agent Flow records. Its
        // microphone ownership must not pause H Chat's existing recognizer.
        standaloneWake.update(text, at: Diagnostics.now, timings: timings)
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action, default: StandaloneWake()].update(text, at: Diagnostics.now, timings: timings) }
        endPhrase.update(text, at: Diagnostics.now, timings: timings)
        // Keep collecting while a keyword waits for its audio pause. An accepted
        // End below cancels the startup file before dispatching the native command.
        if var capture = startupSpeech {
            let previous = capture.text
            capture.observe(text); startupSpeech = capture
            if changed { recordStartupSnapshot(capture, event: "recognition", inputCharacters: text.count) }
            // Only the opening's own revisions; other transcript edits don't touch the file.
            if capture.published, capture.text != previous {
                startupSpeechFile.update(id: capture.id, text: capture.text, truncated: capture.truncated)
            }
        } else if changed, let finished = finishedStartupObservation {
            finishedStartupObservation = nil
            let elapsed = Diagnostics.now - finished.at
            if elapsed <= StartupSpeechBuffer.openLimitSeconds {
                Diagnostics.shared.record("voice.startup_speech.recognition_after_finish",
                    numbers: ["seconds_after_finish": elapsed, "input_characters": Double(text.count)],
                    info: ["request": finished.id.uuidString])
            }
        }
    }
    private func checkStandaloneWake() {
        guard enabled, detectionRunning else { return }
        if !PhraseMatcher.words(wakePhrase).isEmpty && !PhraseMatcher.words(sleepPhrase).isEmpty
            && PhraseMatcher.words(wakePhrase) != PhraseMatcher.words(sleepPhrase)
            && endPhrase.pollEnd(at: Diagnostics.now, phrase: sleepPhrase, similar: similarPhrases) {
            for action in VoiceAudioAction.allCases {
                let values = phrases(for: action)
                if let first = values.first { audioPhraseDetectors[action, default: StandaloneWake()].cancelPending(phrase: first, endPhrase: sleepPhrase, similar: similarPhrases, alternatives: Array(values.dropFirst())) }
            } // An explicit End wins over audio commands in the same transcript.
            cancelStartupSpeech()
            standaloneWake.cancelPending(phrase: wakePhrase, endPhrase: sleepPhrase, similar: similarPhrases)
            Diagnostics.shared.record("phrase.end.detected", info: ["busy": String(busy), "voice": microphone?.rawValue ?? "unknown"])
            // Ethan's "buy chat" / Bye Chat gets its cue when recognized, even
            // while cancelling an opening or when Voice is already off. Native
            // status and errors still report the actual ending outcome separately.
            feedback.play(.ended)
            if busy { manualMute(feedbackAlreadyPlayed: true) }
            else {
                voiceTask = Task { await muteVoice(event: "Heard \(sleepPhrase)", feedbackAlreadyPlayed: true) }
            }
            return
        }
        let actions = VoiceAudioAction.allCases.compactMap { action -> (action: VoiceAudioAction, position: Int)? in
            let values = phrases(for: action)
            guard let first = values.first,
                  audioPhraseDetectors[action, default: StandaloneWake()].poll(at: Diagnostics.now, phrase: first, similar: similarPhrases, alternatives: Array(values.dropFirst()), rejectNegated: true),
                  let position = audioPhraseDetectors[action]?.acceptedRange?.lowerBound else { return nil }
            return (action, position)
        }.sorted { $0.position < $1.position }
        if !actions.isEmpty {
            // Reserve synchronously, as beginVoice does. Consume busy commands
            // rather than replaying a surprise mute when an opening/End finishes.
            guard !busy, !quitting else { return }
            for phrase in controlPhrases {
                standaloneWake.cancelPending(phrase: wakePhrase, endPhrase: phrase, similar: similarPhrases) // Consume fuzzy wakes too, so Hello Chad before mute cannot undo it.
            }
            busy = true
            let token = generation
            voiceTask = Task {
                defer { if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() } }
                do {
                    for (action, _) in actions { // A delayed transcript can contain both channels or opposite commands; apply them in spoken order.
                        let active = try await voice.setAudio(action, onRecognized: { self.feedback.play(.microphoneDetected) }) // Inactive Voice gets no sound or key.
                        guard generation == token else { return }
                        guard active else { continue }
                        error = nil
                        if !action.controlsSpeakers { microphone = action.targetMuted ? .muted : .listening }
                        switch action {
                        case .muteMicrophone: feedback.play(.microphoneMuted)
                        case .unmuteMicrophone: feedback.play(.microphoneUnmuted)
                        case .silenceSpeakers: feedback.play(.speakersMuted)
                        case .unsilenceSpeakers: feedback.play(.speakersUnmuted)
                        }
                        showListening()
                        lastEvent = action.controlsSpeakers ? "Chat audio is \(action.targetMuted ? "muted" : "on")" : "Chat is \(action.targetMuted ? "muted" : "listening")"
                        Diagnostics.shared.record("voice.audio.confirmed", info: ["action": action.rawValue])
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == token else { return }
                    self.error = error.localizedDescription
                    Diagnostics.shared.failure("voice.audio.failed", error)
                }
            }
            return
        }
        guard enabled, detectionRunning,
              standaloneWake.poll(at: Diagnostics.now, phrase: wakePhrase, similar: similarPhrases, onDecision: { decision, quiet, stable in
                  Diagnostics.shared.record("phrase.wake.evaluated", numbers: ["quiet_s": quiet, "stable_s": stable], info: ["decision": decision])
              }) else { return }
        Diagnostics.shared.record("phrase.wake.detected", info: ["contextChecked": "true", "busy": String(busy)])
        if busy {
            // A detected wake still gets its cue while Voice is busy, without
            // scheduling another call or cancelling the work already underway.
            feedback.play(.wake)
            lastEvent = "Heard \(wakePhrase) · finishing the current Voice action"
        } else { beginVoice(trigger: "Heard \(wakePhrase)", wakeRange: standaloneWake.acceptedRange) }
    }
    // Stops, new wakes, desktop changes and quit keep the words heard so far,
    // labelled `interrupted` because the opening's end may be missing.
    private func finishStartupSpeech(preserveRequested: Bool, boundary: StartupSpeechFile.Boundary = .interrupted) {
        guard let capture = startupSpeech else { return }
        startupSpeech = nil
        guard capture.published else { return }
        if preserveRequested {
            finishedStartupObservation = (capture.id, Diagnostics.now)
            startupSpeechFile.update(id: capture.id, text: capture.text, truncated: capture.truncated, boundary: boundary)
            // Metadata only: never the recognised words.
            Diagnostics.shared.record("voice.startup_speech.ready",
                numbers: ["characters": Double(capture.text.count), "seconds_after_open": capture.openSeconds],
                info: ["request": capture.id.uuidString, "boundary": boundary.rawValue,
                       "truncated": String(capture.truncated || boundary.mayBeIncomplete),
                       "opening_words": String(capture.hasOpeningWords), "alignment": capture.alignment.rawValue])
        }
        else { startupSpeechFile.cancel(id: capture.id) }
    }
    private func cancelStartupSpeech() {
        startupSpeech = nil
        finishedStartupObservation = nil
        if let id = lastStartupSpeechID { startupSpeechFile.cancel(id: id); lastStartupSpeechID = nil }
    }
    private func recordStartupSnapshot(_ capture: StartupSpeechBuffer, event: String, inputCharacters: Int) {
        Diagnostics.shared.record("voice.startup_speech.\(event)",
            numbers: ["input_characters": Double(inputCharacters), "captured_characters": Double(capture.text.count),
                      "seconds_after_open": capture.openSeconds],
            info: ["request": capture.id.uuidString, "alignment": capture.alignment.rawValue,
                   "opening_words": String(capture.hasOpeningWords)])
    }
    func quit() { NSApp.terminate(nil) }
    func restoreAfterFailedUpdate() async {
        guard quitting else { return }
        // Keep an in-progress dock deadline (or an already-active session).
        // Real setting, playback or dock changes invalidate this saved state.
        dock.refresh()
        if let saved = updateListeningDelay { dockDelay = saved }
        updateListeningDelay = nil
        quitting = false; busy = false; voiceTask = nil
        spotifyVolume.setEnabled(lowerSpotifyDuringChat)
        microphone = await voice.reattachAfterFailedUpdate()
        showListening()
        // Re-evaluate the existing saved choice and live power/output state.
        // Never turn a user's manual Off into On or persist a temporary pause.
        applyAutomaticListening()
    }
    func prepareToQuit(preservingSpotify: Bool = false) async -> Bool {
        guard !quitting else { return false }
        Diagnostics.shared.record("app.quit.requested")
        updateListeningDelay = dockDelay
        if enabled { updateListeningDelay?.resumeActiveSession() }
        quitting = true
        let previous = voiceTask
        voice.detachForQuit()
        stopLocal()
        await previous?.value
        archive.flush()
        await startupSpeechFile.flush()
        await spotifyVolume.shutdown(preservingVolume: preservingSpotify)
        return true
    }
}
