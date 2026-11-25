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
    @Published var bringHomeForward = UserDefaults.standard.object(forKey: "bringHomeForward") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bringHomeForward, forKey: "bringHomeForward") }
    }
    let phraseWindow = PhraseWindowPresentation()
    private var endFeedback = VoiceEndFeedback()
    private var voiceStatusRefresh = VoiceStatusRefresh()
    private var voiceStatusTask: Task<Void, Never>?
    private let voiceCalls = VoiceCallMonitor()
    private let receipts = SpokenCommandJournal.shared
    private let repetitions = RepeatedCommands()
    private var repeatAppTargets: [UUID: AppCommandCandidate] = [:]
    private var repetitionDetails: [UUID: (String?, String?)] = [:]
    private final class SpotifySpokenVolume {
        var value: Int
        var root: UUID?
        var cuePlayed = false
        var valid = true
        init(_ value: Int) { self.value = value }
    }
    private var spotifyVolumeRequests: [UUID: SpotifySpokenVolume] = [:]
    private var finalValueFrame = false
    @Published private(set) var lastCommandMessage: String?
    @Published private(set) var lastCommandDetail: String?
    private var latestCommandID: UUID?
    private let notificationHUD = NotificationReplyHUD()

    private func commandTitle(_ action: String) -> String {
        if let slot = PhraseSlot(rawValue: action) { return slot.settingsTitle }
        if let audio = VoiceAudioAction(rawValue: action), let slot = audio.slots.first { return slot.settingsTitle }
        return action == "speakerOutput" ? "Switch speakers" : "Switch app"
    }

    private func finishCommand(_ id: UUID?, _ phase: SpokenCommandJournal.Phase, message: String? = nil, detail: String? = nil,
                               repetition: RepeatedCommands.Progress? = nil) {
        if repetition == nil, let id, let root = repetitions.root(for: id), let outcome = RepeatedCommands.Outcome(rawValue: phase.rawValue) {
            if message != nil || detail != nil { repetitionDetails[root] = (message, detail) }
            if repetitions.finish(id, outcome) { return }
        }
        let entry = repetition.flatMap { receipts.progress($0.id, requested: $0.requested, completed: $0.completed, phase: phase) }
            ?? receipts.finish(id, phase)
        guard let entry else { return }
        let title = commandTitle(entry.action)
        let result: String
        switch phase {
        case .confirmed: result = "Confirmed"
        case .submitted: result = "Sent"
        case .failedBeforeDispatch: result = "Couldn’t run"
        case .superseded: result = "Superseded"
        default: result = "Result unconfirmed"
        }
        let count = repetition.map { $0.requested > 1 ? " \($0.completed) of \($0.requested)" : "" } ?? ""
        let summary = repetition == nil ? (message ?? "\(title) · \(result)") : "\(title) · \(result)\(count)"
        if entry.id == latestCommandID {
            lastCommandMessage = summary
            lastCommandDetail = detail
        }
        // Only command names, receipt state and stock results belong in the retained log.
        Diagnostics.shared.record("command.history", numbers: ["spoken_at": entry.at],
                                  info: ["receipt": entry.id.uuidString, "command": title, "result": result, "summary": summary])
    }

    func openCommandHistory() {
        Task {
            do {
                let url = try await Task.detached { try Diagnostics.shared.exportCommandHistory() }.value
                guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t open the command history."
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private var receiptSession: String?
    private var latestAudioTime: Double = 0
    private var receiptWordEnds: [Double] = []

    // Use the accepted words' audio time, even when an ASR revision arrives after Voice's handoff.
    // Every speech action supplies its normal replay route here. New actions cannot opt out
    // accidentally: the callback is required, while the user's per-command toggle defaults on. — GPT-6.1 Sol
    func reserveSpeech(_ action: String, target: String = "", range: Range<Int>?, discard: Bool = false,
                               onReserved: (UUID) -> Void = { _ in },
                               repeatAction: @escaping (UUID) -> Void) -> UUID? {
        guard let range else { return nil }
        let command = repetitionKey(action)
        guard !commandAvailability.disabledIDs.contains(command) else { return nil }
        // Showing what was heard is independent of dispatch: failed or already-covered
        // commands still need visible feedback. Repeated runs reuse their receipt. — GPT-6.1 Sol
        showHomeForDetectedPhrase()
        let now = Date().timeIntervalSince1970
        let index = range.upperBound - 1
        let age = receiptWordEnds.indices.contains(index) ? max(0, latestAudioTime - receiptWordEnds[index]) : 0
        do {
            switch try receipts.begin(action, target: target, session: receiptSession, at: now - age) {
            case .run(let id):
                onReserved(id)
                latestCommandID = id
                let title = commandTitle(action)
                let summary = title + " · Heard"
                lastCommandMessage = summary
                lastCommandDetail = nil
                Diagnostics.shared.record("command.history", numbers: ["spoken_at": now - age],
                                          info: ["receipt": id.uuidString, "command": title, "result": "Heard", "summary": summary])
                var reserving = true
                let step = repetitions.begin(id: id, range: range, repeats: CommandRepetition.enabled(command), requiresTimes: PhraseSlot(rawValue: action)?.isRewind == true || action == PhraseSlot.spotifyVolumePhrase.rawValue, valueArgument: action == PhraseSlot.spotifyVolumePhrase.rawValue, discard: discard, command: command) { [weak self] step in
                    if reserving { return } // The unqueued first action stays immediate; queued first actions use this callback later.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard !self.quitting, !self.commandAvailability.disabledIDs.contains(command), self.repetitions.shouldRun(step) else { self.finishCommand(step, .superseded); return }
                        repeatAction(step)
                    }
                }
                reserving = false
                if step == nil, !repetitions.contains(id) {
                    finishCommand(id, .failedBeforeDispatch, detail: "Use a repeat count from 1 to 100.")
                }
                return step
            case .covered: return nil
            }
        } catch {
            Diagnostics.shared.failure("voice.command.journal_failed", error)
            // A later lookup might recover. Without a durable claim it could repeat this action.
            return nil
        }
    }
    private func showHomeForDetectedPhrase() {
        guard bringHomeForward, !quitting else { return }
        let requested = phraseWindow.show()
        Diagnostics.shared.record("window.phrase", info: ["result": requested ? "requested" : "window-unavailable"])
    }
    private func repetitionKey(_ action: String) -> String {
        HomeCommand.forAction(action)?.id ?? action
    }
    private func repeatWake(receipt: UUID) {
        Task { @MainActor in
            let previous = voiceTask
            await previous?.value
            guard !quitting, repetitions.shouldRun(receipt) else { finishCommand(receipt, .superseded); return }
            // Repeat the native Start action without replacing the first wake's opening capture.
            let context = VoiceStartContext()
            voiceTask = Task { await openVoice(trigger: "Repeated wake", context: context, receipt: receipt) }
        }
    }
    private func repeatAudio(_ action: VoiceAudioAction, receipt: UUID) {
        Task { @MainActor in
            // The original handler may still be finishing another channel in the same transcript.
            // Await its real completion, without a timer or competing Voice operation. — GPT-6.1 Sol
            let previous = voiceTask
            await previous?.value
            guard !quitting, repetitions.shouldRun(receipt) else { finishCommand(receipt, .superseded); return }
            let shortcut: HChatShortcutAction
            switch action {
            case .muteMicrophone: shortcut = .muteMicrophone
            case .unmuteMicrophone: shortcut = .unmuteMicrophone
            case .silenceSpeakers: shortcut = .silenceSpeakers
            case .unsilenceSpeakers: shortcut = .unsilenceSpeakers
            }
            do { _ = try await performShortcut(shortcut, playFeedback: false); finishCommand(receipt, .submitted) }
            catch { finishCommand(receipt, .unknown, detail: error.localizedDescription) }
        }
    }

    // The former inline Show Voice handler; speech repetitions use the same navigation and status.
    // Moved without changing its current/previous-chat policy. — GPT-6.1 Sol
    private func repeatShowVoice(receipt id: UUID) {
        guard !quitting, showVoiceTask == nil else { finishCommand(id, .superseded); return }
        showVoiceTask = Task { [weak self] in
            let outcome = await ShowVoiceCommand.perform()
            guard let self else { return }
            // Completion can synchronously dispatch the next requested repetition. Clear the
            // finished task first so the next fresh action is not superseded by it.
            // Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
            self.showVoiceTask = nil
            self.finishCommand(id, outcome.didOpen ? .submitted : .failedBeforeDispatch,
                               detail: outcome == .inactive && self.observedVoicePresence == .active ? nil : outcome.message)
            guard !self.quitting else { return }
            if outcome != .inactive || self.observedVoicePresence != .active {
                self.desktopCommandStatus = outcome.message
                self.desktopStatusRequiresInactiveVoice = outcome == .inactive
            }
            if outcome.didOpen, self.repetitions.isFirst(id) { self.feedback.play(PhraseSlot.showVoicePhrase.cue) }
            Diagnostics.shared.record("voice.show", info: ["outcome": outcome.rawValue])
        }
    }
    private func requestSpotifyVolume(_ request: SpotifySpokenVolume, receipt id: UUID) {
        guard !quitting, repetitions.shouldRun(id) else { finishCommand(id, .superseded); return }
        let volume = request.value
        Task { [weak self] in
            guard let self else { return }
            do {
                let actual = try await self.spotifyVolume.setVolume(to: volume)
                self.finishCommand(id, actual == volume ? .confirmed : .unknown,
                                   detail: "Spotify volume · \(actual)%")
                if actual == volume, request.valid, request.value == volume, !request.cuePlayed {
                    request.cuePlayed = true
                    self.feedback.play(PhraseSlot.spotifyVolumePhrase.cue)
                }
                Diagnostics.shared.record("spotify.volume.command", numbers: ["requested": Double(volume), "actual": Double(actual)])
            } catch {
                let detail: String
                let failure = error as? SpotifyVolumeOperationFailure
                let phase: SpokenCommandJournal.Phase = failure?.beforeDispatch == true ? .failedBeforeDispatch : .unknown
                switch failure?.underlying ?? error {
                case SpotifyControlError.unavailable: detail = "Open Spotify, then try again."
                case SpotifyControlError.permissionRequired: detail = "Allow Spotify control in Settings."
                default: detail = "Couldn’t set Spotify volume."
                }
                self.finishCommand(id, phase, detail: detail)
                Diagnostics.shared.failure("spotify.volume.command_failed", error)
            }
        }
    }
    private let voicePeerPriority = VoicePeerPriority()
    private let voicePeerMailbox = VoicePeerMailbox(handler: VoicePeerControl.respond)
    let spotifyVolume: SpotifyVoiceVolume
    @Published var spotifyVolumeLimit = SpotifyVolumePolicy.limit() {
        didSet {
            UserDefaults.standard.set(spotifyVolumeLimit, forKey: SpotifyVolumePolicy.preferenceKey)
            spotifyVolume.volumeLimitChanged()
        }
    }
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
    @Published var rewindVideoPhrase = PhraseSlot.rewindVideoPhrase.savedValue() {
        didSet { UserDefaults.standard.set(rewindVideoPhrase, forKey: PhraseSlot.rewindVideoPhrase.rawValue); updatePhrases() }
    }
    @Published var rewindVideoSeconds = VideoCommand.rewindSeconds() {
        didSet { UserDefaults.standard.set(rewindVideoSeconds, forKey: VideoCommand.rewindSecondsPreference) }
    }
    @Published var rewindFivePhrase = PhraseSlot.rewindFivePhrase.savedValue() {
        didSet { UserDefaults.standard.set(rewindFivePhrase, forKey: "rewindFivePhrase"); updatePhrases() }
    }
    @Published var rewindTenPhrase = PhraseSlot.rewindTenPhrase.savedValue() {
        didSet { UserDefaults.standard.set(rewindTenPhrase, forKey: "rewindTenPhrase"); updatePhrases() }
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
    @Published var spotifyVolumePhrase = PhraseSlot.spotifyVolumePhrase.savedValue() {
        didSet { UserDefaults.standard.set(spotifyVolumePhrase, forKey: PhraseSlot.spotifyVolumePhrase.rawValue); updatePhrases() }
    }
    @Published var callDotPhrase = PhraseSlot.callDotPhrase.savedValue() {
        didSet { UserDefaults.standard.set(callDotPhrase, forKey: PhraseSlot.callDotPhrase.rawValue); updatePhrases() }
    }
    @Published var hangUpDotPhrase = PhraseSlot.hangUpDotPhrase.savedValue() {
        didSet { UserDefaults.standard.set(hangUpDotPhrase, forKey: PhraseSlot.hangUpDotPhrase.rawValue); updatePhrases() }
    }
    @Published var switchAppPhrase = PhraseSlot.switchAppPhrase.savedValue() {
        didSet { UserDefaults.standard.set(switchAppPhrase, forKey: "switchAppPhrase"); updatePhrases() }
    }
    @Published var openAppPhrase = PhraseSlot.openAppPhrase.savedValue() {
        didSet { UserDefaults.standard.set(openAppPhrase, forKey: "openAppPhrase"); updatePhrases() }
    }
    @Published var showVoicePhrase = PhraseSlot.showVoicePhrase.savedValue() {
        didSet { UserDefaults.standard.set(showVoicePhrase, forKey: "showVoicePhrase"); updatePhrases() }
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
    @Published private(set) var commandAvailability = CommandAvailability.load()
    @Published private(set) var commandEditor: CommandEditorRequest?
    var disabledCommands: [HomeCommand] {
        HomeCommand.all.filter { isCommandListed($0, on: .settings) }
    }
    func isCommandListed(_ command: HomeCommand, on origin: CommandEditorRequest.Origin) -> Bool {
        if commandEditor?.command == command { return commandEditor?.origin == origin }
        return commandAvailability.isEnabled(command) == (origin == .home)
    }
    func openCommandSettings(_ command: HomeCommand, from origin: CommandEditorRequest.Origin) {
        guard commandEditor == nil else { return }
        commandEditor = .init(command: command, origin: origin)
    }
    func closeCommandSettings(from origin: CommandEditorRequest.Origin) {
        if commandEditor?.origin == origin { commandEditor = nil }
    }
    func setCommandEnabled(_ value: Bool, command: HomeCommand) {
        guard commandAvailability.isEnabled(command) != value else { return }
        commandAvailability.setEnabled(value, for: command)
        commandAvailability.save()
        if !value { repetitions.cancelPending(command: command.id) }
        updatePhrases(cancelPendingApps: command.slots.contains(.switchAppPhrase))
        Diagnostics.shared.record("command.availability", info: ["command": command.id, "enabled": String(value)])
    }
    // Mac app and zoom commands don't depend on a connected Voice call.
    @Published var appNameSpellings = AppNameSpellings.load(from: .standard) { // Applies new built-ins to saved lists once.
        didSet { UserDefaults.standard.set(appNameSpellings.overrides, forKey: AppNameSpellings.defaultsKey) }
    }
    @Published private(set) var speakerOutputSettings = SpeakerOutputSettings.load()
    @Published private(set) var speakerOutputStatus: String?
    private var showVoiceDetector = StandaloneWake()
    private var spotifyVolumeDetector = SpotifyVolumePhrase()
    private var dotPhraseDetectors = CommandPhraseDetectors<DotCallCommand.Action>()
    private var dotTasks: [UUID: Task<DotCallCommand.Result, Never>] = [:]
    private var dotTail: Task<DotCallCommand.Result, Never>?
    private var dotPatterns: [DotCallCommand.Action: [PhrasePattern]] {
        [.start: patterns(for: .callDotPhrase), .hangUp: patterns(for: .hangUpDotPhrase)]
    }
    private func runDot(_ action: DotCallCommand.Action, valid: @escaping () -> Bool = { true }) async -> DotCallCommand.Result {
        let previous = dotTail
        let token = UUID()
        let operation = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !self.quitting, !Task.isCancelled else { return DotCallCommand.Result(status: "unavailable", state: .unknown) }
            return await DotCallCommand.perform(action, valid: valid)
        }
        dotTasks[token] = operation; dotTail = operation
        let result = await operation.value
        dotTasks[token] = nil
        if dotTasks.isEmpty { dotTail = nil }
        return result
    }
    private func requestDot(_ action: DotCallCommand.Action, receipt id: UUID) {
        Task { @MainActor [weak self] in
            guard let self, !self.quitting, self.repetitions.shouldRun(id) else { self?.finishCommand(id, .superseded); return }
            let result = await self.runDot(action)
            let phase: SpokenCommandJournal.Phase = result.confirmed ? .confirmed : (result.submitted ? .submitted : (result.beforeDispatch ? .failedBeforeDispatch : .unknown))
            self.finishCommand(id, phase, detail: result.message)
            Diagnostics.shared.record("dot.command.completed", info: ["action": action.rawValue, "status": result.status, "state": result.state.rawValue])
            if (result.status == "confirmed" || result.submitted), self.repetitions.isFirst(id) {
                self.feedback.play(action == .start ? PhraseSlot.callDotPhrase.cue : PhraseSlot.hangUpDotPhrase.cue)
            }
        }
    }
    private var showVoiceTask: Task<Void, Never>?
    private var speakerOutputDetector = StandaloneWake(speakerRoute: true)
    private var speakerQueue = SpeakerOutputQueue()
    private var speakerOutputTask: Task<Void, Never>?
    @Published private(set) var switchingSpeakerOutput = false
    // App prefixes are handled by the overlapping-prefix suppression below. All other
    // commands retain ownership even when they are contained inside a speaker phrase.
    var speakerOutputConflictingPhrases: [PhrasePattern] {
        PhraseSlot.allCases.filter { $0 != .switchAppPhrase && $0 != .openAppPhrase }.flatMap { configuredPatterns[$0] ?? [] }
    }
    @Published private(set) var speakerOutputConflict: String?
    private var activeSpeakerCommands: [(pattern: PhrasePattern, output: String)] = []
    private var configuredSpeakerCommands: [(pattern: PhrasePattern, output: String)] = []
    private var activeSpeakerPrefixes: [PhrasePattern] = []
    // Recognition checks each audio frame. Compile speaker combinations only when settings
    // change, not on that hot path, and share the result with highlighting and cancellation.
    private func rebuildSpeakerCommands() {
        let otherPatterns = speakerOutputConflictingPhrases
        if let upgraded = speakerOutputSettings.upgradingDefaultPrefixes(in: .standard, avoiding: otherPatterns) {
            speakerOutputSettings = upgraded
        }
        let effective = similarPhrases ? speakerOutputSettings.omittingConflictingBuiltIns(avoiding: otherPatterns) : speakerOutputSettings
        let conflict = effective.conflictingPhrase(with: otherPatterns, alternateSpellings: similarPhrases)
        let enabledConflict = commandAvailability.isEnabled(.speakerOutput) ? conflict : nil
        if speakerOutputConflict != enabledConflict { speakerOutputConflict = enabledConflict }
        configuredSpeakerCommands = conflict == nil ? effective.commands(alternateSpellings: similarPhrases) : []
        activeSpeakerCommands = commandAvailability.isEnabled(.speakerOutput) ? configuredSpeakerCommands : []
        let appPrefixes = patterns(for: .switchAppPhrase) + patterns(for: .openAppPhrase)
        // Preserve explicitly configured app prefixes even when the speaker editor uses the
        // same wording; only the complete speaker request owns that ambiguous phrase. — GPT-6.1 Sol
        activeSpeakerPrefixes = activeSpeakerCommands.isEmpty ? [] : effective.commandPrefixes(alternateSpellings: similarPhrases).filter { speaker in
            let words = PhraseMatcher.words(speaker.text)
            return !appPrefixes.contains { app in app.matches(in: words).contains { $0.start == 0 && $0.end == words.count } }
        }
    }
    func saveSpeakerOutputSettings(_ settings: SpeakerOutputSettings) -> Bool {
        let settings = settings.cleaned()
        let otherPatterns = speakerOutputConflictingPhrases
        let effective = settings.omittingConflictingBuiltIns(avoiding: otherPatterns)
        guard effective.issue == nil, effective.conflictingPhrase(with: otherPatterns) == nil else { return false }
        speakerOutputSettings = settings
        settings.save()
        updatePhrases()
        return true
    }
    let desktopCommands = DesktopCommands()
    func appSpellingChoices() async -> [AppCandidate] { await desktopCommands.spellingChoices() }
    private var zoomPhraseDetectors = CommandPhraseDetectors<ZoomDirection>()
    // Both music phrases are one hardware action. Sharing the detector prevents a revised
    // "Play music" -> "Pause music" hypothesis from sending the same toggle twice.
    private var musicPhraseDetector = StandaloneWake()
    private var musicPatterns: [(slot: PhraseSlot, pattern: PhrasePattern)] {
        [PhraseSlot.pauseMusicPhrase, .playMusicPhrase].flatMap { slot in patterns(for: slot).map { (slot, $0) } }
    }
    private var appCommandDetector = AppCommandDetector()
    private var desktopTask: Task<Void, Never>?
    private var pendingAppCommands: [(AppCommandCandidate, UUID)] = []
    private var desktopCommandGeneration = UUID()
    @Published private(set) var desktopCommandStatus: String? {
        didSet { desktopStatusRequiresInactiveVoice = false }
    }
    private var desktopStatusRequiresInactiveVoice = false
    private var observedVoicePresence: VoiceCallPresence = .unknown
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
        didSet {
            UserDefaults.standard.set(phraseDictionaries, forKey: "phraseDictionaries"); updatePhrases()
            let keys = [NotificationReplyCore.Commands.replySpellingKey, NotificationReplyCore.Commands.endReplySpellingKey]
            if keys.contains(where: { oldValue[$0] != phraseDictionaries[$0] }) { notificationReplies.interrupted("settings-changed") }
        }
    }
    private(set) var matchingDictionaries = PhraseDictionaries(savedByTrigger:
        UserDefaults.standard.dictionary(forKey: "phraseDictionaries") as? [String: [String]] ?? [:])
    func spellingConflict(_ entries: [String], for slot: PhraseSlot, phrase: String) -> String? {
        for other in PhraseSlot.allCases where other.action != slot.action {
            for text in phraseConfiguration.phrases(for: other) {
                let pattern = PhrasePattern(slot: other, text: text, similar: true, dictionaries: matchingDictionaries)
                if let conflict = entries.first(where: { pattern.kind(for: $0) != nil }) {
                    return "“" + conflict + "” already belongs to " + other.action.settingsTitle + "."
                }
            }
        }
        if let conflict = entries.first(where: { value in configuredSpeakerCommands.contains { $0.pattern.kind(for: value) != nil } }) {
            return "“" + conflict + "” already belongs to Switch speakers."
        }
        return nil
    }
    // Move explicitly entered alternatives with a renamed custom trigger. Stock dictionaries
    // keep their historical slot key so restoring the default recovers its own entries.
    func renamePhrase(_ slot: PhraseSlot, id: UUID?, old: String, new: String) {
        let draftKey = slot.rawValue + ":draft:" + (id?.uuidString ?? "main")
        // Slash entry keeps its first component in the edited row on commit.
        let oldTrigger = PhraseList.pieces(old).first ?? "", newTrigger = PhraseList.pieces(new).first ?? ""
        let oldKey = PhraseList.key(oldTrigger).isEmpty ? draftKey : slot.spellingKey(for: oldTrigger)
        let newKey = PhraseList.key(newTrigger).isEmpty ? draftKey : slot.spellingKey(for: newTrigger)
        if !slot.isDefault(oldTrigger), !slot.isDefault(newTrigger), oldKey != newKey, let entries = phraseDictionaries[oldKey] {
            var updated = phraseDictionaries
            if !otherRowUses(slot, text: oldTrigger, excluding: id) { updated[oldKey] = nil }
            if let existing = updated[newKey] {
                var seen = Set(existing.map(PhraseList.key))
                updated[newKey] = existing + entries.filter { seen.insert(PhraseList.key($0)).inserted }
            } else { updated[newKey] = entries }
            phraseDictionaries = updated
        }
        if let id { setPhraseRow(slot, id: id, text: new) }
        else { self[keyPath: phraseKeyPath(for: slot)] = new }
    }
    private func otherRowUses(_ slot: PhraseSlot, text: String, excluding id: UUID?) -> Bool {
        let key = PhraseList.key(text)
        guard !key.isEmpty else { return false }
        if id != nil && PhraseList.key(self[keyPath: phraseKeyPath(for: slot)]) == key { return true }
        return phraseAliases[slot]?.contains { $0.id != id && PhraseList.key($0.text) == key } == true
    }
    private var compiledPatterns: [PhraseSlot: [PhrasePattern]] = [:]
    private var configuredPatterns: [PhraseSlot: [PhrasePattern]] = [:]
    func patterns(for slot: PhraseSlot) -> [PhrasePattern] { compiledPatterns[slot] ?? [] }
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
        if let old = phraseAliases[slot]?[index].text, !slot.isDefault(old), !otherRowUses(slot, text: old, excluding: id) {
            let key = PhraseList.key(old).isEmpty ? slot.rawValue + ":draft:" + id.uuidString : slot.spellingKey(for: old)
            if phraseDictionaries[key] != nil { phraseDictionaries[key] = nil }
        }
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
        case .rewindVideoPhrase: return \.rewindVideoPhrase
        case .rewindFivePhrase: return \.rewindFivePhrase
        case .rewindTenPhrase: return \.rewindTenPhrase
        case .playVideoPhrase: return \.playVideoPhrase
        case .pauseMusicPhrase: return \.pauseMusicPhrase
        case .playMusicPhrase: return \.playMusicPhrase
        case .spotifyVolumePhrase: return \.spotifyVolumePhrase
        case .callDotPhrase: return \.callDotPhrase
        case .hangUpDotPhrase: return \.hangUpDotPhrase
        case .switchAppPhrase: return \.switchAppPhrase
        case .openAppPhrase: return \.openAppPhrase
        case .showVoicePhrase: return \.showVoicePhrase
        case .zoomInPhrase: return \.zoomInPhrase
        case .zoomOutPhrase: return \.zoomOutPhrase
        }
    }
    var controlPhrases: [String] { VoiceAudioAction.allCases.flatMap { $0.slots.flatMap { patterns(for: $0).map(\.text) } } }
    @Published var similarPhrases = UserDefaults.standard.object(forKey: "similarPhrases") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(similarPhrases, forKey: "similarPhrases"); updatePhrases()
            if oldValue != similarPhrases { notificationReplies.interrupted("settings-changed") }
        }
    }
    @Published private(set) var error: String?
    // Shortcut activation is independent of microphone/model preparation, which
    // clears ordinary errors. Keep the restart notice until an explicit refresh.
    @Published private(set) var shortcutNotice: String?
    @Published private(set) var lastEvent = ""
    @Published private(set) var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var micPermissionDenied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
    @Published private(set) var accessibilityAllowed = AXIsProcessTrusted()
    let voice: NativeVoice
    // Ethan calls this conversation "Chat" in the UI. It is still the same
    // native Codex Voice session; both menu and window use one action/state.
    var chatActionTitle: String {
        // Ethan wants the button to feel familiar: use the configured wake/end words. — GPT-6.1 Sol
        status == "Connecting" ? "Cancel" : (voice.connected ? spokenEndPhrase : spokenWakePhrase)
    }
    func toggleChat() {
        if voice.connected || status == "Connecting" { manualMute() } else { manualTalk() }
    }
    private let desktopSession = DesktopSessionMonitor()
    private let feedback = FeedbackSounds()
    private let listener = SpeechListener()
    let notificationReplies = NotificationReplyCoordinator()
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
    private(set) var quitting = false
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
    init(enableSpotifyControl: Bool = true, voice: NativeVoice? = nil) {
        self.voice = voice ?? NativeVoice(diagnostics: .shared)
        spotifyVolume = SpotifyVoiceVolume(monitor: voiceCalls)
        repetitions.onProgress = { [weak self] progress in
            guard let self else { return }
            if let outcome = progress.outcome, let phase = SpokenCommandJournal.Phase(rawValue: outcome.rawValue) {
                self.finishCommand(progress.id, phase, detail: self.repetitionDetails[progress.id]?.1, repetition: progress)
            } else {
                _ = self.receipts.progress(progress.id, requested: progress.requested, completed: progress.completed, phase: .attempted)
            }
        }
        PhraseList.seedDefaults(in: .standard) { [speakerOutputSettings] pattern in
            speakerOutputSettings.conflictingPhrase(with: [pattern]) != nil
        }
        phraseAliases = PhraseList.decode(UserDefaults.standard.object(forKey: PhraseList.defaultsKey)).mapValues { $0.map { PhraseRow($0) } }
        Diagnostics.shared.record("app.started", info: ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
        Task { [weak self] in
            let previous = await Task.detached(priority: .utility) { Diagnostics.shared.latestCommandSummary() }.value
            if let self, self.latestCommandID == nil { self.lastCommandMessage = previous }
        }
        desktopSession.onChange = { [weak self] state in
            guard let self else { return }
            // A lock or session switch cannot carry a queued wake into the
            // next desktop. Preserve any late call and require a fresh phrase.
            self.repetitions.cancelPending(); self.endPhrase.reset(); self.standaloneWake.reset(); self.resetAudioPhrases()
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
            self?.repetitions.endUtterance()
            self?.finalValueFrame = true
            guard let self, var capture = self.startupSpeech else { return }
            let complete = capture.markUtteranceEnded()
            self.startupSpeech = capture
            if complete { self.finishStartupSpeech(preserveRequested: true, boundary: .utterance) }
        }
        listener.onWaiting = { [weak self] in self?.repetitions.cancelPending(); self?.archive.boundary(); self?.standaloneWake.reset(); self?.resetAudioPhrases(); self?.detectionRunning = false }
        listener.onAudioActivity = { [weak self] level, seconds, audioTime in
            self?.latestAudioTime = audioTime
            self?.standaloneWake.audio(level: level, seconds: seconds, at: audioTime)
            for action in VoiceAudioAction.allCases { self?.audioPhraseDetectors[action, default: StandaloneWake()].audio(level: level, seconds: seconds, at: audioTime) }
            self?.videoPhraseDetectors.audio(level: level, seconds: seconds, at: audioTime)
            self?.zoomPhraseDetectors.audio(level: level, seconds: seconds, at: audioTime)
            self?.musicPhraseDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.showVoiceDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.spotifyVolumeDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.dotPhraseDetectors.audio(level: level, seconds: seconds, at: audioTime)
            self?.speakerOutputDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.appCommandDetector.audio(level: level, seconds: seconds, at: audioTime)
            self?.endPhrase.audio(level: level, seconds: seconds, at: audioTime)
            // Raw speech can resume before its first text hypothesis arrives.
            if level >= 0.02 { self?.startupSpeech?.speechResumed() }
            self?.startupSpeech?.audioProcessed(seconds: seconds)
        }
        listener.onFrame = { [weak self] utteranceEnded in
            self?.speechRecovery.processed(at: Diagnostics.now)
            // Apple finals close repeat/value bookkeeping, without changing its separate startup-capture boundary. — GPT-6.1 Sol
            if utteranceEnded, self?.speechModel == .appleLocal {
                self?.repetitions.endUtterance()
                self?.finalValueFrame = true
            }
            // After this frame's text; before a new wake can replace the capture.
            if let boundary = self?.startupSpeech?.boundaryReached {
                self?.finishStartupSpeech(preserveRequested: true, boundary: boundary)
            }
            self?.checkStandaloneWake(utteranceEnded: utteranceEnded)
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
        notificationReplies.currentReadiness = { [weak self] in
            guard let self, !self.quitting else { return .desktopUnavailable }
            guard self.enabled else { return .listeningOff }
            guard self.detectionRunning, !self.checkingSpeech, !self.changingModel else { return .listenerUnavailable }
            guard DesktopSessionState.current == .interactive else { return .desktopUnavailable }
            if self.voiceStartContext != nil || self.observedVoicePresence == .active { return .voiceActive }
            guard self.observedVoicePresence == .inactive else { return .voiceUnknown }
            guard VoiceBridge.currentApplication() != nil else { return .codexUnavailable }
            return .ready
        }
        // Notification controls share the existing spelling store without becoming
        // ambient commands. Each admitted attempt freezes these exact forms. — GPT-6.1 Sol
        notificationReplies.commandForms = { [weak self] in
            guard let self else { return .init() }
            return .init(replySpellings: self.phraseDictionaries[NotificationReplyCore.Commands.replySpellingKey],
                         endReplySpellings: self.phraseDictionaries[NotificationReplyCore.Commands.endReplySpellingKey],
                         alternateSpellings: self.similarPhrases)
        }
        notificationReplies.resetRecognition = { [weak self] in
            guard let self else { return }
            self.repetitions.cancelPending(); self.endPhrase.reset(); self.standaloneWake.reset(); self.resetAudioPhrases()
            self.listener.discardPendingRecognition()
        }
        notificationReplies.finalizeRecognition = { [weak self] time, ending in self?.listener.finalizeReplyRecognition(through: time, ending: ending) }
        notificationReplies.showPresentation = { [weak self] in self?.notificationHUD.show($0) }
        notificationHUD.onDismiss = { [weak self] in self?.notificationReplies.dismiss(event: $0) }
        notificationReplies.acceptedReply = { [weak self] in self?.feedback.play(.notificationReplyAccepted) }
        notificationReplies.outcome = { [weak self] event, phase, reason, first in
            guard let self else { return }
            if first { self.latestCommandID = event }
            let summary = "Notification reply · " + NotificationReplyHUDContent.statusTitle(phase, reason: reason)
            if self.latestCommandID == event {
                self.lastCommandMessage = summary
                self.lastCommandDetail = nil
            }
            Diagnostics.shared.record("command.history", info: ["receipt": event.uuidString, "command": "Notification reply", "result": phase.rawValue, "summary": summary])
        }
        listener.needsReplyRecognition = { [weak self] in self?.notificationReplies.interceptsSpeech ?? false }
        listener.onReplyRecognition = { [weak self] in self?.notificationReplies.recognized($0) }
        listener.onReplyProgress = { [weak self] in self?.notificationReplies.processed(through: $0) }
        listener.onReplyInterruption = { [weak self] in self?.notificationReplies.interrupted($0) }
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
        appCommandDetector.usesEditableShortForms = UserDefaults.standard.bool(forKey: PhraseList.editableShortFormsKey)
        updatePhrases()
        if enableSpotifyControl {
            Task { await CodexVoiceSpeed.shared.recoverOnLaunch() }
            voiceCalls.onSessionStarted = { date in
                Task {
                    do { try await CodexVoiceSpeed.shared.observedSessionStart(date, executable: CodexVoiceSpeed.executable()) }
                    catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
                }
            }
            voiceCalls.onChange = { [weak self] state in
                guard let self, !self.quitting else { return }
                self.observedVoicePresence = state.presence
                if state.presence == .active, self.desktopStatusRequiresInactiveVoice {
                    if self.lastCommandDetail == ShowVoiceCommand.Outcome.inactive.message { self.lastCommandDetail = nil }
                    self.desktopCommandStatus = nil
                }
                self.receiptSession = state.presence == .active ? state.callIdentifier?.lowercased() : nil
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
        // Receipt ownership needs the same native call identity even with feedback and ducking off.
        if !quitting { voiceCalls.start() }
    }
    // Spoken or button video control. Sent once; Agent Flow Bridge picks the browser video and
    // answers with the outcome. Nothing here changes Voice, the microphone or the busy state.
    func requestVideo(_ requested: VideoCommand, receipt: UUID? = nil) {
        guard !quitting else { return }
        let command = requested.resolved(rewindSeconds: rewindVideoSeconds)
        Diagnostics.shared.record("video.command.requested", info: ["action": command.rawValue,
            "bridge": videoBridge.availability.isAvailable ? "available" : "unavailable"])
        videoBridge.sendIfAvailable(command, seconds: rewindVideoSeconds, shouldSend: { [weak self] in
            guard let self, !self.quitting else { return false }
            guard let receipt, self.repetitions.root(for: receipt) != nil else { return true }
            return self.repetitions.shouldRun(receipt)
        }) { [weak self] outcome in
            let phase: SpokenCommandJournal.Phase
            switch outcome {
            case _ where outcome.confirms(command): phase = .confirmed
            case .rejected, .unavailable: phase = .failedBeforeDispatch
            default: phase = .unknown
            }
            self?.finishCommand(receipt, phase, message: outcome.summary(for: command))
            Diagnostics.shared.record("video.command.result", info: ["action": command.rawValue, "outcome": outcome.diagnostic])
            guard let self, !self.quitting else { return }
            self.lastEvent = outcome.summary(for: command)
            self.videoCommandStatus = outcome.summary(for: command)
            if outcome.confirms(command) { if self.repetitions.isFirst(receipt ?? UUID()) { self.feedback.play(requested.slot.cue) } }
        }
    }
    func refreshVideoBridge() { if !quitting { videoBridge.refresh() } }
    // One shortcut pair to the frontmost app. Reports dispatch, not whether the app zoomed.
    private func requestZoom(_ direction: ZoomDirection, range: Range<Int>, receipt: UUID? = nil) {
        guard !quitting else { finishCommand(receipt, .superseded); return }
        guard let id = receipt ?? reserveSpeech(direction.slot.rawValue, range: range,
            repeatAction: { [weak self] id in self?.requestZoom(direction, range: range, receipt: id) }) else { return }
        let result = desktopCommands.zoom(direction) { if repetitions.isFirst(id) { feedback.play(direction.slot.cue) } } // Only once the keys are sent.
        finishCommand(id, result.diagnostic == "sent" ? .submitted : .failedBeforeDispatch, detail: result.message)
        Diagnostics.shared.record("desktop.zoom", info: ["direction": direction.rawValue, "outcome": result.diagnostic])
        if let message = result.message { desktopCommandStatus = message }
    }
    private func requestSpeakerOutput(_ output: String, range: Range<Int>, receipt: UUID? = nil) {
        guard !quitting else { finishCommand(receipt, .superseded); return }
        guard let id = receipt ?? reserveSpeech("speakerOutput", target: output.lowercased(), range: range,
            repeatAction: { [weak self] id in self?.requestSpeakerOutput(output, range: range, receipt: id) }) else { return }
        for superseded in speakerQueue.enqueue(output, receipt: id) { finishCommand(superseded, .superseded) }
        guard speakerOutputTask == nil else { return }
        speakerOutputStatus = "Switching speakers…"
        switchingSpeakerOutput = true
        speakerOutputTask = Task {
            while let request = speakerQueue.active {
                let admitted = request.receipts.filter { repetitions.root(for: $0) == nil || repetitions.shouldRun($0) }
                guard !admitted.isEmpty else {
                    for receipt in speakerQueue.finished() { finishCommand(receipt, .superseded) }
                    continue
                }
                let started = Diagnostics.now
                let first = request.receipts[0].uuidString
                // Device names can be personal. The saved destination UUID identifies the output
                // across the request and completion without copying its name into diagnostics.
                let destination = speakerOutputSettings.destinations.first { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) == request.output }?.id.uuidString ?? "unknown"
                Diagnostics.shared.record("speaker.output.requested", info: ["receipt": first, "destination": destination])
                let outcome = await Task.detached { SpeakerOutput.switchTo(request.output) }.value
                for receipt in speakerQueue.finished() { finishCommand(receipt, outcome.phase, detail: outcome.message) }
                Diagnostics.shared.record("speaker.output.completed", numbers: ["elapsed_ms": (Diagnostics.now - started) * 1000],
                                          info: ["verified": String(outcome.verified), "receipt": first, "destination": destination])
                if !quitting {
                    speakerOutputStatus = outcome.message; lastEvent = outcome.message
                    if outcome.verified, request.receipts.contains(where: { repetitions.isFirst($0) }) { feedback.play(control: "speakerOutput", default: nil) }
                }
            }
            speakerOutputTask = nil
            switchingSpeakerOutput = false
        }
    }
    private func requestMusic(_ slot: PhraseSlot, receipt: UUID? = nil) {
        guard !quitting else { finishCommand(receipt, .superseded); return }
        guard let id = receipt ?? reserveSpeech(slot.rawValue, range: musicPhraseDetector.acceptedRange,
            repeatAction: { [weak self] id in self?.requestMusic(slot, receipt: id) }) else { return }
        let result = desktopCommands.toggleCurrentMedia { if repetitions.isFirst(id) { feedback.play(slot.cue) } }
        finishCommand(id, result.diagnostic == "sent" ? .submitted : .failedBeforeDispatch, detail: result.message)
        Diagnostics.shared.record("media.play_pause", info: ["phrase_slot": slot.rawValue, "outcome": result.diagnostic])
        if let message = result.message { lastEvent = message; desktopCommandStatus = message }
    }
    // App commands run one after another in spoken order; each heard occurrence acts once.
    private func performAppCommands(_ candidates: [AppCommandCandidate], receipt: UUID? = nil) {
        for candidate in candidates {
            let target = appNameSpellings.commandTarget(candidate.name)
            guard let id = receipt ?? reserveSpeech("app", target: target, range: candidate.wordRange,
                repeatAction: { [weak self] id in
                    guard let self else { return }
                    let root = self.repetitions.root(for: id) ?? id
                    self.performAppCommands([self.repeatAppTargets[root] ?? candidate], receipt: id)
                }) else { continue }
            guard pendingAppCommands.count < 8 else { finishCommand(id, .superseded); continue }
            pendingAppCommands.append((candidate, id))
        }
        guard desktopTask == nil else { return }
        let token = desktopCommandGeneration
        desktopTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.desktopCommandGeneration == token,
                  let (candidate, id) = self.pendingAppCommands.first {
                self.pendingAppCommands.removeFirst()
                let prepared = await self.desktopCommands.repetitionCandidate(candidate, spellings: self.appNameSpellings)
                if prepared.name != candidate.name, let range = prepared.wordRange, self.repetitions.isFirst(id) {
                    guard self.repetitions.setArgumentRange(range, for: id),
                          let root = self.repetitions.root(for: id),
                          self.receipts.retarget(root, to: self.appNameSpellings.commandTarget(prepared.name)) else {
                        self.finishCommand(id, .failedBeforeDispatch); continue
                    }
                }
                if let root = self.repetitions.root(for: id) { self.repeatAppTargets[root] = prepared }
                let candidate = prepared
                guard self.repetitions.root(for: id) == nil || self.repetitions.shouldRun(id) else {
                    self.finishCommand(id, .superseded); continue
                }
                let dispatchedAt = Diagnostics.now
                // The cue marks an accepted switch/open request, before front-app confirmation.
                // Ordinary speech, unresolved names and cancelled work stay silent.
                let result = await self.desktopCommands.perform(candidate, spellings: self.appNameSpellings) {
                    if !self.quitting, self.desktopCommandGeneration == token, self.repetitions.isFirst(id) { self.feedback.play(candidate.kind.slot.cue) }
                }
                guard !Task.isCancelled, self.desktopCommandGeneration == token else { self.finishCommand(id, .unknown); return }
                let phase: SpokenCommandJournal.Phase
                switch result.diagnostic {
                case "frontmost": phase = .confirmed
                case "dispatched": phase = .submitted
                case "ignored", "not-resolved", "verify-failed": phase = .failedBeforeDispatch
                default: phase = .unknown
                }
                self.finishCommand(id, phase, detail: result.message)
                Diagnostics.shared.record("desktop.app", numbers: ["duration_ms": (Diagnostics.now - dispatchedAt) * 1000],
                    info: ["kind": candidate.kind.rawValue, "bare": String(candidate.bare), "outcome": result.diagnostic])
                if let message = result.message { self.desktopCommandStatus = message }
            }
            if self?.desktopCommandGeneration == token { self?.desktopTask = nil }
        }
    }
    private func cancelAppCommands() {
        for (_, id) in pendingAppCommands { finishCommand(id, .failedBeforeDispatch) }
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
        repetitions.boundary()
        spotifyVolumeRequests.removeAll()
        finalValueFrame = false
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action] = StandaloneWake() }
        videoPhraseDetectors.reset()
        zoomPhraseDetectors.reset()
        musicPhraseDetector.reset()
        showVoiceDetector.reset()
        spotifyVolumeDetector.reset()
        dotPhraseDetectors.reset()
        speakerOutputDetector.reset()
        appCommandDetector.reset()
    }
    private func updatePhrases(cancelPendingApps: Bool = true) {
        rebuildPhraseConfiguration()
        matchingDictionaries = PhraseDictionaries(savedByTrigger: phraseDictionaries, active: phraseConfiguration)
        // Disabled commands keep ownership of their saved phrases; only the derived recognition/highlight patterns disappear. — GPT-6.1 Sol
        configuredPatterns = Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map { slot in
            (slot, phraseConfiguration.phrases(for: slot).map {
                PhrasePattern(slot: slot, text: $0, similar: similarPhrases, dictionaries: matchingDictionaries)
            })
        })
        compiledPatterns = configuredPatterns.filter { commandAvailability.isEnabled($0.key) }
        rebuildSpeakerCommands()
        if cancelPendingApps { cancelAppCommands() }
        listener.contextualPhrases = PhraseSlot.allCases.flatMap { patterns(for: $0).map(\.text) } + activeSpeakerCommands.map { $0.pattern.text }
            + [NotificationReplyCore.Commands.replyPhrase, NotificationReplyCore.Commands.endReplyPhrase]
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
    func previewSound(_ cue: FeedbackSounds.Cue) { feedback.sample(cue) }
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
    func toggle(preservingCall: Bool = false) {
        if listeningToggleOn {
            manualListeningEnabled = false
            policy.pause(); turnOff(preservingCall: preservingCall)
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
            guard (!commandAvailability.isEnabled(.wakePhrase) || !phraseConfiguration.phrases(for: .wakePhrase).isEmpty),
                  (!commandAvailability.isEnabled(.sleepPhrase) || !phraseConfiguration.phrases(for: .sleepPhrase).isEmpty) else {
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
    func turnOff(preservingCall: Bool = false) {
        let previous = voiceTask
        stopLocal(preservingCall: preservingCall); busy = true; error = nil
        status = "Off"; detail = "Start listening for \(spokenWakePhrase)."; lastEvent = "Listening stopped"
        let token = generation
        Task {
            if !preservingCall { await voice.stop() }
            await previous?.value
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
    func performDotShortcut(_ action: DotCallCommand.Action, playFeedback: Bool = true, valid: @escaping () -> Bool = { true }) async -> DotCallCommand.Result {
        guard !quitting else { return .init(status: "unavailable", state: .unknown) }
        let result = await runDot(action, valid: valid)
        if playFeedback, result.confirmed || result.submitted, result.status != "unchanged" {
            feedback.play(action == .start ? PhraseSlot.callDotPhrase.cue : PhraseSlot.hangUpDotPhrase.cue)
        }
        return result
    }

    func cancelRemoteStart(request: UUID) throws {
        guard !quitting, busy, let context = voiceStartContext, let task = voiceTask,
              context.matches(request: request, generation: generation),
              !context.remoteCancelled, !task.isCancelled else {
            throw HControlFailure.conflict("This Start request is no longer opening.")
        }
        // The native shortcut returns no session identity. After dispatch begins, only an explicitly
        // selected current call may receive End. A reused call belongs to its existing owner.
        guard context.sentAt == nil, !context.resolvedCall else {
            throw HControlFailure.unavailable("Native Voice has taken over this opening. After Start finishes, read voice.identity to select a call for End.")
        }
        context.withdrawBeforeNativeStart()
        task.cancel()
    }

    func performShortcut(_ action: HChatShortcutAction, playFeedback: Bool = true, remoteGuard: HControlCall? = nil, remoteStartRequest: UUID? = nil, beforeRemoteDispatch: (() throws -> Void)? = nil) async throws -> String {
        if action == .callDot || action == .hangUpDot {
            guard !quitting else { throw CancellationError() }
            let result = await performDotShortcut(action == .callDot ? .start : .hangUp, playFeedback: playFeedback)
            guard result.confirmed || result.submitted else { throw BridgeError.message(result.message) }
            return result.message
        }
        if action == .status {
            let snapshot = await voice.readStatus()
            guard snapshot.accessibilityAllowed else {
                throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.")
            }
            if let microphone = snapshot.microphone {
                return microphone == .muted ? "Chat microphone is muted." : "Chat is listening."
            }
            if snapshot.voiceConnectionEvidence != nil { return "Chat is on. Microphone status is unknown." }
            if snapshot.endControlAvailable { return "Chat status is unknown." }
            if snapshot.applicationAbsent || (snapshot.controlsComplete && !snapshot.inputRunning) { return "Chat is off." }
            return "Chat status is unknown."
        }
        guard !quitting, !busy || action == .end else {
            throw BridgeError.message("Hello Chat is busy. Try again when the current action finishes.")
        }
        let token = generation
        var shortcutOpening: VoiceStartContext?
        error = nil
        Diagnostics.shared.record("shortcut.requested", info: ["action": action.rawValue])
        switch action {
        case .start:
            let context = VoiceStartContext(remoteOwner: remoteStartRequest.map { ($0, token) })
            context.beforeRemoteDispatch = beforeRemoteDispatch
            shortcutOpening = context
            if enabled && detectionRunning {
                beginVoice(trigger: "Voice started with shortcut", opening: context)
            } else {
                busy = true
                if playFeedback { feedback.play(PhraseSlot.wakePhrase.cue) }
                voiceStartContext = context
                voiceTask = Task {
                    await openVoice(trigger: "Voice started with shortcut", context: context, requiresListening: false)
                }
            }
        case .end:
            manualMute(force: true)
        case .ultrafast:
            busy = true
            voiceTask = Task {
                defer { if generation == token { busy = false; voiceTask = nil } }
                let result: CodexChatSpeed.Result
                if let target = remoteGuard {
                    do { try target.check() } catch { self.error = error.localizedDescription; return }
                    result = await CodexChatSpeed.currentVoice(resolve: {
                        do { try target.check(); return .init(status: .active, call: target.call) }
                        catch { return .init(status: .changed) }
                    })
                } else { result = await CodexChatSpeed.currentVoice() }
                guard generation == token, !quitting else { return }
                if result.succeeded { lastEvent = result.message }
                else { error = result.message }
            }
        case .muteMicrophone, .unmuteMicrophone, .silenceSpeakers, .unsilenceSpeakers:
            let audio: VoiceAudioAction
            switch action {
            case .muteMicrophone: audio = .muteMicrophone
            case .unmuteMicrophone: audio = .unmuteMicrophone
            case .silenceSpeakers: audio = .silenceSpeakers
            case .unsilenceSpeakers: audio = .unsilenceSpeakers
            case .start, .end, .ultrafast, .status, .callDot, .hangUpDot: preconditionFailure("Handled above")
            }
            busy = true
            voiceTask = Task {
                defer { if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() } }
                do {
                    let call = spotifyVolume.callEpoch
                    let sent = try await voice.setAudio(audio, beforeShortcut: remoteGuard.map { target in { try target.check() } }, onRecognized: { if playFeedback { self.feedback.play(.microphoneDetected) } })
                    guard generation == token else { return }
                    guard sent else { throw BridgeError.message("Open Codex, then try again.") }
                    if !audio.controlsSpeakers { spotifyVolume.microphonePhraseSent(audio.targetMuted, in: call) }
                    if playFeedback, let slot = audio.slots.first { feedback.play(slot.cue) }
                    showListening()
                    lastEvent = audio.shortcutSentMessage
                } catch {
                    guard generation == token, !(error is CancellationError) else { return }
                    self.error = error.localizedDescription
                }
            }
        case .status, .callDot, .hangUpDot: break // Read-only status and Dot returned before reserving any control work.
        }
        let completionGeneration = generation // End may supersede an opening/audio operation.
        let operation = voiceTask
        await operation?.value
        try Task.checkCancellation()
        if shortcutOpening?.remoteCancelled == true {
            throw HControlFailure.unavailable("This Start was cancelled before H Chat sent a native Voice shortcut.")
        }
        guard generation == completionGeneration, !quitting else { throw CancellationError() }
        if let error { throw BridgeError.message(error) }
        if action == .start, !voice.connected { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
        Diagnostics.shared.record("shortcut.completed", info: ["action": action.rawValue])
        // Keep actual configured wake/end phrases out of Siri's spoken result.
        switch action {
        case .start: return "Chat is on."
        case .end: return "Chat is off."
        case .muteMicrophone, .unmuteMicrophone: return VoiceAudioAction.muteMicrophone.shortcutSentMessage
        case .silenceSpeakers, .unsilenceSpeakers: return VoiceAudioAction.silenceSpeakers.shortcutSentMessage
        case .ultrafast: return "Ultrafast selected for the next turn."
        case .status: return "Chat status is unknown."
        case .callDot, .hangUpDot: preconditionFailure("Dot commands returned above")
        }
    }
    func manualMute(feedbackAlreadyPlayed: Bool = false, force: Bool = false, receipt: UUID? = nil) {
        guard enabled || voice.connected || voiceStartContext != nil || force, !quitting, !endingVoice else { finishCommand(receipt, .unknown); return }
        cancelStartupSpeech()
        if busy, voiceStartContext != nil {
            let previous = voiceTask
            previous?.cancel()
            let token = UUID(); generation = token
            busy = true; endingVoice = true
            voiceTask = Task {
                defer { finishCommand(receipt, .unknown); endingVoice = false; if generation == token { busy = false; voiceTask = nil } }
                do { _ = try await voice.endIfPresent() }
                catch { if generation == token { self.error = error.localizedDescription } }
                await previous?.value
                guard generation == token, enabled || force else { return }
                showListening(); lastEvent = "Voice connection cancelled"
            }
        } else if busy {
            let previous = voiceTask
            let token = UUID(); generation = token // The cancelled audio task must not clear the End request's busy state or show a cancellation error.
            previous?.cancel()
            voiceTask = Task {
                await previous?.value
                guard generation == token, !quitting else { finishCommand(receipt, .failedBeforeDispatch); return }
                await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed, reserved: true, force: force, receipt: receipt)
            }
        } else {
            busy = true; endingVoice = true
            voiceTask = Task { await muteVoice(event: "Codex Voice ended", feedbackAlreadyPlayed: feedbackAlreadyPlayed, reserved: true, force: force, receipt: receipt) }
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
    private func beginVoice(trigger: String, wakeRange: Range<Int>? = nil, receipt: UUID? = nil, opening: VoiceStartContext? = nil) {
        guard enabled, detectionRunning, !busy, !quitting else { finishCommand(receipt, .failedBeforeDispatch); return }
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
        let context = opening ?? VoiceStartContext()
        voiceStartContext = context
        startupSpeech = StartupSpeechBuffer(id: context.id, text: transcript, wakeRange: wakeRange, patterns: patterns(for: .wakePhrase), repeatCounts: CommandRepetition.enabled("wakePhrase"))
        context.prepareNewCall = { [weak self, weak context] in
            guard let self, let context, self.voiceStartContext === context,
                  var capture = self.startupSpeech, capture.id == context.id else { return }
            capture.markPublished(); self.startupSpeech = capture
            self.lastStartupSpeechID = context.id
            let saved = await self.startupSpeechFile.begin(id: context.id, text: capture.text, truncated: capture.truncated)
            if !saved, self.startupSpeech?.id == context.id { self.startupSpeech = nil }
            if saved { Diagnostics.shared.record("voice.startup_speech.started", info: ["request": context.id.uuidString]) }
        }
        voiceTask = Task { await openVoice(trigger: trigger, context: context, receipt: receipt) }
    }
    private func openVoice(trigger: String, context: VoiceStartContext, requiresListening: Bool = true, receipt: UUID? = nil) async {
        defer { finishCommand(receipt, .unknown) }
        guard enabled || !requiresListening, !quitting, !Task.isCancelled else {
            if voiceStartContext === context {
                if startupSpeech?.id == context.id { finishStartupSpeech(preserveRequested: false) }
                voiceStartContext = nil
                if !endingVoice { busy = false }
            }
            return
        }
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
            finishCommand(receipt, .confirmed)
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
    private func muteVoice(event: String, feedbackAlreadyPlayed: Bool = false, reserved: Bool = false, force: Bool = false, receipt: UUID? = nil) async {
        defer { finishCommand(receipt, .unknown) }
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
            finishCommand(receipt, .confirmed)
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
        // A rewritten transcript can have a different token layout from its timing hypothesis.
        // Never attribute its command to an unrelated word in the previous timing batch.
        receiptWordEnds = timings.map(\.word) == PhraseMatcher.words(text) ? timings.map(\.end) : []
        if saveTranscripts { archive.update(text, model: speechModel.rawValue, microphone: inputs.selectedName) }
        let changed = transcript != text
        if changed {
            transcript = text
        }
        // The same words remain visible/archived under the existing preference, but reply content cannot execute ambient commands. — GPT-6.1 Sol
        guard !notificationReplies.interceptsSpeech else { return }
        // Use the same phrase and mention rules while Agent Flow records. Its
        // microphone ownership must not pause H Chat's existing recognizer.
        standaloneWake.update(text, at: Diagnostics.now, timings: timings)
        for action in VoiceAudioAction.allCases { audioPhraseDetectors[action, default: StandaloneWake()].update(text, at: Diagnostics.now, timings: timings) }
        videoPhraseDetectors.update(text, at: Diagnostics.now, timings: timings)
        zoomPhraseDetectors.update(text, at: Diagnostics.now, timings: timings)
        musicPhraseDetector.update(text, at: Diagnostics.now, timings: timings)
        showVoiceDetector.update(text, at: Diagnostics.now, timings: timings)
        spotifyVolumeDetector.update(text, at: Diagnostics.now, timings: timings)
        dotPhraseDetectors.update(text, at: Diagnostics.now, timings: timings)
        speakerOutputDetector.update(text, at: Diagnostics.now, timings: timings)
        appCommandDetector.update(text, at: Diagnostics.now, timings: timings)
        endPhrase.update(text, at: Diagnostics.now, timings: timings)
        let repetitionText = CommandRepetition.tokens(text)
        repetitions.update(repetitionText.words, timings: timings, boundaries: repetitionText.boundaries)
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
    private func checkStandaloneWake(utteranceEnded: Bool = false) {
        guard enabled, detectionRunning, !notificationReplies.interceptsSpeech else { return }
        defer {
            if finalValueFrame { spotifyVolumeDetector.endUtterance(); finalValueFrame = false }
        }
        // Every listed phrase for a command shares its detector, occurrence count and sound.
        // A phrase listed for different commands keeps its first owner in PhraseConfiguration.
        let wakePatterns = patterns(for: .wakePhrase), endPatterns = patterns(for: .sleepPhrase)
        if let endPattern = endPatterns.first, endPhrase.poll(at: Diagnostics.now, phrase: endPattern.text, similar: endPattern.similar, rejectNegated: true, ending: true, patterns: endPatterns) {
            for action in VoiceAudioAction.allCases {
                let entries = patterns(for: action).map(\.pattern)
                if !entries.isEmpty { audioPhraseDetectors[action, default: StandaloneWake()].cancelPending(patterns: entries, endPatterns: endPatterns) }
            } // An explicit End wins over audio commands in the same transcript.
            videoPhraseDetectors.cancelPending(aliases: videoPatterns, endPatterns: endPatterns) // ...and over video commands.
            zoomPhraseDetectors.cancelPending(aliases: zoomPatterns, endPatterns: endPatterns) // ...and desktop commands.
            musicPhraseDetector.cancelPending(patterns: musicPatterns.map(\.pattern), endPatterns: endPatterns)
            showVoiceDetector.cancelPending(patterns: patterns(for: .showVoicePhrase), endPatterns: endPatterns)
            spotifyVolumeDetector.cancelPending(prefixes: patterns(for: .spotifyVolumePhrase), endPatterns: endPatterns)
            dotPhraseDetectors.cancelPending(aliases: dotPatterns, endPatterns: endPatterns)
            speakerOutputDetector.cancelPending(patterns: activeSpeakerCommands.map(\.pattern), endPatterns: endPatterns)
            appCommandDetector.consumeAll(switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase))
            cancelStartupSpeech()
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: endPatterns)
            Diagnostics.shared.record("phrase.end.detected", info: ["busy": String(busy), "voice": microphone?.rawValue ?? "unknown"])
            // Ethan's "buy chat" / Bye Chat gets its cue when recognized, even
            // while cancelling an opening or when Voice is already off. Native
            // status and errors still report the actual ending outcome separately.
            repetitions.cancelPending()
            guard let id = reserveSpeech("sleepPhrase", range: endPhrase.acceptedRange,
                repeatAction: { [weak self] id in self?.manualMute(feedbackAlreadyPlayed: true, force: true, receipt: id) }) else { return }
            endFeedback.detectedEnd()
            feedback.play(PhraseSlot.sleepPhrase.cue)
            if busy { manualMute(feedbackAlreadyPlayed: true, receipt: id) }
            else {
                voiceTask = Task { await muteVoice(event: "Heard \(spokenEndPhrase)", feedbackAlreadyPlayed: true, receipt: id) }
            }
            return
        }
        repetitions.poll()
        // Browser video commands: consumed whether or not the bridge is available, never busy-gated,
        // and never routed to beginVoice. Earlier wakes in the same transcript are consumed too.
        let videoCommands = videoPhraseDetectors.poll(at: Diagnostics.now, aliases: videoPatterns, directOnly: true,
            embeddedCommands: [.pause, .play], onDecision: { command, decision in
                Diagnostics.shared.record("video.phrase.evaluated", info: ["action": command.rawValue, "decision": decision])
            })
        let lastPlayback = videoCommands.lastIndex { $0.command.setsPlaybackState }
        for (index, accepted) in videoCommands.enumerated() {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: accepted.command.slot))
            guard let id = reserveSpeech(accepted.command.slot.rawValue, range: accepted.range,
                repeatAction: { [weak self] id in self?.requestVideo(accepted.command, receipt: id) }) else { continue }
            if VideoCommand.isSuperseded(accepted.command, at: index, lastPlayback: lastPlayback) {
                finishCommand(id, .superseded)
            } else {
                requestVideo(accepted.command, receipt: id)
            }
        }
        let music = musicPatterns
        if let first = music.first,
           musicPhraseDetector.poll(at: Diagnostics.now, phrase: first.pattern.text, similar: first.pattern.similar,
                rejectNegated: true, patterns: music.map(\.pattern), directOnly: true),
           let index = musicPhraseDetector.acceptedPatternIndex, music.indices.contains(index) {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: music.map(\.pattern))
            requestMusic(music[index].slot)
        }
        for command in dotPhraseDetectors.poll(at: Diagnostics.now, aliases: dotPatterns, directOnly: true) {
            let slot: PhraseSlot = command.command == .start ? .callDotPhrase : .hangUpDotPhrase
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: slot))
            if let id = reserveSpeech(slot.rawValue, range: command.range,
                repeatAction: { [weak self] id in self?.requestDot(command.command, receipt: id) }) {
                requestDot(command.command, receipt: id)
            }
        }
        let showPatterns = patterns(for: .showVoicePhrase)
        for command in spotifyVolumeDetector.poll(at: Diagnostics.now, prefixes: patterns(for: .spotifyVolumePhrase)) {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: [command.pattern])
            if command.revised {
                guard let request = spotifyVolumeRequests[command.id], let root = request.root else { continue }
                if command.invalid {
                    request.valid = false; repetitionDetails[root] = nil
                    repetitions.invalidateValue(root)
                    continue
                }
                _ = repetitions.reviseValue(root, range: command.range, reapply: request.value != command.volume, finishingUtterance: finalValueFrame) {
                    guard receipts.retarget(root, to: String(command.volume), revisingValue: true) else { return false }
                    request.value = command.volume
                    repetitionDetails[root] = nil
                    return true
                }
            } else {
                let request = SpotifySpokenVolume(command.volume)
                spotifyVolumeRequests[command.id] = request
                if let id = reserveSpeech(PhraseSlot.spotifyVolumePhrase.rawValue, target: String(command.volume), range: command.range,
                    onReserved: { request.root = $0 },
                    repeatAction: { [weak self] id in self?.requestSpotifyVolume(request, receipt: id) }) {
                    requestSpotifyVolume(request, receipt: id)
                }
            }
        }
        if let first = showPatterns.first,
           showVoiceDetector.poll(at: Diagnostics.now, phrase: first.text, similar: first.similar,
                                  rejectNegated: true, patterns: showPatterns, directOnly: true) {
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: showPatterns)
            if !quitting, let id = reserveSpeech("showVoicePhrase", range: showVoiceDetector.acceptedRange,
                repeatAction: { [weak self] id in self?.repeatShowVoice(receipt: id) }) {
                repeatShowVoice(receipt: id)
            }
        }
        // A full prefix + destination is required. Consume matching app prefixes too: the
        // generic "Switch" app prefix must not also open an app named after a speaker.
        let speakerCommands = activeSpeakerCommands
        speakerOutputDetector.dispatchSpeaker(at: Diagnostics.now, commands: speakerCommands,
            onDecision: { decision, _, _ in Diagnostics.shared.record("speaker.phrase.evaluated", info: ["decision": decision]) }
        ) { output, range in
            standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: speakerCommands.map(\.pattern))
            appCommandDetector.consume(overlapping: range, switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase))
            requestSpeakerOutput(output, range: range)
        }
        // The same direct-command and mention rules apply while recording the opening.
        let zooms = zoomPhraseDetectors.poll(at: Diagnostics.now, aliases: zoomPatterns, directOnly: true,
            onDecision: { command, decision in
                Diagnostics.shared.record("desktop.zoom.evaluated", info: ["command": command.rawValue, "decision": decision])
            })
        if !zooms.isEmpty {
            for accepted in zooms {
                standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: accepted.command.slot))
            }
            for accepted in zooms { requestZoom(accepted.command, range: accepted.range) }
        }
        let appCommands = appCommandDetector.poll(switchPrefixes: patterns(for: .switchAppPhrase), openPrefixes: patterns(for: .openAppPhrase),
            reserved: patterns(for: .showVoicePhrase) + activeSpeakerCommands.map(\.pattern),
            reservedSwitchPrefixes: activeSpeakerPrefixes,
            onDecision: { command, decision, evidence in
                // Counts and timing only, never words: separates a missed pause from discussion.
                var numbers = ["left_words": Double(evidence.leftWords), "name_words": Double(evidence.nameWords)]
                if let gap = evidence.gapBefore { numbers["gap_before_s"] = gap }
                if let elapsed = evidence.elapsed { numbers["pause_after_s"] = elapsed }
                Diagnostics.shared.record("desktop.app.evaluated", numbers: numbers,
                    info: ["command": command.rawValue, "decision": decision, "timing": evidence.timing])
            })
        if !appCommands.isEmpty, !quitting { performAppCommands(appCommands) }
        let actions = VoiceAudioAction.allCases.compactMap { action -> (action: VoiceAudioAction, position: Int, slot: PhraseSlot)? in
            let entries = patterns(for: action)
            guard let first = entries.first,
                  audioPhraseDetectors[action, default: StandaloneWake()].poll(at: Diagnostics.now, phrase: first.pattern.text, similar: similarPhrases, rejectNegated: true, patterns: entries.map(\.pattern), utteranceEnded: utteranceEnded),
                  let detector = audioPhraseDetectors[action], let position = detector.acceptedRange?.lowerBound,
                  let patternIndex = detector.acceptedPatternIndex, entries.indices.contains(patternIndex) else { return nil }
            return (action, position, entries[patternIndex].slot)
        }.sorted { $0.position < $1.position }
        if !actions.isEmpty {
            // Reserve synchronously, as beginVoice does. Consume busy commands
            // rather than replaying a surprise mute when an opening/End finishes.
            guard !quitting else { return }
            if busy {
                for item in actions {
                    _ = reserveSpeech(item.action.rawValue, range: audioPhraseDetectors[item.action]?.acceptedRange, discard: true,
                        repeatAction: { [weak self] id in self?.repeatAudio(item.action, receipt: id) })
                }
                return
            }
            for slot in PhraseSlot.allCases.dropFirst(2) where !slot.controlsDesktop {
                standaloneWake.cancelPending(patterns: wakePatterns, endPatterns: patterns(for: slot)) // Consume fuzzy wakes too, so Hello Chad before mute cannot undo it.
            }
            busy = true
            let token = generation
            let reservedActions = actions.compactMap { item -> (VoiceAudioAction, PhraseSlot, UUID)? in
                guard let id = reserveSpeech(item.action.rawValue, range: audioPhraseDetectors[item.action]?.acceptedRange,
                    repeatAction: { [weak self] id in self?.repeatAudio(item.action, receipt: id) }) else { return nil }
                return (item.action, item.slot, id)
            }
            voiceTask = Task {
                defer {
                    for (_, _, id) in reservedActions { finishCommand(id, .unknown) }
                    if generation == token { busy = false; voiceTask = nil; shortcutNotice = VoiceBridge.shortcutSetupMessage() }
                }
                do {
                    for (action, slot, id) in reservedActions { // A delayed transcript can contain both channels or opposite commands; apply them in spoken order.
                        Diagnostics.shared.record("voice.audio.requested", info: ["action": action.rawValue, "phrase_slot": slot.rawValue])
                        let spotifyCall = spotifyVolume.callEpoch
                        let sent = try await voice.setAudio(action, onRecognized: { self.feedback.play(.microphoneDetected) })
                        guard generation == token else { return }
                        guard sent else { finishCommand(id, .failedBeforeDispatch); continue }
                        finishCommand(id, .submitted)
                        error = nil
                        if !action.controlsSpeakers { spotifyVolume.microphonePhraseSent(action.targetMuted, in: spotifyCall) }
                        feedback.play(slot.cue) // Acknowledge dispatch; the native mute state remains unknown.
                        showListening()
                        lastEvent = action.shortcutSentMessage
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
            showHomeForDetectedPhrase()
            feedback.play(PhraseSlot.wakePhrase.cue)
            lastEvent = "Heard \(spokenWakePhrase) · finishing the current Voice action"
        } else if let id = reserveSpeech("wakePhrase", range: standaloneWake.acceptedRange,
            repeatAction: { [weak self] id in
                self?.repeatWake(receipt: id)
            }) { beginVoice(trigger: "Heard \(spokenWakePhrase)", wakeRange: standaloneWake.acceptedRange, receipt: id) }
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
        await notificationReplies.shutdown()
        showVoiceTask?.cancel()
        let pendingDot = Array(dotTasks.values)
        pendingDot.forEach { $0.cancel() }
        voiceStatusTask?.cancel(); voiceStatusTask = nil
        voiceCalls.stop()
        voicePeerMailbox.stop()
        videoBridge.stop()
        let previous = voiceTask
        voice.detachForQuit()
        stopLocal()
        await voicePeerPriority.shutdown()
        await previous?.value
        for operation in pendingDot { _ = await operation.value }
        do { try await CodexVoiceSpeed.shared.shutdown() }
        catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
        await speakerOutputTask?.value // Let the helper finish microphone recovery before exit.
        archive.flush()
        await startupSpeechFile.flush()
        await spotifyVolume.shutdown(preservingVolume: preservingSpotify)
        return true
    }
}
