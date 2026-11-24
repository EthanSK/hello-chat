// Ethan's “Call Dot” and “Hang up” control Your dot, not Codex realtime Voice.
// Native controls were inspected by Claude Opus 5.5; implementation by GPT-6.1 Sol.
import AppKit
import ApplicationServices
import Darwin
import Foundation

enum DotCallCommand {
    // Bound the whole AX traversal, rather than restarting a limit for each
    // descendant search. Uptime keeps clock adjustments from extending it.
    struct ReadBudget {
        let deadline: TimeInterval
        let maximumNodes: Int
        let maximumDepth: Int
        private(set) var visited = 0
        init(now: TimeInterval, seconds: TimeInterval = 2, maximumNodes: Int = 12000, maximumDepth: Int = 70) {
            deadline = now + seconds; self.maximumNodes = maximumNodes; self.maximumDepth = maximumDepth
        }
        func permitsRead(now: TimeInterval, cancelled: Bool) -> Bool { !cancelled && now < deadline }
        mutating func visit(depth: Int, now: TimeInterval, cancelled: Bool) -> Bool {
            guard permitsRead(now: now, cancelled: cancelled), depth <= maximumDepth, visited < maximumNodes else { return false }
            visited += 1
            return true
        }
    }
    enum Action: String, CaseIterable { case start, hangUp }
    enum Press { case notSent, sent, uncertain }
    enum Block: String { case accessibility, desktop, voice, disabled }
    enum State: String, Codable { case inactive, starting, active, unknown, ambiguous, unavailable }
    struct Snapshot: Equatable { let state: State; let pid: pid_t?; var mayStart = false; var block: Block? = nil }
    struct Result: Equatable {
        let status: String
        let state: State
        var confirmed: Bool { status == "confirmed" || status == "unchanged" }
        var submitted: Bool { status == "submitted" }
        var beforeDispatch: Bool { ["unavailable", "changed", "busy", "voice", "accessibility", "desktop", "disabled", "notFound"].contains(status) }
        var message: String {
            switch (status, state) {
            case ("confirmed", .active): return "Dot call is active."
            case ("unchanged", .active): return "Dot call is already active."
            case ("confirmed", .inactive): return "Dot call is off."
            case ("unchanged", .inactive): return "Dot call is already off."
            case ("submitted", _): return "Dot call is opening."
            case ("busy", _): return "A Dot command is already running."
            case ("changed", _): return "ChatGPT changed while opening Your dot. Try again."
            case ("unavailable", .ambiguous): return "Found more than one Dot control."
            case ("voice", _): return "Dot call wasn’t started. Codex Voice is active or its status is unknown."
            case ("accessibility", _): return "Allow Accessibility for Hello Chat in System Settings."
            case ("notFound", _): return "Couldn’t find Dot call controls."
            case ("unconfirmed", _): return "Couldn’t confirm the Dot call. Check Your dot in ChatGPT."
            default: return "Couldn’t control the Dot call. Open Your dot in ChatGPT, then try again."
            }
        }
    }
    struct Environment {
        var read: () async -> Snapshot
        var open: () async -> Bool
        var press: (Action) async -> Press
        var confirm: (Action) async -> Snapshot
    }
    static func perform(_ action: Action, using environment: Environment) async -> Result {
        var before = await environment.read()
        if action == .start, [.active, .starting].contains(before.state) {
            return Result(status: before.state == .active ? "unchanged" : "submitted", state: before.state)
        }
        if action == .hangUp, before.state == .inactive { return Result(status: "unchanged", state: .inactive) }
        guard !Task.isCancelled, before.state != .ambiguous,
              action != .start || before.mayStart else { return Result(status: before.block?.rawValue ?? "unavailable", state: before.state) }
        // Hang up never opens or navigates the app. Missing controls are a
        // no-dispatch result, not permission to start a different call surface.
        // Found by Claude Opus 5.5; fixed by GPT-6.1 Sol.
        if action == .hangUp, ![.active, .starting].contains(before.state) { return Result(status: "notFound", state: before.state) }
        if before.pid == nil || before.state == .unknown || before.state == .unavailable {
            guard await environment.open(), !Task.isCancelled else { return Result(status: "unavailable", state: before.state) }
            let opened = await environment.read()
            guard before.pid == nil || before.pid == opened.pid else { return Result(status: "changed", state: .unknown) }
            before = opened
        }
        if action == .start, [.active, .starting].contains(before.state) {
            return Result(status: before.state == .active ? "unchanged" : "submitted", state: before.state)
        }
        if action == .hangUp, before.state == .inactive { return Result(status: "unchanged", state: .inactive) }
        let ready = action == .start ? before.state == .inactive && before.mayStart : [.active, .starting].contains(before.state)
        guard ready, !Task.isCancelled else { return Result(status: before.block?.rawValue ?? "unavailable", state: before.state) }
        switch await environment.press(action) {
        case .notSent: return Result(status: "unavailable", state: before.state)
        case .uncertain: return Result(status: "unconfirmed", state: .unknown)
        case .sent: break
        }
        let after = await environment.confirm(action)
        guard after.pid == before.pid else { return Result(status: "unconfirmed", state: .unknown) }
        if (action == .start && after.state == .active) || (action == .hangUp && after.state == .inactive) {
            return Result(status: "confirmed", state: after.state)
        }
        return Result(status: action == .start && after.state == .starting ? "submitted" : "unconfirmed", state: after.state)
    }

