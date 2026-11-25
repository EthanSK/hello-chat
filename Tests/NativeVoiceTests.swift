// Check native Voice actions with injected snapshots and observed control
// shapes. These tests never send shortcuts to a real Voice call.
import Foundation

@main enum NativeVoiceTests {
    @MainActor static func main() async throws {
        func state(_ mic: MicrophoneState? = nil, input: Bool = false, allowed: Bool = true) -> VoiceSnapshot {
            VoiceSnapshot(pid: 123, inputRunning: input || mic != nil, recorderRunning: false,
                          microphone: mic, accessibilityAllowed: allowed)
        }
        let request = UUID(), generation = UUID()
        let ownedOpening = VoiceStartContext(remoteOwner: (request, generation))
        precondition(ownedOpening.matches(request: request, generation: generation))
        precondition(!ownedOpening.matches(request: request, generation: UUID()))
        precondition(!ownedOpening.matches(request: UUID(), generation: generation))
        precondition(!VoiceStartContext().matches(request: request, generation: generation))
        for action in VoiceAudioAction.allCases {
            var sends = 0, recognitions = 0, targets = 0
            let audio = NativeVoice(transport: .init(
                snapshot: { fatalError("Explicit audio commands must not read hidden or visible controls") },
                send: { command, pid in
                    precondition(pid == 123)
                    precondition(command == (action.controlsSpeakers ? VoiceBridge.outputMuteCommand : VoiceBridge.muteCommand))
                    sends += 1
                }, activate: { _ in fatalError("Explicit audio must not activate Codex") },
                wait: { _ in fatalError("Explicit audio must not wait for confirmation") },
                audioTargetPID: { targets += 1; return 123 }))
            let first = try await audio.setAudio(action, onRecognized: { recognitions += 1 })
            let second = try await audio.setAudio(action, onRecognized: { recognitions += 1 })
            precondition(first && second && sends == 2 && targets == 2 && recognitions == 2,
                         "Each accepted phrase sends one toggle, including a repeated mute phrase")
            precondition(!audio.connected, "Dispatch alone must not claim an active call or a mute state")
            audio.detachForQuit()
            do { try await audio.setAudio(action); fatalError("Detached helper accepted audio action") }
            catch is CancellationError { }
            precondition(sends == 2 && targets == 2)
        }
        for action in VoiceAudioAction.allCases {
            var recognized = false
            let absent = NativeVoice(transport: .init(snapshot: { fatalError("No UI read") },
                send: { _, _ in fatalError("Missing Codex must not receive a key") },
                activate: { _ in fatalError("No activation") }, launch: { fatalError("No launch") },
                audioTargetPID: { nil }))
            let sent = try await absent.setAudio(action, onRecognized: { recognized = true })
            precondition(!sent && !recognized)
        }
        var guardedSends = 0, sessionChanged = false
        let guarded = NativeVoice(transport: .init(snapshot: { fatalError("Explicit audio must not inspect the microphone or speaker controls") },
            send: { _, _ in fatalError("A scoped toggle must use the guarded native dispatch") }, activate: { _ in fatalError("No activation") },
            guardedShortcut: { _, _, beforeKey in
                try beforeKey()
                guardedSends += 1
            }, audioTargetPID: { 123 }))
        func currentSession() throws {
            if sessionChanged { throw CancellationError() }
        }
        let sentToCurrentCall = try await guarded.setAudio(.silenceSpeakers, beforeShortcut: currentSession)
        precondition(sentToCurrentCall && guardedSends == 1)
        sessionChanged = true
        do { _ = try await guarded.setAudio(.unmuteMicrophone, beforeShortcut: currentSession); fatalError("Replaced call received a toggle") }
        catch is CancellationError { }
        precondition(guardedSends == 1)
        let unavailableDesktop = NativeVoice(transport: .init(snapshot: { fatalError("No UI read") },
            send: { _, _ in fatalError("Locked desktop must not receive an audio key") },
            activate: { _ in fatalError("No activation") }, startSession: { .locked },
            audioTargetPID: { fatalError("Check existing desktop guard first") }))
        do { try await unavailableDesktop.setAudio(.muteMicrophone); fatalError("Locked desktop accepted audio") }
        catch is BridgeError { }
        var wakeTime: TimeInterval = 0, wakeSent = false
        let wakeUnmute = NativeVoice(transport: .init(snapshot: {
            state(wakeSent && wakeTime >= 0.6 ? .listening : .muted)
        }, send: { _, _ in fatalError("Existing call must not start again") }, activate: { _ in fatalError("Wake unmute must not activate") },
        unmute: { _ in wakeSent = true }, now: { wakeTime }, wait: { wakeTime += $0 }))
        _ = try await wakeUnmute.start()
        try await wakeUnmute.setMicrophone(.listening)
        precondition(wakeSent && wakeTime >= 0.6 && wakeTime < 0.8, "Wake unmute observes delayed completion through the same bounded path")
        var cancellationSent = false, endRequests = 0
        var cancelWaiting: CheckedContinuation<Void, Never>?
        let cancellation = NativeVoice(transport: .init(snapshot: { state(cancellationSent ? .muted : .listening) },
            send: { _, _ in cancellationSent = true; await withCheckedContinuation { cancelWaiting = $0 } }, activate: { _ in },
            requestEnd: { endRequests += 1; return nil }, audioTargetPID: { 123 }))
        let audioTask = Task { @MainActor in
            do { try await cancellation.setAudio(.muteMicrophone); fatalError("Cancelled action must not confirm success") }
            catch is CancellationError { }
        }
        while !cancellationSent { await Task.yield() }
        audioTask.cancel(); cancelWaiting?.resume(); try await audioTask.value
        _ = try await cancellation.endIfPresent()
        precondition(endRequests == 1, "Explicit End remains available after cancelling in-flight audio")
        var failedSends = 0
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("audio-toggle-test-logs")
        let diagnosticLog = Diagnostics(directory: logDirectory)
        let failed = NativeVoice(transport: .init(snapshot: { fatalError("No UI read") },
            send: { _, _ in failedSends += 1; throw BridgeError.message("Not applied") },
            activate: { _ in fatalError("No activation") }, audioTargetPID: { 123 }), diagnostics: diagnosticLog)
        do { try await failed.setAudio(.muteMicrophone); fatalError("A rejected native shortcut must fail") }
        catch is BridgeError { }
        precondition(failedSends == 1, "No retry or AX fallback may invert a channel")
        let logged = NativeVoice(transport: .init(snapshot: { fatalError("No UI read") },
            send: { _, _ in }, activate: { _ in fatalError("No activation") }, audioTargetPID: { 123 }), diagnostics: diagnosticLog)
        try await logged.setAudio(.silenceSpeakers)
        diagnosticLog.flush()
        let events = try String(contentsOf: logDirectory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        precondition(events.contains("voice.audio.shortcut_failed") && events.contains("voice.output.shortcut_sent"))
        precondition(events.contains("unverified") && !events.contains("voice.audio.confirmed"),
                     "Logs distinguish a failed post and a sent key from confirmed audio")
        try FileManager.default.removeItem(at: logDirectory)

        precondition(VoiceBridge.outputMuteState(label: "Mute speakers") == false)
        precondition(VoiceBridge.outputMuteState(label: "Unmute speakers") == true)
        precondition(VoiceBridge.outputMuteState(label: "Mute microphone") == nil, "Microphone state cannot be mistaken for speaker state")
        struct ObservedControl: Decodable { let role: String; let subrole: String?; let label: String }
        struct ObservedPanel: Decodable { let controls: [ObservedControl] }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CodexVoice/floating-controls-observed.json")
        let floating = try JSONDecoder().decode(ObservedPanel.self, from: Data(contentsOf: fixture))
        for control in floating.controls {
            precondition(VoiceBridge.isVoiceControlRole(control.role), "Fallback traversal must inspect the observed floating controls")
        }
        let observedMicrophones = floating.controls.compactMap { MicrophoneState.accessibilityLabel($0.label) }
        let observedOutputs = floating.controls.compactMap { VoiceBridge.outputMuteState(label: $0.label) }
        precondition(observedMicrophones == [.listening] && observedOutputs == [true], "Read each channel from its own observed label")
        for role in ["AXStaticText", "AXImage", "AXWindow", "AXWebArea", "AXToggleButton", ""] {
            precondition(!VoiceBridge.isVoiceControlRole(role), "Unrelated elements are not audio controls")
        }
        precondition(!VoiceBridge.isVoiceControlRole(nil))
        precondition(VoiceBridge.outputMuteState(label: "  MUTE VOICE CHAT\n") == false)
        precondition(VoiceBridge.outputMuteState(label: "Mute voice chat for this app") == nil)
        precondition(MicrophoneState.accessibilityLabel("Mute voice chat") == nil)
        precondition(MicrophoneState.accessibilityLabel("Unmute voice chat") == nil)
        var mailboxState = state(), mailboxEvents: [String] = []
        var launchBoundaries: [Date?] = []
        let mailboxContext = VoiceStartContext()
        mailboxContext.prepareNewCall = { mailboxEvents.append("mailbox") }
        let mailboxVoice = NativeVoice(transport: .init(snapshot: { mailboxState }, send: { command, _ in
            mailboxEvents.append(command); mailboxState = state(.listening)
        }, activate: { _ in fatalError("Global Start must not make Codex frontmost") },
        prepareNewVoiceSpeed: { pid, _ in precondition(pid == 123); mailboxEvents.append("speed") },
        finishLaunchDefaults: { _, sent in launchBoundaries.append(sent) }))
        var afterLaunchCalls = 0
        mailboxVoice.onNewCall = { context in
            precondition(mailboxState.microphone == .listening && context.requestedPID == 123 && context.sentAt != nil,
                         "Model Bar handoff is armed only after a successful native new-call dispatch")
            afterLaunchCalls += 1
        }
        _ = try await mailboxVoice.start(context: mailboxContext)
        precondition(mailboxEvents == ["speed", "mailbox", VoiceBridge.startCommand] && mailboxContext.requestedNewCall && afterLaunchCalls == 1)
        let reusedMailboxContext = VoiceStartContext()
        reusedMailboxContext.prepareNewCall = { fatalError("Reusing a live call must not replace startup speech") }
        _ = try await mailboxVoice.start(context: reusedMailboxContext)
        precondition(!reusedMailboxContext.requestedNewCall && mailboxEvents == ["speed", "mailbox", VoiceBridge.startCommand] && afterLaunchCalls == 1,
                     "Reusing the active call never repeats automatic speed selection")

        precondition(launchBoundaries.count == 2 && launchBoundaries[0] != nil && launchBoundaries[1] == nil)
        _ = try await mailboxVoice.start(context: mailboxContext)
        precondition(afterLaunchCalls == 1, "Even an accidentally reused opening context cannot repeat its Model Bar handoff")
        // Native confirmation can suspend after a successful shortcut. Cleanup must
        // already be handed to the defaults owner, independently of that UI read. — GPT-6.1 Sol
        precondition(NativeVoice.Transport.live.prepareNewVoiceSpeed == nil && NativeVoice.Transport.live.finishLaunchDefaults == nil,
                     "Production Start preserves model/effort/defaults; automatic speed belongs to the exact-call Model Bar handoff")
        var dispatched = false, cleanupArmed = false, delayedHandoffs = 0
        var resumeConfirmation: CheckedContinuation<VoiceSnapshot, Never>?
        let delayedConfirmation = NativeVoice(transport: .init(snapshot: {
            guard dispatched else { return state() }
            precondition(cleanupArmed, "Defaults cleanup must be armed before post-Start confirmation")
            return await withCheckedContinuation { resumeConfirmation = $0 }
        }, send: { _, _ in dispatched = true }, activate: { _ in },
            finishLaunchDefaults: { _, sent in cleanupArmed = sent != nil }))
        delayedConfirmation.onNewCall = { context in
            precondition(dispatched && !delayedConfirmation.connected && context.requestedPID == 123 && context.sentAt != nil)
            delayedHandoffs += 1
        }
        let delayedStart = Task { try await delayedConfirmation.start() }
        while resumeConfirmation == nil { await Task.yield() }
        precondition(cleanupArmed && !delayedConfirmation.connected && delayedHandoffs == 1,
                     "A suspended native confirmation cannot lose the exact-call automatic speed handoff")
        resumeConfirmation?.resume(returning: state(.listening))
        _ = try await delayedStart.value
        precondition(delayedConfirmation.connected && delayedHandoffs == 1)
        var rollbackOnError = false
        var appeared = state()
        let appearedDuringSpeedChange = NativeVoice(transport: .init(snapshot: { appeared },
            send: { _, _ in fatalError("A call opened during speed preparation") }, activate: { _ in },
            prepareNewVoiceSpeed: { _, _ in appeared = state(.listening) }))
        let reused = try await appearedDuringSpeedChange.start()
        precondition(reused == .listening)
        let unavailableSpeed = NativeVoice(transport: .init(snapshot: { state() },
            send: { _, _ in fatalError("Start must wait for the shared preference") }, activate: { _ in },
            prepareNewVoiceSpeed: { _, _ in throw BridgeError.message("Test configuration error") },
            finishLaunchDefaults: { _, sent in rollbackOnError = sent == nil }))
        do { _ = try await unavailableSpeed.start(); fatalError("Expected configuration failure") } catch is BridgeError { }

        precondition(rollbackOnError)

        var desktop = DesktopSessionState.locked
        var sessionCommands: [String] = [], sessionState = state()
        let sessionVoice = NativeVoice(transport: .init(snapshot: { sessionState }, send: { command, _ in
            sessionCommands.append(command); sessionState = state(.listening)
        }, activate: { _ in precondition(desktop == .interactive) }, startSession: { desktop }))
        for unavailable in [DesktopSessionState.locked, .inactive, .unknown] {
            desktop = unavailable
            do { _ = try await sessionVoice.start(); fatalError("Unavailable desktop accepted Start") }
            catch BridgeError.desktopUnavailable(let found) { precondition(found == unavailable) }
        }
        precondition(sessionCommands.isEmpty, "Locked/inactive starts never post a key")
        desktop = .interactive
        _ = try await sessionVoice.start()
        precondition(sessionVoice.connected && sessionCommands == [VoiceBridge.startCommand],
                     "A fresh wake after unlock starts once without stale pending ownership")

        var changedDuringRead = DesktopSessionState.interactive
        let readLock = NativeVoice(transport: .init(snapshot: {
            changedDuringRead = .locked; return state()
        }, send: { _, _ in fatalError("A lock during scanning must prevent delivery") },
            activate: { _ in fatalError("A lock during scanning must prevent activation") },
            startSession: { changedDuringRead }))
        do { _ = try await readLock.start(); fatalError("Lock during scan accepted Start") }
        catch BridgeError.desktopUnavailable { }

        var confirmationSession = DesktopSessionState.interactive
        var confirmationState = state(), confirmationCommands: [String] = []
        let lockDuringConfirmation = NativeVoice(transport: .init(snapshot: { confirmationState }, send: { command, _ in
            confirmationCommands.append(command)
            if confirmationCommands.count == 1 { confirmationSession = .locked }
            else { confirmationState = state(.listening) }
        }, activate: { _ in }, startSession: { confirmationSession }))
        let lockedOpening = VoiceStartContext()
        do { _ = try await lockDuringConfirmation.start(context: lockedOpening); fatalError("Locked confirmation continued") }
        catch {
            guard case BridgeError.desktopUnavailable = error else { throw error }
            await lockDuringConfirmation.recoverFromStartFailure(error, context: lockedOpening)
        }
        precondition(confirmationCommands == [VoiceBridge.startCommand], "Lock recovery never sends End")
        confirmationSession = .interactive
        _ = try await lockDuringConfirmation.start()
        precondition(confirmationCommands == [VoiceBridge.startCommand, VoiceBridge.startCommand],
                     "A locked attempt cannot poison a later unlocked wake")
        let cancelledBeforeStart = NativeVoice(transport: .init(
            snapshot: { fatalError("A cancelled request must not scan native controls") },
            send: { _, _ in fatalError("A cancelled request must not send commands") },
            activate: { _ in fatalError("A cancelled request must not activate Codex") }))
        let preCancelled = Task { @MainActor in
            do {
                _ = try await cancelledBeforeStart.start(onRequestAccepted: {
                    fatalError("An already-cancelled request must not play a cue")
                })
                fatalError("Cancelled start unexpectedly succeeded")
            } catch is CancellationError { }
        }
        preCancelled.cancel()
        try await preCancelled.value
        var acknowledgedBeforeRead = false
        let immediateFeedback = NativeVoice(transport: .init(snapshot: {
            precondition(acknowledgedBeforeRead, "A slow native-control read must not delay the wake acknowledgement")
            return state(.listening)
        }, send: { _, _ in fatalError("Existing Voice needs no toggle") }, activate: { _ in }))
        _ = try await immediateFeedback.start(onRequestAccepted: { acknowledgedBeforeRead = true })
        var current = state()
        var sent: [String] = []
        var activationCount = 0
        let voice = NativeVoice(transport: .init(snapshot: { current }, send: { command, _ in
            sent.append(command)
            if command == VoiceBridge.muteCommand { current = state(.listening) }
            else { current = current.microphone == nil ? state(.listening) : state() }
        }, activate: { _ in activationCount += 1 }, unmute: { _ in
            sent.append("native.unmute"); current = state(.listening)
        }))
        var startCues = 0
        try await voice.start(onRequestAccepted: { startCues += 1 })
        precondition(startCues == 1, "New native Voice gets its start cue")
        try await voice.setMicrophone(.listening)
        precondition(voice.connected && sent == [VoiceBridge.startCommand], "Start native call once")
        async let first: Void = voice.stop()
        async let second: Void = voice.stop()
        _ = await (first, second)
        precondition(!voice.connected && sent == [VoiceBridge.startCommand, VoiceBridge.endCommand], "Concurrent cleanup must end once, never reopen")
        await voice.stop()
        precondition(sent.count == 2, "Repeated stop must not reopen a call")
        current = state(.muted)
        let beforeMutedWake = sent.count
        let beforeMutedWakeActivations = activationCount
        let openedMicrophone = try await voice.start(onRequestAccepted: { startCues += 1 })
        precondition(openedMicrophone == .muted, "Start returns fresh state so callers can skip a redundant snapshot when already listening")
        precondition(sent.count == beforeMutedWake, "Hello Chat adopts an existing muted call without sending the new-chat shortcut")
        try await voice.setMicrophone(.listening)
        precondition(activationCount == beforeMutedWakeActivations, "Waking an already-open muted call must not activate Codex")
        precondition(Array(sent.dropFirst(beforeMutedWake)) == ["native.unmute"], "Hello Chat sends only unmute for an existing muted native call")
        precondition(startCues == 2, "An accepted wake acknowledges reuse and unmute without a new-call shortcut")
        let beforeRepeatedWake = sent.count
        let alreadyListening = try await voice.start(onRequestAccepted: { startCues += 1 })
        precondition(alreadyListening == .listening, "Repeated Hello Chat sees the same unmuted Voice call")
        try await voice.setMicrophone(.listening)
        precondition(sent.count == beforeRepeatedWake, "Repeated Hello Chat neither creates another chat nor remutes the current call")
        precondition(startCues == 3, "An accepted wake acknowledges an already-listening call without toggling it")
        await voice.stop()
        current = state(input: true)
        let beforeResidualStart = sent.count
        _ = try await voice.start()
        precondition(voice.connected && sent.count == beforeResidualStart + 1 && sent.last == VoiceBridge.startCommand,
                     "Residual process input must not block an explicit start after a complete absent Voice-control scan")
        await voice.stop()
        for input in [false, true] {
            let count = sent.count
            current = state(input: input); current.controlsComplete = false; current.applicationReady = false
            _ = try await voice.start()
            precondition(sent.count == count + 1 && sent.last == VoiceBridge.startCommand && voice.connected,
                         "An explicit wake makes one start attempt after persistently unknown controls, regardless of residual input")
            await voice.stop()
        }
        let count = sent.count
        var transientReads = 0
        let transient = NativeVoice(transport: .init(snapshot: {
            transientReads += 1
            var value = state(.muted)
            if transientReads == 1 { value = state(input: true); value.controlsComplete = false }
            return value
        }, send: { _, _ in fatalError("A recovered existing muted call must not be toggled") }, activate: { _ in }))
        var recoveredCues = 0
        let recoveredMicrophone = try await transient.start(onRequestAccepted: { recoveredCues += 1 })
        precondition(recoveredCues == 1, "Snapshot retries must not replay the acknowledgement")
        precondition(recoveredMicrophone == .muted && transientReads == 2, "Retry a transient incomplete read without toggling an existing call")

        var lookupReads = 0
        let missingInitialApp = NativeVoice(transport: .init(snapshot: {
            lookupReads += 1
            var value = state(.muted)
            if lookupReads == 1 { value.pid = nil; value.microphone = nil; value.controlsComplete = false }
            return value
        }, send: { _, _ in fatalError("Recovered existing call must not receive Start or End") }, activate: { _ in }))
        let recoveredInitialApp = try await missingInitialApp.start()
        precondition(recoveredInitialApp == .muted && lookupReads == 2,
                     "A transient initial application lookup recovers before deciding Voice is absent")

        var preparedForColdLaunch = false
        var launched = false, launchCount = 0, readinessReads = 0, launchCommands: [String] = []
        let closedApp = NativeVoice(transport: .init(snapshot: {
            var value = state()
            if !launched { value.pid = nil; value.controlsComplete = false; return value }
            readinessReads += 1
            value.applicationReady = readinessReads >= 3
            if !launchCommands.isEmpty { value = state(.listening) }
            return value
        }, send: { command, _ in
            precondition(readinessReads >= 3, "Never deliver to a process before its actual readiness")
            launchCommands.append(command)
        }, activate: { _ in }, launch: {
            precondition(preparedForColdLaunch, "Set speed before the cold desktop reads its initial configuration")
            launched = true
            launchCount += 1
        }, prepareNewVoiceSpeed: { pid, _ in
            precondition(pid == nil && !launched && !preparedForColdLaunch)
            preparedForColdLaunch = true
        }), minimumLaunchWait: 0)
        _ = try await closedApp.start()
        precondition(launchCount == 1 && launchCommands == ["realtimeVoice"] && closedApp.connected,
                     "A closed Codex launches once, waits for readiness, then receives only the global Voice action")

        // Virtual time exercises production's launch delay without making the
        // test suite sleep or starting a real Codex conversation.
        for readyAt in [0.0, 9.0, 99.0] {
            var clock: TimeInterval = 0
            var opened = false, commands = 0
            let settled = NativeVoice(transport: .init(snapshot: {
                var value = state()
                value.pid = opened ? 123 : nil
                value.applicationReady = opened && clock >= readyAt
                value.applicationHasWebContent = opened
                if commands > 0 { value = state(.listening) }
                return value
            }, send: { command, _ in
                precondition(clock >= max(5, readyAt), "A visible launch shell cannot receive Start early")
                precondition(command == "realtimeVoice", "Never use Toggle as a launch fallback")
                commands += 1
            }, activate: { _ in }, launch: { opened = true },
            now: { clock }, wait: { clock += $0 }))
            if readyAt < 10 {
                _ = try await settled.start()
                precondition(commands == 1, "Interactive readiness sends Start once, never early")
            } else {
                do { _ = try await settled.start(); fatalError("An unready web shell must time out") }
                catch { precondition(commands == 0, "A timer never overrides explicit unready state") }
            }
        }

        var replacementClock: TimeInterval = 0
        var replacementLaunches = 0, replacementSends = 0
        let slowReplacement = NativeVoice(transport: .init(snapshot: {
            var value = state()
            if replacementLaunches == 0 { value.pid = nil }
            else if replacementLaunches == 1 {
                value.pid = replacementClock >= 6 ? nil : 123
                value.applicationReady = false
            } else {
                value.pid = 456
                if replacementSends > 0 { value.microphone = .listening }
            }
            return value
        }, send: { _, pid in
            precondition(pid == 456 && replacementClock >= 11, "Replacement receives its full five-second minimum")
            replacementSends += 1
        }, activate: { _ in }, launch: { replacementLaunches += 1 },
        now: { replacementClock }, wait: { replacementClock += $0 }))
        _ = try await slowReplacement.start()
        precondition(replacementLaunches == 2 && replacementSends == 1, "A late process exit gets one bounded replacement launch")

        var launchFoundCall = false, adoptedLaunches = 0
        let launchAdoption = NativeVoice(transport: .init(snapshot: {
            if launchFoundCall { return state(.listening) }
            var value = state(); value.pid = nil; return value
        }, send: { _, _ in fatalError("Never send Start when launch discovers an existing call") },
        activate: { _ in }, launch: { launchFoundCall = true; adoptedLaunches += 1 }))
        _ = try await launchAdoption.start()
        precondition(adoptedLaunches == 1 && launchAdoption.connected, "A call that appears during launch is reused")

        var reopened = false, windowlessCommands: [String] = []
        let closedWindow = NativeVoice(transport: .init(snapshot: {
            var value = state()
            value.applicationHasWindow = reopened; value.applicationReady = reopened
            if !windowlessCommands.isEmpty { value = state(.listening) }
            return value
        }, send: { command, _ in windowlessCommands.append(command) }, activate: { _ in }, launch: { reopened = true }), minimumLaunchWait: 0)
        _ = try await closedWindow.start()
        precondition(reopened && windowlessCommands == ["realtimeVoice"], "An existing process with its last window closed receives a normal reopen before Start")

        var raceLaunches = 0, raceCommands: [String] = []
        let exitsDuringReopen = NativeVoice(transport: .init(snapshot: {
            var value = state()
            if raceLaunches == 0 { value.applicationHasWindow = false; value.applicationReady = false }
            else if raceLaunches == 1 { value.pid = nil; value.applicationReady = false }
            else { value.pid = 456; if !raceCommands.isEmpty { value.microphone = .listening } }
            return value
        }, send: { command, pid in
            precondition(pid == 456, "Only the replacement process receives Start")
            raceCommands.append(command)
        }, activate: { _ in }, launch: { raceLaunches += 1 }), minimumLaunchWait: 0)
        _ = try await exitsDuringReopen.start()
        precondition(raceLaunches == 2 && raceCommands == ["realtimeVoice"],
                     "If the old process exits during reopen, relaunch once and send Voice only once after readiness")

        var adoptionReads = 0
        let activationAdoption = NativeVoice(transport: .init(snapshot: {
            adoptionReads += 1; return adoptionReads >= 2 ? state(.listening) : state()
        }, send: { _, _ in fatalError("Never send Start when a call appears during the fresh recheck") },
            activate: { _ in fatalError("Global Start must not activate Codex") }, launch: { fatalError("An open app is not launched again") }))
        _ = try await activationAdoption.start()
        precondition(activationAdoption.connected, "The final fresh check prevents a duplicate call")

        var readinessLaunches = 0, unreadyCommands = 0
        let neverReady = NativeVoice(transport: .init(snapshot: {
            var value = state(); value.pid = readinessLaunches == 0 ? nil : 123
            value.applicationReady = false; return value
        }, send: { _, _ in unreadyCommands += 1 }, activate: { _ in },
        launch: { readinessLaunches += 1 }), launchTimeout: 0.01)
        do { _ = try await neverReady.start(); fatalError("Unready launch must time out") } catch { }
        precondition(readinessLaunches == 1 && unreadyCommands == 0, "A launch timeout neither relaunches nor sends blindly")

        let launchFailure = NativeVoice(transport: .init(snapshot: {
            var value = state(); value.pid = nil; return value
        }, send: { _, _ in fatalError("Failed launch must send nothing") }, activate: { _ in },
        launch: { throw BridgeError.message("not installed") }))
        do { _ = try await launchFailure.start(); fatalError("Missing installation must fail") }
        catch { precondition(error.localizedDescription == "not installed") }

        var finishLaunch: CheckedContinuation<Void, Never>?
        var launchCancelledCommands = 0
        let cancelledLaunch = NativeVoice(transport: .init(snapshot: {
            var value = state(); value.pid = nil; return value
        }, send: { _, _ in launchCancelledCommands += 1 }, activate: { _ in }, launch: {
            await withCheckedContinuation { finishLaunch = $0 }
        }))
        let launchTask = Task { try await cancelledLaunch.start() }
        while finishLaunch == nil { await Task.yield() }
        launchTask.cancel()
        finishLaunch?.resume()
        do { _ = try await launchTask.value; fatalError("Cancelled launch must not start Voice") }
        catch is CancellationError { }
        precondition(launchCancelledCommands == 0, "Cancellation during application launch sends neither Start nor End")

        var startedWithMissingRead = false, openingReads = 0
        var recoveryCommands: [String] = []
        let recoveredOpening = NativeVoice(transport: .init(snapshot: {
            guard startedWithMissingRead else { return state() }
            openingReads += 1
            var value = state(input: true)
            if openingReads == 1 { value.pid = nil; value.controlsComplete = false }
            else if openingReads == 2 { value.controlsComplete = false }
            else { value.endControlAvailable = true }
            return value
        }, send: { command, _ in recoveryCommands.append(command); startedWithMissingRead = true }, activate: { _ in }))
        let recoveredOpeningMic = try await recoveredOpening.start()
        precondition(recoveredOpeningMic == nil && recoveredOpening.connected && openingReads == 3
                     && recoveryCommands == [VoiceBridge.startCommand],
                     "Missing application and incomplete controls during opening recover without another Start or cleanup End")

        var timeoutStarted = false, timeoutRecovered = false
        var timeoutCommands: [String] = []
        let timedOutOpeningContext = VoiceStartContext()
        let timedOutOpening = NativeVoice(transport: .init(snapshot: {
            if timeoutRecovered { return state(.listening) }
            var value = state()
            if timeoutStarted { value.pid = nil; value.controlsComplete = false }
            return value
        }, send: { command, _ in timeoutCommands.append(command); timeoutStarted = true }, activate: { _ in }), confirmationTimeout: 0.05)
        do { _ = try await timedOutOpening.start(context: timedOutOpeningContext); fatalError("Unknown opening must remain bounded") }
        catch { await timedOutOpening.recoverFromStartFailure(error, context: timedOutOpeningContext) }
        await timedOutOpening.stop()
        precondition(timeoutCommands == [VoiceBridge.startCommand] && !timedOutOpening.connected,
                     "An opening timeout releases stale ownership without ending a possibly working call")
        timeoutRecovered = true
        _ = try await timedOutOpening.start(context: timedOutOpeningContext)
        precondition(timedOutOpening.connected && timeoutCommands == [VoiceBridge.startCommand],
                     "The next wake adopts the late successful call without creating another chat")

        var replacementStarted = false, replacementCommands: [String] = []
        let replacedOpeningContext = VoiceStartContext()
        let replacedOpening = NativeVoice(transport: .init(snapshot: {
            var value = state()
            if replacementStarted { value.pid = 456; value.endControlAvailable = true }
            return value
        }, send: { command, _ in replacementCommands.append(command); replacementStarted = true }, activate: { _ in }))
        do { _ = try await replacedOpening.start(context: replacedOpeningContext); fatalError("A different process cannot confirm our opening") }
        catch { await replacedOpening.recoverFromStartFailure(error, context: replacedOpeningContext) }
        await replacedOpening.stop()
        precondition(replacementCommands == [VoiceBridge.startCommand], "A changed Codex process must not receive cleanup End")
        current = state(allowed: false)
        do { try await voice.start(); fatalError("Missing Accessibility must fail before sending") }
        catch is BridgeError { }
        precondition(sent.count == count)

        // The user may close Voice in Codex without this helper seeing it.
        current = state(.listening)
        try await voice.start()
        current = state()
        let beforeWake = sent.count
        try await voice.start()
        precondition(sent.count == beforeWake + 1 && sent.last == VoiceBridge.startCommand, "Fresh wake reopens an externally closed native call")
        await voice.stop()
        current = state(.listening)
        let beforeEnd = sent.count
        let ended = try await voice.endIfPresent()
        precondition(ended && sent.count == beforeEnd + 1 && sent.last == VoiceBridge.endCommand, "Explicit spoken end can end a manually opened native call")
        let emptyEnd = try await voice.endIfPresent()
        precondition(!emptyEnd && sent.count == beforeEnd + 1, "End while Voice is off does not start a call")
        current = state(input: true)
        do { _ = try await voice.endIfPresent(); fatalError("Unknown input must not be reported as Voice off") }
        catch is BridgeError { }
        precondition(sent.count == beforeEnd + 1, "Spoken end does not touch unrelated dictation")

        var late = state()
        var lateSends = 0
        let cancelledContext = VoiceStartContext()
        let cancelled = NativeVoice(transport: .init(snapshot: { late }, send: { _, _ in
            lateSends += 1
            if lateSends == 1 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    late = state(.listening)
                }
            } else { late = state() }
        }, activate: { _ in }))
        let opening = Task { @MainActor in
            do { try await cancelled.start(context: cancelledContext) }
            catch { await cancelled.recoverFromStartFailure(error, context: cancelledContext) }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        opening.cancel()
        await cancelled.stop()
        await opening.value
        precondition(lateSends == 2 && !cancelled.connected, "Cancelled late native opening is ended exactly once")

        // A background send can still be in flight when cancellation arrives.
        // Cleanup must wait for that owned opening and end it exactly once.
        var asynchronous = state()
        var asynchronousSends: [String] = []
        let inFlightContext = VoiceStartContext()
        let inFlight = NativeVoice(transport: .init(snapshot: { asynchronous }, send: { command, _ in
            asynchronousSends.append(command)
            if command == VoiceBridge.startCommand {
                try await Task.detached { try await Task.sleep(nanoseconds: 400_000_000) }.value
                asynchronous = state(.listening)
            } else { asynchronous = state() }
        }, activate: { _ in }))
        let sending = Task { @MainActor in
            do { try await inFlight.start(context: inFlightContext) }
            catch { await inFlight.recoverFromStartFailure(error, context: inFlightContext) }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        sending.cancel()
        await inFlight.stop(); await sending.value
        precondition(asynchronousSends == [VoiceBridge.startCommand, VoiceBridge.endCommand] && !inFlight.connected,
                     "Cancellation during an asynchronous send cannot leave an owned call running")

        var preservedState = state(), preservedCommands: [String] = []
        let preserveContext = VoiceStartContext()
        let environmental = NativeVoice(transport: .init(snapshot: { preservedState }, send: { command, _ in
            precondition(command != VoiceBridge.endCommand, "A microphone-only call must use fresh explicit End")
            preservedCommands.append(command)
            if command == VoiceBridge.startCommand {
                try await Task.detached { try await Task.sleep(nanoseconds: 100_000_000) }.value
                preservedState = state(.listening)
            } else { preservedState = state() }
        }, activate: { _ in }, requestEnd: {
            preservedCommands.append("native.end"); preservedState = state(); return 123
        }))
        let environmentalTask = Task { @MainActor in
            do { _ = try await environmental.start(context: preserveContext) }
            catch { await environmental.recoverFromStartFailure(error, context: preserveContext) }
        }
        while preservedCommands.isEmpty { await Task.yield() }
        preserveContext.preserveCallOnCancellation = true
        environmentalTask.cancel()
        await environmentalTask.value
        precondition(preservedCommands == [VoiceBridge.startCommand], "An environmental capture pause never sends End")
        _ = try await environmental.endIfPresent()
        precondition(preservedCommands == [VoiceBridge.startCommand, "native.end"], "The first End after preservation uses the fresh microphone-only path")
        preservedState = state(.listening)
        _ = try await environmental.start()
        precondition(environmental.connected && preservedCommands.count == 2, "Capture can resume and reuse the call after a temporary pause")
        _ = try await environmental.endIfPresent()
        precondition(preservedCommands.last == "native.end", "A later explicit End still works")
        preservedState = state(.listening)
        environmental.detachForQuit()
        _ = await environmental.reattachAfterFailedUpdate()
        _ = try await environmental.start()
        precondition(environmental.connected, "Aborted update preparation can reattach without ending an existing call")

        // An older cancelled opening must not clear a newer request's pending
        // ownership, or explicit End could bypass late-opening cleanup.
        var raceState = state(), raceStarts = 0, directEnds = 0, strictEnds = 0
        var finishNewSend: CheckedContinuation<Void, Never>?
        let oldContext = VoiceStartContext(), newContext = VoiceStartContext()
        oldContext.preserveCallOnCancellation = true
        let ownership = NativeVoice(transport: .init(snapshot: { raceState }, send: { command, _ in
            if command == VoiceBridge.startCommand {
                raceStarts += 1
                if raceStarts == 2 {
                    await withCheckedContinuation { finishNewSend = $0 }
                    raceState = state(.listening)
                }
            } else { strictEnds += 1; raceState = state() }
        }, activate: { _ in }, requestEnd: { directEnds += 1; raceState = state(); return 123 }))
        let oldRequest = Task { try? await ownership.start(context: oldContext) }
        while raceStarts == 0 { await Task.yield() }
        oldRequest.cancel(); _ = await oldRequest.value
        let newRequest = Task { try? await ownership.start(context: newContext) }
        while finishNewSend == nil { await Task.yield() }
        await ownership.recoverFromStartFailure(CancellationError(), context: oldContext)
        let endNew = Task { try await ownership.endIfPresent() }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(directEnds == 0, "An old cancellation cannot erase a newer pending Start")
        finishNewSend?.resume(); newRequest.cancel(); _ = await newRequest.value
        _ = try await endNew.value
        precondition(strictEnds == 1 && directEnds == 0, "Explicit cancellation still cleans up its late opening")

        // An exact End action plus a saved Voice session can establish an
        // existing call with no readable microphone control or input.
        var endOnlyState = state(.listening)
        let endOnly = NativeVoice(transport: .init(snapshot: { endOnlyState }, send: { _, _ in
            fatalError("Unknown existing microphone must not authorize a start or cleanup End")
        }, activate: { _ in fatalError("Existing End-only call must not activate a start") }))
        _ = try await endOnly.start() // Establish a stale cached connected flag.
        endOnlyState = state(); endOnlyState.endControlAvailable = true
        endOnlyState.savedVoiceActive = true
        var endOnlyCues = 0
        let unknownMicrophone = try await endOnly.start(onRequestAccepted: { endOnlyCues += 1 })
        precondition(endOnlyCues == 1, "An accepted End-only reuse still acknowledges the wake")
        precondition(unknownMicrophone == nil && endOnly.connected,
                     "End and its corroborating session preserve an unknown microphone state and send nothing")

        var newlyOpened = state()
        var newlyOpenedCommands: [String] = []
        let newlyEndOnly = NativeVoice(transport: .init(snapshot: { newlyOpened }, send: { command, _ in
            newlyOpenedCommands.append(command)
            if command == VoiceBridge.startCommand {
                newlyOpened.endControlAvailable = true
                newlyOpened.inputRunning = true
            }
            else if command == VoiceBridge.endCommand { newlyOpened = state() }
            else { fatalError("Unknown microphone must never authorize a mute toggle") }
        }, activate: { _ in }))
        let newUnknownMicrophone = try await newlyEndOnly.start()
        precondition(newUnknownMicrophone == nil && newlyEndOnly.connected && newlyOpenedCommands == [VoiceBridge.startCommand],
                     "End plus Codex input confirms Start without guessing the microphone state")
        let endedNewUnknown = try await newlyEndOnly.endIfPresent()
        precondition(endedNewUnknown && newlyOpenedCommands == [VoiceBridge.startCommand, VoiceBridge.endCommand] && !newlyEndOnly.connected,
                     "A call with unknown mic state still supports explicit End")

        // A pending panel exposes End, without a microphone or saved
        // session. This was observed both after Start and on later wakes.
        var pendingPanel = state()
        pendingPanel.endControlAvailable = true
        pendingPanel.savedVoiceActive = false
        var panel = state()
        var stalledCommands: [String] = []
        let stalled = NativeVoice(transport: .init(snapshot: { panel }, send: { command, _ in
            stalledCommands.append(command)
            panel = pendingPanel
        }, activate: { _ in fatalError("Stalled opening must not activate Codex") }),
                                  confirmationTimeout: 0.05)
        for _ in 0..<2 {
            let context = VoiceStartContext()
            do { _ = try await stalled.start(context: context); fatalError("An End-only panel is not a connection") }
            catch let error as BridgeError { await stalled.recoverFromStartFailure(error, context: context) }
            precondition(!stalled.connected && stalledCommands == [VoiceBridge.startCommand],
                         "A stalled opening and a repeated wake neither confirm it nor send another key")
        }
        panel = state(.listening)
        let stalledThenRecoveredMic = try await stalled.start()
        precondition(stalledThenRecoveredMic == .listening && stalledCommands == [VoiceBridge.startCommand],
                     "A manually recovered call is adopted without another Start")
        // A later complete empty scan allows a real retry. An incomplete
        // read from the previous call's process must never send its toggle.
        panel = state()
        panel.controlsComplete = false
        do { _ = try await stalled.start(); fatalError("An incomplete repeat must remain unconfirmed") }
        catch is BridgeError { }
        precondition(stalledCommands == [VoiceBridge.startCommand])
        panel.controlsComplete = true
        do { _ = try await stalled.start(); fatalError("The test transport produces another unconnected panel") }
        catch is BridgeError { }
        precondition(stalledCommands == [VoiceBridge.startCommand, VoiceBridge.startCommand],
                     "A fresh, complete absence makes a retry eligible")
        var hiddenSavedCall = state()
        hiddenSavedCall.savedVoiceActive = true
        let hiddenCall = NativeVoice(transport: .init(snapshot: { hiddenSavedCall },
            send: { _, _ in fatalError("A saved call from the current process may still be active") },
            activate: { _ in }), confirmationTimeout: 0.05)
        do { _ = try await hiddenCall.start(); fatalError("Saved metadata alone cannot confirm connected audio") }
        catch is BridgeError { }
        precondition(!hiddenCall.connected)

        var panelReads = 0
        let panelRace = NativeVoice(transport: .init(snapshot: {
            panelReads += 1
            return panelReads == 1 ? state() : panelReads == 2 ? pendingPanel : state(.listening)
        }, send: { _, _ in fatalError("A panel that opened during the final check must not get another Start") },
            activate: { _ in fatalError("An existing startup does not need activation") }))
        let connectedAfterRace = try await panelRace.start()
        precondition(connectedAfterRace == .listening && panelReads == 3,
                     "Wait for a real connection if End appears during the final pre-send scan")

        var endingState = state(.muted)
        var endSent = false, confirmationReads = 0
        let incompleteEnd = NativeVoice(transport: .init(snapshot: {
            if endSent {
                confirmationReads += 1
                var empty = state()
                empty.controlsComplete = confirmationReads > 1
                return empty
            }
            return endingState
        }, send: { command, _ in
            precondition(command == VoiceBridge.endCommand)
            endSent = true
        }, activate: { _ in }))
        _ = try await incompleteEnd.start()
        await incompleteEnd.stop()
        precondition(confirmationReads == 2 && !incompleteEnd.connected && incompleteEnd.lastError == nil,
                     "End confirmation waits past an incomplete empty read for a complete negative scan")

        endSent = false; confirmationReads = 0
        _ = try await incompleteEnd.start()
        endingState = state(); endingState.controlsComplete = false
        await incompleteEnd.stop()
        precondition(!endSent && incompleteEnd.connected && incompleteEnd.lastError != nil,
                     "An incomplete initial end scan cannot falsely confirm disappearance or send a toggle")

        let unknownEnd = NativeVoice(transport: .init(snapshot: {
            var empty = state(); empty.controlsComplete = false; return empty
        }, send: { _, _ in fatalError("Incomplete absence cannot authorize a control") }, activate: { _ in }))
        do { _ = try await unknownEnd.endIfPresent(); fatalError("Incomplete empty scan must not report Voice off") }
        catch is BridgeError { }
        // Voice can end while Codex continues a different input stream.
        // Process-wide audio input alone must not override complete Voice UI reads.
        var residualInput = state(.listening)
        var endEvents: [String] = []
        var residualReads = 0
        let residual = NativeVoice(transport: .init(snapshot: {
            if residualInput.microphone == nil { residualReads += 1 }
            return residualInput
        }, send: { command, _ in
            precondition(command == VoiceBridge.endCommand)
            endEvents.append(command)
            residualInput = state(input: true)
        }, activate: { _ in endEvents.append("activate") }))
        _ = try await residual.start()
        await residual.stop()
        precondition(!residual.connected && residual.lastError == nil && residualReads == 2,
                     "Two complete absent Voice scans confirm our End despite unrelated Codex input")
        precondition(endEvents == ["activate", VoiceBridge.endCommand],
                     "Activate Codex before the native End action, as for start and unmute")

        var transientEndSent = false, transientEndReads = 0
        let transientAbsence = NativeVoice(transport: .init(snapshot: {
            guard transientEndSent else { return state(.listening) }
            transientEndReads += 1
            if transientEndReads == 1 { return state(input: true) }
            if transientEndReads == 2 { return state(.listening) }
            return state(input: true)
        }, send: { command, _ in
            precondition(command == VoiceBridge.endCommand); transientEndSent = true
        }, activate: { _ in }))
        _ = try await transientAbsence.start()
        await transientAbsence.stop()
        precondition(!transientAbsence.connected && transientEndReads == 4,
                     "A transient missing Voice presentation cannot confirm End while input runs")

        var incompleteResidualSent = false, incompleteResidualReads = 0
        let incompleteResidual = NativeVoice(transport: .init(snapshot: {
            guard incompleteResidualSent else { return state(.listening) }
            incompleteResidualReads += 1
            var result = state(input: true)
            result.controlsComplete = incompleteResidualReads != 2
            return result
        }, send: { command, _ in
            precondition(command == VoiceBridge.endCommand); incompleteResidualSent = true
        }, activate: { _ in }))
        _ = try await incompleteResidual.start()
        await incompleteResidual.stop()
        precondition(!incompleteResidual.connected && incompleteResidualReads == 4,
                     "An incomplete read resets the consecutive complete-absence confirmation")

        var activationFailedCommands = 0
        let activationFailed = NativeVoice(transport: .init(snapshot: { state(.listening) }, send: { _, _ in
            activationFailedCommands += 1
        }, activate: { _ in throw BridgeError.message("Open Codex, then try again.") }))
        _ = try await activationFailed.start()
        await activationFailed.stop()
        precondition(activationFailed.connected && activationFailed.lastError != nil && activationFailedCommands == 0,
                     "Failed activation cannot falsely confirm End or send a shortcut")

        // Bye Chat can arrive while the very first AX read is still running.
        // Once that read returns, cancellation must prevent activation/start.
        var firstReadEntered = false
        let beforeActivation = NativeVoice(transport: .init(snapshot: {
            firstReadEntered = true
            try? await Task.detached { try await Task.sleep(nanoseconds: 200_000_000) }.value
            return state()
        }, send: { _, _ in fatalError("Cancelled pre-activation opening sent a command") },
        activate: { _ in fatalError("Cancelled pre-activation opening activated Codex") }))
        let early = Task { @MainActor in
            do { try await beforeActivation.start(); fatalError("Expected cancellation") }
            catch is CancellationError { }
            catch { fatalError("Unexpected error: \(error)") }
        }
        while !firstReadEntered { await Task.yield() }
        early.cancel(); await beforeActivation.stop(); await early.value
        precondition(!beforeActivation.connected)
        var directSent = false, directReads = 0
        let direct = NativeVoice(transport: .init(snapshot: {
            precondition(directSent, "Send direct End before the first expensive control scan")
            directReads += 1
            return state()
        }, send: { _, _ in fatalError("Successful direct End needs no fallback") }, activate: { _ in },
        requestEnd: { directSent = true; return 123 }))
        let directEnded = try await direct.endIfPresent()
        precondition(directEnded && directReads == 1 && !direct.connected)
        var slowEndSentAt: Date?
        var slowEndRetries = 0
        let slowEnd = NativeVoice(transport: .init(snapshot: {
            guard let sentAt = slowEndSentAt else { fatalError("End must be sent first") }
            return Date().timeIntervalSince(sentAt) < 1.2 ? state(.listening) : state()
        }, send: { _, _ in slowEndRetries += 1 }, activate: { _ in },
        requestEnd: { slowEndSentAt = Date(); return 123 }))
        _ = try await slowEnd.endIfPresent()
        precondition(slowEndRetries == 0 && !slowEnd.connected,
                     "A slow teardown must not receive a second toggle that could reopen Voice")
        var missingRootReads = 0
        let missingRoot = NativeVoice(transport: .init(snapshot: {
            missingRootReads += 1
            if missingRootReads == 1 {
                var missing = state(input: true)
                missing.pid = nil; missing.controlsComplete = false
                return missing
            }
            return state()
        }, send: { _, _ in fatalError("Incomplete root must not resend a toggle") }, activate: { _ in },
        requestEnd: { 123 }))
        _ = try await missingRoot.endIfPresent()
        precondition(missingRootReads == 2 && !missingRoot.connected,
                     "Missing app/AX root must not falsely confirm shutdown")

        var unconfirmedSends = 0
        let staleEnd = NativeVoice(transport: .init(snapshot: { state(.listening) },
            send: { _, _ in unconfirmedSends += 1 }, activate: { _ in }, requestEnd: { 123 }), endConfirmationTimeout: 0.01)
        do { _ = try await staleEnd.endIfPresent(); fatalError("Stale controls do not prove closure") }
        catch BridgeError.endUnconfirmed { }
        precondition(unconfirmedSends == 0, "An uncertain End must never retry Start or claim the call failed to close")
        var coalescedRequests = 0
        let coalesced = NativeVoice(transport: .init(snapshot: { state() }, send: { _, _ in }, activate: { _ in },
        requestEnd: { coalescedRequests += 1; return 123 }))
        async let endA = coalesced.endIfPresent()
        async let endB = coalesced.endIfPresent()
        let both = try await (endA, endB)
        precondition(both.0 && both.1 && coalescedRequests == 1, "Concurrent end phrases share one native stop")
        var attemptedDirect = false, fallbackPresses = 0
        let fallbackEnd = NativeVoice(transport: .init(snapshot: {
            fallbackPresses == 0 ? state(.listening) : state()
        }, send: { _, _ in fatalError("End retry must never send a second keyboard toggle") }, activate: { _ in },
        requestEnd: { attemptedDirect = true; return 123 }, retryEnd: { _ in fallbackPresses += 1 }))
        _ = try await fallbackEnd.endIfPresent()
        precondition(attemptedDirect && fallbackPresses == 1 && !fallbackEnd.connected,
                     "An initial End without effect retries the exact End button once, never the toggle")
        var unownedRequests = 0
        let unowned = NativeVoice(transport: .init(snapshot: { state() }, send: { _, _ in }, activate: { _ in },
        requestEnd: { unownedRequests += 1; return nil }))
        await unowned.stop()
        precondition(unownedRequests == 0, "Cleanup never adopts an unowned call")
        let absent = try await unowned.endIfPresent()
        precondition(!absent && unownedRequests == 1, "An explicit end may check an unowned call without starting anything")
        var closedExternally = false, staleCleanupRequests = 0
        let staleCleanup = NativeVoice(transport: .init(snapshot: { closedExternally ? state() : state(.listening) },
            send: { _, _ in fatalError("Closed-call cleanup must never send a toggle") }, activate: { _ in fatalError("Closed-call cleanup must not activate Codex") },
            requestEnd: { staleCleanupRequests += 1; return 123 },
            retryEnd: { _ in fatalError("Closed-call cleanup must not press End") }))
        _ = try await staleCleanup.start()
        closedExternally = true
        await staleCleanup.stop()
        precondition(staleCleanupRequests == 0 && !staleCleanup.connected, "Stale connected ownership cannot reopen externally closed Voice on Quit")

        var cleanupPressed = false, cleanupDirect = 0
        let activeCleanup = NativeVoice(transport: .init(snapshot: { cleanupPressed ? state() : state(.listening) },
            send: { _, _ in fatalError("Cleanup must use idempotent End, never a start-capable toggle") }, activate: { _ in },
            requestEnd: { cleanupDirect += 1; return 123 }, retryEnd: { _ in cleanupPressed = true }))
        _ = try await activeCleanup.start()
        await activeCleanup.stop()
        precondition(cleanupPressed && cleanupDirect == 0 && !activeCleanup.connected, "Owned active cleanup uses exact End only")

        var refreshed = state(.listening)
        let refreshing = NativeVoice(transport: .init(snapshot: { refreshed },
            send: { _, _ in fatalError("Refresh must never send a shortcut") },
            activate: { _ in fatalError("Refresh must not activate Codex") }))
        let openedInCodex = await refreshing.refresh()
        precondition(openedInCodex == .listening && refreshing.connected, "Refresh adopts a call opened in Codex")
        precondition(refreshing.acceptObservedEnd() && !refreshing.connected,
                     "A confirmed observer End clears only the cache, with no key or activation")
        _ = await refreshing.refresh()
        precondition(refreshing.connected, "An actual active call can still be read after cache invalidation")
        refreshed = state()
        let closedInCodex = await refreshing.refresh()
        precondition(closedInCodex == nil && !refreshing.connected, "Refresh notices a call closed in Codex")
        refreshed = state(.listening)
        _ = await refreshing.refresh()
        refreshed = state(input: true); refreshed.controlsComplete = false
        let unknown = await refreshing.refresh()
        precondition(unknown == nil && !refreshing.connected, "An incomplete read counts as off, so it never blocks the next start")
        // Quit detaches without making the active conversation ours to end.
        for adopted in [false, true] {
            var quitState = adopted ? state(.listening) : state()
            var quitCommands: [String] = []
            let quitting = NativeVoice(transport: .init(snapshot: { quitState }, send: { command, _ in
                quitCommands.append(command)
                quitState = state(.listening)
            }, activate: { _ in }))
            _ = try await quitting.start()
            let beforeQuit = quitCommands
            quitting.detachForQuit()
            await quitting.stop()
            await quitting.recoverFromStartFailure(CancellationError(), context: VoiceStartContext())
            let endedAfterQuit = try await quitting.endIfPresent()
            precondition(quitState.microphone == .listening && quitCommands == beforeQuit && !endedAfterQuit,
                         "Normal Quit preserves both owned and adopted active calls")
        }
        var openingEntered = false
        var releaseOpening: CheckedContinuation<Void, Never>?
        var quitDuringOpenState = state()
        var quitDuringOpenCommands: [String] = []
        let quitDuringOpenContext = VoiceStartContext()
        let quitDuringOpen = NativeVoice(transport: .init(snapshot: { quitDuringOpenState }, send: { command, _ in
            quitDuringOpenCommands.append(command)
            quitDuringOpenState = state(.listening)
            openingEntered = true
            await withCheckedContinuation { releaseOpening = $0 }
        }, activate: { _ in }))
        let quitOpeningTask = Task { @MainActor in
            do { _ = try await quitDuringOpen.start(context: quitDuringOpenContext) }
            catch { await quitDuringOpen.recoverFromStartFailure(error, context: quitDuringOpenContext) }
        }
        while !openingEntered { await Task.yield() }
        quitDuringOpen.detachForQuit()
        quitOpeningTask.cancel()
        releaseOpening?.resume()
        await quitOpeningTask.value
        precondition(quitDuringOpenCommands == [VoiceBridge.startCommand] && quitDuringOpenState.microphone == .listening,
                     "Quit during an in-flight Start does not hang up the late-opened call")
        var quitReadEntered = false
        var releaseQuitRead: CheckedContinuation<VoiceSnapshot, Never>?
        let quitBeforeStartContext = VoiceStartContext()
        let quitBeforeStart = NativeVoice(transport: .init(snapshot: {
            quitReadEntered = true
            return await withCheckedContinuation { releaseQuitRead = $0 }
        }, send: { _, _ in fatalError("Quit before Start must send no command") },
        activate: { _ in fatalError("Quit before Start must not activate Codex") }))
        let quitBeforeTask = Task { @MainActor in
            do { _ = try await quitBeforeStart.start(context: quitBeforeStartContext) }
            catch { await quitBeforeStart.recoverFromStartFailure(error, context: quitBeforeStartContext) }
        }
        while !quitReadEntered { await Task.yield() }
        quitBeforeStart.detachForQuit()
        quitBeforeTask.cancel()
        releaseQuitRead?.resume(returning: state())
        await quitBeforeTask.value
        if let cli = ProcessInfo.processInfo.environment["HELLOCHAT_TEST_CODEX_CLI"] {
            try await temporaryVoiceDefaults(executable: URL(fileURLWithPath: cli))
            try await warmVoiceDefaults(executable: URL(fileURLWithPath: cli))
        }
        print("Passed native Voice transport checks including stale closed-call and active-call cleanup. No desktop events or real calls sent.")
    }

    // The picker fixture writes its choices just like Desktop's native empty draft.
    // Use the real configuration protocol in a private home, never the user's renderer.
    private final class DraftFixture: VoiceDraftPicker {
        var selection: DraftChoices
        var closed = false
        var rejectSpeed = false
        var interruptEffort = false
        var adopted = false
        var delayedPersistence = false
        private let writes = DispatchQueue(label: "test.native-picker.preference-writes")
        var speedlessModel: String?
        var adoptBeforeModelSaves = false
        let file: URL
        init(_ selection: DraftChoices, file: URL) { self.selection = selection; self.file = file }
        func choices() throws -> DraftChoices {
            guard !adopted else { throw BridgeError.message("Draft adopted") }
            var visible = selection
            if selection.model == speedlessModel { visible.speed = DraftChoices.speedUnavailable }
            return visible
        }
        func put(_ key: String, _ value: String) throws {
            func writeToFile() throws {
                var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                    .map(String.init).filter { !$0.hasPrefix(key + " = ") }
                lines.append(key + " = \"" + value + "\"")
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            }
            if delayedPersistence {
                writes.asyncAfter(deadline: .now() + 0.35) { try! writeToFile() }
            } else { try writeToFile() }
        }
        func selectModel(_ value: String) throws {
            if adoptBeforeModelSaves { selection.model = value; adopted = true; return }
            try put("model", value.lowercased().replacingOccurrences(of: " ", with: "-")); selection.model = value
        }
        func selectEffort(_ value: String, beforeStep: (String, String) throws -> Void = { _, _ in }) throws {
            if interruptEffort && value == "High" {
                try beforeStep(selection.effort, "Extra High")
                try put("model_reasoning_effort", "xhigh")
                selection.effort = "Extra High"
                throw BridgeError.message("Interrupted after one confirmed slider step")
            }
            try beforeStep(selection.effort, value)
            try put("model_reasoning_effort", value == "Extra High" ? "xhigh" : value.lowercased()); selection.effort = value
        }
        func selectSpeed(_ value: String) throws {
            precondition(selection.model != speedlessModel && value != DraftChoices.speedUnavailable)
            if rejectSpeed { throw BridgeError.message("Speed choice unavailable") }
            // Observed Codex persistence: the displayed Fast tier is priority,
            // deliberately independent of production's catalogue lookup. — GPT-6.1 Sol
            let raw = ["Standard": "default", "Fast": "priority", "Ultrafast": "ultrafast"][value]!
            try put("service_tier", raw); selection.speed = value
        }
        func closeIfEmpty() { if !adopted { closed = true } }
    }
    private static func warmVoiceDefaults(executable: URL) async throws {
        precondition(CodexVoiceDraft.pickerFailureReason(CodexVoiceDraft.OwnershipFailure.inputChanged) == "input-changed")
        precondition(CodexVoiceDraft.pickerFailureReason(CodexVoiceDraft.OwnershipFailure.draftChanged) == "draft-changed")
        precondition(CodexVoiceDraft.pickerFailureReason(CancellationError()) == "cancelled")
        precondition(CodexVoiceDraft.pickerFailureReason(BridgeError.message("Private composer contents")) == "native-or-readiness",
                     "Picker diagnostics must not copy private exception text or mislabel ownership cancellation as a missing button")
        precondition(DraftChoices.modelAndEffort("GPT-6.1 Sol Extra High")?.0 == "GPT-6.1 Sol")
        precondition(DraftChoices.modelAndEffort("Opus 5.5 Max")?.1 == "Max")
        precondition(DraftChoices.modelAndEffort("GPT-6.2\u{00a0}Sol\n High")?.0 == "GPT-6.2 Sol")
        // Actual M1 picker: Select model contains these two texts while its separate
        // slider says "GPT-6.2 Sol Standard, 2 of 6.". Found by Claude Opus 5.5.
        // Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
        let solSelection = DraftChoices.modelMenuSelection(["GPT-6.2 Sol", "Medium"])
        precondition(solSelection?.model == "GPT-6.2 Sol" && solSelection?.effort == "Medium")
        precondition(DraftChoices.modelMenuSelection(["Opus 5.5", "High"])?.effort == "High")
        precondition(DraftChoices.modelMenuSelection(["GPT-6.2\u{00a0}Sol", "Extra\nHigh"])?.effort == "Extra High")
        precondition(DraftChoices.modelMenuSelection(["GPT-6.2 Sol", "Standard"]) == nil, "Never guess an effort from the slider's label")
        precondition(DraftChoices.modelMenuSelection(["Opus 5.5", "Extended"]) == nil)
        precondition(DraftChoices.modelMenuSelection(["GPT-6.2 Sol"]) == nil)
        precondition(DraftChoices.modelMenuSelection(["GPT-6.2 Sol", "Medium", "High"]) == nil)
        precondition(DraftChoices.modelMenuSelection(["", "High"]) == nil)
        var menuReads = 0, menuPresses = 0
        let opened: Int = try CodexVoiceDraft.waitForModelMenu(group: {
            menuReads += 1
            return menuPresses == 1 && menuReads >= 4 ? 42 : nil
        }, pill: { menuReads >= 2 ? 7 : nil }, press: {
            precondition($0 == 7)
            menuPresses += 1
        })
        precondition(opened == 42 && menuReads == 4 && menuPresses == 1,
                     "A temporarily missing button and a delayed popover share one opening attempt")
        let alreadyOpen: Int = try CodexVoiceDraft.waitForModelMenu(group: { 42 },
            pill: { preconditionFailure("An open menu needs no button read") },
            press: { _ in preconditionFailure("An open menu must not be toggled") })
        precondition(alreadyOpen == 42)
        enum MenuInterrupted: Error { case input }
        do {
            let _: Int = try CodexVoiceDraft.waitForModelMenu(group: { throw MenuInterrupted.input },
                pill: { 7 }, press: { _ in preconditionFailure("Input cancellation must precede a press") })
            preconditionFailure("Input cancellation must propagate")
        } catch MenuInterrupted.input { }
        var failedPresses = 0
        do {
            let _: Int = try CodexVoiceDraft.waitForModelMenu(group: { nil }, pill: { 7 }, press: { _ in
                failedPresses += 1
                throw MenuInterrupted.input
            })
            preconditionFailure("A failed press must propagate")
        } catch MenuInterrupted.input { }
        precondition(failedPresses == 1)
        precondition(DraftChoices.modelAndEffort("Select effort") == nil)
        precondition(DraftChoices.speed("Speed Ultrafast") == "Ultrafast" && DraftChoices.speed("Ultrafast") == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml"), receipt = dir.appendingPathComponent("launch/receipt.json")
        let env = ["CODEX_HOME": dir.path, "HOME": dir.path, "PATH": "/usr/bin:/bin"]
        let generation = Date()
        let baseline = DraftChoices(model: "GPT-6.1 Sol", effort: "Extra High", speed: "Standard")
        let config = "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"xhigh\"\n"
        let observedTiers = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/CodexVoice/service-tiers-observed.json"))
        let catalogue = dir.appendingPathComponent("models_cache.json")
        try observedTiers.write(to: catalogue)
        let fixture = DraftFixture(baseline, file: file)
        let manager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in fixture }, generation: { _ in generation })
        try config.write(to: file, atomically: true, encoding: .utf8)
        let id = UUID(), sent = Date()
        try await manager.prepare(id, executable: executable, environment: env, runningPID: 57)
        precondition(fixture.selection == .voice && !fixture.closed)
        try await manager.finish(id, sent: sent, executable: executable, environment: env)
        try await manager.observedSessionStart(sent.addingTimeInterval(-1), executable: executable, environment: env)
        precondition(fixture.selection == .voice && !fixture.closed)
        try await manager.observedSessionStart(sent.addingTimeInterval(1), executable: executable, environment: env)
        let restored = try String(contentsOf: file, encoding: .utf8)
        precondition(fixture.selection == baseline && fixture.closed && restored == config)

        let second = UUID()
        try await manager.prepare(second, executable: executable, environment: env, runningPID: 57)
        try fixture.selectEffort("Medium")
        try await manager.finish(second, sent: nil, executable: executable, environment: env)
        precondition(fixture.selection == DraftChoices(model: baseline.model, effort: "Medium", speed: baseline.speed))
        fixture.rejectSpeed = true
        do {
            try await manager.prepare(UUID(), executable: executable, environment: env, runningPID: 57)
            preconditionFailure("A rejected picker selection must not dispatch Voice")
        } catch { }
        precondition(fixture.selection == DraftChoices(model: baseline.model, effort: "Medium", speed: baseline.speed))
        precondition(!FileManager.default.fileExists(atPath: receipt.path))

        fixture.rejectSpeed = false
        try fixture.selectEffort("Max"); fixture.interruptEffort = true
        do {
            try await manager.prepare(UUID(), executable: executable, environment: env, runningPID: 57)
            preconditionFailure("The second step was interrupted")
        } catch { }
        precondition(fixture.selection == DraftChoices(model: baseline.model, effort: "Max", speed: baseline.speed))
        precondition(!FileManager.default.fileExists(atPath: receipt.path))
        fixture.interruptEffort = false

        // When the user adopts the window, recover settings in a new empty draft.
        let adopted = DraftFixture(baseline, file: file)
        let replacement = DraftFixture(.voice, file: file)
        let reopened = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in
            adopted.adopted ? replacement : adopted
        }, generation: { _ in generation })
        try config.write(to: file, atomically: true, encoding: .utf8)
        let adoptedID = UUID()
        try await reopened.prepare(adoptedID, executable: executable, environment: env, runningPID: 57)
        adopted.adopted = true
        try await reopened.finish(adoptedID, sent: nil, executable: executable, environment: env)
        precondition(!adopted.closed && replacement.closed && replacement.selection == baseline)
        let afterAdoption = try String(contentsOf: file, encoding: .utf8)
        precondition(afterAdoption == config)

        let stale = DraftFixture(baseline, file: file)
        let userPick = DraftFixture(DraftChoices(model: DraftChoices.voice.model, effort: "Medium", speed: "Ultrafast"), file: file)
        var opens = 0
        let otherComposer = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in
            opens += 1
            return opens == 1 ? stale : userPick
        }, generation: { _ in generation })
        let third = UUID()
        try await otherComposer.prepare(third, executable: executable, environment: env, runningPID: 57)
        try userPick.selectEffort("Medium") // Other window edited the shared preference; original picker is stale.
        try await otherComposer.finish(third, sent: nil, executable: executable, environment: env)
        precondition(opens == 2 && stale.closed && userPick.closed)
        precondition(userPick.selection == DraftChoices(model: baseline.model, effort: "Medium", speed: baseline.speed))

        let originalAgain = UUID()
        opens = 0
        stale.selection = baseline
        try config.write(to: file, atomically: true, encoding: .utf8)
        try await otherComposer.prepare(originalAgain, executable: executable, environment: env, runningPID: 57)
        userPick.selection = .voice
        try userPick.selectEffort(baseline.effort)
        try await otherComposer.finish(originalAgain, sent: nil, executable: executable, environment: env)
        precondition(userPick.selection == baseline && userPick.closed, "A manual return to the ordinary setting wins")

        let speedless = DraftFixture(.init(model: "Opus 5.5", effort: "High", speed: "Standard"), file: file)
        speedless.delayedPersistence = true
        speedless.speedlessModel = "Opus 5.5"
        let hiddenConfig = "model = \"opus-5.5\"\nmodel_reasoning_effort = \"high\"\n"
        try hiddenConfig.write(to: file, atomically: true, encoding: .utf8)
        let hidden = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in speedless }, generation: { _ in generation })
        let fourth = UUID()
        try await hidden.prepare(fourth, executable: executable, environment: env, runningPID: 57)
        precondition(speedless.selection == .voice)
        try await hidden.finish(fourth, sent: nil, executable: executable, environment: env)
        precondition(speedless.selection == DraftChoices(model: "Opus 5.5", effort: "High", speed: "Standard"))
        let hiddenRestored = try String(contentsOf: file, encoding: .utf8)
        precondition(hiddenRestored.split(separator: "\n").sorted() == hiddenConfig.split(separator: "\n").sorted() && speedless.closed)

        let interrupted = DraftFixture(baseline, file: file)
        interrupted.adoptBeforeModelSaves = true
        let recoveryPicker = DraftFixture(.init(model: DraftChoices.voice.model, effort: baseline.effort, speed: baseline.speed), file: file)
        let pending = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in
            interrupted.adopted ? recoveryPicker : interrupted
        }, generation: { _ in generation })
        try config.write(to: file, atomically: true, encoding: .utf8)
        do {
            try await pending.prepare(UUID(), executable: executable, environment: env, runningPID: 57)
            preconditionFailure("User input interrupted the native selection")
        } catch { }
        precondition(FileManager.default.fileExists(atPath: receipt.path), "A pending native write must keep its recovery record when the user adopts the draft")
        precondition(!interrupted.closed && !recoveryPicker.closed)
        try interrupted.put("model", CodexVoiceSpeed.model)
        try await pending.recover(executable: executable, environment: env)
        precondition(recoveryPicker.selection == baseline && recoveryPicker.closed)
        precondition(!FileManager.default.fileExists(atPath: receipt.path))

        fixture.selection = .voice; fixture.closed = false
        let same = UUID()
        try await manager.prepare(same, executable: executable, environment: env, runningPID: 57)
        precondition(!fixture.closed && !FileManager.default.fileExists(atPath: receipt.path))
        try await manager.finish(same, sent: nil, executable: executable, environment: env)
        precondition(fixture.closed && !FileManager.default.fileExists(atPath: receipt.path))
        // Existing-chat speed must leave ordinary model, effort and inherited defaults intact.
        for speed in CodexChatSpeed.Speed.allCases {
            let speedFixture = DraftFixture(baseline, file: file)
            let speedManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in speedFixture }, generation: { _ in generation })
            try config.write(to: file, atomically: true, encoding: .utf8)
            let thread = UUID()
            let action = await speedManager.preservingSpeedDefaults(thread: thread, speed: speed, pid: 57, executable: executable, environment: env) {
                precondition(speedFixture.selection.model == baseline.model && speedFixture.selection.effort == baseline.effort,
                             "Speed-only preparation must not touch ordinary model or effort")
                precondition(speedFixture.selection.speed == speed.rawValue)
                return .init(status: "confirmed", thread: thread, speed: speed, model: "Target model stays unchanged")
            }
            precondition(action.succeeded && speedFixture.selection == baseline && speedFixture.closed)
            let restored = try String(contentsOf: file, encoding: .utf8)
            precondition(restored == config, "Missing inherited tier must be removed, not saved as Standard")
        }
        let already = DraftFixture(.init(model: baseline.model, effort: baseline.effort, speed: "Ultrafast"), file: file)
        let alreadyManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in already }, generation: { _ in generation })
        try config.write(to: file, atomically: true, encoding: .utf8)
        let exact = UUID()
        let selected = await alreadyManager.preservingSpeedDefaults(thread: exact, speed: .ultrafast, pid: 57, executable: executable, environment: env) {
            try! already.put("service_tier", "ultrafast") // Existing-chat handler also saves the default.
            return .init(status: "confirmed", thread: exact, speed: .ultrafast, model: baseline.model)
        }
        precondition(selected.succeeded && already.selection.speed == "Ultrafast" && already.closed)
        let rawRestored = try String(contentsOf: file, encoding: .utf8)
        precondition(rawRestored == config, "Keep a differing warm UI and saved inherited default exactly as found")
        for rawOriginal in [config, config + "service_tier = \"default\"\n"] {
            let fast = DraftFixture(.init(model: baseline.model, effort: baseline.effort, speed: "Fast"), file: file)
            let fastManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in fast }, generation: { _ in generation })
            try rawOriginal.write(to: file, atomically: true, encoding: .utf8)
            let outcome = await fastManager.preservingSpeedDefaults(thread: exact, speed: .ultrafast, pid: 57,
                executable: executable, environment: env) {
                precondition(fast.selection.speed == "Ultrafast")
                return .init(status: "confirmed", thread: exact, speed: .ultrafast, model: baseline.model)
            }
            precondition(outcome.succeeded && fast.selection.speed == "Fast" && fast.closed)
            let restored = try String(contentsOf: file, encoding: .utf8)
            precondition(restored == rawOriginal, "Restore native Fast/priority and then its exact inherited or explicit raw default")
        }
        // Missing/ambiguous model metadata is not permission to guess a tier ID.
        for badCatalogue in [#"{"models":[]}"#,
            #"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","service_tiers":[{"id":"priority","name":"Fast"},{"id":"other","name":"Fast"}]}]}"#] {
            try badCatalogue.write(to: catalogue, atomically: true, encoding: .utf8)
            try config.write(to: file, atomically: true, encoding: .utf8)
            let unresolved = DraftFixture(baseline, file: file)
            let unresolvedManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in unresolved }, generation: { _ in generation })
            let refused = await unresolvedManager.preservingSpeedDefaults(thread: exact, speed: .fast, pid: 57,
                executable: executable, environment: env) { fatalError("Unknown tier metadata must prevent any target action") }
            let unchanged = try String(contentsOf: file, encoding: .utf8)
            precondition(!refused.succeeded && unchanged == config && unresolved.selection == baseline && unresolved.closed)
            precondition(!FileManager.default.fileExists(atPath: receipt.path))
        }
        try observedTiers.write(to: catalogue)
        let locked = DraftFixture(baseline, file: file)
        let lockedManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in locked }, generation: { _ in generation })
        try config.write(to: file, atomically: true, encoding: .utf8)
        let firstSpeed = await lockedManager.preservingSpeedDefaults(thread: exact, speed: .ultrafast, pid: 57, executable: executable, environment: env) {
            let secondSpeed = await lockedManager.preservingSpeedDefaults(thread: UUID(), speed: .fast, pid: 57, executable: executable, environment: env) {
                fatalError("A second defaults owner must never act")
            }
            precondition(secondSpeed.status == "busy")
            return .init(status: "unconfirmed", thread: exact, speed: nil, model: nil)
        }
        precondition(firstSpeed.status == "unconfirmed" && locked.selection == baseline && locked.closed)
        let noOpManager = CodexVoiceSpeed(receipt: receipt, openDraft: { _ in fatalError("An already-selected speed must never open a draft") }, generation: { _ in generation })
        let noOp = await noOpManager.preservingSpeedDefaults(thread: exact, speed: .ultrafast, pid: 57, executable: executable, environment: env,
            inspect: { .init(status: "observed", thread: exact, speed: .ultrafast, model: baseline.model) }) {
                fatalError("An already-selected speed must never dispatch a second selection")
            }
        precondition(noOp.status == "unchanged")
        let lease = open(receipt.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        precondition(lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0)
        let foreignOwner = await alreadyManager.preservingSpeedDefaults(thread: exact, speed: .ultrafast,
            pid: 57, executable: executable, environment: env) { fatalError("A foreign defaults lease must prevent any native action") }
        precondition(foreignOwner.status == "unavailable")
        let blockedRead = await alreadyManager.observe(thread: exact)
        precondition(blockedRead.status == "unavailable")
        flock(lease, LOCK_UN); close(lease)
        precondition(!FileManager.default.fileExists(atPath: receipt.path), "The foreign lease must not create a competing recovery record")
        print("Passed warm native picker selection, fresh session boundary, inherited speed restore, manual overrides, partial failure, interrupted slider steps, user-adopted windows and no-op checks")
    }
    // Real configuration protocol, isolated from all user config and login data.
    static func temporaryVoiceDefaults(executable: URL) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["CODEX_HOME": dir.path, "PATH": "/usr/bin:/bin", "HOME": dir.path]
        let file = dir.appendingPathComponent("config.toml"), receipt = dir.appendingPathComponent("launch/receipt.json")
        let manager = CodexVoiceSpeed(receipt: receipt)
        let original = "model_reasoning_effort = \"max\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let start = Date(), id = UUID()
        try await manager.prepare(id, executable: executable, environment: env)
        let prepared = try String(contentsOf: file, encoding: .utf8)
        precondition(prepared.contains(CodexVoiceSpeed.model) && prepared.contains(CodexVoiceSpeed.tier)
                     && prepared.contains("model_reasoning_effort = \"high\""))
        try await manager.finish(id, sent: start, executable: executable, environment: env)
        try await manager.observedSessionStart(start.addingTimeInterval(-1), executable: executable, environment: env)
        precondition(FileManager.default.fileExists(atPath: receipt.path))
        try await manager.observedSessionStart(start.addingTimeInterval(1), executable: executable, environment: env)
        let restored = try String(contentsOf: file, encoding: .utf8)
        precondition(restored == original && !FileManager.default.fileExists(atPath: receipt.path))
        let next = UUID()
        try await manager.prepare(next, executable: executable, environment: env)
        let manual = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: CodexVoiceSpeed.model, with: "gpt-6.1-sol").replacingOccurrences(of: "\"high\"", with: "\"medium\"")
        try manual.write(to: file, atomically: true, encoding: .utf8)
        let restarted = CodexVoiceSpeed(receipt: receipt)
        do {
            try await restarted.recover(executable: executable, environment: env)
            preconditionFailure("A live defaults owner must not be recovered by a second process")
        } catch {}
        // Simulate the persisted bytes left by a dead process, after releasing the
        // original live test owner's native lock; no actual app/process is killed.
        let abandoned = try Data(contentsOf: receipt)
        try await manager.finish(next, sent: nil, executable: executable, environment: env)
        try manual.write(to: file, atomically: true, encoding: .utf8)
        try abandoned.write(to: receipt, options: .atomic)
        try await restarted.recover(executable: executable, environment: env)
        let after = try String(contentsOf: file, encoding: .utf8)
        precondition(after.contains("gpt-6.1-sol") && after.contains("model_reasoning_effort = \"medium\"") && !after.contains("service_tier"))
        let timeoutID = UUID()
        try await restarted.prepare(timeoutID, executable: executable, environment: env)
        try await restarted.finish(timeoutID, sent: Date(), executable: executable, environment: env, timeout: 0.01)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: receipt.path) { try await Task.sleep(for: .milliseconds(25)) }
        precondition(!FileManager.default.fileExists(atPath: receipt.path))
        let timedOut = try String(contentsOf: file, encoding: .utf8)
        precondition(timedOut == after)
        print("Passed isolated native Codex launch-default writes, session boundary, rollback, crash recovery and manual override checks")
    }
}
