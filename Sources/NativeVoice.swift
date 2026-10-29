import AppKit
import Foundation

// Codex owns the conversation, audio and UI. HelloChat has no WebRTC client and
// starts no App Server. The installed composer's existing shortcut toggles its
// native call. Ending sends that same toggle only with a validated active call.
@MainActor final class NativeVoice {
    struct Transport {
        var snapshot: () async -> VoiceSnapshot
        var send: (String, Int32) async throws -> Void
        var activate: (Int32) throws -> Void
        var requestEnd: (() async throws -> Int32?)? = nil
        var retryEnd: ((Int32) async throws -> Void)? = nil
        static var live: Self {
            Self(snapshot: { await Task.detached(priority: .utility) { VoiceBridge.snapshot() }.value },
                 send: { command, pid in
                    try await Task.detached(priority: .userInitiated) {
                        if command == VoiceBridge.endCommand {
                            try VoiceBridge.endCall(pid: pid, record: { event, numbers, info in
                                Diagnostics.shared.record(event, numbers: numbers, info: info)
                            })
                        }
                        else { try VoiceBridge.post(command: command, pid: pid) }
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
                 })
        }
    }
    private let transport: Transport
    private let diagnostics: Diagnostics?
    private let confirmationTimeout: TimeInterval
    private(set) var connected = false
    private(set) var lastError: String?
    private var pendingUntil: Date?
    private var ending: Task<Bool, Error>?

    init(transport: Transport = .live, diagnostics: Diagnostics? = nil, confirmationTimeout: TimeInterval = 15) {
        self.transport = transport; self.diagnostics = diagnostics; self.confirmationTimeout = confirmationTimeout
    }

