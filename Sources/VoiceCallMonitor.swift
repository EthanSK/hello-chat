// Observe real native call controls and metadata-only saved call boundaries.
// This observer sends no shortcuts, starts no server and never ends a call.
import AppKit
import ApplicationServices
import Foundation

import SQLite3

struct VoiceTimeline {
    static func databaseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return codex.appendingPathComponent("sqlite/codex.db")
    }

    // This private schema is supplementary evidence, not a public Codex API.
    // Temporary calls can be memory-only, so their actual controls still win.
    static func hasActiveCall(database: URL, since: Date) -> Bool? {
        activeSessions(database: database, since: since).map { !$0.isEmpty }
    }

    enum RecentChat: Equatable { case thread(UUID), none, unknown }

    // "Last known Voice chat" means the most recently started saved local call.
    // Use the same ledger even after H Chat or Codex restarts. Its catalogue
    // excludes missing chats, and ordinary chat activity never changes the order.
    static func mostRecentChat(database: URL) -> RecentChat {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return .unknown }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT l.thread_id, MAX(json_extract(l.payload_json, '$.occurredAtMs')) AS started
            FROM thread_timeline_ledger l
            JOIN local_thread_catalog c ON c.host_id = l.host_id AND c.thread_id = l.thread_id
            WHERE l.host_id = 'local' AND c.missing_candidate = 0
              AND l.record_id LIKE 'session:%:started' AND json_valid(l.payload_json)
              AND json_extract(l.payload_json, '$.type') = 'session-started'
              AND json_type(l.payload_json, '$.occurredAtMs') = 'integer'
            GROUP BY l.thread_id ORDER BY started DESC LIMIT 2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return .unknown }
        defer { sqlite3_finalize(statement) }
        let first = sqlite3_step(statement)
        if first == SQLITE_DONE { return .none }
        guard first == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: raw)) else { return .unknown }
        let started = sqlite3_column_int64(statement, 1)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return .thread(id)
        case SQLITE_ROW: return sqlite3_column_int64(statement, 1) == started ? .unknown : .thread(id)
        default: return .unknown
        }
    }

    // Verify the same session's End even if a replacement has since started.
    static func hasEnded(database: URL, thread: UUID, session: UUID, since: Date) -> Bool? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT 1 FROM thread_timeline_ledger
            WHERE host_id = 'local' AND lower(thread_id) = ? AND json_valid(payload_json)
              AND lower(json_extract(payload_json, '$.sessionId')) = ?
              AND json_extract(payload_json, '$.type') = 'session-ended'
              AND json_extract(payload_json, '$.occurredAtMs') >= ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, thread.uuidString.lowercased(), -1, transient)
        sqlite3_bind_text(statement, 2, session.uuidString.lowercased(), -1, transient)
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970 * 1000)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }

    static func activeSessions(database: URL, since: Date) -> Set<String>? {
        sessions(database: database, since: since)?.active
    }

    // Also report each exact session's own End record. Absence from the
    // active set alone is not proof that a call closed.
    static func sessions(database: URL, since: Date) -> VoiceLedgerSessions? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT thread_id, json_extract(payload_json, '$.sessionId'),
                   json_extract(payload_json, '$.type'), json_extract(payload_json, '$.occurredAtMs')
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
        var starts: [String: Int64] = [:], ended = Set<String>(), count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return count < 2000 ? VoiceLedgerSessions(startedAtMilliseconds: starts, ended: ended) : nil
            }
            guard result == SQLITE_ROW,
                  let thread = sqlite3_column_text(statement, 0),
                  let session = sqlite3_column_text(statement, 1),
                  let kind = sqlite3_column_text(statement, 2) else { return nil }
            count += 1
            let key = String(cString: thread) + ":" + String(cString: session)
            switch String(cString: kind) {
            case "session-started":
                guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else { return nil }
                let startedAt = sqlite3_column_int64(statement, 3)
                starts[key] = min(starts[key] ?? startedAt, startedAt)
            case "session-ended": starts.removeValue(forKey: key); ended.insert(key)
            default: return nil
            }
        }
    }
}

@MainActor final class VoiceCallMonitor {
    // An unknown guard alone cannot explain a failed native read. Preserve only
    // the collector's numeric/error evidence, never chat labels or speech. — GPT-6.1 Sol
    nonisolated static func recordIncompleteRead(_ state: VoiceSnapshot, readAudio: Bool,
                                                diagnostics: Diagnostics = .shared) {
        guard !state.controlsComplete else { return }
        diagnostics.record("voice.controls.incomplete", numbers: [
            "codex_pid": Double(state.pid ?? 0), "scan_nodes": Double(state.scanNodes),
            "scan_timeouts": Double(state.scanTimeouts), "scan_depth": Double(state.scanDepth)
        ], info: ["failure": state.scanFailure, "accessibility_allowed": String(state.accessibilityAllowed),
                  "application_ready": String(state.applicationReady),
                  "application_has_window": String(state.applicationHasWindow), "read_audio": String(readAudio)])
    }

