// H Chat's exact-chat speed action uses Codex's native composer menu. It never types a slash
// command, sends a message, changes model/reasoning or starts Voice. — GPT-6.1 Sol
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SQLite3

enum CodexChatSpeed {
    enum Speed: String, Codable, CaseIterable {
        case standard = "Standard", fast = "Fast", ultrafast = "Ultrafast"
    }
    struct Selection: Equatable {
        let model: String
        let speed: Speed
        let draft: String
    }
    struct Result: Codable {
        let status: String
        let thread: UUID?
        let speed: Speed?
        let model: String?
        var succeeded: Bool { ["observed", "unchanged", "confirmed"].contains(status) }
        var message: String {
            if succeeded { return "Ultrafast selected for the next turn." }
            if status == "inactive" { return "Codex Voice is off." }
            if status == "changed" { return "The Voice call changed. Try again in the current call." }
            return "Couldn’t set Ultrafast. Open the current Voice chat in a single Codex pane, then try again."
        }
    }
    protocol Picker {
        func read() throws -> Selection
        func select(_ speed: Speed) throws
        func finish() throws
    }
    enum Failure: String, Error {
        case unavailable, ambiguousChat, wrongChat, multiplePanes, busy, unsupported, interrupted, unconfirmed
    }

    static func perform(thread: UUID, speed: Speed?, picker: Picker) -> Result {
        var selected: Selection?
        do {
            let before = try picker.read()
            selected = before
            if let speed, before.speed != speed {
                try picker.select(speed)
                let after = try picker.read()
                guard after.model == before.model, after.draft == before.draft, after.speed == speed
                else { throw Failure.unconfirmed }
                selected = after
            }
            try picker.finish()
            return Result(status: speed == nil ? "observed" : (before.speed == speed ? "unchanged" : "confirmed"),
                          thread: thread, speed: selected?.speed, model: selected?.model)
        } catch {
            try? picker.finish()
            return Result(status: (error as? Failure)?.rawValue ?? "unconfirmed", thread: thread,
                          speed: nil, model: nil)
        }
    }

