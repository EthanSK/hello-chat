import Foundation

@main enum NativeVoiceTests {
    @MainActor static func main() async throws {
        func state(_ mic: MicrophoneState? = nil, input: Bool = false, allowed: Bool = true) -> VoiceSnapshot {
            VoiceSnapshot(pid: 123, inputRunning: input || mic != nil, recorderRunning: false,
                          microphone: mic, accessibilityAllowed: allowed)
        }
        var current = state()
        var sent: [String] = []
        let voice = NativeVoice(transport: .init(snapshot: { current }, send: { command, _ in
            sent.append(command)
            if command == VoiceBridge.muteCommand { current = state(.listening) }
            else { current = current.microphone == nil ? state(.listening) : state() }
        }, activate: { _ in }))
        var newCallCues = 0
        try await voice.start(onNewCall: { newCallCues += 1 })
        precondition(newCallCues == 1, "New native Voice gets its start cue")
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
        let openedMicrophone = try await voice.start(onNewCall: { newCallCues += 1 })
        precondition(openedMicrophone == .muted, "Start returns fresh state so callers can skip a redundant snapshot when already listening")
        precondition(sent.count == beforeMutedWake, "Hello Chat adopts an existing muted call without sending the new-chat shortcut")
        try await voice.setMicrophone(.listening)
        precondition(Array(sent.dropFirst(beforeMutedWake)) == [VoiceBridge.muteCommand], "Hello Chat sends only unmute for an existing muted native call")
        precondition(newCallCues == 1, "Existing muted Voice is unmuted without another boot sound")
        let beforeRepeatedWake = sent.count
        let alreadyListening = try await voice.start(onNewCall: { newCallCues += 1 })
        precondition(alreadyListening == .listening, "Repeated Hello Chat sees the same unmuted Voice call")
        try await voice.setMicrophone(.listening)
        precondition(sent.count == beforeRepeatedWake, "Repeated Hello Chat neither creates another chat nor remutes the current call")
        precondition(newCallCues == 1, "Existing listening Voice remains quiet without a fixed expiry timer")
        await voice.stop()
        current = state(input: true)
        let beforeResidualStart = sent.count
        _ = try await voice.start()
        precondition(voice.connected && sent.count == beforeResidualStart + 1 && sent.last == VoiceBridge.startCommand,
                     "Residual process input must not block an explicit start after a complete absent Voice-control scan")
        await voice.stop()
        let count = sent.count
        current = state(); current.controlsComplete = false
        do { try await voice.start(); fatalError("An incomplete scan cannot establish Voice is off") }
        catch is BridgeError { }
        precondition(sent.count == count, "Timeout or traversal cap must never authorize a start toggle")
        current = state(input: true); current.controlsComplete = false
        do { try await voice.start(); fatalError("Input activity must not authorize a start after an incomplete scan") }
        catch is BridgeError { }
        precondition(sent.count == count, "Incomplete Voice controls still block even when process input is active")
        var transientReads = 0
        let transient = NativeVoice(transport: .init(snapshot: {
            transientReads += 1
            var value = state(.muted)
            if transientReads == 1 { value = state(input: true); value.controlsComplete = false }
            return value
        }, send: { _, _ in fatalError("A recovered existing muted call must not be toggled") }, activate: { _ in }))
        let recoveredMicrophone = try await transient.start(onNewCall: { fatalError("Recovered existing call must not play a startup cue") })
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
        let timedOutOpening = NativeVoice(transport: .init(snapshot: {
            if timeoutRecovered { return state(.listening) }
            var value = state()
            if timeoutStarted { value.pid = nil; value.controlsComplete = false }
            return value
        }, send: { command, _ in timeoutCommands.append(command); timeoutStarted = true }, activate: { _ in }), confirmationTimeout: 0.05)
        do { _ = try await timedOutOpening.start(); fatalError("Unknown opening must remain bounded") }
        catch { await timedOutOpening.recoverFromStartFailure(error) }
        await timedOutOpening.stop()
        precondition(timeoutCommands == [VoiceBridge.startCommand] && !timedOutOpening.connected,
                     "An opening timeout releases stale ownership without ending a possibly working call")
        timeoutRecovered = true
        _ = try await timedOutOpening.start()
        precondition(timedOutOpening.connected && timeoutCommands == [VoiceBridge.startCommand],
                     "The next wake adopts the late successful call without creating another chat")

        var replacementStarted = false, replacementCommands: [String] = []
        let replacedOpening = NativeVoice(transport: .init(snapshot: {
            var value = state()
            if replacementStarted { value.pid = 456; value.endControlAvailable = true }
            return value
        }, send: { command, _ in replacementCommands.append(command); replacementStarted = true }, activate: { _ in }))
        do { _ = try await replacedOpening.start(); fatalError("A different process cannot confirm our opening") }
        catch { await replacedOpening.recoverFromStartFailure(error) }
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
            do { try await cancelled.start() }
            catch { await cancelled.recoverFromStartFailure(error) }
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
        let inFlight = NativeVoice(transport: .init(snapshot: { asynchronous }, send: { command, _ in
            asynchronousSends.append(command)
            if command == VoiceBridge.startCommand {
                try await Task.detached { try await Task.sleep(nanoseconds: 400_000_000) }.value
                asynchronous = state(.listening)
            } else { asynchronous = state() }
        }, activate: { _ in }))
        let sending = Task { @MainActor in
            do { try await inFlight.start() }
            catch { await inFlight.recoverFromStartFailure(error) }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        sending.cancel()
        await inFlight.stop(); await sending.value
        precondition(asynchronousSends == [VoiceBridge.startCommand, VoiceBridge.endCommand] && !inFlight.connected,
                     "Cancellation during an asynchronous send cannot leave an owned call running")

        // An exact End action establishes a call, but not its microphone state.
        // Confirm the call without guessing a microphone state or toggling it.
        var endOnlyState = state(.listening)
        let endOnly = NativeVoice(transport: .init(snapshot: { endOnlyState }, send: { _, _ in
            fatalError("Unknown existing microphone must not authorize a start or cleanup End")
        }, activate: { _ in fatalError("Existing End-only call must not activate a start") }))
        _ = try await endOnly.start() // Establish a stale cached connected flag.
        endOnlyState = state(); endOnlyState.endControlAvailable = true
        let unknownMicrophone = try await endOnly.start(onNewCall: { fatalError("End-only active Voice must not play a startup cue") })
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
        print("Passed native Voice transport checks including stale closed-call and active-call cleanup. No desktop events or real calls sent.")
    }
}