    var onChange: ((VoiceCallObservation) -> Void)?
    var onSessionStarted: ((Date) -> Void)?
    var onMetadataChanged: (() -> Void)?
    var observesAudioState = false { didSet { if oldValue != observesAudioState { refresh() } } }
    private var lastSessionStart: Int64?
    private var tracker = VoiceCallTracker()
    private var started = false
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var metadataTask: Task<Void, Never>?
    private var metadataAgain = false
    private var workspace: [NSObjectProtocol] = []
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var registrations: [(AXUIElement, CFString)] = []
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private let fileQueue = DispatchQueue(label: "HelloChat.voice-call-files", qos: .utility)
    private let database: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        database = VoiceTimeline.databaseURL(home: home)
    }

    func start() {
        guard !started else { refresh(); return }
        started = true; generation = UUID(); tracker = VoiceCallTracker()
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
                let database = self.database, readAudio = self.observesAudioState
                let evidence = await Task.detached(priority: .utility) {
                    let observedAt = ProcessInfo.processInfo.systemUptime
                    let absent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                        .filter { !$0.isTerminated }.isEmpty
                    // Bound saved boundaries by the same verified process as
                    // the native controls. An unresolved process or launch is
                    // unknown evidence, never "no sessions since now".
                    let app = VoiceBridge.currentApplication()
                    let previousLedger = readAudio ? app?.launchDate.flatMap { VoiceTimeline.sessions(database: database, since: $0) } : nil
                    var callElements: [AXUIElement] = []
                    var audioElements: [AXUIElement] = []
                    let state = VoiceBridge.snapshot(requireEnd: true, readCallAudioState: readAudio,
                        observeCallElements: { callElements = $0 }, observeAudioElements: { audioElements = $0 })
                    Self.recordIncompleteRead(state, readAudio: readAudio)
                    let launch = state.pid != nil && app?.processIdentifier == state.pid ? app?.launchDate : nil
                    let ledger = launch.flatMap { VoiceTimeline.sessions(database: database, since: $0) }
                    let sameCall = readAudio && ledger?.active.count == 1 && previousLedger?.active == ledger?.active
                    let read = VoiceCallRead(controlsPresent: state.endControlAvailable || state.microphone != nil,
                        controlsComplete: state.controlsComplete, applicationAbsent: absent, process: state.pid,
                        ledger: ledger, ledgerResolved: launch != nil, accessibilityAllowed: state.accessibilityAllowed,
                        microphoneMuted: sameCall ? state.microphone.map { $0 == .muted } : nil,
                        outputSilenced: sameCall ? state.outputMuted : nil)
                    return (read, state.pid, callElements, observedAt, audioElements)
                }.value
                guard !Task.isCancelled, self.started, self.generation == generation else { break }
                if let started = evidence.0.ledger?.startedAtMilliseconds.values.max(), started != self.lastSessionStart {
                    self.lastSessionStart = started
                    self.onSessionStarted?(Date(timeIntervalSince1970: Double(started) / 1_000))
                }
                let result = self.tracker.observe(evidence.0)
                self.installAccessibilityObserver(pid: evidence.1, callElements: evidence.2, audioElements: evidence.4)
                self.installFileObservers()
                for var observation in result.observations {
                    observation.observedAt = evidence.3
                    self.onChange?(observation)
                }
                self.refreshAgain = self.refreshAgain || result.readAgain
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
                    guard let app = VoiceBridge.currentApplication(), let launched = app.launchDate else { return Optional<Set<String>>.none }
                    return VoiceTimeline.activeSessions(database: database, since: launched)
                }.value
                guard !Task.isCancelled, self.started, self.generation == generation else { break }
                // Most SQLite writes are unrelated to call boundaries. They
                // must not cause repeated AX scans of a busy conversation.
                if let value, value != self.tracker.activeSessions { self.refresh() }
                self.onMetadataChanged?()
            } while self.metadataAgain && !Task.isCancelled && self.started
            if self.generation == generation { self.metadataTask = nil }
        }
    }

    private func installAccessibilityObserver(pid: pid_t?, callElements: [AXUIElement], audioElements: [AXUIElement]) {
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
            let names = notifications + (observesAudioState && audioElements.contains(where: { CFEqual($0, element) })
                ? [kAXValueChangedNotification, kAXTitleChangedNotification] : [])
            for name in names {
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

// A fresh unique call identity can survive Electron replacing its AX nodes on activation.
// It is supplementary evidence for an already identified native End, never proof from input IO. — GPT-6.1 Sol
enum VoiceCallMembership {
    static func validator() -> (() -> Bool)? {
        guard let app = VoiceBridge.currentApplication(), let launched = app.launchDate,
              let expected = VoiceTimeline.sessions(database: VoiceTimeline.databaseURL(), since: launched)?.startedAtMilliseconds,
              expected.count == 1 else { return nil }
        let pid = app.processIdentifier
        return {
            guard let current = VoiceBridge.currentApplication(), current.processIdentifier == pid,
                  current.launchDate == launched else { return false }
            return VoiceTimeline.sessions(database: VoiceTimeline.databaseURL(), since: launched)?.startedAtMilliseconds == expected
        }
    }
}