    static func perform(thread: UUID, speed: Speed?, expectedCall: VoicePeerCall? = nil) -> Result {
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lock = open(AppPaths.support.appendingPathComponent("codex-chat-speed.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw Failure.unavailable }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
            defer { flock(lock, LOCK_UN) }
            return perform(thread: thread, speed: speed, picker: try NativePicker(thread: thread, expectedCall: expectedCall))
        }
        catch { return Result(status: (error as? Failure)?.rawValue ?? "unavailable", thread: thread, speed: nil, model: nil) }
    }

    // The menu, Settings and native Shortcuts all enter here. Resolve the actual local call,
    // open its exact chat, and keep its session identity through every native press. — GPT-6.1 Sol
    @MainActor static func currentVoice(
        resolve: () async -> VoicePeerReceipt = { await Task.detached { VoicePeerControl.localStatus() }.value },
        open: (Int32?, URL) async -> Bool = VoiceBridge.openChat,
        apply: (VoicePeerCall) async -> Result = { call in
            let operation = Task.detached { perform(thread: call.thread, speed: .ultrafast, expectedCall: call) }
            return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        }
    ) async -> Result {
        let before = await resolve()
        guard before.status == .active, let call = before.call else {
            return Result(status: before.status == .inactive ? "inactive" : "unavailable", thread: nil, speed: nil, model: nil)
        }
        guard !Task.isCancelled,
              let link = URL(string: "codex://threads/" + call.thread.uuidString.lowercased()),
              await open(call.pid, link) else {
            return Result(status: "unavailable", thread: call.thread, speed: nil, model: nil)
        }
        let afterOpen = await resolve()
        guard !Task.isCancelled, afterOpen.status == .active, afterOpen.call == call else {
            return Result(status: "changed", thread: call.thread, speed: nil, model: nil)
        }
        let result = await apply(call)
        let after = await resolve()
        guard !Task.isCancelled, after.status == .active, after.call == call else {
            return Result(status: "changed", thread: call.thread, speed: nil, model: nil)
        }
        return result
    }

    // AX exposes the chat name, not its UUID. Bind a unique live catalogue name to the exact
    // requested UUID; an archived duplicate or concurrent rename makes the action refuse. — GPT-6.1 Sol
    static func uniqueTitle(thread: UUID, database: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw Failure.unavailable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "SELECT name FROM threads WHERE lower(id)=? AND length(name)>0 AND (SELECT COUNT(*) FROM threads other WHERE other.name=threads.name)=1"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw Failure.unavailable }
        defer { sqlite3_finalize(statement) }
        let id = thread.uuidString.lowercased()
        _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.ambiguousChat }
        let title = String(cString: text)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.ambiguousChat }
        return title
    }

    private final class NativePicker: Picker {
        let thread: UUID
        let database: URL
        let title: String
        let pid: pid_t
        let launched: Date
        let app: AXUIElement
        let window: AXUIElement
        let pane: AXUIElement
        let composer: AXUIElement
        var trigger: AXUIElement
        let model: String
        let draft: String
        let input: [UInt32]
        let hadFocus: Bool
        let expectedCall: VoicePeerCall?
        var ownsMenu = false

        init(thread: UUID, expectedCall: VoicePeerCall?) throws {
            guard AXIsProcessTrusted(), DesktopSessionState.current == .interactive,
                  let running = VoiceBridge.currentApplication(), let launched = running.launchDate else { throw Failure.unavailable }
            let home = VoiceTimeline.databaseURL().deletingLastPathComponent().deletingLastPathComponent()
            let candidates = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.range(of: #"^state_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            guard let database = candidates.first else { throw Failure.unavailable }
            let title = try uniqueTitle(thread: thread, database: database)
            let pid = running.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.4)
            let initialInput = Self.inputCounters()
            let window: AXUIElement = try Self.wait {
                guard !Task.isCancelled, Self.inputCounters() == initialInput else { throw Failure.interrupted }
                let matches = Self.children(app, key: kAXWindowsAttribute).filter {
                    Self.string(kAXSubroleAttribute, $0) == kAXStandardWindowSubrole && Self.string(kAXTitleAttribute, $0) == title
                }
                guard matches.count <= 1 else { throw Failure.wrongChat }
                return matches.first
            }
            let panes = try Self.search(window, stopAtPane: true) { Self.isPane($0) }
            guard panes.count == 1, let pane = panes.first else { throw Failure.multiplePanes }
            let rows = try Self.search(window, stopAtPane: true) { Self.string(kAXRoleAttribute, $0) == kAXButtonRole && Self.label($0) == title }
            guard rows.count == 1, Self.string("AXARIACurrent", rows[0]) == "page" else { throw Failure.wrongChat }
            let composers = try Self.search(pane) { Self.string(kAXRoleAttribute, $0) == kAXTextAreaRole }
            let triggers = try Self.search(pane) { Self.string(kAXRoleAttribute, $0) == kAXPopUpButtonRole && Self.string(kAXTitleAttribute, $0).hasPrefix("GPT-") }
            guard composers.count == 1, triggers.count == 1, let composer = composers.first, let trigger = triggers.first,
                  (VoiceBridge.attribute("AXDOMClassList", composer) as? [String])?.contains("ProseMirror") == true else { throw Failure.wrongChat }
            guard try Self.menuItems(app).isEmpty else { throw Failure.busy }
            self.thread = thread; self.database = database; self.title = title; self.pid = pid; self.launched = launched
            self.app = app; self.window = window; self.pane = pane; self.composer = composer; self.trigger = trigger
            self.expectedCall = expectedCall
            model = Self.string(kAXTitleAttribute, trigger); draft = Self.string(kAXValueAttribute, composer)
            input = initialInput; hadFocus = VoiceBridge.attribute(kAXFocusedAttribute, composer) as? Bool == true
        }

        func read() throws -> Selection {
            try owned()
            try open()
            let speed = try Self.wait {
                let items = try Self.menuItems(self.app).compactMap { item -> Speed? in
                    let text = Self.string(kAXTitleAttribute, item)
                    return Speed.allCases.first { text == "Speed " + $0.rawValue }
                }
                guard items.count <= 1 else { throw Failure.wrongChat }
                return items.first
            }
            return Selection(model: model, speed: speed, draft: draft)
        }

        func select(_ speed: Speed) throws {
            try owned(); try open()
            let current = try Self.menuItems(app).filter { Self.string(kAXTitleAttribute, $0).hasPrefix("Speed ") }
            guard current.count == 1 else { throw Failure.unsupported }
            try owned(); try Self.press(current[0])
            let option: AXUIElement = try Self.wait {
                let items = try Self.menuItems(self.app).filter {
                    let text = Self.string(kAXTitleAttribute, $0)
                    return text == speed.rawValue || text.hasPrefix(speed.rawValue + " ")
                }
                guard items.count <= 1 else { throw Failure.wrongChat }
                return items.first
            }
            try owned(); try Self.press(option)
            // Read back the native menu's real value; no fixed post-click delay or message. — GPT-6.1 Sol
            _ = try Self.wait { () -> Bool? in
                try self.owned()
                if try Self.menuItems(self.app).isEmpty { self.ownsMenu = false; try self.open() }
                return try Self.menuItems(self.app).contains { Self.string(kAXTitleAttribute, $0) == "Speed " + speed.rawValue } ? true : nil
            }
        }

        func finish() throws {
            guard ownsMenu else { return }
            defer { ownsMenu = false }
            try owned()
            let items = try Self.menuItems(app)
            if !items.isEmpty {
                try Self.press(trigger)
            }
            // Opus found that the model label can settle after the menu disappears.
            // Resolve the re-rendered button and both conditions together. — GPT-6.1 Sol
            _ = try Self.wait {
                try self.owned()
                return try Self.menuItems(self.app).isEmpty && Self.string(kAXTitleAttribute, self.trigger) == self.model ? true : nil
            }
            guard Self.string(kAXTitleAttribute, trigger) == model,
                  Self.string(kAXValueAttribute, composer) == draft else { throw Failure.unconfirmed }
            if hadFocus, Self.inputCounters() == input {
                _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }

        private func open() throws {
            if ownsMenu { return }
            try owned()
            guard try Self.menuItems(app).isEmpty else { throw Failure.busy }
            try Self.press(trigger); ownsMenu = true
        }

        private func owned() throws {
            guard !Task.isCancelled, Self.inputCounters() == input else { throw Failure.interrupted }
            if let expectedCall {
                let current = VoicePeerControl.localStatus()
                guard current.status == .active, current.call == expectedCall else { throw Failure.interrupted }
            }
            guard let running = VoiceBridge.currentApplication(), running.processIdentifier == pid, running.launchDate == launched,
                  try uniqueTitle(thread: thread, database: database) == title,
                  Self.string(kAXTitleAttribute, window) == title,
                  Self.children(app, key: kAXWindowsAttribute).contains(where: { CFEqual($0, window) }),
                  Self.string(kAXValueAttribute, composer) == draft else { throw Failure.wrongChat }
            let panes = try Self.search(window, stopAtPane: true) { Self.isPane($0) }
            guard panes.count == 1, CFEqual(panes[0], pane) else { throw Failure.multiplePanes }
            let rows = try Self.search(window, stopAtPane: true) { Self.string(kAXRoleAttribute, $0) == kAXButtonRole && Self.label($0) == title }
            guard rows.count == 1, Self.string("AXARIACurrent", rows[0]) == "page" else { throw Failure.wrongChat }
            let triggers = try Self.search(pane) {
                Self.string(kAXRoleAttribute, $0) == kAXPopUpButtonRole &&
                    (Self.string(kAXTitleAttribute, $0).hasPrefix("GPT-") || Self.string(kAXTitleAttribute, $0) == "Select effort")
            }
            guard triggers.count == 1 else { throw Failure.wrongChat }
            trigger = triggers[0]
            let label = Self.string(kAXTitleAttribute, trigger)
            guard label == model || (ownsMenu && label == "Select effort") else { throw Failure.interrupted }
        }

        private static func inputCounters() -> [UInt32] {
            [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        }
        private static func string(_ key: String, _ e: AXUIElement) -> String { VoiceBridge.attribute(key, e) as? String ?? "" }
        private static func label(_ e: AXUIElement) -> String {
            let value = string(kAXDescriptionAttribute, e); return value.isEmpty ? string(kAXTitleAttribute, e) : value
        }
        private static func children(_ e: AXUIElement, key: String = kAXChildrenAttribute) -> [AXUIElement] {
            VoiceBridge.attribute(key, e) as? [AXUIElement] ?? []
        }
        private static func isPane(_ e: AXUIElement) -> Bool {
            (VoiceBridge.attribute("AXDOMClassList", e) as? [String] ?? []).contains { $0.contains("--thread-floating-content-top-inset") }
        }
        private static func search(_ root: AXUIElement, stopAtPane: Bool = false, menusOnly: Bool = false, matching: (AXUIElement) -> Bool) throws -> [AXUIElement] {
            var stack = [root], found: [AXUIElement] = [], visited = 0
            while let e = stack.popLast() {
                visited += 1
                guard visited <= 2000 else { throw Failure.unavailable }
                if matching(e) { found.append(e) }
                let role = string(kAXRoleAttribute, e)
                if menusOnly && ([kAXListRole, kAXOutlineRole].contains(role) ||
                    ["AXLandmarkNavigation", "AXLandmarkComplementary"].contains(string(kAXSubroleAttribute, e))) { continue }
                if (stopAtPane && isPane(e)) || [kAXStaticTextRole, kAXImageRole, kAXButtonRole, kAXPopUpButtonRole, kAXTextAreaRole].contains(role) { continue }
                stack.append(contentsOf: children(e))
            }
            return found
        }
        private static func menuItems(_ app: AXUIElement) throws -> [AXUIElement] {
            try children(app, key: kAXWindowsAttribute).flatMap { window in
                // Opus observed untitled page-content menu items with no open menu.
                // Only named actionable items count as an open composer menu. — GPT-6.1 Sol
                try search(window, menusOnly: true) {
                    string(kAXRoleAttribute, $0) == kAXMenuItemRole && !string(kAXTitleAttribute, $0).isEmpty
                }
            }
        }
        private static func press(_ e: AXUIElement) throws {
            guard AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else { throw Failure.unconfirmed }
        }
        private static func wait<T>(_ read: () throws -> T?) throws -> T {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            repeat {
                if let value = try read() { return value }
                Thread.sleep(forTimeInterval: 0.045)
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw Failure.unconfirmed
        }
    }
}
