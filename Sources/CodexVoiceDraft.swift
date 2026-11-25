/* ============================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-24: reuse of the existing M1-first native draft candidate
 from codex/voice-ultrafast-20261120. The earlier candidate was not
 installed; its placement/readiness fixes require new M1 validation.
 This shared native picker now also preserves ordinary defaults
 around an exact existing-chat speed action. No Voice shortcut here.
 Port/provenance — GPT-6.1 Sol
 ============================================================ */
// Ethan's temporary Codex window is a new, unsent draft. Only its native settings
// picker is operated here. NativeVoice remains the sole sender of the Voice shortcut.
import AppKit
import ApplicationServices

struct DraftChoices: Codable, Equatable {
    var model: String
    var effort: String
    var speed: String

    static let voice = DraftChoices(model: "GPT-6.2 Sol", effort: "High", speed: "Ultrafast")
    static let efforts = ["Minimal", "Low", "Medium", "High", "Extra High", "Max", "Ultra"]
    static func modelAndEffort(_ title: String) -> (String, String)? {
        let title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for effort in efforts.reversed() where title.hasSuffix(" " + effort) {
            let model = String(title.dropLast(effort.count + 1))
            if !model.isEmpty { return (model, effort) }
        }
        return nil
    }
    static func speed(_ title: String) -> String? {
        ["Standard", "Fast", "Ultrafast"].first { title == "Speed " + $0 }
    }
    // Some models (e.g. Opus 5.5 in Codex) show no speed control at all. This label never matches a
    // selectable speed, so a launch from such a model switches the model first and then reads the real speed.
    static let speedUnavailable = "Unavailable"
    // Read the open Select model row, not the power slider's marketing label:
    // Codex says "Standard, 2 of 6" there while its real reasoning is Medium.
    // A closed pill can also lag, so both values must come from this live row.
    // Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    static func modelMenuSelection(_ texts: [String]) -> (model: String, effort: String)? {
        let texts = texts.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        guard texts.count == 2, !texts[0].isEmpty, efforts.contains(texts[1]) else { return nil }
        return (texts[0], texts[1])
    }
}

protocol VoiceDraftPicker: AnyObject {
    func choices() throws -> DraftChoices
    func selectModel(_ value: String) throws
    func selectEffort(_ value: String, beforeStep: (String, String) throws -> Void) throws
    func selectSpeed(_ value: String) throws
    func closeIfEmpty()
}

