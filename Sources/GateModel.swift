import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor final class GateModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false {
        didSet { if !busy { scheduleObservedVoiceEnd() } }
    }
    @Published private(set) var status = "Off"
    @Published private(set) var detail = "Start listening for Hello Chat."
    @Published var soundEffects = UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEffects, forKey: "soundEffects"); updateVoiceCallMonitoring() }
    }
    @Published var soundEffectsVolume = Double(FeedbackVolume.level(UserDefaults.standard.object(forKey: FeedbackVolume.defaultsKey))) {
        didSet { UserDefaults.standard.set(soundEffectsVolume, forKey: FeedbackVolume.defaultsKey) }
    }
    private var endFeedback = VoiceEndFeedback()
    private var voiceStatusRefresh = VoiceStatusRefresh()
    private var voiceStatusTask: Task<Void, Never>?
    private let voiceCalls = VoiceCallMonitor()
    private let voicePeerPriority = VoicePeerPriority()
    private let voicePeerMailbox = VoicePeerMailbox(handler: VoicePeerControl.respond)
    let spotifyVolume: SpotifyVoiceVolume
    @Published var lowerSpotifyDuringChat = UserDefaults.standard.bool(forKey: "lowerSpotifyDuringChat") {
        didSet {
            UserDefaults.standard.set(lowerSpotifyDuringChat, forKey: "lowerSpotifyDuringChat")
            spotifyVolume.setEnabled(lowerSpotifyDuringChat)
            updateVoiceCallMonitoring()
        }
    }
    @Published private(set) var voiceText = "Chat is off"
    @Published private(set) var microphone: MicrophoneState? = .muted
    let meter = AudioMeter()
    @Published private(set) var transcript = ""
    @Published private(set) var transcriptBatchID = UUID() // Reset the reader at the recognizer’s existing batch boundary; scrolling must not retain earlier batches.
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
    // Manual On is remembered independently of docking.
    // An automatic dock start also appears On, without saving a manual override.
    var listeningToggleOn: Bool {
        manualListeningEnabled || enabled || (busy && status == "Starting")
    }
    @Published var automaticListening = ListeningPreferences().automatic {
        didSet {
            listeningPreferences.automatic = automaticListening
            if oldValue != automaticListening { updateListeningDelay = nil }
            if oldValue, !automaticListening {
                manualListeningEnabled = enabled || (busy && status == "Starting")
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
    @Published var wakePhrase = PhraseSlot.wakePhrase.savedValue() {
        didSet { UserDefaults.standard.set(wakePhrase, forKey: "wakePhrase"); updatePhrases() }
    }
    @Published var sleepPhrase = PhraseSlot.sleepPhrase.savedValue() {
        didSet { UserDefaults.standard.set(sleepPhrase, forKey: "sleepPhrase"); updatePhrases() }
    }
    @Published var mutePhrase = PhraseSlot.mutePhrase.savedValue() {
        didSet { UserDefaults.standard.set(mutePhrase, forKey: "mutePhrase"); updatePhrases() }
    }
    @Published var silentPhrase = PhraseSlot.silentPhrase.savedValue() {
        didSet { UserDefaults.standard.set(silentPhrase, forKey: "silentPhrase"); updatePhrases() }
    }
    @Published var silencePhrase = PhraseSlot.silencePhrase.savedValue() {
        didSet { UserDefaults.standard.set(silencePhrase, forKey: "silencePhrase"); updatePhrases() }
    }
    @Published var unmutePhrase = PhraseSlot.unmutePhrase.savedValue() {
        didSet { UserDefaults.standard.set(unmutePhrase, forKey: "unmutePhrase"); updatePhrases() }
    }
    @Published var unsilencePhrase = PhraseSlot.unsilencePhrase.savedValue() {
        didSet { UserDefaults.standard.set(unsilencePhrase, forKey: "unsilencePhrase"); updatePhrases() }
    }
    @Published var pauseVideoPhrase = PhraseSlot.pauseVideoPhrase.savedValue() {
        didSet { UserDefaults.standard.set(pauseVideoPhrase, forKey: "pauseVideoPhrase"); updatePhrases() }
    }
    @Published var playVideoPhrase = PhraseSlot.playVideoPhrase.savedValue() {
        didSet { UserDefaults.standard.set(playVideoPhrase, forKey: "playVideoPhrase"); updatePhrases() }
    }
    @Published var pauseMusicPhrase = PhraseSlot.pauseMusicPhrase.savedValue() {
        didSet { UserDefaults.standard.set(pauseMusicPhrase, forKey: "pauseMusicPhrase"); updatePhrases() }
    }
    @Published var playMusicPhrase = PhraseSlot.playMusicPhrase.savedValue() {
        didSet { UserDefaults.standard.set(playMusicPhrase, forKey: "playMusicPhrase"); updatePhrases() }
    }
    @Published var switchAppPhrase = PhraseSlot.switchAppPhrase.savedValue() {
        didSet { UserDefaults.standard.set(switchAppPhrase, forKey: "switchAppPhrase"); updatePhrases() }
    }
    @Published var openAppPhrase = PhraseSlot.openAppPhrase.savedValue() {
        didSet { UserDefaults.standard.set(openAppPhrase, forKey: "openAppPhrase"); updatePhrases() }
    }
    @Published var zoomInPhrase = PhraseSlot.zoomInPhrase.savedValue() {
        didSet { UserDefaults.standard.set(zoomInPhrase, forKey: "zoomInPhrase"); updatePhrases() }
    }
    @Published var zoomOutPhrase = PhraseSlot.zoomOutPhrase.savedValue() {
        didSet { UserDefaults.standard.set(zoomOutPhrase, forKey: "zoomOutPhrase"); updatePhrases() }
    }
    // Extra explicit phrases listed below each section's main phrase (Ethan, 14 November 2026).
    // One store serves both the + rows and slash entry; each main phrase keeps its existing key.
    @Published private(set) var phraseAliases: [PhraseSlot: [PhraseRow]] =
        PhraseList.decode(UserDefaults.standard.object(forKey: PhraseList.defaultsKey)).mapValues { $0.map { PhraseRow($0) } } {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(PhraseList.encode(phraseAliases.mapValues { $0.map(\.text) }, preserving: defaults.object(forKey: PhraseList.defaultsKey)),
                         forKey: PhraseList.defaultsKey)
            updatePhrases()
        }
    }
    // Detection, highlighting, cancellation and startup capture all read this one configuration.
    @Published private(set) var phraseConfiguration = PhraseConfiguration(rows: [:])
    // Mac app and zoom commands don't depend on a connected Voice call.
    @Published var appNameSpellings = AppNameSpellings(saved: UserDefaults.standard.object(forKey: AppNameSpellings.defaultsKey)) {
        didSet { UserDefaults.standard.set(appNameSpellings.overrides, forKey: AppNameSpellings.defaultsKey) }
    }
    @Published private(set) var speakerOutputSettings = SpeakerOutputSettings.load()
    @Published private(set) var speakerOutputStatus: String?
    private var speakerOutputDetector = StandaloneWake()
    private var speakerOutputTask: Task<Void, Never>?
    @Published private(set) var switchingSpeakerOutput = false
    // App prefixes are handled by the overlapping-prefix suppression below. All other
    // commands retain ownership even when they are contained inside a speaker phrase.
    var speakerOutputConflictingPhrases: [PhrasePattern] {
        PhraseSlot.allCases.filter { $0 != .switchAppPhrase && $0 != .openAppPhrase }.flatMap { patterns(for: $0) }
    }
    @Published private(set) var speakerOutputConflict: String?
    private var activeSpeakerCommands: [(pattern: PhrasePattern, output: String)] = []
    // Recognition checks each audio frame. Compile speaker combinations only when settings
    // change, not on that hot path, and share the result with highlighting and cancellation.
    private func rebuildSpeakerCommands() {
        let conflict = speakerOutputSettings.conflictingPhrase(with: speakerOutputConflictingPhrases)
        if speakerOutputConflict != conflict { speakerOutputConflict = conflict }
        activeSpeakerCommands = conflict == nil ? speakerOutputSettings.commands : []
    }
    func saveSpeakerOutputSettings(_ settings: SpeakerOutputSettings) -> Bool {
        guard settings.issue == nil, settings.conflictingPhrase(with: speakerOutputConflictingPhrases) == nil else { return false }
        speakerOutputSettings = settings
        settings.save()
        updatePhrases()
        return true
    }
    private let desktopCommands = DesktopCommands()
    func appSpellingChoices() async -> [AppCandidate] { await desktopCommands.spellingChoices() }
    private var zoomPhraseDetectors = CommandPhraseDetectors<ZoomDirection>()
    // Both music phrases are one hardware action. Sharing the detector prevents a revised
    // "Play music" -> "Pause music" hypothesis from sending the same toggle twice.
    private var musicPhraseDetector = StandaloneWake()
    private var musicPatterns: [(slot: PhraseSlot, pattern: PhrasePattern)] {
        PhraseSlot.musicSlots.flatMap { slot in patterns(for: slot).map { (slot, $0) } }
    }
    private var appCommandDetector = AppCommandDetector()
    private var desktopTask: Task<Void, Never>?
    private var pendingAppCommands: [AppCommandCandidate] = []
    private var desktopCommandGeneration = UUID()
    @Published private(set) var desktopCommandStatus: String?
    private var zoomPatterns: [ZoomDirection: [PhrasePattern]] {
        Dictionary(uniqueKeysWithValues: ZoomDirection.allCases.map { ($0, patterns(for: $0.slot)) })
    }
    // Browser video control through Agent Flow Bridge. Independent of Codex Voice.
    let videoBridge = VideoBridge()
    @Published private(set) var videoCommandStatus: String?
    private var videoPhraseDetectors = VideoPhraseDetectors()
    private var videoPatterns: [VideoCommand: [PhrasePattern]] {
        Dictionary(uniqueKeysWithValues: VideoCommand.allCases.map { ($0, patterns(for: $0.slot)) })
    }
    @Published var phraseDictionaries = UserDefaults.standard.object(forKey: "phraseDictionaries") as? [String: [String]] ?? [:] {
        didSet { UserDefaults.standard.set(phraseDictionaries, forKey: "phraseDictionaries"); rebuildPhraseDictionaries(); updatePhrases() }
    }
    private(set) var matchingDictionaries = PhraseDictionaries(Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.compactMap { slot in
        (UserDefaults.standard.object(forKey: "phraseDictionaries") as? [String: [String]])?[slot.rawValue].map { (PhraseMatcher.words(slot.defaultText).joined(), $0) }
    }))
    private func rebuildPhraseDictionaries() {
        matchingDictionaries = PhraseDictionaries(Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.compactMap { slot in
            phraseDictionaries[slot.rawValue].map { (PhraseMatcher.words(slot.defaultText).joined(), $0) }
        }))
    }
    // A section's active phrases. Only a phrase equal to the section's default uses alternate
    // spellings; every other main or extra phrase matches exactly.
    func patterns(for slot: PhraseSlot) -> [PhrasePattern] {
        phraseConfiguration.phrases(for: slot).map {
            PhrasePattern(slot: slot, text: $0, similar: similarPhrases, dictionaries: matchingDictionaries)
        }
    }
    var phrasePatterns: [PhrasePattern] { PhraseSlot.allCases.flatMap { patterns(for: $0) } + activeSpeakerCommands.map(\.pattern) }
    // Every phrase for an audio action, with the section that owns it, so the cue follows the match.
    private func patterns(for action: VoiceAudioAction) -> [(slot: PhraseSlot, pattern: PhrasePattern)] {
        action.slots.flatMap { slot in patterns(for: slot).map { (slot, $0) } }
    }
    private var spokenWakePhrase: String { phraseConfiguration.phrases(for: .wakePhrase).first ?? wakePhrase }
    private var spokenEndPhrase: String { phraseConfiguration.phrases(for: .sleepPhrase).first ?? sleepPhrase }
    private func rebuildPhraseConfiguration() {
        let rows = Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map { slot in
            (slot, [self[keyPath: phraseKeyPath(for: slot)]] + (phraseAliases[slot] ?? []).map(\.text))
        })
        let configuration = PhraseConfiguration(rows: rows)
        if configuration != phraseConfiguration { phraseConfiguration = configuration }
    }
    // Rows below a main phrase. Typing updates the row immediately; slash entry is split later.
    func setPhraseRow(_ slot: PhraseSlot, id: UUID, text: String) {
        guard let index = phraseAliases[slot]?.firstIndex(where: { $0.id == id }), phraseAliases[slot]?[index].text != text else { return }
        phraseAliases[slot]?[index].text = text
    }
    @discardableResult func addPhraseRow(_ slot: PhraseSlot) -> UUID {
        let row = PhraseRow("")
        phraseAliases[slot, default: []].append(row)
        return row.id
    }
    func removePhraseRow(_ slot: PhraseSlot, id: UUID) {
        guard let index = phraseAliases[slot]?.firstIndex(where: { $0.id == id }) else { return }
        phraseAliases[slot]?.remove(at: index)
        if phraseAliases[slot]?.isEmpty == true { phraseAliases[slot] = nil }
    }
    func phraseSlot(containing id: UUID) -> PhraseSlot? {
        PhraseSlot.allCases.first { phraseAliases[$0]?.contains { $0.id == id } == true }
    }
    // Submit or focus loss: "Open app / Switch app" keeps the first piece in this row and adds the
    // rest directly below it, skipping phrases this section already lists. `id` nil is the main row.
    func commitPhraseRow(_ slot: PhraseSlot, id: UUID?) {
        let aliases = phraseAliases[slot] ?? []
        let index = id.flatMap { id in aliases.firstIndex { $0.id == id } }
        if id != nil, index == nil { return }
        let mainText = self[keyPath: phraseKeyPath(for: slot)]
        let result = PhraseList.commit(main: mainText, rows: aliases, at: index)
        if result.main != mainText { self[keyPath: phraseKeyPath(for: slot)] = result.main }
        if result.rows != aliases { phraseAliases[slot] = result.rows.isEmpty ? nil : result.rows }
    }
    // Any row with letters or numbers, even one ignored as a repeat, so Settings doesn't ask for
    // a phrase already entered. Starting still needs a distinct active wake and End phrase.
    func hasPhrase(_ slot: PhraseSlot) -> Bool {
        phraseConfiguration.rows[slot]?.contains { !PhraseMatcher.words($0).isEmpty } == true
    }
    func phraseIssue(_ slot: PhraseSlot, id: UUID?) -> PhraseConfiguration.Issue? {
        guard let id else { return phraseConfiguration.issue(slot, row: 0) }
        return phraseAliases[slot]?.firstIndex { $0.id == id }.flatMap { phraseConfiguration.issue(slot, row: $0 + 1) }
    }
    func phraseKeyPath(for slot: PhraseSlot) -> ReferenceWritableKeyPath<GateModel, String> {
        switch slot {
        case .wakePhrase: return \.wakePhrase
        case .sleepPhrase: return \.sleepPhrase
        case .mutePhrase: return \.mutePhrase
        case .unmutePhrase: return \.unmutePhrase
        case .silentPhrase: return \.silentPhrase
        case .silencePhrase: return \.silencePhrase
        case .unsilencePhrase: return \.unsilencePhrase
        case .pauseVideoPhrase: return \.pauseVideoPhrase
        case .playVideoPhrase: return \.playVideoPhrase
        case .pauseMusicPhrase: return \.pauseMusicPhrase
        case .playMusicPhrase: return \.playMusicPhrase
        case .switchAppPhrase: return \.switchAppPhrase
        case .openAppPhrase: return \.openAppPhrase
        case .zoomInPhrase: return \.zoomInPhrase
        case .zoomOutPhrase: return \.zoomOutPhrase
        }
    }
    var controlPhrases: [String] { VoiceAudioAction.allCases.flatMap { $0.slots.flatMap { phraseConfiguration.phrases(for: $0) } } }
    @Published var similarPhrases = UserDefaults.standard.object(forKey: "similarPhrases") as? Bool ?? true {
        didSet { UserDefaults.standard.set(similarPhrases, forKey: "similarPhrases"); updatePhrases() }
    }
    @Published private(set) var error: String?
    // Shortcut activation is independent of microphone/model preparation, which
    // clears ordinary errors. Keep the restart notice until an explicit refresh.
    @Published private(set) var shortcutNotice: String?
    @Published private(set) var lastEvent = ""
    @Published private(set) var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var micPermissionDenied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()
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
    private var listeningInitialized = false
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
        spotifyVolume = SpotifyVoiceVolume(monitor: voiceCalls)
        PhraseList.seedDefaults(in: .standard)
        phraseAliases = PhraseList.decode(UserDefaults.standard.object(forKey: PhraseList.defaultsKey)).mapValues { $0.map { PhraseRow($0) } }
        Diagnostics.shared.record("app.started", info: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
        desktopSession.onChange = { [weak self] state in
            guard let self else { return }
            // A lock or session switch cannot carry a queued wake into the
            // next desktop. Preserve any late call and require a fresh phrase.
            self.endPhrase.reset(); self.standaloneWake.reset(); self.resetAudioPhrases()
            self.cancelAppCommands()
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
            self?.transcriptBatchID = UUID()
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
            self?.videoPhraseDetectors.audio(level: level, seconds: seconds, at: audioTime)
            self?.zoomPhraseDetectors.audio(level: level, seconds: seconds, at: audioTime)
            self?.musicPhraseDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.speakerOutputDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.appCommandDetector.audio(level: level, seconds: seconds, at: audioTime)
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
            self.detail = self.microphone == .listening ? "Say \(self.spokenEndPhrase) to end chat." : "Say \(self.spokenWakePhrase) to start chat."
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
            guard let input = self?.inputs.selected else { throw BridgeError.message("Selected microphone is unavailable. Choose a microphone on Home.") }
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
        if enableSpotifyControl {
            voiceCalls.onChange = { [weak self] state in
                guard let self, !self.quitting else { return }
                self.spotifyVolume.observe(state)
                self.voicePeerPriority.observe(state)
                self.voiceStatusRefresh.observe(state.presence, at: state.observedAt)
                self.scheduleObservedVoiceEnd()
                if self.endFeedback.observe(state.presence, callIdentifier: state.callIdentifier) {
                    self.feedback.play(PhraseSlot.sleepPhrase.cue)
                }
            }
            spotifyVolume.setEnabled(lowerSpotifyDuringChat)
            if voicePeerPriority.enabled { voicePeerMailbox.start() }
            updateVoiceCallMonitoring()
        }
    }

    private func updateVoiceCallMonitoring() {
        if soundEffects || lowerSpotifyDuringChat || voicePeerPriority.enabled { voiceCalls.start() }
        else { voiceCalls.stop(); endFeedback = VoiceEndFeedback() }
    }
    // Spoken or button video control. Sent once; Agent Flow Bridge picks the browser video and
    // answers with the outcome. Nothing here changes Voice, the microphone or the busy state.
    func requestVideo(_ command: VideoCommand) {
        guard !quitting else { return }
        Diagnostics.shared.record("video.command.requested", info: ["action": command.rawValue,
            "bridge": videoBridge.availability.isAvailable ? "available" : "unavailable"])
        videoBridge.send(command) { [weak self] outcome in
            Diagnostics.shared.record("video.command.result", info: ["action": command.rawValue, "outcome": outcome.diagnostic])
            guard let self, !self.quitting else { return }
            self.lastEvent = outcome.summary(for: command)
            self.videoCommandStatus = outcome.summary(for: command)
            if outcome.confirms(command) { self.feedback.play(command.slot.cue) }
        }
    }
    func refreshVideoBridge() { if !quitting { videoBridge.refresh() } }
    // One shortcut pair to the frontmost app. Reports dispatch, not whether the app zoomed.
    private func requestZoom(_ direction: ZoomDirection) {
        guard !quitting else { return }
        let result = desktopCommands.zoom(direction) { feedback.play(direction.slot.cue) } // Only once the keys are sent.
        Diagnostics.shared.record("desktop.zoom", info: ["direction": direction.rawValue, "outcome": result.diagnostic])
        if let message = result.message { desktopCommandStatus = message }
    }
    private func requestSpeakerOutput(_ output: String) {
        guard !quitting else { return }
        guard speakerOutputTask == nil else { speakerOutputStatus = "Already switching speakers."; return }
        speakerOutputStatus = "Switching speakers…"
        switchingSpeakerOutput = true
        speakerOutputTask = Task { [weak self] in
            let message = await Task.detached { SpeakerOutput.switchTo(output) }.value
            guard let self else { return }
            self.speakerOutputTask = nil
            self.switchingSpeakerOutput = false
            if !self.quitting { self.speakerOutputStatus = message; self.lastEvent = message }
        }
    }
    private func requestMusic(_ slot: PhraseSlot) {
        guard !quitting else { return }
        let result = desktopCommands.toggleCurrentMedia { feedback.play(slot.cue) }
        Diagnostics.shared.record("media.play_pause", info: ["phrase_slot": slot.rawValue, "outcome": result.diagnostic])
        if let message = result.message { lastEvent = message; desktopCommandStatus = message }
    }
    // App commands run one after another in spoken order; each heard occurrence acts once.
    private func performAppCommands(_ candidates: [AppCommandCandidate]) {
        pendingAppCommands.append(contentsOf: candidates.prefix(max(0, 8 - pendingAppCommands.count)))
        guard desktopTask == nil else { return }
        let token = desktopCommandGeneration
        desktopTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.desktopCommandGeneration == token,
                  let candidate = self.pendingAppCommands.first {
                self.pendingAppCommands.removeFirst()
                let dispatchedAt = Diagnostics.now
                // The cue marks an accepted switch/open request, before front-app confirmation.
                // Ordinary speech, unresolved names and cancelled work stay silent.
                let result = await self.desktopCommands.perform(candidate, spellings: self.appNameSpellings) {
                    if !self.quitting, self.desktopCommandGeneration == token { self.feedback.play(candidate.kind.slot.cue) }
                }
                guard !Task.isCancelled, self.desktopCommandGeneration == token else { return }
                Diagnostics.shared.record("desktop.app", numbers: ["duration_ms": (Diagnostics.now - dispatchedAt) * 1000],
                    info: ["kind": candidate.kind.rawValue, "bare": String(candidate.bare), "outcome": result.diagnostic])
                if let message = result.message { self.desktopCommandStatus = message }
            }
            if self?.desktopCommandGeneration == token { self?.desktopTask = nil }
        }
    }
    private func cancelAppCommands() {
        pendingAppCommands.removeAll()
        desktopCommandGeneration = UUID()
        desktopTask?.cancel()
        desktopTask = nil
    }
    func initializeListening() {
        refreshVideoBridge()
        guard !listeningInitialized else { return }
        // Screen enumeration can settle after model construction. Read it at
        // window startup before choosing the already-docked behavior.
        dock.refresh()
        dockDelay = DockListeningDelay(alreadyDockedAtStartup: automaticListening && dock.eligible)
        listeningInitialized = true
        applyAutomaticListening()
    }
    private func applyAutomaticListening() {
        guard listeningInitialized else { return }
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
        guard enabled, !checkingSpeech, !quitting else { return }
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
                    detail = voice.connected ? (microphone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(spokenEndPhrase) to end chat.") : "Say \(spokenWakePhrase) to start chat."
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
        guard enabled, !quitting, !checkingSpeech else { return }
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
              !quitting, !checkingSpeech else { return }
        speechRecovery = SpeechRecovery()
        Diagnostics.shared.record("speech.recovery.environment_changed")
        restartMicrophone(settle: true)
    }
    private func resetAudioPhrases() {
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action] = StandaloneWake() }
        videoPhraseDetectors.reset()
        zoomPhraseDetectors.reset()
        musicPhraseDetector.reset()
        speakerOutputDetector.reset()
        appCommandDetector.reset()
    }
    private func updatePhrases() {
        rebuildPhraseConfiguration()
        rebuildSpeakerCommands()
        cancelAppCommands()
        listener.contextualPhrases = phraseConfiguration.allPhrases + activeSpeakerCommands.map { $0.pattern.text }
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
        micPermissionDenied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibilityAllowed = AXIsProcessTrusted()
    }
    func requestAudioPermissions() {
        Task {
            do { try await SpeechListener.authorize(); refreshPermissions() }
            catch { self.error = error.localizedDescription; refreshPermissions() }
        }
    }
    func requestAccessibilityPermission() {
        // Only a user's button press requests the native prompt; never grant or
        // reset access automatically. Returning to the app rechecks the grant.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
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
            confirmedVoiceStatusRead()
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
                    throw BridgeError.message("The speech sample is missing. Reinstall Hello Chat.")
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
        guard !enabled, !busy, !quitting else { return }
        cancelAutomaticStart(reason: "starting")
        busy = true; error = nil; status = "Starting"; detail = "Preparing local speech recognition."
        let token = UUID(); generation = token
        defer {
            if generation == token { busy = false; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
        }
        do {
            // A phrase listed for both is ignored for End, as before; at least one distinct phrase each.
            guard !phraseConfiguration.phrases(for: .wakePhrase).isEmpty, !phraseConfiguration.phrases(for: .sleepPhrase).isEmpty else {
                throw BridgeError.message("Use different wake and end phrases.")
            }
            try await SpeechListener.authorize()
            guard generation == token, !quitting else { return }
            refreshPermissions(); updatePhrases(); endPhrase.reset()
            if !preservingTranscript { transcript = "" } // A diagnostic can keep the current batch visible until fresh recognition replaces it, without accumulating older batches.
            transcriptBatchID = UUID()
            lastEvent = ""
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
        detail = enabled ? "Say \(spokenWakePhrase) to start chat." : "Start listening for \(spokenWakePhrase)."
        if enabled, voice.connected {
            detail = microphone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(spokenEndPhrase) to end chat."
        }
        voiceText = voice.connected ? "Check chat" : "Chat is off"
        if !voice.connected { microphone = .muted }
    }
    private func stopLocal(preservingCall: Bool = false) {
        cancelAppCommands()
        finishStartupSpeech(preserveRequested: preservingCall || quitting)
        if !preservingCall, !quitting { cancelStartupSpeech() }
        // Undocking stops local capture while preserving the conversation.
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
        status = "Off"; detail = "Start listening for \(spokenWakePhrase)."; lastEvent = "Listening stopped"
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
    // Siri and personally trained Vocal Shortcuts use the same native actions
    // and task ownership as the window/phrases. A native shortcut can start a
    // call while local transcription is off, without turning that listener on.
    func performShortcut(_ action: HChatShortcutAction) async throws -> String {
        if action == .status {
            let snapshot = await Task.detached(priority: .utility) { VoiceBridge.snapshot() }.value
            guard snapshot.accessibilityAllowed else {
                throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.")
            }
            if let microphone = snapshot.microphone {
                return microphone == .muted ? "Chat microphone is muted." : "Chat is listening."
            }
            if snapshot.endControlAvailable { return "Chat is on. Microphone status is unknown." }
            if snapshot.applicationAbsent || (snapshot.controlsComplete && !snapshot.inputRunning) { return "Chat is off." }
            return "Chat status is unknown."
        }
        guard !quitting, !busy || action == .end else {
            throw BridgeError.message("Hello Chat is busy. Try again when the current action finishes.")
        }
        let token = generation
        error = nil
        Diagnostics.shared.record("shortcut.requested", info: ["action": action.rawValue])
        switch action {
        case .start:
            if enabled && detectionRunning {
                beginVoice(trigger: "Voice started with shortcut")
            } else {
                busy = true
                feedback.play(PhraseSlot.wakePhrase.cue)
                let context = VoiceStartContext()
                voiceStartContext = context
                voiceTask = Task {
                    await openVoice(trigger: "Voice started with shortcut", context: context, requiresListening: false)
                }
            }
        case .end:
            manualMute(force: true)
        case .muteMicrophone, .unmuteMicrophone, .silenceSpeakers, .unsilenceSpeakers:
            let audio: VoiceAudioAction
            switch action {
            case .muteMicrophone: audio = .muteMicrophone
            case .unmuteMicrophone: audio = .unmuteMicrophone
            case .silenceSpeakers: audio = .silenceSpeakers
            case .unsilenceSpeakers: audio = .unsilenceSpeakers
            case .start, .end, .status: preconditionFailure("Handled above")
            }
            busy = true
            voiceTask = Task {
                defer { if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() } }
                do {
                    let call = spotifyVolume.callEpoch
                    let active = try await voice.setAudio(audio, onRecognized: { self.feedback.play(.microphoneDetected) })
                    guard generation == token else { return }
                    guard active else { throw BridgeError.message("Codex Voice is off.") }
                    confirmedVoiceStatusRead()
                    if !audio.controlsSpeakers {
                        microphone = audio.targetMuted ? .muted : .listening
                        spotifyVolume.confirmMicrophoneMute(audio.targetMuted, in: call)
                    }
                    if let slot = audio.slots.first { feedback.play(slot.cue) }
                    showListening()
                    lastEvent = audio.controlsSpeakers ? "Chat audio is \(audio.targetMuted ? "muted" : "on")" : "Chat is \(audio.targetMuted ? "muted" : "listening")"
                } catch {
                    guard generation == token, !(error is CancellationError) else { return }
                    self.error = error.localizedDescription
                }
            }
        case .status: break // Read-only status returned before reserving any control work.
        }
        let completionGeneration = generation // End may supersede an opening/audio operation.
        let operation = voiceTask
        await operation?.value
        try Task.checkCancellation()
        guard generation == completionGeneration, !quitting else { throw CancellationError() }
        if let error { throw BridgeError.message(error) }
        if action == .start, !voice.connected { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
        Diagnostics.shared.record("shortcut.completed", info: ["action": action.rawValue])
        // Keep actual configured wake/end phrases out of Siri's spoken result.
        switch action {
        case .start: return "Chat is on."
        case .end: return "Chat is off."
        case .muteMicrophone: return "Chat microphone is muted."
        case .unmuteMicrophone: return "Chat microphone is on."
        case .silenceSpeakers: return "Chat speakers are muted."
        case .unsilenceSpeakers: return "Chat speakers are on."
        case .status: return "Chat status is unknown."
        }
    }
    func manualMute(feedbackAlreadyPlayed: Bool = false, force: Bool = false) {
        guard enabled || voice.connected || voiceStartContext != nil || force, !quitting, !endingVoice else { return }
        cancelStartupSpeech()
        if busy, voiceStartContext != nil {
            let previous = voiceTask
            previous?.cancel()
            let token = UUID(); generation = token
            busy = true; endingVoice = true
            voiceTask = Task {
                defer { endingVoice = false; if generation == token { busy = false; voiceTask = nil } }
                await voice.stop(); await previous?.value
                guard generation == token, enabled || force else { return }
                showListening(); lastEvent = "Voice connection cancelled"
                if let failure = voice.lastError { error = failure }
            }
        } else if busy {
            let previous = voiceTask
            let token = UUID(); generation = token // The cancelled audio task must not clear the End request's busy state or show a cancellation error.
            previous?.cancel()
            voiceTask = Task {
                await previous?.value
                guard generation == token, !quitting else { return }
                await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed, reserved: true, force: force)
            }
        } else {
            busy = true; endingVoice = true
            voiceTask = Task { await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed, reserved: true, force: force) }
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
            confirmedVoiceStatusRead()
            microphone = found
            showListening()
            if voice.connected { voiceText = "Chat is on" }
            lastEvent = voice.connected ? "Chat is on" : "Chat is off"
        }
    }
    private func confirmedVoiceStatusRead() {
        // A fresh positive command/status result outranks an older queued observer read.
        guard voice.connected else { return }
        voiceStatusRefresh.confirmedLocalState(active: true, at: ProcessInfo.processInfo.systemUptime)
    }
    private func scheduleObservedVoiceEnd() {
        guard voiceStatusRefresh.pending, voiceStatusTask == nil, !quitting else { return }
        voiceStatusTask = Task { @MainActor [weak self] in
            // One observer read can emit End(old) then Active(new). Coalesce that
            // actor job before changing the cache, without a timer or busy window.
            await Task.yield()
            guard let self else { return }
            self.voiceStatusTask = nil
            guard !Task.isCancelled,
                  self.voiceStatusRefresh.takeIfIdle(!self.busy && !self.endingVoice
                    && self.voiceStartContext == nil && !self.quitting),
                  self.voice.acceptObservedEnd() else { return }
            self.voiceText = "Chat is off"
            self.microphone = .muted
            // A call ending must not replace an unrelated capture error or dock wait.
            if ["Chat on", "Listening", "Off"].contains(self.status) { self.showListening() }
            self.lastEvent = "Chat is off"
            Diagnostics.shared.record("voice.status.observed_end")
        }
    }
    private func beginVoice(trigger: String, wakeRange: Range<Int>? = nil) {
        guard enabled, detectionRunning, !busy, !quitting else { return }
        // Reserve synchronously so an end phrase arriving before this Task's
        // first turn cancels the queued opening instead of starting a second action.
        busy = true
        // Acknowledge the request before scheduling Voice work. The sound does
        // not mean Codex connected, and the busy reservation prevents reentry.
        feedback.play(PhraseSlot.wakePhrase.cue)
        // A repeated wake may reuse the current call. Finish its previous
        // opening first; an unpublished reuse buffer must not strand that file.
        finishStartupSpeech(preserveRequested: true)
        finishedStartupObservation = nil
        let context = VoiceStartContext()
        voiceStartContext = context
        startupSpeech = StartupSpeechBuffer(id: context.id, text: transcript, wakeRange: wakeRange, patterns: patterns(for: .wakePhrase))
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
    private func openVoice(trigger: String, context: VoiceStartContext, requiresListening: Bool = true) async {
        guard enabled || !requiresListening, !quitting, !Task.isCancelled else { busy = false; return }
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
            let spotifyCall = spotifyVolume.callEpoch
            let openedMicrophone = try await voice.start(context: context)
            try Task.checkCancellation()
            guard enabled || !requiresListening, generation == token else { return }
            if let openedMicrophone, openedMicrophone != .listening { try await voice.setMicrophone(.listening) }
            try Task.checkCancellation()
            guard enabled || !requiresListening, generation == token else { return }
            if openedMicrophone != nil, !context.requestedNewCall {
                spotifyVolume.confirmMicrophoneMute(false, in: spotifyCall)
            }
            voiceStatusRefresh.confirmedLocalState(active: true, at: ProcessInfo.processInfo.systemUptime)
            microphone = openedMicrophone == nil ? nil : .listening; voiceText = "Chat is on"; status = "Chat on"
            detail = openedMicrophone == nil ? "Chat is open. Check the microphone in Codex." : "Say \(spokenEndPhrase) to end chat."; lastEvent = trigger
        } catch {
            Diagnostics.shared.failure("voice.open.failed", error)
            await voice.recoverFromStartFailure(error, context: context)
            guard generation == token, enabled || !requiresListening else { return }
            showListening()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    private func muteVoice(event: String, feedbackAlreadyPlayed: Bool = false, reserved: Bool = false, force: Bool = false) async {
        guard enabled || voice.connected || force, !busy || reserved else { return }
        cancelStartupSpeech()
        let token = generation
        let feedbackEpoch = endFeedback.activeEpoch
        busy = true; endingVoice = true
        defer {
            endingVoice = false
            if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
        }
        do {
            let ended = try await voice.endIfPresent()
            guard generation == token else { return }
            voiceStatusRefresh.confirmedLocalState(active: false, at: ProcessInfo.processInfo.systemUptime)
            showListening(); lastEvent = ended ? event : "Heard \(spokenEndPhrase) · Codex Voice is already off"
            if ended, !feedbackAlreadyPlayed, endFeedback.claimConfirmedEnd(for: feedbackEpoch) { feedback.play(PhraseSlot.sleepPhrase.cue) }
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
        // Use the same phrase and mention rules while Agent Flow records. Its
        // microphone ownership must not pause H Chat's existing recognizer.
        standaloneWake.update(text, at: Diagnostics.now, timings: timings)
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action, default: StandaloneWake()].update(text, at: Diagnostics.now, timings: timings) }
        videoPhraseDetectors.update(text, at: Diagnostics.now, timings: timings)
        zoomPhraseDetectors.update(text, at: Diagnostics.now, timings: timings)
        musicPhraseDetector.update(text, at: Diagnostics.now, timings: timings)
        speakerOutputDetector.update(text, at: Diagnostics.now, timings: timings)
        appCommandDetector.update(text, at: Diagnostics.now, timings: timings)
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
        // Every listed phrase for a command shares its detector, occurrence count and sound.
        // A phrase listed for different commands keeps its first owner in PhraseConfiguration.
        let wakePatterns = patterns(for: .wakePhrase), endPatterns = patterns(for: .sleepPhrase)
        if let endPattern = endPatterns.first, !wakePatterns.isEmpty
            && endPhrase.poll(at: Diagnostics.now, phrase: endPattern.text, similar: endPattern.similar, rejectNegated: true, ending: true, patterns: endPatterns) {
            for action in VoiceAudioAction.allCases {
                let entries = patterns(for: action).map(\.pattern)
                if !entries.isEmpty { audioPhraseDetectors[action, default: StandaloneWake()].cancelPending(patterns: entries, endPatterns: endPatterns) }
            } // An explicit End wins over audio commands in the same transcript.
            videoPhraseDetectors.cancelPending(aliases: videoPatterns, endPatterns: endPatterns) // ...and over video commands.
            zoomPhraseDetectors.cancelPending(aliases: zoomPatterns, endPatterns: endPatterns) // ...and desktop commands.
            musicPhraseDetector.cancelPending(patterns: musicPatterns.map(\.pattern), endPatterns: endPatterns)
            speakerOutputDetector.cancelPending(patterns: activeSpeakerCommands.map(\.pattern), endPatterns: endPatterns)
            appCommandDetector.consumeAll(switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase))
            cancelStartupSpeech()
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: endPatterns)
            Diagnostics.shared.record("phrase.end.detected", info: ["busy": String(busy), "voice": microphone?.rawValue ?? "unknown"])
            // Ethan's "buy chat" / Bye Chat gets its cue when recognized, even
            // while cancelling an opening or when Voice is already off. Native
            // status and errors still report the actual ending outcome separately.
            endFeedback.detectedEnd()
            feedback.play(PhraseSlot.sleepPhrase.cue)
            if busy { manualMute(feedbackAlreadyPlayed: true) }
            else {
                voiceTask = Task { await muteVoice(event: "Heard \(spokenEndPhrase)", feedbackAlreadyPlayed: true) }
            }
            return
        }
        // Browser video commands: consumed whether or not the bridge is available, never busy-gated,
        // and never routed to beginVoice. Earlier wakes in the same transcript are consumed too.
        let videoCommands = videoPhraseDetectors.poll(at: Diagnostics.now, aliases: videoPatterns)
        if let command = VideoPhraseDetectors.admitted(videoCommands) {
            for accepted in videoCommands {
                standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: accepted.command.slot))
            }
            requestVideo(command)
        }
        let music = musicPatterns
        if let first = music.first,
           musicPhraseDetector.poll(at: Diagnostics.now, phrase: first.pattern.text, similar: first.pattern.similar,
                rejectNegated: true, patterns: music.map(\.pattern), directOnly: true),
           let index = musicPhraseDetector.acceptedPatternIndex, music.indices.contains(index) {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: music.map(\.pattern))
            requestMusic(music[index].slot)
        }
        // A full prefix + destination is required. Consume matching app prefixes too: the
        // generic "Switch" app prefix must not also open an app named after a speaker.
        let speakerCommands = activeSpeakerCommands
        if let first = speakerCommands.first,
           speakerOutputDetector.poll(at: Diagnostics.now, phrase: first.pattern.text, similar: false,
                rejectNegated: true, patterns: speakerCommands.map(\.pattern), directOnly: true),
           let index = speakerOutputDetector.acceptedPatternIndex, speakerCommands.indices.contains(index) {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: speakerCommands.map(\.pattern))
            if let range = speakerOutputDetector.acceptedRange {
                appCommandDetector.consume(overlapping: range, switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase))
            }
            if !quitting, !capturingStartupSpeech { requestSpeakerOutput(speakerCommands[index].output) }
        }
        // Zoom and app commands: same consumption rules, never busy-gated and never routed to
        // beginVoice. While an opening is being captured for Voice, its words belong to Voice.
        let zooms = zoomPhraseDetectors.poll(at: Diagnostics.now, aliases: zoomPatterns, directOnly: true,
            onDecision: { command, decision in
                Diagnostics.shared.record("desktop.zoom.evaluated", info: ["command": command.rawValue, "decision": decision])
            })
        if !zooms.isEmpty {
            for accepted in zooms {
                standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: accepted.command.slot))
            }
            if !quitting, !capturingStartupSpeech { for accepted in zooms { requestZoom(accepted.command) } }
        }
        let appCommands = appCommandDetector.poll(switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase),
            onDecision: { command, decision, evidence in
                // Counts and timing only, never words: separates a missed pause from discussion.
                var numbers = ["left_words": Double(evidence.leftWords), "name_words": Double(evidence.nameWords)]
                if let gap = evidence.gapBefore { numbers["gap_before_s"] = gap }
                if let elapsed = evidence.elapsed { numbers["pause_after_s"] = elapsed }
                Diagnostics.shared.record("desktop.app.evaluated", numbers: numbers,
                    info: ["command": command.rawValue, "decision": decision, "timing": evidence.timing])
            })
        if !appCommands.isEmpty, !quitting, !capturingStartupSpeech { performAppCommands(appCommands) }
        let actions = VoiceAudioAction.allCases.compactMap { action -> (action: VoiceAudioAction, position: Int, slot: PhraseSlot)? in
            let entries = patterns(for: action)
            guard let first = entries.first,
                  audioPhraseDetectors[action, default: StandaloneWake()].poll(at: Diagnostics.now, phrase: first.pattern.text, similar: similarPhrases, rejectNegated: true, patterns: entries.map(\.pattern)),
                  let detector = audioPhraseDetectors[action], let position = detector.acceptedRange?.lowerBound,
                  let patternIndex = detector.acceptedPatternIndex, entries.indices.contains(patternIndex) else { return nil }
            return (action, position, entries[patternIndex].slot)
        }.sorted { $0.position < $1.position }
        if !actions.isEmpty {
            // Reserve synchronously, as beginVoice does. Consume busy commands
            // rather than replaying a surprise mute when an opening/End finishes.
            guard !busy, !quitting else { return }
            for slot in PhraseSlot.allCases.dropFirst(2) where !slot.controlsDesktop {
                standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: slot)) // Consume fuzzy wakes too, so Hello Chad before mute cannot undo it.
            }
            busy = true
            let token = generation
            voiceTask = Task {
                defer { if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() } }
                do {
                    for (action, _, slot) in actions { // A delayed transcript can contain both channels or opposite commands; apply them in spoken order.
                        Diagnostics.shared.record("voice.audio.requested", info: ["action": action.rawValue, "phrase_slot": slot.rawValue])
                        let spotifyCall = spotifyVolume.callEpoch
                        let active = try await voice.setAudio(action, onRecognized: { self.feedback.play(.microphoneDetected) }) // Inactive Voice gets no sound or key.
                        guard generation == token else { return }
                        guard active else { continue }
                        confirmedVoiceStatusRead()
                        error = nil
                        if !action.controlsSpeakers {
                            microphone = action.targetMuted ? .muted : .listening
                            spotifyVolume.confirmMicrophoneMute(action.targetMuted, in: spotifyCall)
                        }
                        feedback.play(slot.cue) // Only after the requested state is confirmed.
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
              let wakePattern = wakePatterns.first,
              standaloneWake.poll(at: Diagnostics.now, phrase: wakePattern.text, similar: wakePattern.similar, patterns: wakePatterns, onDecision: { decision, quiet, stable in
                  Diagnostics.shared.record("phrase.wake.evaluated", numbers: ["quiet_s": quiet, "stable_s": stable], info: ["decision": decision])
              }) else { return }
        Diagnostics.shared.record("phrase.wake.detected", info: ["contextChecked": "true", "busy": String(busy)])
        if busy {
            // A detected wake still gets its cue while Voice is busy, without
            // scheduling another call or cancelling the work already underway.
            feedback.play(PhraseSlot.wakePhrase.cue)
            lastEvent = "Heard \(spokenWakePhrase) · finishing the current Voice action"
        } else { beginVoice(trigger: "Heard \(spokenWakePhrase)", wakeRange: standaloneWake.acceptedRange) }
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
        // Changes to listening settings or docking invalidate this saved state.
        dock.refresh()
        if let saved = updateListeningDelay { dockDelay = saved }
        updateListeningDelay = nil
        quitting = false; busy = false; voiceTask = nil
        spotifyVolume.setEnabled(lowerSpotifyDuringChat)
        if voicePeerPriority.enabled { voicePeerMailbox.start() }
        updateVoiceCallMonitoring()
        microphone = await voice.reattachAfterFailedUpdate()
        confirmedVoiceStatusRead()
        showListening()
        // Re-evaluate the saved listening choice and current docking state.
        applyAutomaticListening()
    }
    func prepareToQuit(preservingSpotify: Bool = false) async -> Bool {
        guard !quitting else { return false }
        Diagnostics.shared.record("app.quit.requested")
        updateListeningDelay = dockDelay
        if enabled { updateListeningDelay?.resumeActiveSession() }
        quitting = true
        voiceStatusTask?.cancel(); voiceStatusTask = nil
        voiceCalls.stop()
        voicePeerMailbox.stop()
        videoBridge.stop()
        let previous = voiceTask
        voice.detachForQuit()
        stopLocal()
        await voicePeerPriority.shutdown()
        await previous?.value
        await speakerOutputTask?.value // Let the helper finish microphone recovery before exit.
        archive.flush()
        await startupSpeechFile.flush()
        await spotifyVolume.shutdown(preservingVolume: preservingSpotify)
        return true
    }
}