    @MainActor static func perform(_ action: Action) async -> Result {
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lock = Darwin.open(AppPaths.support.appendingPathComponent("dot-call.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return Result(status: "unavailable", state: .unknown) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return Result(status: "busy", state: .unknown) }
            defer { flock(lock, LOCK_UN) }
            let native = Native()
            return await withTaskCancellationHandler(operation: {
                await perform(action, using: Environment(
                    read: { await Task.detached { native.read() }.value },
                    open: {
                        guard !Task.isCancelled,
                              await VoiceBridge.openChat(native.pid, URL(string: "codex://dots")!) else { return false }
                        return await Task.detached { native.waitForControls() }.value
                    },
                    press: { action in await Task.detached { native.press(action) }.value },
                    confirm: { action in await Task.detached { native.confirm(action) }.value }))
            }, onCancel: { native.cancel() })
        } catch { return Result(status: "unavailable", state: .unknown) }
    }

    // Exact AX labels and ancestors come from the installed Dot profile. Never
    // use realtimeVoice toggles, a meeting Hang up button, or a guessed shortcut.
    private final class Native: @unchecked Sendable {
        var pid: pid_t?
        private let cancellation = NSLock()
        private var cancelled = false
        private var waitingLoop: CFRunLoop?
        private var isCancelled: Bool { cancellation.lock(); defer { cancellation.unlock() }; return cancelled }
        func cancel() {
            cancellation.lock(); cancelled = true; let loop = waitingLoop; cancellation.unlock()
            if let loop { CFRunLoopStop(loop) }
        }
        private var start: AXUIElement?
        private var hangUp: AXUIElement?
        private var profile: AXUIElement?
        private var region: AXUIElement?
        private var observed: Snapshot?
        private var app: AXUIElement?
        private var budget = ReadBudget(now: 0)
        private enum Failure: Error { case incomplete }

        func read() -> Snapshot {
            budget = ReadBudget(now: ProcessInfo.processInfo.systemUptime)
            guard !isCancelled else { return Snapshot(state: .unavailable, pid: pid) }
            guard AXIsProcessTrusted() else { return Snapshot(state: .unavailable, pid: pid, block: .accessibility) }
            guard DesktopSessionState.current == .interactive else { return Snapshot(state: .unavailable, pid: pid, block: .desktop) }
            guard let running = VoiceBridge.currentApplication() else { return Snapshot(state: .inactive, pid: nil, mayStart: true) }
            if let pid, running.processIdentifier != pid { return Snapshot(state: .unknown, pid: running.processIdentifier) }
            pid = running.processIdentifier
            let app = AXUIElementCreateApplication(running.processIdentifier)
            self.app = app
            start = nil; hangUp = nil; profile = nil; region = nil
            do {
                let windows = try children(app, key: kAXWindowsAttribute)
                var profiles: [(AXUIElement, AXUIElement)] = [], calls: [(AXUIElement, AXUIElement, Bool)] = []
                for window in windows {
                    for group in try search(window, matching: { element in
                        let title = try self.label(element)
                        return try (self.string(kAXSubroleAttribute, element) == "AXApplicationDialog" && ["Your dot’s profile", "Your dot's profile"].contains(title))
                            || CodexCallControlScope.isDotContainer(role: self.string(kAXRoleAttribute, element), label: title)
                    }) {
                        let members = try search(group, matching: { _ in true })
                        if try ["Your dot’s profile", "Your dot's profile"].contains(label(group)) {
                            for item in members where try label(item) == "Start call" && string(kAXSubroleAttribute, item) == "AXToggleButton" {
                                profiles.append((group, item))
                            }
                        } else {
                            let ends = try members.filter { try self.string(kAXRoleAttribute, $0) == kAXButtonRole && self.label($0) == "Hang up" }
                            let microphones = try members.filter { try ["Mute microphone", "Unmute microphone"].contains(self.label($0)) }
                            guard ends.count <= 1 else { return Snapshot(state: .ambiguous, pid: pid) }
                            if let end = ends.first, !microphones.isEmpty {
                                let connected = try members.contains { try self.label($0).range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil }
                                calls.append((group, end, connected))
                            }
                        }
                    }
                }
                guard profiles.count <= 1, calls.count <= 1 else { return Snapshot(state: .ambiguous, pid: pid) }
                let snapshot: Snapshot
                if let call = calls.first {
                    region = call.0; hangUp = call.1
                    snapshot = Snapshot(state: call.2 ? .active : .starting, pid: pid, mayStart: false)
                } else if let match = profiles.first, let value = try attribute(kAXValueAttribute, match.1) as? NSNumber {
                    profile = match.0; start = match.1
                    let enabled = try attribute(kAXEnabledAttribute, match.1) as? Bool == true
                    // Voice's existing scan has its own two-second bound. Do
                    // not run it for an already active/starting Dot call.
                    let mayStart = value.boolValue ? false : VoicePeerControl.localStatus().status == .inactive
                    snapshot = Snapshot(state: value.boolValue ? .starting : .inactive, pid: pid,
                        mayStart: mayStart && enabled,
                        block: mayStart ? .disabled : .voice)
                } else {
                    let mayStart = VoicePeerControl.localStatus().status == .inactive
                    snapshot = Snapshot(state: .unknown, pid: pid, mayStart: mayStart, block: mayStart ? nil : .voice)
                }
                guard !isCancelled, !Task.isCancelled else { return Snapshot(state: .unknown, pid: pid) }
                observed = snapshot
                return snapshot
            } catch { return Snapshot(state: .unknown, pid: pid) }
        }

        func press(_ action: Action) -> Press {
            let original = action == .start ? start : hangUp
            let originalContainer = action == .start ? profile : region
            let before = observed
            let fresh = read()
            let target = action == .start ? start : hangUp
            let container = action == .start ? profile : region
            guard !isCancelled, !Task.isCancelled, before?.pid == fresh.pid, let original, let originalContainer,
                  let target, let container, CFEqual(original, target), CFEqual(originalContainer, container),
                  action == .start ? fresh.state == .inactive && fresh.mayStart : [.active, .starting].contains(fresh.state),
                  VoiceBridge.attribute(kAXEnabledAttribute, target) as? Bool == true else { return .notSent }
            return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? .sent : .uncertain
        }

        func waitForControls() -> Bool {
            // Match the existing native launch timeout, returning as soon as real
            // controls exist. An absent process is not an inactive Dot control.
            let snapshot = wait(seconds: 10) { state in
                [.starting, .active, .ambiguous].contains(state.state)
                    || (state.state == .inactive && state.pid != nil && self.start != nil)
            }
            return !isCancelled && [.inactive, .starting, .active].contains(snapshot.state)
                && snapshot.pid != nil && (snapshot.state != .inactive || start != nil)
        }
        func confirm(_ action: Action) -> Snapshot {
            wait { state in
                (action == .start && [.active, .starting].contains(state.state)) || (action == .hangUp && state.state == .inactive)
            }
        }
        private func wait(seconds: TimeInterval = 3, until complete: (Snapshot) -> Bool) -> Snapshot {
            // Wait only for actual native readiness/state notifications, never a
            // settling delay and never a second press if confirmation is absent.
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            var state = read()
            guard !complete(state), !isCancelled, let app, let pid else { return state }
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, _ in CFRunLoopStop(CFRunLoopGetCurrent()) }, &observer) == .success,
                  let observer else { return state }
            let loop = CFRunLoopGetCurrent()
            cancellation.lock(); waitingLoop = loop; cancellation.unlock()
            defer { cancellation.lock(); waitingLoop = nil; cancellation.unlock() }
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(loop, source, .defaultMode)
            defer { CFRunLoopRemoveSource(loop, source, .defaultMode) }
            let elements = [app] + [start, hangUp, profile, region].compactMap { $0 }
            var registered = false
            for element in elements {
                for name in [kAXValueChangedNotification, "AXLayoutChanged", kAXWindowCreatedNotification] {
                    if AXObserverAddNotification(observer, element, name as CFString, nil) == .success { registered = true }
                }
            }
            // Close the registration race before sleeping on the run loop.
            state = read()
            while registered, !isCancelled, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, !complete(state) {
                CFRunLoopRunInMode(.defaultMode, max(0, deadline - ProcessInfo.processInfo.systemUptime), true)
                state = read()
            }
            return state
        }

