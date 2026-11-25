// Coordinate one native Voice request, with fresh call checks and bounded readiness.
import AppKit
import Foundation

// Cancellation is owned by the specific opening task, so a later wake cannot
// overwrite an environmental pause's instruction to preserve the current call.
@MainActor final class VoiceStartContext {
    let id = UUID()
    private let remoteOwner: (request: UUID, generation: UUID)?
    private(set) var remoteCancelled = false
    private(set) var resolvedCall = false
    var preserveCallOnCancellation = false
    var beforeRemoteDispatch: (() throws -> Void)?
    var prepareNewCall: (() async -> Void)?
    var sentAt: Date?
    var defaultsExecutable: URL?
    private(set) var requestedNewCall = false
    init(remoteOwner: (request: UUID, generation: UUID)? = nil) { self.remoteOwner = remoteOwner }
    func matches(request: UUID, generation: UUID) -> Bool {
        remoteOwner?.request == request && remoteOwner?.generation == generation
    }
    func didResolveCall() { resolvedCall = true }
    func withdrawBeforeNativeStart() {
        preserveCallOnCancellation = true
        remoteCancelled = true
    }
    func didRequestNewCall() { requestedNewCall = true }
}

// Codex owns the conversation, audio and UI. HelloChat has no WebRTC client and
// uses a configuration-only client for the shared speed. Start uses Codex's global "Voice chat hotkey"; the
// composer's "Toggle voice chat" remains untouched. End stays dedicated.
@MainActor final class NativeVoice {
    struct Transport {
        var snapshot: () async -> VoiceSnapshot
        var send: (String, Int32) async throws -> Void
        var activate: (Int32) throws -> Void
        var requestEnd: (() async throws -> Int32?)? = nil
        var retryEnd: ((Int32) async throws -> Void)? = nil
        var launch: (() async throws -> Void)? = nil
        var unmute: ((Int32) async throws -> Void)? = nil
        var startSession: () -> DesktopSessionState = { .interactive }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        var guardedShortcut: ((String, Int32, @escaping () throws -> Void) async throws -> Void)? = nil
        var audioTargetPID: () -> Int32? = { nil }
        var prepareNewVoiceSpeed: (@MainActor (Int32?, VoiceStartContext) async throws -> Void)? = nil
        var finishLaunchDefaults: (@MainActor (VoiceStartContext, Date?) async throws -> Void)? = nil
        static var live: Self {
            Self(snapshot: {
                    await Task.detached(priority: .utility) {
                        var state = VoiceBridge.snapshot()
                        if state.accessibilityAllowed, state.microphone == nil,
                           let pid = state.pid, let app = VoiceBridge.currentApplication(),
                           app.processIdentifier == pid, let launchDate = app.launchDate {
                            state.savedVoiceActive = VoiceTimeline.activeSessions(
                                database: VoiceTimeline.databaseURL(), since: launchDate).map { !$0.isEmpty }
                        }
                        return state
                    }.value
                 },
                 send: { command, pid in
                    try await Task.detached(priority: .userInitiated) {
                        if command == VoiceBridge.endCommand {
                            try VoiceBridge.endCall(pid: pid, record: { event, numbers, info in
                                Diagnostics.shared.record(event, numbers: numbers, info: info)
                            })
                        }
                        else {
                            try VoiceBridge.post(command: command, pid: pid, record: { event, numbers, info in
                                Diagnostics.shared.record(event, numbers: numbers, info: info)
                            })
                        }
                    }.value
                 },
                 activate: { pid in
                    guard let app = VoiceBridge.currentApplication(), app.processIdentifier == pid else {
                        throw BridgeError.message("Open Codex, then try again.")
                    }
                    app.activate(options: [])
                 }, requestEnd: {
                    try await Task.detached(priority: .userInitiated) {
                        try VoiceBridge.requestActiveEnd(verifyCall: VoiceCallMembership.validator(), record: { event, numbers, info in
                            Diagnostics.shared.record(event, numbers: numbers, info: info)
                        })
                    }.value
                 }, retryEnd: { pid in
                    try await Task.detached(priority: .userInitiated) {
                        try VoiceBridge.pressEnd(pid: pid)
                    }.value
                 }, launch: { try await VoiceBridge.launchCodex() }, unmute: { pid in
                    try await Task.detached(priority: .userInitiated) {
                        try VoiceBridge.pressUnmute(pid: pid, record: { event, numbers, info in
                            Diagnostics.shared.record(event, numbers: numbers, info: info)
                        })
                    }.value
                 }, startSession: { .current },
                 guardedShortcut: { command, pid, check in
                    try await Task.detached(priority: .userInitiated) { try VoiceBridge.post(command: command, pid: pid, beforePost: check) }.value
                 }, audioTargetPID: { VoiceBridge.currentApplication()?.processIdentifier },
                 prepareNewVoiceSpeed: { pid, opening in
                    guard UserDefaults.standard.object(forKey: CodexVoiceSpeed.preferenceKey) as? Bool ?? true else { return }
                    let exe = try CodexVoiceSpeed.executable(pid: pid)
                    opening.defaultsExecutable = exe
                    try await CodexVoiceSpeed.shared.prepare(opening.id, executable: exe, runningPID: pid)
                    Diagnostics.shared.record("voice.defaults.prepared", info: [
                        "model": CodexVoiceSpeed.model, "effort": CodexVoiceSpeed.effort, "tier": CodexVoiceSpeed.tier
                    ])
                 }, finishLaunchDefaults: { opening, sent in
                    guard let exe = opening.defaultsExecutable else { return }
                    try await CodexVoiceSpeed.shared.finish(opening.id, sent: sent, executable: exe)
                 })
        }
    }
    private let transport: Transport
    private let diagnostics: Diagnostics?
    private let confirmationTimeout: TimeInterval
    private let launchTimeout: TimeInterval
    private let minimumLaunchWait: TimeInterval
    private let endConfirmationTimeout: TimeInterval
    private(set) var connected = false
    private(set) var lastError: String?
    private var pendingUntil: Date?
    private var pendingOpeningID: UUID?
    private var lastVoicePID: Int32?
    private var ending: Task<Bool, Error>?
    private var detachedForQuit = false

