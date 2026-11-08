import Foundation

@main enum NativeVoiceTests {
    @MainActor static func main() async throws {
        func state(_ mic: MicrophoneState? = nil, input: Bool = false, allowed: Bool = true) -> VoiceSnapshot {
            VoiceSnapshot(pid: 123, inputRunning: input || mic != nil, recorderRunning: false,
                          microphone: mic, accessibilityAllowed: allowed)
        }
        var toggledState = state(.listening), toggles: [MicrophoneState] = []
        let toggledVoice = NativeVoice(transport: .init(snapshot: { toggledState },
            send: { command, pid in
                precondition(command == VoiceBridge.muteCommand && pid == 123, "Microphone phrases send only the microphone shortcut")
                guard let current = toggledState.microphone else { preconditionFailure("Fixture requires an active microphone") }
                toggles.append(current)
                toggledState = state(current == .listening ? .muted : .listening)
            }, activate: { pid in precondition(pid == 123) }))
        let muted = try await toggledVoice.toggleMicrophone()
        precondition(muted == .muted && toggledVoice.connected, "Adopt an externally started call and mute without ending it")
        let unmuted = try await toggledVoice.toggleMicrophone()
        precondition(unmuted == .listening && toggles == [.listening, .muted], "Second command unmutes exactly once")
        for unavailable in [state(), state(.muted, allowed: false)] {
            toggledState = unavailable
            do { _ = try await toggledVoice.toggleMicrophone(); fatalError("Unknown/off/denied Voice accepted toggle") }
            catch is BridgeError { }
        }
        precondition(toggles.count == 2, "Unavailable controls never send a toggle or start a call")
        var unknownSends = 0
        let unknownMicrophoneToggle = NativeVoice(transport: .init(snapshot: { state(input: true) },
            send: { command, pid in
                precondition(command == VoiceBridge.muteCommand && pid == 123)
                unknownSends += 1
            }, activate: { _ in }))
        do { _ = try await unknownMicrophoneToggle.toggleMicrophone(); fatalError("Missing labels cannot prove a muted state") }
        catch is BridgeError { }
        precondition(unknownSends == 1, "Current call/input with missing AX labels still sends exactly one microphone shortcut")

        var discoveredState = state(input: true)
        let discoveredMicrophone = NativeVoice(transport: .init(snapshot: { discoveredState },
            send: { command, _ in
                precondition(command == VoiceBridge.muteCommand)
                discoveredState = state(.muted)
            }, activate: { _ in }))
        let discovered = try await discoveredMicrophone.toggleMicrophone()
        precondition(discovered == .muted, "A newly exposed native state confirms the explicit action")

        var closedDuringActivation = state(input: true)
        let closedMicrophone = NativeVoice(transport: .init(snapshot: { closedDuringActivation },
            send: { _, _ in fatalError("A closed call must not receive a shortcut") },
            activate: { _ in closedDuringActivation = state() }))
        do { _ = try await closedMicrophone.toggleMicrophone(); fatalError("Call closure must invalidate delivery") }
        catch is BridgeError { }
        toggledState = state(.listening)
        toggledVoice.detachForQuit()
        do { _ = try await toggledVoice.toggleMicrophone(); fatalError("Detached helper accepted toggle") }
        catch is CancellationError { }
        precondition(toggles.count == 2, "Quit preserves the active microphone")
        let unconfirmedToggle = NativeVoice(transport: .init(snapshot: { state(.listening) },
            send: { command, _ in precondition(command == VoiceBridge.muteCommand) },
            activate: { _ in }))
        do { _ = try await unconfirmedToggle.toggleMicrophone(); fatalError("Unchanged controls were reported as muted") }
        catch is BridgeError { }

        var changedMicrophone = state(.listening)
        let changedBeforeDelivery = NativeVoice(transport: .init(snapshot: { changedMicrophone },
            send: { _, _ in fatalError("A manual microphone change during activation must cancel the shortcut") },
            activate: { _ in changedMicrophone = state(.muted) }))
        do { _ = try await changedBeforeDelivery.toggleMicrophone(); fatalError("Stale microphone state accepted") }
        catch is BridgeError { }
        var failedSends = 0
        let failedMicrophone = NativeVoice(transport: .init(snapshot: { state(.listening) },
            send: { command, _ in
                precondition(command == VoiceBridge.muteCommand); failedSends += 1
                throw BridgeError.message("Voice shortcuts saved. Restart Codex to apply them.")
            }, activate: { _ in }))
        do { _ = try await failedMicrophone.toggleMicrophone(); fatalError("Pending shortcut must remain an error") }
        catch is BridgeError { }
        precondition(failedSends == 1, "An unregistered shortcut must not retry or fall back to AXPress")

        var mailboxState = state(), mailboxEvents: [String] = []
        let mailboxContext = VoiceStartContext()
        mailboxContext.prepareNewCall = { mailboxEvents.append("mailbox") }
        let mailboxVoice = NativeVoice(transport: .init(snapshot: { mailboxState }, send: { command, _ in
            mailboxEvents.append(command); mailboxState = state(.listening)
        }, activate: { _ in fatalError("Global Start must not make Codex frontmost") }))
        _ = try await mailboxVoice.start(context: mailboxContext)
        precondition(mailboxEvents == ["mailbox", VoiceBridge.startCommand] && mailboxContext.requestedNewCall)
        let reusedMailboxContext = VoiceStartContext()
        reusedMailboxContext.prepareNewCall = { fatalError("Reusing a live call must not replace startup speech") }
        _ = try await mailboxVoice.start(context: reusedMailboxContext)
        precondition(!reusedMailboxContext.requestedNewCall)
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
        let voice = NativeVoice(transport: .init(snapshot: { current }, send: { command, _ in
            sent.append(command)
            if command == VoiceBridge.muteCommand { current = state(.listening) }
            else { current = current.microphone == nil ? state(.listening) : state() }
        }, activate: { _ in }, unmute: { _ in
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
        let openedMicrophone = try await voice.start(onRequestAccepted: { startCues += 1 })
        precondition(openedMicrophone == .muted, "Start returns fresh state so callers can skip a redundant snapshot when already listening")
        precondition(sent.count == beforeMutedWake, "Hello Chat adopts an existing muted call without sending the new-chat shortcut")
        try await voice.setMicrophone(.listening)
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
        }, activate: { _ in }, launch: { launched = true; launchCount += 1 }), minimumLaunchWait: 0)
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

        // An exact End action establishes a call, but not its microphone state.
        // Confirm the call without guessing a microphone state or toggling it.
        var endOnlyState = state(.listening)
        let endOnly = NativeVoice(transport: .init(snapshot: { endOnlyState }, send: { _, _ in
            fatalError("Unknown existing microphone must not authorize a start or cleanup End")
        }, activate: { _ in fatalError("Existing End-only call must not activate a start") }))
        _ = try await endOnly.start() // Establish a stale cached connected flag.
        endOnlyState = state(); endOnlyState.endControlAvailable = true
        var endOnlyCues = 0
        let unknownMicrophone = try await endOnly.start(onRequestAccepted: { endOnlyCues += 1 })
        precondition(endOnlyCues == 1, "An accepted End-only reuse still acknowledges the wake")
        precondition(unknownMicrophone == nil && endOnly.connected,
                     "Exact existing End confirms Voice while preserving unknown microphone state and sending nothing")

        var newlyOpened = state()
        var newlyOpenedCommands: [String] = []
        let newlyEndOnly = NativeVoice(transport: .init(snapshot: { newlyOpened }, send: { command, _ in
            newlyOpenedCommands.append(command)
            if command == VoiceBridge.startCommand { newlyOpened.endControlAvailable = true }
            else if command == VoiceBridge.endCommand { newlyOpened = state() }
            else { fatalError("Unknown microphone must never authorize a mute toggle") }
        }, activate: { _ in }))
        let newUnknownMicrophone = try await newlyEndOnly.start()
        precondition(newUnknownMicrophone == nil && newlyEndOnly.connected && newlyOpenedCommands == [VoiceBridge.startCommand],
                     "Our own start is confirmed by End without timing out or immediately ending the successful call")
        let endedNewUnknown = try await newlyEndOnly.endIfPresent()
        precondition(endedNewUnknown && newlyOpenedCommands == [VoiceBridge.startCommand, VoiceBridge.endCommand] && !newlyEndOnly.connected,
                     "A call with unknown mic state still supports explicit End")

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
        print("Passed native Voice transport checks including stale closed-call and active-call cleanup. No desktop events or real calls sent.")
    }
}
