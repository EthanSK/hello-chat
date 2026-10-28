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
    static let startCommand = "composer.startVoiceMode"
    static let endCommand = "realtimeVoice.endCall"
    static let privateMuteKey = "Command+Control+Option+Shift+F16"
    static let bindingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/keybindings.json")

    static func snapshot(readMicrophone: Bool = true, maximumDepth: Int = 96) -> VoiceSnapshot {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated && codexProcess($0.processIdentifier) }
        let app = applications.count == 1 ? applications[0] : nil
        let pids = inputPIDs()
        let voice = app?.bundleURL.map { bundle in pids.contains { executable($0)?.hasPrefix(bundle.path + "/Contents/") == true } } ?? false
        let recorder = pids.contains { executable($0)?.hasPrefix("/Applications/AgentFlow.app/Contents/") == true }
        let controls = readMicrophone ? voiceControls(app?.processIdentifier, maximumDepth: maximumDepth) : Controls()
        return VoiceSnapshot(pid: app?.processIdentifier, inputRunning: voice, recorderRunning: recorder,
                             microphone: controls.microphone, accessibilityAllowed: AXIsProcessTrusted(), endControlAvailable: controls.end != nil,
                             controlsComplete: controls.complete, scanNodes: controls.nodes, scanTimeouts: controls.timeouts, scanDepth: controls.depth, scanFailure: controls.failure)
    }

    // Passive, one-shot reads only. No AXPress, focus/activation writes or pointer automation.
    static func microphoneState(_ pid: pid_t?) -> MicrophoneState? {
        voiceControls(pid).microphone
    }

    // Exact native end actions from the installed Codex Voice presentations.
    // An explicit End action is idempotent; a start/toggle shortcut is not.
    static func isEndVoiceLabel(_ label: String) -> Bool {
        ["end voice", "end voice chat", "stop voice chat"].contains(label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // Send the user's explicit stop only after finding a current native End
    // control in the live window tree. Detached Electron AX objects can still
    // report enabled/visible/End after a call closes, so never cache them.
    // Codex's configured "Toggle voice chat" shortcut starts OR stops Voice.
    // AXPress can acknowledge without invoking Electron's button handler.
    // Send the proven shortcut only after revalidating an active End control.
    static func requestActiveEnd(record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws -> pid_t? {
        guard AXIsProcessTrusted() else { throw BridgeError.message("Allow Accessibility for HelloChat, then try again.") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated && codexProcess($0.processIdentifier) }
        guard !apps.isEmpty else { return nil }
        guard apps.count == 1 else { throw BridgeError.message("Couldn't identify the active Codex window.") }
        let app = apps[0], pid = app.processIdentifier
        func currentEnd() throws -> AXUIElement? {
            let controls = voiceControls(pid, requireEnd: true)
            guard let found = controls.end, usableEnd(found, pid: pid) else {
                guard controls.complete else { throw BridgeError.message("Couldn't find End Voice in Codex.") }
                // Process input alone may belong to dictation or a residual
                // stream. A complete absent Voice tree authorizes no action.
                return nil
            }
            return found
        }
        guard try currentEnd() != nil else { return nil }
        if Thread.isMainThread { app.activate(options: []) }
        else { _ = DispatchQueue.main.sync { app.activate(options: []) } }
        Thread.sleep(forTimeInterval: 0.2)
        // Activation can replace/close the call. Read live membership again;
        // checking attributes of the earlier object does not establish it.
        guard try currentEnd() != nil else { return nil }
        try post(command: startCommand, pid: pid)
        record?("voice.end.toggle_sent", [:], ["control": "fresh_tree"])
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
    static func endCall(pid: pid_t, record: ((String, [String: Double], [String: String]) -> Void)? = nil) throws {
        let controls = voiceControls(pid, requireEnd: true)
        guard let button = controls.end else { throw BridgeError.message("Couldn't find End Voice in Codex.") }
        AXUIElementSetMessagingTimeout(button, 0.04)
        let enabled = attribute(kAXEnabledAttribute, button) as? Bool
        let hidden = attribute("AXHidden", button) as? Bool
        let info = ["label": controls.endLabel ?? "unknown", "enabled": enabled.map { String($0) } ?? "unknown", "hidden": hidden.map { String($0) } ?? "unknown"]
        record?("voice.end.toggle.requested", ["pid": Double(pid)], info)
        guard usableEnd(button, pid: pid) else { throw BridgeError.message("Couldn't confirm Codex Voice. Check Voice in Codex.") }
        try post(command: startCommand, pid: pid)
        record?("voice.end.toggle_sent", [:], ["control": "fresh"])
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
        var microphone: MicrophoneState?
        var end: AXUIElement?
        var endLabel: String?
        var complete = false
        var nodes = 0
        var timeouts = 0
        var depth = 0
        var failure = ""
    }
    private struct Identity: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private static func voiceControls(_ pid: pid_t?, requireEnd: Bool = false, maximumDepth: Int = 96) -> Controls {
        guard let pid, AXIsProcessTrusted(), codexProcess(pid) else { return Controls() }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.04)
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
        var queue: [(AXUIElement, Int)] = (windows.isEmpty ? [root] : windows).map { ($0, 0) }
        var seen = Set<Identity>()
        let deadline = Date().addingTimeInterval(2)
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
                for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                    if let label = read(name, element) as? String {
                        if let state = MicrophoneState.accessibilityLabel(label) { result.microphone = state }
                        if isEndVoiceLabel(label) {
                            result.end = element; result.endLabel = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                // A snapshot only needs one exact Voice control to establish
                // state. Don't keep scanning a large chat for an absent End
                // button after the microphone was already identified.
                if result.end != nil || (!requireEnd && result.microphone != nil) { result.complete = true; return result }
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

    static func post(command: String, pid: pid_t, deliveryKey: String? = nil) throws {
        guard AXIsProcessTrusted() else { throw BridgeError.message("Allow Accessibility for HelloChat, then try again.") }
        guard codexProcess(pid) else { throw BridgeError.message("ChatGPT changed or closed. Check Voice again.") }
        let bindings = FileManager.default.fileExists(atPath: bindingsURL.path)
            ? (try JSONSerialization.jsonObject(with: Data(contentsOf: bindingsURL)) as? [[String: Any]] ?? []) : []
        guard let key = deliveryKey ?? bindings.first(where: { $0["command"] as? String == command })?["key"] as? String
                ?? (command == startCommand ? "Control+Shift+V" : nil) else {
            throw BridgeError.message("Set a Voice shortcut in Codex settings, then try again.")
        }
        let keys: [String: CGKeyCode] = ["F16": CGKeyCode(kVK_F16), "F17": CGKeyCode(kVK_F17), "F19": CGKeyCode(kVK_F19), "F20": CGKeyCode(kVK_F20), "V": CGKeyCode(kVK_ANSI_V)]
        let parts = key.components(separatedBy: "+")
        guard let last = parts.last, let virtualKey = keys[last] else { throw BridgeError.message("Voice shortcut isn't supported. Use F17 or Control+Shift+V in ChatGPT settings.") }
        var flags: CGEventFlags = []
        if parts.contains(where: { ["Command", "Cmd", "CmdOrCtrl", "CommandOrControl"].contains($0) }) { flags.insert(.maskCommand) }
        if parts.contains(where: { ["Control", "Ctrl"].contains($0) }) { flags.insert(.maskControl) }
        if parts.contains(where: { ["Option", "Alt"].contains($0) }) { flags.insert(.maskAlternate) }
        if parts.contains("Shift") { flags.insert(.maskShift) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            throw BridgeError.message("Could not send Voice shortcut.")
        }
        down.flags = flags; up.flags = flags
        // Match Agent Flow's established process-targeted transport, including fresh
        // event timestamps rather than delivering an indistinguishable key pair.
        down.timestamp = mach_absolute_time(); down.postToPid(pid)
        up.timestamp = mach_absolute_time(); up.postToPid(pid)
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

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
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
        guard !bindings.contains(where: { $0["key"] as? String == VoiceBridge.privateMuteKey }) else { throw BridgeError.message("HelloChat shortcut is already used. Change that shortcut in ChatGPT first.") }
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
