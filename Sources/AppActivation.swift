/*
 =============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-25: DesktopCommands.swift, RunningAppActivation and activateRunning.
 Shared by desktop app commands and exact Codex chat navigation in VoiceBridge.
 The original dispatch routes are retained; navigation now also requires actual
 foreground confirmation. Task: 01a1f046-3f24-76c2-833d-80f22ec44dab.
 =============================================================================
 */
import AppKit
import ApplicationServices
import Foundation

// A background speech command may be refused by AppKit's activation policy (21:33:13 UTC on 14
// November 2026: accepted, then activate-failed). Each later route runs once, only after the
// previous one was refused (or, for navigation, is not actually frontmost), and only while the
// same live process is still the target: the native
// Accessibility frontmost attribute, then Launch Services, which handles activation for an app it
// opens. Launch Services may reopen a window, as a Dock click does; that is now acceptable because
// Switch app and Open app both may open apps. No retry or second request of the same kind.
// The strict foreground option fixes accepted-but-background navigation.
// Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
@MainActor enum RunningAppActivation {
    static func request(identityMatches: () -> Bool, native: () -> Bool, accessibility: () async -> Bool,
                        workspace: () async -> Bool = { false }, isFrontmost: (() -> Bool)? = nil) async -> Bool {
        guard !Task.isCancelled, identityMatches() else { return false }
        if native(), !Task.isCancelled, identityMatches(), isFrontmost?() ?? true { return true }
        guard !Task.isCancelled, identityMatches() else { return false }
        if await accessibility(), !Task.isCancelled, identityMatches(), isFrontmost?() ?? true { return true }
        guard !Task.isCancelled, identityMatches() else { return false }
        let accepted = await workspace()
        return accepted && !Task.isCancelled && identityMatches() && (isFrontmost?() ?? true)
    }
}

// Extraction of DesktopCommands.activateRunning's native same-process routes.
// Explicit chat navigation additionally checks foreground state, rather than treating an
// accepted request as success. Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
@MainActor enum AppActivation {
    static func request(pid: Int32, bundleID: String, url: URL, requireFrontmost: Bool = false) async -> Bool {
        func current() -> NSRunningApplication? {
            guard let running = NSRunningApplication(processIdentifier: pid),
                  !running.isTerminated, running.activationPolicy == .regular,
                  (running.bundleIdentifier ?? "pid:\(pid)") == bundleID, running.bundleURL == url else { return nil }
            return running
        }
        func valid() -> Bool { !Task.isCancelled && DesktopSessionState.current == .interactive && current() != nil }
        if requireFrontmost, valid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        let accepted = await RunningAppActivation.request(identityMatches: valid, native: {
            let accepted = current()?.activate(options: []) ?? false
            Diagnostics.shared.record("desktop.app.activation", numbers: ["target_pid": Double(pid)],
                info: ["method": "appkit", "accepted": String(accepted)])
            return accepted
        }, accessibility: {
            let result = await Task.detached(priority: .userInitiated) { () -> AXError? in
                guard AXIsProcessTrusted() else { return nil }
                let target = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(target, 1)
                return AXUIElementSetAttributeValue(target, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }.value
            Diagnostics.shared.record("desktop.app.activation", numbers: ["target_pid": Double(pid), "ax_result": Double(result?.rawValue ?? 0)],
                info: ["method": "accessibility", "trusted": String(result != nil), "accepted": String(result == .success)])
            return result == .success
        }, workspace: {
            // Navigation already sent its exact deep link; never reopen another window to focus it.
            // Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
            guard !requireFrontmost else { return false }
            guard let target = current()?.bundleURL else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            let opened = try? await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
            Diagnostics.shared.record("desktop.app.activation", numbers: ["target_pid": Double(pid), "opened_pid": Double(opened?.processIdentifier ?? -1)],
                info: ["method": "workspace", "accepted": String(opened != nil), "same_process": String(opened?.processIdentifier == pid)])
            return opened != nil
        }, isFrontmost: requireFrontmost ? { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid } : nil)
        guard requireFrontmost else { return accepted }
        guard valid() else { return false }
        // Observe activation, with the existing app-command one-second completion bound.
        // This waits for a native result only: no activation request is repeated. — GPT-6.1 Sol
        return await ForegroundObservation.wait(pid: pid, valid: valid)
    }
}

// Finite native activation observation shared by explicit navigation callers. — GPT-6.1 Sol
@MainActor private final class ForegroundObservation {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private let pid: Int32
    private let valid: () -> Bool
    private init(pid: Int32, valid: @escaping () -> Bool) { self.pid = pid; self.valid = valid }
    static func wait(pid: Int32, valid: @escaping () -> Bool) async -> Bool {
        let observation = ForegroundObservation(pid: pid, valid: valid)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                observation.continuation = continuation
                guard !Task.isCancelled, valid() else { observation.finish(false); return }
                let center = NSWorkspace.shared.notificationCenter
                observation.observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { observation.check() }
                }
                observation.check()
                if observation.continuation != nil {
                    observation.timeout = Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        observation.finish(valid() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
                    }
                }
            }
        } onCancel: { Task { @MainActor in observation.finish(false) } }
    }
    private func check() {
        if !valid() { finish(false) }
        else if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { finish(true) }
    }
    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer); self.observer = nil }
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: result)
    }
}
