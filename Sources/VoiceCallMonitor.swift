// Observe real native call controls and metadata-only saved call boundaries.
// This observer sends no shortcuts, starts no server and never ends a call.
import AppKit
import ApplicationServices
import Foundation
import SQLite3

struct VoiceTimeline {
    // This private schema is supplementary evidence, not a public Codex API.
    // Temporary calls can be memory-only, so their actual controls still win.
    static func hasActiveCall(database: URL, since: Date) -> Bool? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT thread_id, json_extract(payload_json, '$.sessionId'),
                   json_extract(payload_json, '$.type')
            FROM thread_timeline_ledger
            WHERE host_id = 'local' AND json_valid(payload_json)
              AND json_extract(payload_json, '$.occurredAtMs') >= ?
              AND json_extract(payload_json, '$.type') IN ('session-started', 'session-ended')
            ORDER BY thread_id, sequence LIMIT 2000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970 * 1000)
        var active = Set<String>(), count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return count < 2000 ? !active.isEmpty : nil }
            guard result == SQLITE_ROW,
                  let thread = sqlite3_column_text(statement, 0),
                  let session = sqlite3_column_text(statement, 1),
                  let kind = sqlite3_column_text(statement, 2) else { return nil }
            count += 1
            let key = String(cString: thread) + ":" + String(cString: session)
            switch String(cString: kind) {
            case "session-started": active.insert(key)
            case "session-ended": active.remove(key)
            default: return nil
            }
        }
    }
}

@MainActor final class VoiceCallMonitor {
    var onChange: ((VoiceCallPresence) -> Void)?
    private var decision = VoiceCallDecision()
    private var started = false
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var metadataTask: Task<Void, Never>?
    private var metadataAgain = false
    private var persistedCallActive = false
    private var workspace: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var registrations: [(AXUIElement, CFString)] = []
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private let fileQueue = DispatchQueue(label: "HelloChat.voice-call-files", qos: .utility)
    private let database: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        database = codex.appendingPathComponent("sqlite/codex.db")
    }

    func start() {
        guard !started else { refresh(); return }
        started = true; generation = UUID(); decision = VoiceCallDecision(); persistedCallActive = false
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspace.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    func stop() {
        started = false; generation = UUID(); refreshAgain = false
        refreshTask?.cancel(); refreshTask = nil
        metadataTask?.cancel(); metadataTask = nil; metadataAgain = false
        for token in workspace { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspace.removeAll(); removeAccessibilityObserver()
        for source in fileSources.values { source.cancel() }
        fileSources.removeAll()
    }

    // Native notifications coalesce behind one background read. There is no
    // extra delay in Start/End and no full-tree polling loop while idle.
    func refresh() {
        guard started else { return }
        if refreshTask != nil { refreshAgain = true; return }
        let generation = self.generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                let database = self.database
                let evidence = await Task.detached(priority: .utility) {
                    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                        .filter { !$0.isTerminated }
                    var callElements: [AXUIElement] = []
                    let state = VoiceBridge.snapshot(requireEnd: true, observeCallElements: { callElements = $0 })
                    let since = apps.count == 1 ? apps[0].launchDate ?? Date() : Date()
                    return (state, apps.isEmpty, VoiceTimeline.hasActiveCall(database: database, since: since), callElements)
                }.value
                guard !Task.isCancelled, self.started, self.generation == generation else { break }
                let state = evidence.0
                if let active = evidence.2 { self.persistedCallActive = active }
                let repeatRead = self.decision.observe(controlsPresent: state.endControlAvailable || state.microphone != nil,
                    controlsComplete: state.controlsComplete, persistedCallActive: self.persistedCallActive, applicationAbsent: evidence.1)
                self.installAccessibilityObserver(pid: state.pid, callElements: evidence.3)
                self.installFileObservers()
                self.onChange?(self.decision.presence)
                self.refreshAgain = self.refreshAgain || repeatRead
            } while self.refreshAgain && !Task.isCancelled && self.started
            if self.generation == generation { self.refreshTask = nil }
        }
    }

    private func metadataChanged() {
        guard started else { return }
        if metadataTask != nil { metadataAgain = true; return }
        let generation = self.generation
        metadataTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.metadataAgain = false
                let database = self.database
                let value = await Task.detached(priority: .utility) {
                    guard let app = VoiceBridge.currentApplication(), let launched = app.launchDate else { return Optional<Bool>.none }
                    return VoiceTimeline.hasActiveCall(database: database, since: launched)
                }.value
                guard !Task.isCancelled, self.started, self.generation == generation else { break }
                // Most SQLite writes are unrelated to call boundaries. They
                // must not cause repeated AX scans of a busy conversation.
                if let value, value != self.persistedCallActive { self.refresh() }
            } while self.metadataAgain && !Task.isCancelled && self.started
            if self.generation == generation { self.metadataTask = nil }
        }
    }

    private func installAccessibilityObserver(pid: pid_t?, callElements: [AXUIElement]) {
        guard let pid, AXIsProcessTrusted() else { removeAccessibilityObserver(); return }
        if observedPID != pid {
            removeAccessibilityObserver()
            var created: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                let monitor = Unmanaged<VoiceCallMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor [weak monitor] in monitor?.refresh() }
            }, &created) == .success, let created else { return }
            observer = created; observedPID = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        guard let observer else { return }
        // Window and call-control notifications cover manually opened and
        // temporary chats too. Rebind replaced controls after each real read.
        let root = AXUIElementCreateApplication(pid)
        let windows = VoiceBridge.attribute(kAXWindowsAttribute, root) as? [AXUIElement] ?? []
        let elements = [root] + windows + callElements
        let notifications = [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                             kAXFocusedWindowChangedNotification, kAXLayoutChangedNotification, "AXChildrenChanged",
                             "AXLoadComplete", "AXLayoutComplete"]
        for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
        registrations.removeAll()
        for element in elements {
            for name in notifications {
                if AXObserverAddNotification(observer, element, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque()) == .success {
                    registrations.append((element, name as CFString))
                }
            }
        }
    }

    private func removeAccessibilityObserver() {
        if let observer {
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        registrations.removeAll(); observer = nil; observedPID = nil
    }

    private func installFileObservers() {
        let paths = [database.deletingLastPathComponent().path, database.path, database.path + "-wal"]
        for path in paths where fileSources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .revoke], queue: fileQueue)
            source.setEventHandler { [weak self, weak source] in
                let replaced = source?.data.contains(.rename) == true || source?.data.contains(.delete) == true
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
                    if replaced { self.fileSources.removeValue(forKey: path)?.cancel() }
                    self.installFileObservers()
                    self.metadataChanged()
                }
            }
            source.setCancelHandler { close(descriptor) }
            fileSources[path] = source; source.resume()
        }
    }
}