    init(transport: Transport = .live, diagnostics: Diagnostics? = nil, confirmationTimeout: TimeInterval = 15, launchTimeout: TimeInterval = 10, endConfirmationTimeout: TimeInterval = 8, minimumLaunchWait: TimeInterval = 5) {
        self.transport = transport; self.diagnostics = diagnostics; self.confirmationTimeout = confirmationTimeout
        self.launchTimeout = launchTimeout
        self.minimumLaunchWait = minimumLaunchWait
        self.endConfirmationTimeout = endConfirmationTimeout
    }

    // A confirmed call can still lack a readable microphone control.
    @discardableResult func start(context: VoiceStartContext? = nil, onRequestAccepted: () -> Void = {}) async throws -> MicrophoneState? {
        let opening = context ?? VoiceStartContext()
        let result: MicrophoneState?
        do { result = try await open(opening, onRequestAccepted: onRequestAccepted) }
        catch {
            try await transport.finishLaunchDefaults?(opening, nil)
            throw error
        }
        try await transport.finishLaunchDefaults?(opening, opening.requestedNewCall ? opening.sentAt : nil)
        return result
    }

    private func open(_ opening: VoiceStartContext, onRequestAccepted: () -> Void) async throws -> MicrophoneState? {
        try checkStartAllowed()
        try opening.beforeRemoteDispatch?()
        let starting = Diagnostics.now
        diagnostics?.record("voice.open.requested")
        // Ethan wants the start sound to acknowledge each accepted wake, even
        // when it reuses an open call. This confirms detection, not connection.
        // Do it before the potentially slow native-control scan, exactly once.
        onRequestAccepted()
        lastError = nil
        // A wake must establish ownership from fresh controls. In particular,
        // an End-only presentation doesn't tell us whether its mic is muted.
        connected = false
        var state = await snapshot()
        try checkStartAllowed()
        // Electron can replace an AX node during a read. Retry a bounded,
        // incomplete result before falling back to the explicit wake request.
        for _ in 0..<2 where state.accessibilityAllowed
            && state.microphone == nil && !state.endControlAvailable
            && (state.pid == nil || !state.controlsComplete) {
            try await Task.sleep(nanoseconds: 120_000_000)
            try checkStartAllowed()
            state = await snapshot()
            try checkStartAllowed()
        }
        guard state.accessibilityAllowed else {
            throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.")
        }
        let waitForApplication = state.pid == nil || state.applicationLaunching || !state.applicationHasWindow
            || (!state.applicationReady && state.controlsComplete)
        // A newly launched desktop can read its saved speed as soon as its renderer starts.
        let prepareBeforeLaunch = state.pid == nil && transport.launch != nil
        if prepareBeforeLaunch {
            try opening.beforeRemoteDispatch?()
            try await transport.prepareNewVoiceSpeed?(nil, opening)
            try checkStartAllowed()
        }
        var lastObservedPID = state.pid
        var relaunchedAfterExit = false
        var launchedAt = transport.now()
        var launchDeadline = launchedAt + launchTimeout
        if waitForApplication, let launch = transport.launch {
            try checkStartAllowed()
            diagnostics?.record("voice.application.launch_requested")
            try opening.beforeRemoteDispatch?()
            try await launch()
            try checkStartAllowed()
            state = await snapshot()
            if let pid = state.pid { lastObservedPID = pid }
        }
        // Ethan confirmed that a visible launch shell accepted Start too early.
        // After opening/reopening only, allow five seconds for registration and
        // require a real app action. An explicitly unready web shell must never
        // become ready merely because a timer expires.
        // Already-open chats retain their immediate path; no retry sends Start.
        while waitForApplication {
            if state.microphone != nil || state.endControlAvailable { break }
            let elapsed = transport.now() - launchedAt
            if state.pid != nil && !state.applicationLaunching && state.applicationHasWindow
                && state.applicationReady && elapsed >= minimumLaunchWait { break }
            guard transport.launch != nil, transport.now() < launchDeadline else {
                throw BridgeError.message("Codex didn't open. Try again.")
            }
            try checkStartAllowed()
            if state.pid == nil, lastObservedPID != nil, !relaunchedAfterExit, let launch = transport.launch {
                // A user restart can remove the old process after our first
                // reopen request. Retry launch once, never retry the Voice key.
                relaunchedAfterExit = true
                launchedAt = transport.now()
                // The replacement gets its own bounded readiness window. Its
                // five-second settling time must fit inside that window.
                launchDeadline = launchedAt + launchTimeout
                diagnostics?.record("voice.application.relaunch_after_exit")
                try opening.beforeRemoteDispatch?()
                try await launch()
                try checkStartAllowed()
                state = await snapshot()
                continue
            }
            try await transport.wait(0.3)
            state = await snapshot()
            if let pid = state.pid { lastObservedPID = pid }
        }
        try checkStartAllowed()
        if waitForApplication { diagnostics?.record("voice.application.ready") }
        guard let pid = state.pid else {
            throw BridgeError.message("Couldn't identify the active Codex window.")
        }
        guard state.accessibilityAllowed else {
            throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.")
        }
        if confirmOpening(state, context: opening, startedAt: starting) { return state.microphone }
        // Ethan's "Codex is using the microphone" false block: process audio
        // input can remain active after Voice closes, or belong to dictation.
        // Fresh positive Voice controls reuse the call; audio activity alone
        // does not block an explicit start.
        if state.inputRunning {
            diagnostics?.record("voice.input_activity.ignored", info: ["controls_complete": String(state.controlsComplete)])
        }
        let confirmationDeadline = Date().addingTimeInterval(confirmationTimeout)
        if state.endControlAvailable || state.savedVoiceActive == true { lastVoicePID = pid }
        if !state.endControlAvailable {
            // Ethan's "err on the side of trying to start" applies when AX
            // remains unknown after the bounded retries. Send one native
            // request, never a retry loop. Positive Voice controls above still
            // win, and End/cleanup retain their stricter ownership rules.
            if !state.controlsComplete {
                diagnostics?.record("voice.open.uncertain_fallback", info: ["scan_failure": state.scanFailure])
            }
            try checkStartAllowed()
            // Ethan's file handoff removes the need to make Codex frontmost or
            // navigate a composer. Start is already a global native action.
            // Keep the fresh reuse check, without the old activation delay.
            try opening.beforeRemoteDispatch?()
            if !prepareBeforeLaunch { try await transport.prepareNewVoiceSpeed?(pid, opening) }
            try checkStartAllowed()
            let activated = await snapshot()
            try checkStartAllowed()
            guard activated.pid == pid else { throw BridgeError.message("Codex closed while opening Voice.") }
            guard activated.accessibilityAllowed else {
                throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.")
            }
            if confirmOpening(activated, context: opening, startedAt: starting) { return activated.microphone }
            if waitForApplication, !activated.applicationReady || !activated.applicationHasWindow || activated.applicationLaunching {
                throw BridgeError.message("Codex didn't open. Try again.")
            }
            // The global Start shortcut can also cancel a pending or active
            // call. Respect any fresh reservation, and require a complete
            // negative scan before retrying a known call on the same process.
            if activated.endControlAvailable || activated.savedVoiceActive == true {
                lastVoicePID = pid
            } else if activated.controlsComplete || lastVoicePID != pid {
                pendingUntil = Date().addingTimeInterval(confirmationTimeout)
                pendingOpeningID = opening.id
                do {
                    await opening.prepareNewCall?()
                    try checkStartAllowed()
                    opening.sentAt = Date()
                    if let check = opening.beforeRemoteDispatch, let guarded = transport.guardedShortcut {
                        try await guarded(VoiceBridge.startCommand, pid, check)
                    } else {
                        try opening.beforeRemoteDispatch?()
                        try await transport.send(VoiceBridge.startCommand, pid)
                    }
                    lastVoicePID = pid
                    opening.didRequestNewCall()
                }
                catch { clearPendingOpening(ownedBy: opening.id); throw error }
                diagnostics?.record("voice.shortcut.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000],
                                    info: ["command": VoiceBridge.startCommand, "delivery": "global_hotkey"])
            }
        }
        try checkStartAllowed()
        while Date() < (pendingUntil ?? confirmationDeadline) {
            try checkStartAllowed()
            try await Task.sleep(nanoseconds: 300_000_000)
            let fresh = await snapshot()
            try checkStartAllowed()
            // A transient application lookup is unknown, not proof of exit.
            // Keep waiting for this start without resending its toggle.
            if fresh.pid == nil { continue }
            guard fresh.pid == pid else { throw BridgeError.message("Codex closed while opening Voice.") }
            if confirmOpening(fresh, context: opening, startedAt: starting) { return fresh.microphone }
        }
        throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
    }