        private func attribute(_ key: String, _ element: AXUIElement) throws -> CFTypeRef? {
            guard budget.permitsRead(now: ProcessInfo.processInfo.systemUptime, cancelled: isCancelled || Task.isCancelled) else { throw Failure.incomplete }
            // AX timeouts belong to each object, not just its application.
            AXUIElementSetMessagingTimeout(element, 0.04)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            guard status == .success || status == .noValue || status == .attributeUnsupported else { throw Failure.incomplete }
            guard budget.permitsRead(now: ProcessInfo.processInfo.systemUptime, cancelled: isCancelled || Task.isCancelled) else { throw Failure.incomplete }
            return value
        }
        private func children(_ element: AXUIElement, key: String = kAXChildrenAttribute) throws -> [AXUIElement] {
            try attribute(key, element) as? [AXUIElement] ?? []
        }
        private func search(_ root: AXUIElement, matching predicate: (AXUIElement) throws -> Bool) throws -> [AXUIElement] {
            var pending = [(root, 0)], result: [AXUIElement] = []
            while let (node, depth) = pending.popLast() {
                guard budget.visit(depth: depth, now: ProcessInfo.processInfo.systemUptime, cancelled: isCancelled || Task.isCancelled) else { throw Failure.incomplete }
                if try predicate(node) { result.append(node) }
                let descendants = try children(node)
                guard descendants.count <= budget.maximumNodes - budget.visited - pending.count else { throw Failure.incomplete }
                pending.append(contentsOf: descendants.map { ($0, depth + 1) })
            }
            return result
        }
        private func string(_ key: String, _ node: AXUIElement) throws -> String { try attribute(key, node) as? String ?? "" }
        private func label(_ node: AXUIElement) throws -> String {
            let title = try string(kAXTitleAttribute, node)
            return try title.isEmpty ? string(kAXDescriptionAttribute, node) : title
        }
    }
}
