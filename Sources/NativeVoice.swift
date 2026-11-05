// Coordinate one native Voice request, with fresh call checks and bounded readiness.
import AppKit
import Foundation

// Cancellation is owned by the specific opening task, so a later wake cannot
// overwrite an environmental pause's instruction to preserve the current call.
@MainActor final class VoiceStartContext {
    let id = UUID()
    var preserveCallOnCancellation = false
    var prepareNewCall: (() async -> Void)?
    private(set) var requestedNewCall = false
    func didRequestNewCall() { requestedNewCall = true }
}

// Codex owns the conversation, audio and UI. HelloChat has no WebRTC client and
// starts no App Server. Start uses Codex's global "Voice chat hotkey"; the
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
        static var live: Self {
            Self(snapshot: { await Task.detached(priority: .utility) { VoiceBridge.snapshot() }.value },
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
                    guard let app = NSRunningApplication(processIdentifier: pid) else {
                        throw BridgeError.message("Open Codex, then try again.")
                    }
                    app.activate(options: [])
                 }, requestEnd: {
                    try await Task.detached(priority: .userInitiated) {
                        try VoiceBridge.requestActiveEnd(record: { event, numbers, info in
                            Diagnostics.shared.record(event, numbers: numbers, info: info)
                        })
                    }.value
                 }, retryEnd: { pid in
                    try await Task.detached(priority: .userInitiated) {
                        try VoiceBridge.pressEnd(pid: pid)
                    }.value
                 }, launch: { try await VoiceBridge.launchCodex() }, unmute: { pid in
                    try await Task.detached(priority: .userInitiated) { try VoiceBridge.pressUnmute(pid: pid) }.value
                 }, startSession: { .current })
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
    private var ending: Task<Bool, Error>?
    private var detachedForQuit = false

    init(transport: Transport = .live, diagnostics: Diagnostics? = nil, confirmationTimeout: TimeInterval = 15, launchTimeout: TimeInterval = 10, endConfirmationTimeout: TimeInterval = 8, minimumLaunchWait: TimeInterval = 5) {
        self.transport = transport; self.diagnostics = diagnostics; self.confirmationTimeout = confirmationTimeout
        self.launchTimeout = launchTimeout
        self.minimumLaunchWait = minimumLaunchWait
        self.endConfirmationTimeout = endConfirmationTimeout
    }

    // nil means an exact End Voice control confirmed the call, but the native
    // presentation didn't expose its microphone state. Never infer an unmute.
    @discardableResult func start(context: VoiceStartContext? = nil, onRequestAccepted: () -> Void = {}) async throws -> MicrophoneState? {
        try checkStartAllowed()
        let opening = context ?? VoiceStartContext()
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
            throw BridgeError.message("Allow Accessibility for HelloChat in System Settings.")
        }
        let waitForApplication = state.pid == nil || state.applicationLaunching || !state.applicationHasWindow
            || (!state.applicationReady && state.controlsComplete)
        var lastObservedPID = state.pid
        var relaunchedAfterExit = false
        var launchedAt = transport.now()
        var launchDeadline = launchedAt + launchTimeout
        if waitForApplication, let launch = transport.launch {
            try checkStartAllowed()
            diagnostics?.record("voice.application.launch_requested")
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
            throw BridgeError.message("Allow Accessibility for HelloChat in System Settings.")
        }
        if let microphone = state.microphone { connected = true; clearPendingOpening(); return microphone }
        if state.endControlAvailable {
            connected = true; clearPendingOpening()
            diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["microphone": "unknown", "confirmation": "end_control"])
            return nil
        }
        // Ethan's "Codex is using the microphone" false block: process audio
        // input can remain active after Voice closes, or belong to dictation.
        // Fresh positive Voice controls reuse the call; audio activity alone
        // does not block an explicit start.
        if state.inputRunning {
            diagnostics?.record("voice.input_activity.ignored", info: ["controls_complete": String(state.controlsComplete)])
        }
        let confirmationDeadline = Date().addingTimeInterval(confirmationTimeout)
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
            let activated = await snapshot()
            try checkStartAllowed()
            if let microphone = activated.microphone { connected = true; clearPendingOpening(); return microphone }
            if activated.endControlAvailable { connected = true; clearPendingOpening(); return nil }
            guard activated.pid == pid else { throw BridgeError.message("Codex closed while opening Voice.") }
            if waitForApplication, !activated.applicationReady || !activated.applicationHasWindow || activated.applicationLaunching {
                throw BridgeError.message("Codex didn't open. Try again.")
            }
            pendingUntil = Date().addingTimeInterval(confirmationTimeout)
            pendingOpeningID = opening.id
            do {
                await opening.prepareNewCall?()
                try checkStartAllowed()
                try await transport.send(VoiceBridge.startCommand, pid)
                opening.didRequestNewCall()
            }
            catch { clearPendingOpening(ownedBy: opening.id); throw error }
            diagnostics?.record("voice.shortcut.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000],
                                info: ["command": VoiceBridge.startCommand, "delivery": "global_hotkey"])
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
            if let microphone = fresh.microphone {
                connected = true; clearPendingOpening()
                diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000])
                return microphone
            }
            if fresh.endControlAvailable {
                connected = true; clearPendingOpening()
                diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["microphone": "unknown", "confirmation": "end_control"])
                return nil
            }
        }
        throw BridgeError.message("Codex Voice didn't open. Check Voice in Codex.")
    }

    func setMicrophone(_ state: MicrophoneState) async throws {
        try checkAttached()
        if state == .muted { _ = try await end() }
        else {
            guard connected else { throw BridgeError.message("Codex Voice is off.") }
            let fresh = await snapshot()
            guard let pid = fresh.pid, let microphone = fresh.microphone else {
                throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
            }
            if microphone == .listening { return }
            try checkAttached()
            try transport.activate(pid)
            guard let unmute = transport.unmute else {
                throw BridgeError.message("Couldn't unmute chat. Use the microphone in Codex.")
            }
            try await unmute(pid)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard await snapshot().microphone == .listening else {
                throw BridgeError.message("Codex Voice is still muted. Check the microphone in Codex.")
            }
        }
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
        connected = state.microphone != nil || state.endControlAvailable
        diagnostics?.record("voice.refresh", info: ["connected": String(connected), "complete": String(state.controlsComplete)])
        return state.microphone
    }

    // A spoken end command may address a call opened directly in Codex. Adopt
    // only freshly identified Voice controls; cleanup never takes this path.
    @discardableResult func endIfPresent() async throws -> Bool {
        guard !detachedForQuit else { return false }
        if transport.requestEnd != nil, pendingUntil == nil { return try await end(explicit: true) }
        let state = await snapshot()
        guard state.accessibilityAllowed else { throw BridgeError.message("Allow Accessibility for HelloChat in System Settings.") }
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
            guard let pid = try await requestEnd() else { connected = false; return false }
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
            if !state.inputRunning && state.controlsComplete { connected = false; return false }
            throw BridgeError.message("Couldn't confirm Codex Voice. End the call in Codex.")
        }
        try checkAttached()
        // Match start/unmute: activate Codex before requesting its native action.
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
        diagnostics?.record("voice.controls.checked", numbers: ["ms": (Diagnostics.now - starting) * 1000, "nodes": Double(state.scanNodes), "timeouts": Double(state.scanTimeouts), "depth": Double(state.scanDepth)], info: ["pid": state.pid.map(String.init) ?? "unknown", "scan_failure": state.scanFailure, "complete": String(state.controlsComplete), "microphone": state.microphone?.rawValue ?? "unknown", "end_available": String(state.endControlAvailable), "input_running": String(state.inputRunning), "session": transport.startSession().rawValue])
        return state
    }
}