    private func confirmOpening(_ state: VoiceSnapshot, context: VoiceStartContext, startedAt: TimeInterval) -> Bool {
        guard let evidence = state.voiceConnectionEvidence else { return false }
        context.didResolveCall()
        connected = true
        lastVoicePID = state.pid
        clearPendingOpening()
        diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - startedAt) * 1000],
                            info: ["microphone": state.microphone?.rawValue ?? "unknown", "confirmation": evidence])
        return true
    }

    func readStatus() async -> VoiceSnapshot { await snapshot() }

    func setMicrophone(_ state: MicrophoneState) async throws {
        try checkAttached()
        if state == .muted { _ = try await end() }
        else {
            try checkStartAllowed()
            guard connected else { throw BridgeError.message("Codex Voice is off.") }
            let fresh = await snapshot()
            guard let pid = fresh.pid, let microphone = fresh.microphone else {
                throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
            }
            if microphone == .listening { return }
            try checkStartAllowed() // Waking a muted existing call uses the same background key path as explicit Unmute.
            guard let unmute = transport.unmute else {
                throw BridgeError.message("Couldn't unmute chat. Use the microphone in Codex.")
            }
            try await unmute(pid)
            try await confirmAudio(.unmuteMicrophone, pid: pid)
        }
    }

    // Ethan's explicit mute/unmute phrases now mean one native toggle each.
    // Hidden Voice controls must not block them; dispatch does not confirm mute state. — GPT-6.1 Sol
    @discardableResult
    func setAudio(_ action: VoiceAudioAction, beforeShortcut: (() throws -> Void)? = nil, onRecognized: (() -> Void)? = nil) async throws -> Bool {
        try checkStartAllowed()
        guard let pid = transport.audioTargetPID() else {
            diagnostics?.record("voice.audio.skipped", info: ["action": action.rawValue, "reason": "codex_unavailable"])
            return false
        }
        onRecognized?()
        try checkStartAllowed()
        let command = action.controlsSpeakers ? VoiceBridge.outputMuteCommand : VoiceBridge.muteCommand
        let startedAt = Diagnostics.now
        diagnostics?.record("voice.audio.shortcut_attempted", info: ["action": action.rawValue, "command": command, "pid": String(pid)])
        do {
            if let beforeShortcut, let guarded = transport.guardedShortcut { try await guarded(command, pid, beforeShortcut) }
            else { try beforeShortcut?(); try await transport.send(command, pid) }
        }
        catch {
            diagnostics?.failure("voice.audio.shortcut_failed", error)
            throw error
        }
        diagnostics?.record(action.controlsSpeakers ? "voice.output.shortcut_sent" : "voice.microphone.shortcut_sent",
            numbers: ["ms": (Diagnostics.now - startedAt) * 1000],
            info: ["command": command, "action": action.rawValue, "pid": String(pid), "effect": "unverified"])
        try checkAttached()
        return true
    }

    private func confirmAudio(_ action: VoiceAudioAction, pid: Int32) async throws {
        // Native audio controls update asynchronously. Observe completion for at
        // most two seconds, returning immediately when it arrives; never resend
        // a toggle just because the first read still shows the previous state.
        let deadline = transport.now() + 2
        repeat {
            let confirmed = await snapshot()
            try checkAttached()
            if confirmed.applicationAbsent || (confirmed.pid != nil && confirmed.pid != pid) { break }
            if confirmed.pid == pid, action.isMuted(in: confirmed) == action.targetMuted {
                connected = true; lastError = nil
                return
            }
            let remaining = deadline - transport.now()
            guard remaining > 0 else { break }
            try await transport.wait(min(0.1, remaining))
        } while transport.now() <= deadline
        if action.controlsSpeakers { throw BridgeError.outputUnconfirmed }
        throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
    }

    // Normal H Chat Quit stops our control work, not the Codex conversation.
    // Set this before cancelling a pending start: its cancellation handler must
    // not interpret quitting as an explicit request to end a late-opened call.
    func detachForQuit() {
        detachedForQuit = true
        clearPendingOpening()
        connected = false
        lastError = nil
        ending?.cancel()
        ending = nil
        diagnostics?.record("voice.detached_for_quit")
    }
    func reattachAfterFailedUpdate() async -> MicrophoneState? {
        detachedForQuit = false
        return await refresh()
    }

    private func checkAttached() throws {
        try Task.checkCancellation()
        if detachedForQuit { throw CancellationError() }
    }

    private func checkStartAllowed() throws {
        try checkAttached()
        let session = transport.startSession()
        guard session == .interactive else {
            diagnostics?.record("voice.session.blocked", info: ["state": session.rawValue])
            throw BridgeError.desktopUnavailable(session)
        }
    }

    func stop() async {
        guard !detachedForQuit else { return }
        do { _ = try await end(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    // Ethan's "24/7" reliability: failed confirmation must not tear down a
    // working native call. Explicit End/off still clean up owned late openings;
    // normal Quit detaches and preserves the conversation instead.
    func recoverFromStartFailure(_ error: Error, context: VoiceStartContext) async {
        guard !detachedForQuit else { return }
        if context.preserveCallOnCancellation {
            clearPendingOpening(ownedBy: context.id)
            diagnostics?.record("voice.open.environment_pause_preserved")
            return
        }
        if error is CancellationError || Task.isCancelled { await stop() }
        else {
            clearPendingOpening(ownedBy: context.id)
            connected = false
            diagnostics?.record("voice.open.unconfirmed_preserved")
        }
    }

    private func clearPendingOpening(ownedBy id: UUID? = nil) {
        if let id, pendingOpeningID != id { return }
        pendingUntil = nil; pendingOpeningID = nil
    }

    // Ethan's 2 Nov Refresh button: one fresh read so HelloChat's on/off state
    // follows a call opened or closed in Codex itself. A read that finds no
    // Voice controls counts as off, even when incomplete ("if it can't tell,
    // just let it start"), so the button then offers Start. Sends nothing.
    func refresh() async -> MicrophoneState? {
        let state = await snapshot()
        connected = state.voiceConnectionEvidence != nil
        diagnostics?.record("voice.refresh", info: ["connected": String(connected), "complete": String(state.controlsComplete)])
        return state.microphone
    }

    // The already-running native call observer has confirmed an End. This only
    // invalidates the display cache: no scan, shortcut, detach or pending-call cleanup.
    // GateModel defers it around its own Start/End and discards older observations.
    @discardableResult func acceptObservedEnd() -> Bool {
        guard !detachedForQuit, ending == nil else { return false }
        connected = false
        lastVoicePID = nil
        return true
    }

    // A spoken end command may address a call opened directly in Codex. Adopt
    // only freshly identified Voice controls; cleanup never takes this path.
    @discardableResult func endIfPresent() async throws -> Bool {
        guard !detachedForQuit else { return false }
        if transport.requestEnd != nil, pendingUntil == nil { return try await end(explicit: true) }
        let state = await snapshot()
        guard state.accessibilityAllowed else { throw BridgeError.message("Allow Accessibility for Hello Chat in System Settings.") }
        if state.microphone != nil || state.endControlAvailable { connected = true }
        guard connected || pendingUntil != nil else {
            guard !state.inputRunning else { throw BridgeError.message("Couldn't confirm Codex Voice. Finish dictation or check Voice in Codex.") }
            guard state.controlsComplete else { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
            return false
        }
        return try await end(explicit: true, initial: state)
    }

    private func end(explicit: Bool = false, initial: VoiceSnapshot? = nil) async throws -> Bool {
        if let ending { return try await ending.value }
        let task = Task { try await self.endOnce(explicit: explicit, initial: initial) }
        ending = task
        defer { ending = nil }
        return try await task.value
    }

    private func endOnce(explicit: Bool, initial: VoiceSnapshot?) async throws -> Bool {
        try checkAttached()
        guard explicit || connected || pendingUntil != nil else { return false }
        let starting = Diagnostics.now
        diagnostics?.record("voice.end.requested")
        // Only an explicit spoken/button End can take the direct action path.
        // Recovery cleanup must refresh stale ownership first and must
        // never use Codex's start-capable toggle to dispose of a closed call.
        if explicit, pendingUntil == nil, let requestEnd = transport.requestEnd {
            guard let pid = try await requestEnd() else {
                connected = false
                lastVoicePID = nil
                return false
            }
            connected = true
            diagnostics?.record("voice.end.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["path": "direct_native_end"])
            try await confirmEnd(pid: pid, starting: starting, retryIfPresent: true)
            return true
        }
        // A cancelled native opening may finish late. Wait for its actual Voice
        // controls before sending dedicated End, so cancellation cannot start a call.
        var state: VoiceSnapshot
        if let initial { state = initial } else { state = await snapshot() }
        while state.microphone == nil, !state.endControlAvailable, let deadline = pendingUntil, Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            state = await snapshot()
        }
        clearPendingOpening()
        guard state.microphone != nil || state.endControlAvailable, let pid = state.pid else {
            if !state.inputRunning && state.controlsComplete {
                connected = false
                lastVoicePID = nil
                return false
            }
            throw BridgeError.message("Couldn't confirm Codex Voice. End the call in Codex.")
        }
        try checkAttached()
        // End retains its app-scoped activation. Speaker recovery is separate.
        // An AXPress acknowledgement is not confirmation that the call ended.
        try transport.activate(pid)
        diagnostics?.record("voice.end.activation_requested")
        try await Task.sleep(nanoseconds: 200_000_000)
        try checkAttached()
        if !explicit, let pressEnd = transport.retryEnd {
            try await pressEnd(pid)
        } else {
            try await transport.send(VoiceBridge.endCommand, pid)
        }
        diagnostics?.record("voice.end.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000])
        try await confirmEnd(pid: pid, starting: starting)
        return true
    }

    private func confirmEnd(pid: Int32, starting: Double, retryIfPresent: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(endConfirmationTimeout)
        var absentWhileInputRunning = 0
        var canRetry = retryIfPresent
        let retryAfter = Date().addingTimeInterval(2)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            let fresh = await snapshot()
            let noVoiceControls = fresh.controlsComplete && fresh.microphone == nil && !fresh.endControlAvailable
            absentWhileInputRunning = noVoiceControls && fresh.inputRunning ? absentWhileInputRunning + 1 : 0
            // Codex can keep an unrelated input stream after Voice ends. Only
            // after our exact End action, accept two completed negative scans
            // instead of mistaking that process-wide input for this Voice call.
            // A temporarily missing app/AX root is not evidence of shutdown.
            if noVoiceControls && (!fresh.inputRunning || absentWhileInputRunning >= 2) {
                connected = false
                lastVoicePID = nil
                diagnostics?.record("voice.end.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["input_running": String(fresh.inputRunning)])
                return
            }
            // Let a normal slow teardown finish before a second End request,
            // and require a complete, still-active read.
            if canRetry, Date() >= retryAfter, fresh.controlsComplete,
               fresh.pid == pid, fresh.microphone != nil || fresh.endControlAvailable {
                canRetry = false
                diagnostics?.record("voice.end.fresh_control_retry")
                // Retrying the keyboard toggle could reopen a call whose UI
                // is slow to disappear. The exact End action is idempotent.
                try await transport.retryEnd?(pid)
            }
        }
        diagnostics?.record("voice.end.confirmation_timeout")
        // Stale controls or another audio stream can outlive a successful End.
        // A failed confirmation is unknown, not evidence that End failed.
        throw BridgeError.endUnconfirmed
    }

    // AX reads are bounded and run only during an explicit start/stop, away from
    // the UI thread. There is no background scan of Codex's conversation tree.
    private func snapshot() async -> VoiceSnapshot {
        let starting = Diagnostics.now
        let state = await transport.snapshot()
        diagnostics?.record("voice.controls.checked", numbers: ["ms": (Diagnostics.now - starting) * 1000, "nodes": Double(state.scanNodes), "timeouts": Double(state.scanTimeouts), "depth": Double(state.scanDepth)], info: ["pid": state.pid.map(String.init) ?? "unknown", "scan_failure": state.scanFailure, "complete": String(state.controlsComplete), "microphone": state.microphone?.rawValue ?? "unknown", "output_muted": state.outputMuted.map(String.init) ?? "unknown", "end_available": String(state.endControlAvailable), "input_running": String(state.inputRunning), "saved_voice_active": state.savedVoiceActive.map(String.init) ?? "unknown", "session": transport.startSession().rawValue])
        return state
    }
}
