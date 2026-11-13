// Native Codex discovery, shortcut setup and delivery for H Chat's Voice actions.
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Carbon.HIToolbox
import Darwin
import Foundation

struct VoiceBridge {
    // Previously restricted to /Applications/ChatGPT.app. Identify Codex by its
    // bundle and reported executable so normal Codex.app installs also work.
    static func isCodexApplication(bundleIdentifier: String?, bundlePath: String?, reportedExecutable: String?, actualExecutable: String?) -> Bool {
        guard bundleIdentifier == "com.openai.codex", let bundlePath,
              let reportedExecutable, let actualExecutable else { return false }
        let reported = URL(fileURLWithPath: reportedExecutable).resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: actualExecutable).resolvingSymlinksInPath().path
        let contents = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().appendingPathComponent("Contents").path + "/"
        return reported == actual && actual.hasPrefix(contents)
    }
    private static func codexProcess(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return isCodexApplication(bundleIdentifier: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                                  reportedExecutable: app.executableURL?.path, actualExecutable: executable(pid))
    }
    static let muteCommand = "realtimeVoice.toggleMicrophoneMute"
    static let outputMuteCommand = "realtimeVoice.toggleOutputMute"
    // Ethan's "Voice chat hotkey" is the OS-global action. The separate
    // composer.startVoiceMode is labelled "Toggle voice chat"; leave its reset
    // and any custom binding alone rather than assigning our start key to it.
    static let startCommand = "realtimeVoice"
    static let endCommand = "realtimeVoice.endCall"
    static let privateMuteKey = "Command+Control+Option+Shift+F16"
    static let bindingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/keybindings.json")
    private static let activationURL = AppPaths.support.appendingPathComponent("voice-shortcut-activation.json")

    static func currentApplication() -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated && codexProcess($0.processIdentifier) }
        return apps.count == 1 ? apps[0] : nil
    }

    @discardableResult static func prepareShortcuts() throws -> [String] {
        let setup = VoiceShortcutConfiguration()
        let added = try setup.ensureDefaults()
        if !added.isEmpty, let app = currentApplication(), let launchedAt = app.launchDate {
            let keys = try setup.read().filter { added.contains($0["command"] as? String ?? "") }
            let bindings = Dictionary(uniqueKeysWithValues: keys.compactMap { entry -> (String, String)? in
                guard let command = entry["command"] as? String, let key = entry["key"] as? String else { return nil }
                return (command, key)
            })
            var receipt = (try? JSONDecoder().decode(VoiceShortcutActivation.self, from: Data(contentsOf: activationURL)))
                ?? VoiceShortcutActivation(pid: app.processIdentifier, launchedAt: launchedAt, bindings: [:])
            if receipt.pid != app.processIdentifier || receipt.launchedAt != launchedAt {
                receipt = VoiceShortcutActivation(pid: app.processIdentifier, launchedAt: launchedAt, bindings: [:])
            }
            receipt.bindings.merge(bindings) { _, new in new }
            try FileManager.default.createDirectory(at: activationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipt).write(to: activationURL, options: .atomic)
        }
        return added
    }

    static func shortcutSetupMessage(command: String? = nil) -> String? {
        guard let app = currentApplication(), let launchedAt = app.launchDate,
              let receipt = try? JSONDecoder().decode(VoiceShortcutActivation.self, from: Data(contentsOf: activationURL)),
              let bindings = try? VoiceShortcutConfiguration().read(),
              receipt.requiresRestart(pid: app.processIdentifier, launchedAt: launchedAt,
                                      current: bindings.filter { command == nil || $0["command"] as? String == command }) else { return nil }
        return "Voice shortcuts saved. Restart Codex to apply them."
    }

    @MainActor static func launchCodex() async throws {
        // Set defaults before launch so this new Codex process can register them.
        try prepareShortcuts()
        // Closing Codex's last window can leave its process running. Send the
        // normal reopen request in that case too; never create a second instance.
        guard let url = currentApplication()?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              Bundle(url: url)?.bundleIdentifier == "com.openai.codex" else {
            throw BridgeError.message("Install Codex, then try again.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: BridgeError.message("Codex didn't open. Try again.")) }
            }
        }
        // A previous process can exit while Launch Services is handling its
        // reopen request. Let the readiness coordinator observe that exit and
        // make one fresh launch rather than failing on the stale process.
        if app.isTerminated || currentApplication() == nil { return }
        guard codexProcess(app.processIdentifier) else {
            throw BridgeError.message("Couldn't identify the active Codex window.")
        }
    }

    static func snapshot(readMicrophone: Bool = true, maximumDepth: Int = 96, requireEnd: Bool = false, readOutput: Bool = false,
                         observeCallElements: (([AXUIElement]) -> Void)? = nil) -> VoiceSnapshot {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        let applications = candidates
            .filter { !$0.isTerminated && codexProcess($0.processIdentifier) }
        let app = applications.count == 1 ? applications[0] : nil
        let pids = inputPIDs()
        let voice = app?.bundleURL.map { bundle in pids.contains { executable($0)?.hasPrefix(bundle.path + "/Contents/") == true } } ?? false
        let recorder = pids.contains { executable($0)?.hasPrefix("/Applications/AgentFlow.app/Contents/") == true }
        var controls = (readMicrophone || readOutput) ? voiceControls(app?.processIdentifier, requireEnd: requireEnd, maximumDepth: maximumDepth, requireOutput: readOutput) : Controls()
        observeCallElements?(controls.watchElements + [controls.end, controls.microphoneButton].compactMap { $0 })
        if app == nil { controls.failure = "application_lookup:\(candidates.count)/\(applications.count)" }
        return VoiceSnapshot(pid: app?.processIdentifier, inputRunning: voice, recorderRunning: recorder,
                             microphone: controls.microphone, outputMuted: controls.outputMuted, accessibilityAllowed: AXIsProcessTrusted(), endControlAvailable: controls.end != nil,
                             controlsComplete: controls.complete, scanNodes: controls.nodes, scanTimeouts: controls.timeouts, scanDepth: controls.depth, scanFailure: controls.failure,
                             applicationReady: app?.isFinishedLaunching == true
                                && (controls.windowReady || controls.microphone != nil || controls.end != nil || controls.outputMuted != nil),
                             applicationLaunching: app.map { !$0.isFinishedLaunching } ?? false,
                             applicationHasWindow: controls.hasWindow,
                             applicationHasWebContent: controls.webContentReady,
                             applicationAbsent: candidates.isEmpty)
    }

    // Passive, one-shot reads only. No AXPress, focus/activation writes or pointer automation.
    static func microphoneState(_ pid: pid_t?) -> MicrophoneState? {
        voiceControls(pid).microphone
    }

    // Waking an existing muted call uses the same native microphone shortcut
    // as the explicit mute phrases. AXPress did not work in the live desktop.
    static func pressUnmute(pid: pid_t, record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws {
        guard codexProcess(pid) else { throw BridgeError.message("Codex closed while opening chat.") }
        let controls = voiceControls(pid)
        if controls.microphone == .listening { return }
        guard controls.microphone == .muted else {
            throw BridgeError.message("Couldn't unmute chat. Use the microphone in Codex.")
        }
        try post(command: muteCommand, pid: pid, record: record)
    }

    // Exact native end actions from the installed Codex Voice presentations.
    // An explicit End action is idempotent; a start/toggle shortcut is not.
    static func isEndVoiceLabel(_ label: String) -> Bool {
        ["end voice", "end voice chat", "stop voice chat"].contains(label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func postEnd(pid: pid_t, record: ((String, [String: Double], [String: String]) -> Void)?, control: String) throws {
        // The required dedicated End binding is configured by post. Never use
        // the start/stop toggle as a substitute for an unassigned End command.
        try post(command: endCommand, pid: pid, record: record)
        record?("voice.end.shortcut_sent", [:], ["control": control, "command": endCommand])
    }
    // Send the user's explicit stop only after finding a current native Voice
    // control in the live window tree. Detached Electron AX objects can still
    // report enabled/visible/End after a call closes, so never cache them.
    // AXPress can acknowledge without invoking Electron's button handler.
    // Send the dedicated End shortcut only after revalidating an active control.
    static func requestActiveEnd(record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws -> pid_t? {
        guard AXIsProcessTrusted() else { throw BridgeError.message("Allow Accessibility for Hello Chat, then try again.") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated && codexProcess($0.processIdentifier) }
        guard !apps.isEmpty else { return nil }
        guard apps.count == 1 else { throw BridgeError.message("Couldn't identify the active Codex window.") }
        let app = apps[0], pid = app.processIdentifier
        func currentVoice() throws -> Bool {
            let controls = voiceControls(pid, requireEnd: true)
            record?("voice.end.controls_checked", ["nodes": Double(controls.nodes), "timeouts": Double(controls.timeouts)],
                    ["complete": String(controls.complete), "failure": controls.failure])
            if let found = controls.end, usableEnd(found, pid: pid) { return true }
            // Some live Voice presentations expose only their microphone.
            // That fresh native control identifies the current call too; End
            // never depends on which call HelloChat originally started.
            if let microphone = controls.microphoneButton, usableMicrophone(microphone, pid: pid) { return true }
            guard controls.complete else { throw BridgeError.message("Couldn't find Voice controls in Codex.") }
            return false
        }
        guard try currentVoice() else { return nil }
        if Thread.isMainThread { app.activate(options: []) }
        else { _ = DispatchQueue.main.sync { app.activate(options: []) } }
        Thread.sleep(forTimeInterval: 0.2)
        // Activation can replace/close the call. Read live membership again;
        // checking attributes of the earlier object does not establish it.
        guard try currentVoice() else { return nil }
        try postEnd(pid: pid, record: record, control: "fresh_tree")
        return pid
    }
    private static func usableEnd(_ element: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.04)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
              attribute(kAXRoleAttribute, element) as? String == kAXButtonRole,
              attribute(kAXEnabledAttribute, element) as? Bool != false,
              attribute("AXHidden", element) as? Bool != true else { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .contains { (attribute($0, element) as? String).map(isEndVoiceLabel) == true }
    }
    private static func usableMicrophone(_ element: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.04)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
              attribute(kAXRoleAttribute, element) as? String == kAXButtonRole,
              attribute(kAXEnabledAttribute, element) as? Bool != false,
              attribute("AXHidden", element) as? Bool != true else { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .contains { (attribute($0, element) as? String).flatMap(MicrophoneState.accessibilityLabel) != nil }
    }
    static func endCall(pid: pid_t, record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws {
        let controls = voiceControls(pid, requireEnd: true)
        guard let button = controls.end else { throw BridgeError.message("Couldn't find End Voice in Codex.") }
        AXUIElementSetMessagingTimeout(button, 0.04)
        let enabled = attribute(kAXEnabledAttribute, button) as? Bool
        let hidden = attribute("AXHidden", button) as? Bool
        let info = ["label": controls.endLabel ?? "unknown", "enabled": enabled.map { String($0) } ?? "unknown", "hidden": hidden.map { String($0) } ?? "unknown"]
        record?("voice.end.toggle.requested", ["pid": Double(pid)], info)
        guard usableEnd(button, pid: pid) else { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
        try postEnd(pid: pid, record: record, control: "fresh")
    }
    // A retry must never send the start/stop toggle a second time. A stale
    // End button may fail or do nothing, but cannot open a new Voice call.
    static func pressEnd(pid: pid_t) throws {
        let controls = voiceControls(pid, requireEnd: true)
        guard let button = controls.end, usableEnd(button, pid: pid) else {
            throw BridgeError.message("Couldn't find End Voice in Codex.")
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.")
        }
    }
    private struct Controls {
        var watchElements: [AXUIElement] = []
        var microphone: MicrophoneState?
        var outputMuted: Bool?
        var microphoneButton: AXUIElement?
        var end: AXUIElement?
        var endLabel: String?
        var complete = false
        var nodes = 0
        var timeouts = 0
        var depth = 0
        var failure = ""
        var windowReady = false
        var webContentReady = false
        var hasWindow = false
    }
    private struct Identity: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    static func outputMuteState(label: String) -> Bool? {
        switch label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "mute speakers": return false
        case "unmute speakers": return true
        default: return nil
        }
    }
    private static func voiceControls(_ pid: pid_t?, requireEnd: Bool = false, maximumDepth: Int = 96, requireOutput: Bool = false) -> Controls {
        guard let pid, AXIsProcessTrusted(), codexProcess(pid) else { return Controls() }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        // A fresh Codex process can expose only its native window shell until
        // an accessibility client requests its web controls. Ask before the
        // readiness scan; keep checking real controls instead of assuming ready.
        // Electron can apply this request while returning an unsupported error,
        // so the fresh tree below, not the setter result, decides readiness.
        if attribute("AXEnhancedUserInterface", root) as? Bool != true {
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        var result = Controls()
        var readFailed = false
        func read(_ name: String, _ element: AXUIElement, required: Bool = true) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if error == .cannotComplete { result.timeouts += 1 }
            if required, error != .success && error != .attributeUnsupported && error != .noValue { readFailed = true; if result.failure.isEmpty { result.failure = "attribute:\(name):\(error.rawValue)" } }
            return error == .success ? value : nil
        }
        // Start at each window so a large conversation cannot crowd out floating Voice
        // controls. Electron's nested web content can be deeper than native controls.
        // A real Codex window reaches depth 46 and exceeds 3,000 nodes even idle.
        // Keep the two-second deadline while allowing that complete negative scan.
        let windows = read(kAXWindowsAttribute, root) as? [AXUIElement] ?? []
        result.hasWindow = !windows.isEmpty
        var queue: [(AXUIElement, Int)] = (windows.isEmpty ? [root] : windows).map { ($0, 0) }
        var seen = Set<Identity>()
        let deadline = Date().addingTimeInterval(2)
        func inspectButton(_ element: AXUIElement) {
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                if let label = read(name, element) as? String {
                    // A web area can exist while Electron is still showing its
                    // launch shell. A real conversation action is better evidence.
                    if ["new chat", "new thread", "send message", "send now"].contains(label.lowercased()) {
                        result.windowReady = true
                    }
                    if let state = MicrophoneState.accessibilityLabel(label) {
                        result.microphone = state; result.microphoneButton = element
                    }
                    if let muted = outputMuteState(label: label) { result.outputMuted = muted }
                    if isEndVoiceLabel(label) {
                        result.end = element; result.endLabel = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        var i = 0
        while i < queue.count && seen.count < 12000 && Date() < deadline {
            let (element, depth) = queue[i]; i += 1
            guard seen.insert(Identity(element: element)).inserted else { continue }
            result.nodes = seen.count
            result.depth = max(result.depth, depth)
            // AX timeouts belong to each object, not its application ancestor.
            // A hung child must not bypass the traversal's overall deadline.
            AXUIElementSetMessagingTimeout(element, 0.04)
            let role = read(kAXRoleAttribute, element) as? String
            if role == kAXButtonRole {
                inspectButton(element)
                // Stop after the requested control is found. An End button alone
                // proves a call exists but cannot tell an audio command its mic state.
                if requireOutput ? result.outputMuted != nil : (requireEnd ? result.end != nil : result.microphone != nil) { result.complete = true; return result }
            }
            if role == "AXWebArea" {
                // Chromium may announce newly inserted call controls on this
                // web area rather than its outer window (temporary calls too).
                result.watchElements.append(element)
                // A launched process alone is too early. The native window must
                // expose its web content before the launch path sends Start.
                result.webContentReady = !windows.isEmpty
                // Chromium's native button search skips chat text, including
                // long/offscreen conversations that exhaust a node-by-node scan.
                let limit = 1000
                let predicate: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXResultsLimit": limit,
                    "AXDirection": "AXDirectionNext", "AXVisibleOnly": false]
                AXUIElementSetMessagingTimeout(element, 0.25)
                var value: CFTypeRef?
                let status = AXUIElementCopyParameterizedAttributeValue(element,
                    "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &value)
                if status == .success, let buttons = value as? [AXUIElement], buttons.count < limit {
                    for button in buttons {
                        guard Date() < deadline else { result.failure = "deadline"; return result }
                        inspectButton(button)
                        if requireOutput ? result.outputMuted != nil : (requireEnd ? result.end != nil : result.microphone != nil) { result.complete = true; return result }
                    }
                    continue
                }
                // A failed/truncated native search can fall back to traversal,
                // but can never prove that a Voice call is absent.
                readFailed = true
                if result.failure.isEmpty { result.failure = "button_search:\(status.rawValue)" }
            }
            if [kAXStaticTextRole, kAXImageRole, kAXButtonRole].contains(role ?? "") { continue }
            let children = read("AXChildrenInNavigationOrder", element, required: false) as? [AXUIElement]
                ?? read(kAXChildrenAttribute, element) as? [AXUIElement] ?? []
            if depth < maximumDepth {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            } else if !children.isEmpty { readFailed = true; result.failure = "depth_limit" }
        }
        result.complete = i == queue.count && !readFailed
        if !result.complete && result.failure.isEmpty { result.failure = seen.count >= 12000 ? "node_limit" : "deadline" }
        return result
    }

    static func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func post(command: String, pid: pid_t, deliveryKey: String? = nil,
                     record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws {
        guard AXIsProcessTrusted() else { throw BridgeError.message("Allow Accessibility for Hello Chat, then try again.") }
        guard codexProcess(pid) else { throw BridgeError.message("ChatGPT changed or closed. Check Voice again.") }
        if command == startCommand {
            let session = DesktopSessionState.current
            guard session == .interactive else {
                record?("voice.session.blocked", [:], ["state": session.rawValue])
                throw BridgeError.desktopUnavailable(session)
            }
        }
        try prepareShortcuts()
        if let message = shortcutSetupMessage(command: command) { throw BridgeError.message(message) }
        // Re-read on every send: settings may have changed since app startup.
        let bindings = try VoiceShortcutConfiguration().read()
        guard let key = deliveryKey ?? bindings.first(where: {
            $0["command"] as? String == command && ($0["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })?["key"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.message("Set a Voice shortcut in Codex settings, then try again.")
        }
        let combination = try VoiceKeyCombination(key)
        let virtualKey = combination.resolvedKeyCode(), flags = combination.flags
        record?("voice.key.prepared", ["keycode": Double(virtualKey), "flags": Double(flags.rawValue)],
                ["command": command, "accelerator": key])
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw BridgeError.message("Could not send Voice shortcut.")
        }
        let originalFlags = CGEventSource.flagsState(.hidSystemState)
        down.flags = flags; up.flags = flags
        // Match Agent Flow's established process-targeted transport, including fresh
        // event timestamps rather than delivering an indistinguishable key pair.
        // Voice chat hotkey is registered globally, so it needs the system event
        // path. Dedicated End and microphone actions remain process-targeted.
        if command == startCommand {
            // The isolated receiver reproduced lingering synthetic modifiers
            // when key-up repeated the chord. Restore the pre-send state, so a
            // real modifier the user already held is not released by H Chat.
            up.flags = originalFlags
            down.timestamp = eventTimestamp(); down.post(tap: .cghidEventTap)
            up.timestamp = eventTimestamp(); up.post(tap: .cghidEventTap)
        } else {
            // Keep the established PID sender unchanged for End and microphone
            // actions while diagnosing their live acceptance independently.
            down.timestamp = mach_absolute_time(); down.postToPid(pid)
            up.timestamp = mach_absolute_time(); up.postToPid(pid)
        }
    }

    static func eventTimestamp() -> CGEventTimestamp {
        // CGEvent wants nanoseconds, while mach_absolute_time returns CPU ticks.
        // On Apple Silicon the ratio is commonly 125/3, not one-to-one.
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        let ticks = mach_absolute_time()
        return ticks / UInt64(scale.denom) * UInt64(scale.numer)
            + ticks % UInt64(scale.denom) * UInt64(scale.numer) / UInt64(scale.denom)
    }

    // Fixed key codes are the fallback for character lookup and the canonical
    // codes for function/navigation keys. Resolve character layout at delivery.
    static func virtualKey(for key: String) -> CGKeyCode? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = ["A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
                       "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
                       "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
                       "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
                       "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
                       "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
                       "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let value = letters[key.uppercased()] { return CGKeyCode(value) }
        let standard = ["0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
                        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
                        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
                        "`": kVK_ANSI_Grave, "GRAVE": kVK_ANSI_Grave, "BACKTICK": kVK_ANSI_Grave,
                        "-": kVK_ANSI_Minus, "MINUS": kVK_ANSI_Minus,
                        "=": kVK_ANSI_Equal, "EQUAL": kVK_ANSI_Equal,
                        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
                        "\\": kVK_ANSI_Backslash, "BACKSLASH": kVK_ANSI_Backslash,
                        ";": kVK_ANSI_Semicolon, "SEMICOLON": kVK_ANSI_Semicolon,
                        "'": kVK_ANSI_Quote, "QUOTE": kVK_ANSI_Quote,
                        ",": kVK_ANSI_Comma, "COMMA": kVK_ANSI_Comma,
                        ".": kVK_ANSI_Period, "PERIOD": kVK_ANSI_Period,
                        "/": kVK_ANSI_Slash, "SLASH": kVK_ANSI_Slash,
                        "SPACE": kVK_Space, "SPACEBAR": kVK_Space, "TAB": kVK_Tab,
                        "RETURN": kVK_Return, "ENTER": kVK_Return,
                        "ESC": kVK_Escape, "ESCAPE": kVK_Escape,
                        "BACKSPACE": kVK_Delete, "DELETE": kVK_ForwardDelete,
                        "LEFT": kVK_LeftArrow, "ARROWLEFT": kVK_LeftArrow,
                        "RIGHT": kVK_RightArrow, "ARROWRIGHT": kVK_RightArrow,
                        "UP": kVK_UpArrow, "ARROWUP": kVK_UpArrow,
                        "DOWN": kVK_DownArrow, "ARROWDOWN": kVK_DownArrow,
                        "HOME": kVK_Home, "END": kVK_End,
                        "PAGEUP": kVK_PageUp, "PAGEDOWN": kVK_PageDown]
        if let value = standard[key] { return CGKeyCode(value) }
        if key.uppercased().hasPrefix("F"), let number = Int(key.dropFirst()), (1...functions.count).contains(number) {
            return CGKeyCode(functions[number - 1])
        }
        return nil
    }

    static func inputPIDs() -> Set<pid_t> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        var result = Set<pid_t>()
        for object in objects {
            guard uintProperty(kAudioProcessPropertyIsRunningInput, object) == 1,
                  let pid = uintProperty(kAudioProcessPropertyPID, object) else { continue }
            result.insert(pid_t(pid))
        }
        return result
    }
    static func uintProperty(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    static func executable(_ pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }
}

// Previously parsed inline in post. Preserve the complete user-saved chord,
// accepting Electron's common aliases/case and standard punctuation without
// replacing a custom shortcut or changing the system keyboard layout.
struct VoiceKeyCombination {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    private let baseCharacter: String?

    static func modifierFlag(_ value: String) -> CGEventFlags? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd", "cmdorctrl", "commandorcontrol", "super", "meta": return .maskCommand
        case "control", "ctrl": return .maskControl
        case "alt", "option": return .maskAlternate
        case "shift": return .maskShift
        case "fn": return .maskSecondaryFn
        default: return nil
        }
    }

    init(_ accelerator: String) throws {
        var parts = accelerator.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count >= 2, parts.suffix(2).allSatisfy({ $0.isEmpty }) {
            parts.removeLast(2); parts.append("Plus")
        }
        guard let name = parts.last, !name.isEmpty else { throw Self.unsupported }
        var modifiers: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = Self.modifierFlag(part) else { throw Self.unsupported }
            modifiers.insert(flag)
        }
        let shifted = ["~": "`", "TILDE": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
                       "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "PLUS": "=",
                       "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/"]
        let normalized = name.uppercased()
        let base = shifted[normalized] ?? normalized
        if shifted[normalized] != nil { modifiers.insert(.maskShift) }
        guard let code = VoiceBridge.virtualKey(for: base) else { throw Self.unsupported }
        let namedCharacters = ["GRAVE": "`", "BACKTICK": "`", "MINUS": "-", "EQUAL": "=", "BACKSLASH": "\\",
                               "SEMICOLON": ";", "QUOTE": "'", "COMMA": ",", "PERIOD": ".", "SLASH": "/"]
        baseCharacter = base.count == 1 ? base.lowercased() : namedCharacters[base]
        keyCode = code; flags = modifiers
    }

    func resolvedKeyCode(characters: [CGKeyCode: String]? = nil) -> CGKeyCode {
        guard let baseCharacter else { return keyCode }
        let mapping: [CGKeyCode: String]
        if let characters { mapping = characters }
        else if Thread.isMainThread { mapping = Self.layoutCharacters() }
        else { mapping = DispatchQueue.main.sync { Self.layoutCharacters() } }
        // Match Chromium's LayoutAwareGlobalHotkeys lookup: find the base key
        // with no modifiers, then deliver the complete saved modifiers. Control
        // characters and Dvorak-QWERTY Command's alternate table must not change
        // this lookup. Native global registration uses the same fixed fallback.
        return mapping.keys.sorted().first { mapping[$0]?.lowercased() == baseCharacter } ?? keyCode
    }

    private static func layoutCharacters() -> [CGKeyCode: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var mapping: [CGKeyCode: String] = [:]
        for code in CGKeyCode(0)..<128 {
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let result = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdLast()),
                                        UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
            if result == noErr, dead == 0, length > 0 {
                mapping[code] = String(utf16CodeUnits: characters, count: length)
            }
        }
        return mapping
    }

    private static var unsupported: BridgeError {
        .message("Voice shortcut uses an unsupported key or key sequence.")
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    case endUnconfirmed
    case outputUnconfirmed
    case desktopUnavailable(DesktopSessionState)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .endUnconfirmed: return "Couldn't confirm Voice ended. Check Codex."
        case .outputUnconfirmed: return "Sent the speaker shortcut. Couldn't confirm the change in Codex."
        case .desktopUnavailable(let session): return session.message
        }
    }
}

// Ethan's "assign it if missing" setup is permanent, unlike ShortcutLease's
// temporary mute reservation. Keep custom shortcuts and extra fields, filling
// only unset keys. Reuse its compare-before-atomic-write pattern to preserve edits.
struct VoiceShortcutConfiguration {
    // Input and Voice audio have separate commands; preserve any existing key
    // (including the M5's F20 microphone binding) instead of assigning over it.
    static let defaults: [(command: String, key: String)] = [
        (VoiceBridge.startCommand, "Command+Control+Shift+V"),
        (VoiceBridge.endCommand, "Ctrl+Alt+Shift+V"),
        (VoiceBridge.muteCommand, "Command+Control+Shift+M"),
        (VoiceBridge.outputMuteCommand, "Command+Control+Shift+O")
    ]
    var bindingsURL: URL = VoiceBridge.bindingsURL

    func read() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: bindingsURL.path) else { return [] }
        return try parse(Data(contentsOf: bindingsURL))
    }

    private func parse(_ data: Data) throws -> [[String: Any]] {
        guard let bindings = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for entry in bindings {
            guard let command = entry["command"] as? String, !command.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            if let key = entry["key"], !(key is String), !(key is NSNull) { throw CocoaError(.fileReadCorruptFile) }
        }
        return bindings
    }

    // Modifier aliases and ordering must not hide another command's binding.
    static func normalizedKey(_ key: String) -> String {
        let parts = key.split(separator: "+").map { value -> String in
            let part = String(value)
            return VoiceKeyCombination.modifierFlag(part).map { String($0.rawValue) }
                ?? part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return Set(parts).sorted().joined(separator: "+")
    }

    @discardableResult func ensureDefaults() throws -> [String] {
        let fm = FileManager.default
        let original = fm.fileExists(atPath: bindingsURL.path) ? try Data(contentsOf: bindingsURL) : nil
        var bindings = try original.map(parse) ?? []
        var added: [String] = []
        for setting in Self.defaults {
            let indices = bindings.indices.filter { bindings[$0]["command"] as? String == setting.command }
            // Ethan explicitly wants absent/blank/null keys filled; a nonempty
            // custom binding stays untouched, including additional bindings.
            guard !indices.contains(where: { index in
                guard let key = bindings[index]["key"] as? String else { return false }
                return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { continue }
            guard !bindings.contains(where: { entry in
                guard let key = entry["key"] as? String else { return false }
                return Self.normalizedKey(key) == Self.normalizedKey(setting.key)
            }) else {
                throw BridgeError.message("Hello Chat shortcut is already used. Change that shortcut in ChatGPT first.")
            }
            if let index = indices.first {
                guard indices.count == 1 else { throw BridgeError.message("Set a Voice shortcut in Codex settings, then try again.") }
                bindings[index]["key"] = setting.key
            } else {
                bindings.append(["command": setting.command, "key": setting.key])
            }
            added.append(setting.command)
        }
        guard !added.isEmpty else { return [] }
        try fm.createDirectory(at: bindingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = fm.fileExists(atPath: bindingsURL.path) ? try Data(contentsOf: bindingsURL) : nil
        guard current == original else { throw BridgeError.message("ChatGPT shortcuts changed. Try again.") }
        try JSONSerialization.data(withJSONObject: bindings, options: [.prettyPrinted, .sortedKeys])
            .write(to: bindingsURL, options: .atomic)
        return added
    }
}

// A disk write is not a live registration. Remember only our writes made while
// Codex was running; a different launch can load them. A removed/edited binding
// no longer belongs to this receipt. Never call this proof of Voice acceptance.
struct VoiceShortcutActivation: Codable {
    var pid: Int32
    var launchedAt: Date
    var bindings: [String: String]

    func requiresRestart(pid: Int32, launchedAt: Date, current: [[String: Any]]) -> Bool {
        guard self.pid == pid, self.launchedAt == launchedAt else { return false }
        return current.contains { entry in
            guard let command = entry["command"] as? String, let key = entry["key"] as? String else { return false }
            return bindings[command] == key
        }
    }
}

// While armed, use F16 so Agent Flow's F20 preflight refuses to act. Restore only our own changes;
// never overwrite user edits. The recovery file survives a crash, and is restored next launch.
final class ShortcutLease {
    let recoveryURL: URL
    let bindingsURL: URL
    private(set) var deliveryKey: String?
    init(bindingsURL: URL = VoiceBridge.bindingsURL,
         recoveryURL: URL = AppPaths.support.appendingPathComponent("shortcut-recovery.json")) {
        self.bindingsURL = bindingsURL; self.recoveryURL = recoveryURL
    }
    func acquire() throws {
        try restore()
        let original = try Data(contentsOf: bindingsURL)
        var bindings = try JSONSerialization.jsonObject(with: original) as? [[String: Any]] ?? []
        let mute = bindings.filter { $0["command"] as? String == VoiceBridge.muteCommand }
        bindings.removeAll { $0["command"] as? String == VoiceBridge.muteCommand }
        guard !bindings.contains(where: { $0["key"] as? String == VoiceBridge.privateMuteKey }) else { throw BridgeError.message("Hello Chat shortcut is already used. Change that shortcut in ChatGPT first.") }
        let installed: [String: Any] = ["command": VoiceBridge.muteCommand, "key": VoiceBridge.privateMuteKey]
        bindings.append(installed)
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recovery: [String: Any] = ["previous": mute, "installed": installed]
        try JSONSerialization.data(withJSONObject: recovery).write(to: recoveryURL, options: .atomic)
        guard try Data(contentsOf: bindingsURL) == original else { throw BridgeError.message("ChatGPT shortcuts changed. Try again.") }
        try JSONSerialization.data(withJSONObject: bindings, options: [.prettyPrinted, .sortedKeys]).write(to: bindingsURL, options: .atomic)
        // The desktop process already registered the previous shortcut. Editing the
        // file reserves ownership against Agent Flow but does not acknowledge a native
        // hotkey reload. Keep sending that registered shortcut and verify every result.
        deliveryKey = mute.count == 1 ? mute[0]["key"] as? String : nil
    }
    func restore() throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        let recovery = try JSONSerialization.jsonObject(with: Data(contentsOf: recoveryURL)) as? [String: Any] ?? [:]
        let before = try Data(contentsOf: bindingsURL)
        var current = try JSONSerialization.jsonObject(with: before) as? [[String: Any]] ?? []
        let mine = current.filter { $0["command"] as? String == VoiceBridge.muteCommand }
        if mine.count == 1, let installed = recovery["installed"] as? [String: Any], NSDictionary(dictionary: mine[0]).isEqual(to: installed) {
            current.removeAll { $0["command"] as? String == VoiceBridge.muteCommand }
            current.append(contentsOf: recovery["previous"] as? [[String: Any]] ?? [])
            guard try Data(contentsOf: bindingsURL) == before else { throw BridgeError.message("ChatGPT shortcuts changed. Try again.") }
            try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]).write(to: bindingsURL, options: .atomic)
        }
        try FileManager.default.removeItem(at: recoveryURL)
        deliveryKey = nil
    }
}