final class CodexVoiceDraft: VoiceDraftPicker {
    enum OwnershipFailure: LocalizedError {
        case inputChanged, draftChanged
        var errorDescription: String? { CodexVoiceDraft.changed.localizedDescription }
    }
    // The old 'model button' catch also covered ownership cancellation. Record only
    // these fixed causes, never AX labels, draft contents or exception text. — GPT-6.1 Sol
    static func pickerFailureReason(_ error: Error) -> String {
        switch error {
        case OwnershipFailure.inputChanged: return "input-changed"
        case OwnershipFailure.draftChanged: return "draft-changed"
        case is CancellationError: return "cancelled"
        default: return "native-or-readiness"
        }
    }
    private let app: AXUIElement
    private let window: AXUIElement
    private let pid: pid_t
    private let previousApp: NSRunningApplication?
    private let originalInputCounters: [UInt32]
    private static let changed = BridgeError.message("The temporary Codex window changed. Try starting Voice again.")
    private static func string(_ key: String, _ e: AXUIElement) -> String {
        VoiceBridge.attribute(key, e) as? String ?? ""
    }
    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        VoiceBridge.attribute(kAXChildrenAttribute, e) as? [AXUIElement] ?? []
    }
    private static func label(_ e: AXUIElement) -> String {
        let title = string(kAXTitleAttribute, e)
        return title.isEmpty ? string(kAXDescriptionAttribute, e) : title
    }
    private static func element(_ key: String, _ e: AXUIElement) -> AXUIElement? {
        guard let value = VoiceBridge.attribute(key, e), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func press(_ e: AXUIElement) throws {
        guard AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else {
            throw BridgeError.message("Codex couldn’t select that setting.")
        }
    }
    private static func wait<T>(_ message: String, seconds: Double = 2, _ read: () throws -> T?) throws -> T {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let result = try read() { return result }
            Thread.sleep(forTimeInterval: 0.045)
        } while ProcessInfo.processInfo.systemUptime < until
        throw BridgeError.message(message)
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (VoiceBridge.attribute(kAXWindowsAttribute, app) as? [AXUIElement] ?? [])
            .filter { string(kAXSubroleAttribute, $0) == kAXStandardWindowSubrole }
    }
    private init(app: AXUIElement, window: AXUIElement, pid: pid_t, previousApp: NSRunningApplication?, inputCounters: [UInt32]) {
        self.app = app; self.window = window; self.pid = pid
        self.previousApp = previousApp
        originalInputCounters = inputCounters
    }
    static func open(pid: pid_t) throws -> VoiceDraftPicker {
        guard AXIsProcessTrusted(), VoiceBridge.currentApplication()?.processIdentifier == pid else { throw changed }
        guard let placement = draftPlacement() else {
            throw BridgeError.message("Couldn’t identify the MacBook display for the temporary Codex window.")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let bar = element(kAXMenuBarAttribute, app),
              let file = children(bar).first(where: { label($0) == "File" }),
              let menu = children(file).first(where: { string(kAXRoleAttribute, $0) == kAXMenuRole }),
              let new = children(menu).first(where: { string(kAXRoleAttribute, $0) == kAXMenuItemRole && label($0) == "New Window" })
        else { throw BridgeError.message("Couldn’t find New Window in Codex.") }
        let before = windows(app)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let originalInputCounters = inputCounters()
        try press(new)
        let window: AXUIElement = try wait("Couldn’t identify the new Codex window.", seconds: 5) {
            let added = windows(app).filter { candidate in !before.contains { CFEqual($0, candidate) } }
            guard added.count < 2 else { throw changed }
            return added.first
        }
        guard inputCounters() == originalInputCounters else { throw changed }
        let draft = CodexVoiceDraft(app: app, window: window, pid: pid, previousApp: previousApp, inputCounters: originalInputCounters)
        var missing = "window"
        do {
            _ = try wait("Couldn’t verify the empty Codex draft.", seconds: 12) {
                guard inputCounters() == originalInputCounters else { throw changed }
                if let reason = draft.emptyProblem() { missing = reason; return nil as Bool? }
                return true
            }
            // A newly created Electron window can reapply its own initial size while its
            // renderer loads. Fit the verified empty draft after that required readiness,
            // with failure cleanup covering placement too. Found by Claude Opus 5.5.
            // Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
            try place(window, inside: placement, originalInputCounters: originalInputCounters)
        } catch {
            Diagnostics.shared.record("voice.draft.not_ready", info: ["check": missing])
            draft.closeIfEmpty()
            throw error
        }
        return draft
    }

    // Skip navigation and transcripts entirely. No settings lookup should depend on the
    // number of chats in a sidebar, or use a similarly named control in a different window.
    private func find(_ role: String, from root: AXUIElement? = nil, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [root ?? window]
        var visits = 0
        while let e = stack.popLast(), visits < 1400 {
            visits += 1
            let r = Self.string(kAXRoleAttribute, e)
            if r == role, matching(e) { return e }
            if ["AXStaticText", "AXImage", "AXMenuItem", "AXButton", "AXPopUpButton", "AXTextArea", "AXOutline", "AXList"].contains(r) { continue }
            let sub = Self.string(kAXSubroleAttribute, e)
            if ["AXLandmarkNavigation", "AXLandmarkComplementary"].contains(sub) { continue }
            stack.append(contentsOf: Self.children(e))
        }
        return nil
    }
    private func named(_ role: String, _ name: String) -> AXUIElement? {
        find(role) { Self.label($0) == name }
    }
    private func emptyProblem() -> String? {
        guard Self.windows(app).contains(where: { CFEqual($0, window) }) else { return "window identity" }
        guard Self.string(kAXTitleAttribute, window) == "ChatGPT" else { return "window title" }
        guard let composer = named(kAXTextAreaRole, "Do anything") else { return "new chat composer" }
        guard (VoiceBridge.attribute("AXDOMClassList", composer) as? [String])?.contains("ProseMirror") == true else { return "composer identity" }
        guard let placeholder = Self.children(composer).only,
              (VoiceBridge.attribute("AXDOMClassList", placeholder) as? [String])?.contains("placeholder") == true else { return "draft contents" }
        guard named(kAXPopUpButtonRole, "Choose project") != nil else { return "new chat page" }
        // Files, pasted images and other attached context can exist with an empty text area.
        if find(kAXButtonRole, matching: { Self.label($0).lowercased().hasPrefix("remove ") }) != nil { return "attached content" }
        return nil
    }
    private func empty() -> Bool { emptyProblem() == nil }
    private func owned() throws {
        guard Self.inputCounters() == originalInputCounters else { throw OwnershipFailure.inputChanged }
        guard empty() else { throw OwnershipFailure.draftChanged }
    }
    private func pill() -> AXUIElement? {
        find(kAXPopUpButtonRole) { Self.label($0) == "Select effort" || DraftChoices.modelAndEffort(Self.label($0)) != nil }
    }
    private func menu() throws -> AXUIElement {
        var pressed = false
        do {
            return try Self.waitForModelMenu(group: {
                try self.owned()
                return self.named(kAXGroupRole, "Select effort")
            }, pill: { self.pill() }, press: {
                try self.owned()
                try Self.press($0)
                pressed = true
            })
        } catch {
            Diagnostics.shared.record("voice.draft.picker_not_ready", info: ["check": pressed ? "open menu" : "model button",
                                                                          "reason": Self.pickerFailureReason(error)])
            throw error
        }
    }
    // An empty composer does not establish model-button readiness. Share the
    // existing two-second menu-opening bound across its fresh button and popover
    // reads, with one press at most; never add padding or repeat the action.
    // Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    static func waitForModelMenu<Element>(group: () throws -> Element?, pill: () -> Element?,
                                          press: (Element) throws -> Void) throws -> Element {
        var pressed = false
        return try wait("Couldn’t open the Codex model picker.") {
            if let menu = try group() { return menu }
            if !pressed, let button = pill() {
                try press(button)
                pressed = true
            }
            return nil
        }
    }
    private func dismiss() throws {
        guard let open = named(kAXPopUpButtonRole, "Select effort") else { return }
        try Self.press(open)
        // Bug observed 2026-11-22: choices() closed the popover and selectModel() reopened it at once. menu()
        // then found the "Select effort" group that was still animating closed, pressed "Select model" in it,
        // and the model list never appeared ("Couldn’t find that choice in the Codex picker."). Wait until the
        // closing popover has actually left the tree, so the next menu() opens a fresh, live one.
        _ = try Self.wait("Couldn’t close the Codex model picker.") {
            self.named(kAXGroupRole, "Select effort") == nil && self.named(kAXPopUpButtonRole, "Select effort") == nil ? true : nil
        }
    }
    private func modelMenuSelection(in group: AXUIElement) -> (model: String, effort: String)? {
        guard let row = find(kAXMenuItemRole, from: group, matching: { Self.label($0) == "Select model" }) else { return nil }
        var stack = Array(Self.children(row).reversed()), texts: [String] = [], visited = 0
        while let element = stack.popLast() {
            visited += 1
            guard visited <= 32 else { return nil }
            if Self.string(kAXRoleAttribute, element) == kAXStaticTextRole {
                let value = Self.string(kAXValueAttribute, element)
                if !value.isEmpty { texts.append(value) }
            } else { stack.append(contentsOf: Self.children(element).reversed()) }
        }
        return DraftChoices.modelMenuSelection(texts)
    }
    func choices() throws -> DraftChoices {
        try owned()
        _ = try menu()
        let result: DraftChoices = try Self.wait("Couldn’t read the selected Codex model, reasoning and speed.") {
            try self.owned()
            // Model changes replace this group. Re-find it on every read instead of
            // polling an obsolete AX element. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol.
            guard let group = self.named(kAXGroupRole, "Select effort"),
                  let pair = self.modelMenuSelection(in: group) else { return nil }
            let speed: String
            if let item = self.find(kAXMenuItemRole, from: group, matching: { DraftChoices.speed(Self.label($0)) != nil }) {
                guard let value = DraftChoices.speed(Self.label(item)) else { return nil }
                speed = value
            } else {
                guard self.find(kAXMenuItemRole, from: group, matching: { Self.label($0) == "Power" }) != nil else { return nil }
                speed = DraftChoices.speedUnavailable
            }
            return DraftChoices(model: pair.model, effort: pair.effort, speed: speed)
        }
        try dismiss()
        return result
    }
    private func pick(_ parent: (String) -> Bool, option: @escaping (String) -> Bool) throws {
        let group = try menu()
        guard let item = find(kAXMenuItemRole, from: group, matching: { parent(Self.label($0)) }) else { throw Self.changed }
        try Self.press(item)
        let choice: AXUIElement = try Self.wait("Couldn’t find that choice in the Codex picker.") {
            try self.owned()
            return self.find(kAXMenuItemRole) { option(Self.label($0)) }
        }
        try owned()
        try Self.press(choice)
        try dismiss()
    }
    func selectModel(_ value: String) throws { try pick({ $0 == "Select model" }, option: { $0 == value }) }
    func selectSpeed(_ value: String) throws { try pick({ DraftChoices.speed($0) != nil }, option: { $0 == value || $0.hasPrefix(value + " ") }) }

    func selectEffort(_ value: String, beforeStep: (String, String) throws -> Void) throws {
        guard let goal = DraftChoices.efforts.firstIndex(of: value) else { throw Self.changed }
        for _ in DraftChoices.efforts {
            let before = try choices()
            if before.effort == value { return }
            guard let index = DraftChoices.efforts.firstIndex(of: before.effort) else { throw Self.changed }
            let group = try menu()
            guard let power = find(kAXMenuItemRole, from: group, matching: { Self.label($0) == "Power" }) else { throw Self.changed }
            _ = AXUIElementSetAttributeValue(power, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard let focused = Self.element(kAXFocusedUIElementAttribute, app), CFEqual(focused, power),
                  VoiceBridge.attribute(kAXMainAttribute, window) as? Bool == true else { throw Self.changed }
            let direction = index < goal ? 1 : -1
            try beforeStep(before.effort, DraftChoices.efforts[index + direction])
            let key: CGKeyCode = direction == 1 ? 124 : 123
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            guard CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty,
                  let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { throw Self.changed }
            down.flags = []; up.flags = []
            try owned()
            down.postToPid(pid); up.postToPid(pid)
            _ = try Self.wait("Codex didn’t confirm the reasoning change.") { () -> String? in
                try self.owned()
                guard let group = self.named(kAXGroupRole, "Select effort"),
                      let pair = self.modelMenuSelection(in: group),
                      pair.model == before.model, pair.effort != before.effort else { return nil }
                return pair.effort
            }
            try dismiss()
        }
        throw Self.changed
    }
    func closeIfEmpty() {
        guard Self.inputCounters() == originalInputCounters, empty(),
              let close = Self.element(kAXCloseButtonAttribute, window) else { return }
        let wasFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let wasMain = VoiceBridge.attribute(kAXMainAttribute, window) as? Bool == true
        guard (try? Self.press(close)) != nil, wasFront, wasMain else { return }
        if let previousApp, previousApp.processIdentifier != pid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            _ = previousApp.activate(options: [])
        }
    }
    private static func inputCounters() -> [UInt32] {
        [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].map {
            CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
        }
    }
    // Place only the uniquely created helper window before opening its picker, so it
    // does not sit over another display's video during settings persistence.
    // Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    private static func draftPlacement() -> CGRect? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { draftPlacement() } }
        let screens = NSScreen.screens
        let builtIn = screens.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(id.uint32Value)) != 0
        }
        guard builtIn.count == 1, let screen = builtIn.first, let primary = screens.first else { return nil }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY, width: visible.width, height: visible.height)
        return frame
    }
    private static func place(_ window: AXUIElement, inside frame: CGRect, originalInputCounters: [UInt32]) throws {
        func size() -> CGSize? {
            guard let raw = VoiceBridge.attribute(kAXSizeAttribute, window), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var result = CGSize.zero
            return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
        }
        guard let original = size() else { throw changed }
        var wanted = CGSize(width: min(original.width, frame.width * 2 / 3), height: min(original.height, frame.height * 2 / 3))
        if wanted != original {
            guard let value = AXValueCreate(.cgSize, &wanted),
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else { throw changed }
        }
        _ = try wait("Couldn’t place the temporary Codex window.") { () -> Bool? in
            guard inputCounters() == originalInputCounters else { throw changed }
            guard let actual = size(), actual.width <= frame.width + 1, actual.height <= frame.height + 1 else { return nil }
            var origin = CGPoint(x: (frame.midX - actual.width / 2).rounded(), y: (frame.midY - actual.height / 2).rounded())
            guard let value = AXValueCreate(.cgPoint, &origin),
                  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success,
                  let raw = VoiceBridge.attribute(kAXPositionAttribute, window), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var observed = CGPoint.zero
            guard AXValueGetValue(raw as! AXValue, .cgPoint, &observed) else { return nil }
            return abs(observed.x - origin.x) <= 1 && abs(observed.y - origin.y) <= 1 ? true : nil
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