    // nil means an exact End Voice control confirmed the call, but the native
    // presentation didn't expose its microphone state. Never infer an unmute.
    @discardableResult func start(onNewCall: () -> Void = {}) async throws -> MicrophoneState? {
        let starting = Diagnostics.now
        diagnostics?.record("voice.open.requested")
        lastError = nil
        // A wake must establish ownership from fresh controls. In particular,
        // an End-only presentation doesn't tell us whether its mic is muted.
        connected = false
        var state = await snapshot()
        try Task.checkCancellation()
        // Electron can replace an AX node during a read. Retry a bounded,
        // incomplete negative result; never infer absence from a failed scan.
        for _ in 0..<2 where state.accessibilityAllowed
            && state.microphone == nil && !state.endControlAvailable
            && (state.pid == nil || !state.controlsComplete) {
            try await Task.sleep(nanoseconds: 120_000_000)
            try Task.checkCancellation()
            state = await snapshot()
            try Task.checkCancellation()
        }
        guard let pid = state.pid else {
            throw BridgeError.message("Open Codex, then try again.")
        }
        guard state.accessibilityAllowed else {
            throw BridgeError.message("Allow Accessibility for HelloChat in System Settings.")
        }
        if let microphone = state.microphone { connected = true; return microphone }
        if state.endControlAvailable {
            connected = true; pendingUntil = nil
            diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["microphone": "unknown", "confirmation": "end_control"])
            return nil
        }
        // Ethan's "Codex is using the microphone" false block: process audio
        // input can remain active after Voice closes, or belong to dictation.
        // Only the complete Voice-control scan below gates an explicit start.
        if state.inputRunning {
            diagnostics?.record("voice.input_activity.ignored", info: ["controls_complete": String(state.controlsComplete)])
        }
        let confirmationDeadline = Date().addingTimeInterval(confirmationTimeout)
        if !state.endControlAvailable {
            guard state.controlsComplete else { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
            try transport.activate(pid)
            try await Task.sleep(nanoseconds: 200_000_000)
            try Task.checkCancellation()
            pendingUntil = Date().addingTimeInterval(confirmationTimeout)
            // Ethan's "boot/start sound" belongs only to an actual new-call
            // request. Existing Voice (including muted or End-only) returns
            // above; elapsed time never decides whether its cue is suppressed.
            onNewCall()
            do { try await transport.send(VoiceBridge.startCommand, pid) }
            catch { pendingUntil = nil; throw error }
            diagnostics?.record("voice.shortcut.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000])
        }
        try Task.checkCancellation()
        while Date() < (pendingUntil ?? confirmationDeadline) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
            let fresh = await snapshot()
            try Task.checkCancellation()
            // A transient application lookup is unknown, not proof of exit.
            // Keep waiting for this start without resending its toggle.
            if fresh.pid == nil { continue }
            guard fresh.pid == pid else { throw BridgeError.message("Codex closed while opening Voice.") }
            if let microphone = fresh.microphone {
                connected = true; pendingUntil = nil
                diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000])
                return microphone
            }
            if fresh.endControlAvailable {
                connected = true; pendingUntil = nil
                diagnostics?.record("voice.open.confirmed", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["microphone": "unknown", "confirmation": "end_control"])
                return nil
            }
        }
        throw BridgeError.message("Codex Voice didn't open. Check Voice in Codex.")
    }

    func setMicrophone(_ state: MicrophoneState) async throws {
        if state == .muted { _ = try await end() }
        else {
            guard connected else { throw BridgeError.message("Codex Voice is off.") }
            let fresh = await snapshot()
            guard let pid = fresh.pid, let microphone = fresh.microphone else {
                throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
            }
            if microphone == .listening { return }
            try transport.activate(pid)
            try await transport.send(VoiceBridge.muteCommand, pid)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard await snapshot().microphone == .listening else {
                throw BridgeError.message("Codex Voice is still muted. Check the microphone in Codex.")
            }
        }
    }

    func stop() async {
        do { _ = try await end(); lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    // Ethan's "24/7" reliability: failed confirmation must not tear down a
    // working native call. Explicit cancellation (Bye Chat, off, or Quit)
    // still cleans up an owned late opening through the existing stop path.
    func recoverFromStartFailure(_ error: Error) async {
        if error is CancellationError || Task.isCancelled { await stop() }
        else {
            pendingUntil = nil; connected = false
            diagnostics?.record("voice.open.unconfirmed_preserved")
        }
    }

    // A spoken end command may address a call opened directly in Codex. Adopt
    // only freshly identified Voice controls; cleanup never takes this path.
    @discardableResult func endIfPresent() async throws -> Bool {
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
        guard explicit || connected || pendingUntil != nil else { return false }
        let starting = Diagnostics.now
        diagnostics?.record("voice.end.requested")
        // Only an explicit spoken/button End can take the direct action path.
        // Quit/recovery cleanup must refresh stale ownership first and must
        // never use Codex's start-capable toggle to dispose of a closed call.
        if explicit, pendingUntil == nil, let requestEnd = transport.requestEnd {
            guard let pid = try await requestEnd() else { connected = false; return false }
            connected = true
            diagnostics?.record("voice.end.sent", numbers: ["ms_since_request": (Diagnostics.now - starting) * 1000], info: ["path": "direct_native_end"])
            try await confirmEnd(pid: pid, starting: starting, retryIfPresent: true)
            return true
        }
        // A cancelled native opening may finish late. Wait for its actual Voice
        // controls before sending the toggle, so cancellation cannot start a call.
        var state: VoiceSnapshot
        if let initial { state = initial } else { state = await snapshot() }
        while state.microphone == nil, !state.endControlAvailable, let deadline = pendingUntil, Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            state = await snapshot()
        }
        pendingUntil = nil
        guard state.microphone != nil || state.endControlAvailable, let pid = state.pid else {
            if !state.inputRunning && state.controlsComplete { connected = false; return false }
            throw BridgeError.message("Couldn't confirm Codex Voice. End the call in Codex.")
        }
        // Match start/unmute: activate Codex before requesting its native action.
        // An AXPress acknowledgement is not confirmation that the call ended.
        try transport.activate(pid)
        diagnostics?.record("voice.end.activation_requested")
        try await Task.sleep(nanoseconds: 200_000_000)
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
        let deadline = Date().addingTimeInterval(8)
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
            // End is a toggle. Let a normal slow teardown finish before a
            // second request, and require a complete, still-active read.
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
        throw BridgeError.message("Codex Voice is still using the microphone. End the call in Codex.")
    }

    // AX reads are bounded and run only during an explicit start/stop, away from
    // the UI thread. There is no background scan of Codex's conversation tree.
    private func snapshot() async -> VoiceSnapshot {
        let starting = Diagnostics.now
        let state = await transport.snapshot()
        diagnostics?.record("voice.controls.checked", numbers: ["ms": (Diagnostics.now - starting) * 1000, "nodes": Double(state.scanNodes), "timeouts": Double(state.scanTimeouts), "depth": Double(state.scanDepth)], info: ["pid": state.pid.map(String.init) ?? "unknown", "scan_failure": state.scanFailure, "complete": String(state.controlsComplete), "microphone": state.microphone?.rawValue ?? "unknown", "end_available": String(state.endControlAvailable), "input_running": String(state.inputRunning)])
        return state
    }
}
