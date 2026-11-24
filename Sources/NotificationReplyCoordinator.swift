// The signed H Chat process owns notification reply sessions; the speech hook supplies only notification and media lifecycle facts. — GPT-6.1 Sol
import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation

/// One editable settings store shared by Settings and the notification connection. — GPT-6.1 Sol
@MainActor final class NotificationReplySettings: ObservableObject {
    static let enabledKey = "notificationRepliesEnabled"
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); if oldValue != enabled { changed?() } } }
    @Published private var idleValue: Int
    @Published private var replyValue: Int
    // Clamp before publishing. Assigning an @Published property inside its own didSet recurses through the wrapper. — GPT-6.1 Sol
    var idleSeconds: Int {
        get { idleValue }
        set { let next = min(180, max(10, newValue)); guard next != idleValue else { return }; idleValue = next; defaults.set(next, forKey: "notificationReplyIdleSeconds"); changed?() }
    }
    var replySeconds: Int {
        get { replyValue }
        set { let next = min(180, max(10, newValue)); guard next != replyValue else { return }; replyValue = next; defaults.set(next, forKey: "notificationReplySeconds"); changed?() }
    }
    var changed: (() -> Void)?
    private let defaults: UserDefaults
    var limits: NotificationReplyCore.Limits { .init(idleSeconds: Double(idleSeconds), replySeconds: Double(replySeconds)) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        idleValue = Int(NotificationReplyCore.Limits(idleSeconds: defaults.object(forKey: "notificationReplyIdleSeconds") as? Double ?? 60).idleSeconds)
        replyValue = Int(NotificationReplyCore.Limits(replySeconds: defaults.object(forKey: "notificationReplySeconds") as? Double ?? 120).replySeconds)
    }
}

/// An active capture is separate from frozen deliveries, so FIFO unlock cannot let a newer prepare overwrite an older reply. — GPT-6.1 Sol
@MainActor final class NotificationReplyCoordinator: ObservableObject {
    enum Readiness: String { case ready, disabled, listeningOff, listenerUnavailable, voiceActive, voiceUnknown, agentFlow, desktopUnavailable, codexUnavailable }
    enum Failure: String, Error { case invalidEvent, busy, differentInstance, unavailable }
    struct Presentation { let event: UUID; let phase: NotificationReplyCore.Phase; let reason: String; let spokenText: String; var replyText = "" }
    let settings: NotificationReplySettings
    let instance = UUID()
    @Published private(set) var lastPhase: NotificationReplyCore.Phase?
    @Published private(set) var lastReason = ""
    var currentReadiness: () -> Readiness = { .listenerUnavailable }
    var resetRecognition: (() -> Void)?
    var finalizeRecognition: ((Double, Bool) -> Void)?
    var acceptedReply: (() -> Void)?
    var showPresentation: ((Presentation?) -> Void)?
    var outcome: ((UUID, NotificationReplyCore.Phase, String, Bool) -> Void)?
    var currentDesktop: () -> (executable: URL, pid: Int32)? = {
        guard let app = VoiceBridge.currentApplication(), let executable = try? CodexVoiceSpeed.executable(pid: app.processIdentifier) else { return nil }
        return (executable, app.processIdentifier)
    }
    private let files: NotificationReplyFiles
    private var sessions: [UUID: Session] = [:]
    private var active: UUID?
    private var timer: Timer?
    private var shown: UUID?
    private var originTasks: [UUID: Task<Void, Never>] = [:]
    private var originAgain: Set<UUID> = []
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    private let recording: AgentFlowRecordingMonitor?
    var queueCommand: ([String]) throws -> Int32 = NotificationReplyCoordinator.runQueue
    var clock: () -> Double = { Diagnostics.now }
    var wallClock: () -> Double = { Date().timeIntervalSince1970 }
    var recordingBusy: (() -> Bool)?
    var captureOrigin: (UUID, UUID?, String) async throws -> NotificationReplyOrigin = { thread, turn, question in
        try await Task.detached(priority: .utility) { try NotificationReplyOrigin.capture(thread: thread, turn: turn, question: question) }.value
    }
    var validateOrigin: (NotificationReplyOrigin) throws -> Void = { try $0.validate() }
    private var now: Double { clock() }
    var interceptsSpeech: Bool { active.flatMap { sessions[$0]?.core.interceptsSpeech } ?? false }
    var isComposing: Bool { active.flatMap { sessions[$0]?.core.phase } == .composing }
    var hasOpenAttempt: Bool { sessions.values.contains { !$0.releaseAcknowledged } || !deliveryTasks.isEmpty }
    var readiness: Readiness { !settings.enabled ? .disabled : (recordingBusy?() ?? recording?.recordingOrUnknown ?? true) ? .agentFlow : currentReadiness() }
    var lifecycleCounts: (sessions: Int, watchers: Int, textBytes: Int, checkingBounds: Bool) {
        (sessions.count, sessions.values.reduce(0) { $0 + $1.observers.count },
         sessions.values.reduce(0) { $0 + $1.spokenText.utf8.count + ($1.core.body?.utf8.count ?? 0) }, timer != nil)
    }

    init(settings: NotificationReplySettings? = nil, directory: URL = AppPaths.support.appendingPathComponent("notification-replies-v1"), observeRecording: Bool = true) {
        self.settings = settings ?? NotificationReplySettings()
        files = NotificationReplyFiles(directory: directory)
        recording = observeRecording ? AgentFlowRecordingMonitor() : nil
        self.settings.changed = { [weak self] in self?.cancelAll("settings-changed") }
        recording?.onChange = { [weak self] busy in if busy { self?.cancelAll("agentFlow") } }
    }

    func prepare(event: UUID, thread: UUID, turn: UUID?, question: String, spokenText: String) async throws -> [String: Any] {
        guard !spokenText.isEmpty, spokenText.count <= 2048, question.count <= 160 else { throw Failure.invalidEvent }
        if let existing = sessions[event] {
            guard existing.thread == thread, existing.turn == turn, existing.question == question,
                  existing.spokenFingerprint == Data(SHA256.hash(data: Data(spokenText.utf8))) else { throw Failure.invalidEvent }
            return snapshot(existing)
        }
        guard !interceptsSpeech else { throw Failure.busy }
        prune()
        let session = Session(event: event, thread: thread, turn: turn, question: question, spokenText: spokenText, at: now, limits: settings.limits)
        let admitted = readiness
        sessions[event] = session; startTimer()
        if admitted == .ready { active = event; resetRecognition?() }
        if admitted != .ready { session.core.cancel(admitted.rawValue, unavailable: true) }
        publish(session)
        if admitted == .ready {
            do {
                let origin = try await captureOrigin(thread, turn, question)
                guard sessions[event] === session, session.core.phase == .preparing else { return snapshot(session) }
                session.origin = origin
                installObservers(session)
            } catch { session.core.cancel(Self.reason(error), unavailable: true) }
            publish(session)
        }
        await files.flush()
        return snapshot(session)
    }

    func audioStarted(event: UUID, instance: UUID, uptime: Double, wall: Double) throws -> [String: Any] {
        let session = try selected(event, instance)
        if let started = session.started {
            guard started == uptime else { throw Failure.invalidEvent }; return snapshot(session)
        }
        guard validClock(uptime, wall, maxAge: 10), uptime >= session.core.preparedAt else {
            session.core.cancel("audio-start-stale"); publish(session); return snapshot(session)
        }
        session.started = uptime; session.core.audioStarted(at: uptime)
        publish(session); return snapshot(session)
    }
    func audioEnded(event: UUID, instance: UUID, uptime: Double, wall: Double, completed: Bool) throws -> [String: Any] {
        let session = try selected(event, instance)
        if let ended = session.core.audioEndedAt {
            guard ended == uptime else { throw Failure.invalidEvent }; return snapshot(session)
        }
        guard validClock(uptime, wall, maxAge: 5), let started = session.started, uptime >= started else {
            session.core.cancel("audio-end-stale"); publish(session); return snapshot(session)
        }
        session.core.audioEnded(at: uptime, completed: completed, now: now)
        publish(session); return snapshot(session)
    }
    func cancel(event: UUID, instance: UUID, reason: String) throws -> [String: Any] {
        let session = try selected(event, instance)
        cancelSession(session, reason: "client-cancelled"); return snapshot(session)
    }
    func status(event: UUID, instance: UUID) throws -> [String: Any] {
        let session = try selected(event, instance)
        session.core.ownerSeen(at: now)
        return snapshot(session)
    }

    func mediaReleased(event: UUID, instance: UUID, released: Bool, expiresAt: Double = .infinity) throws -> [String: Any] {
        let session = try selected(event, instance)
        guard !session.releaseAcknowledged else { return snapshot(session) }
        session.releaseAcknowledged = true
        if shown == event { shown = nil; showPresentation?(nil) }
        guard released, session.core.canDispatch, readiness == .ready, let origin = session.origin,
              let body = session.core.body, let desktop = currentDesktop() else {
            if session.core.interceptsSpeech { session.core.cancel(released ? "media-release-before-dispatch" : "media-release-unconfirmed") }
            session.lease.cancel(); publish(session); return snapshot(session)
        }
        let claims = files.directory.appendingPathComponent("dispatch-claims"), lease = session.lease
        let executable = desktop.executable, pid = desktop.pid
        let spokenText = session.spokenText, run = queueCommand, validate = validateOrigin, wall = wallClock
        // No body leaves the app before the exact speaker/FIFO has released and a durable claim is reserved. — GPT-6.1 Sol
        deliveryTasks[event] = Task { [weak self, weak session] in
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result {
                    try origin.dispatch(event: event, spokenText: spokenText, body: body, executable: executable, claims: claims,
                        validate: { try validate(origin) },
                        valid: { lease.valid && wall() < expiresAt && kill(pid, 0) == 0 }, run: run)
                }
            }.value
            guard let self, let session, self.sessions[event] === session else { return }
            self.deliveryTasks[event] = nil
            switch result {
            case .success: session.core.queued()
            case .failure(let error): session.core.cancel(Self.reason(error), unavailable: true)
            }
            self.publish(session)
            self.checkOrigin(session)
        }
        return snapshot(session)
    }

    func recognized(_ recognition: NotificationReplyCore.Recognition) {
        guard let id = active, let session = sessions[id] else { return }
        guard readiness == .ready else { cancelAll(readiness.rawValue); return }
        session.core.observe(recognition, now: now)
        if let requested = session.core.finalizeThrough { finalizeRecognition?(requested, session.core.phase == .composing) }
        publish(session)
    }
    func processed(through time: Double) {
        guard let id = active, let session = sessions[id] else { return }
        session.core.processed(through: time, now: now)
    }
    func interrupted(_ reason: String) { cancelAll(reason) }
    func dismiss(event: UUID) {
        guard let session = sessions[event] else { return }
        session.presentationDismissed = true
        if shown == event { shown = nil; showPresentation?(nil) }
        // Hiding cannot retract a queue already in flight; the eventual receipt remains authoritative. — GPT-6.1 Sol
        if deliveryTasks[event] == nil, session.core.interceptsSpeech { cancelSession(session, reason: "user-dismissed") }
    }
    func cancelAll(_ reason: String) {
        for session in sessions.values where session.core.interceptsSpeech || session.core.canDispatch {
            cancelSession(session, reason: reason)
        }
    }
    func shutdown() async {
        cancelAll("app-closing")
        timer?.invalidate(); timer = nil
        for task in originTasks.values { task.cancel() }; originTasks.removeAll()
        for task in deliveryTasks.values { await task.value }
        showPresentation?(nil); await files.flush()
    }
    private func cancelSession(_ session: Session, reason: String) {
        session.lease.cancel()
        // An in-flight queue command may already have succeeded. Its receipt decides queued/unknown; cancellation cannot promise unsent. — GPT-6.1 Sol
        if deliveryTasks[session.event] == nil { session.core.cancel(reason) }
        publish(session)
    }

    private final class Session {
        let event: UUID, thread: UUID, turn: UUID?
        let question: String
        var spokenText: String
        let spokenFingerprint: Data
        var core: NotificationReplyCore
        var origin: NotificationReplyOrigin?
        var started: Double?
        var releaseAcknowledged = false
        var presentationDismissed = false
        var cuePlayed = false
        var queuedAt: Double?
        var revision = 0, signature = ""
        var presentedTextRevision = -1
        var observers: [DispatchSourceFileSystemObject] = []
        let lease = NotificationReplyLease()
        init(event: UUID, thread: UUID, turn: UUID?, question: String, spokenText: String, at: Double, limits: NotificationReplyCore.Limits) {
            self.event = event; self.thread = thread; self.turn = turn; self.question = question; self.spokenText = spokenText
            spokenFingerprint = Data(SHA256.hash(data: Data(spokenText.utf8)))
            core = .init(at: at, limits: limits)
        }
        deinit { observers.forEach { $0.cancel() } }
    }
    private func selected(_ event: UUID, _ owner: UUID) throws -> Session {
        guard instance == owner else { throw Failure.differentInstance }
        guard let session = sessions[event] else { throw Failure.invalidEvent }
        return session
    }
    private func validClock(_ uptime: Double, _ wall: Double, maxAge: Double) -> Bool {
        uptime.isFinite && wall.isFinite && now - uptime >= -0.05 && now - uptime <= maxAge &&
            abs((wallClock() - wall) - (now - uptime)) <= 0.5
    }
    private func snapshot(_ session: Session) -> [String: Any] {
        let limits = session.core.limits
        return ["protocolVersion": 1, "eventID": session.event.uuidString.lowercased(), "threadID": session.thread.uuidString.lowercased(),
                "instance": instance.uuidString.lowercased(), "statusFile": files.path(session.event).path,
                "phase": session.core.phase.rawValue, "reason": session.core.reason, "releaseRequested": session.core.releaseRequested,
                "maxSetupSeconds": NotificationReplyCore.maxSetupSeconds,
                "maxAnnouncementSeconds": NotificationReplyCore.maxAnnouncementSeconds,
                "maxHoldSeconds": limits.maxHoldSeconds,
                "limits": ["commandSeconds": limits.commandSeconds, "idleSeconds": limits.idleSeconds, "replySeconds": limits.replySeconds,
                           "confirmationSeconds": limits.confirmationSeconds, "endConfirmationSeconds": limits.endConfirmationSeconds,
                           "commandDrainSeconds": limits.commandDrainSeconds, "maxHoldSeconds": limits.maxHoldSeconds]]
    }
    private func publish(_ session: Session) {
        if session.core.acceptedCount > 0, !session.cuePlayed { session.cuePlayed = true; acceptedReply?() }
        if session.core.releaseRequested, active == session.event {
            active = nil; resetRecognition?()
        }
        let signature = session.core.phase.rawValue + ":" + session.core.reason
        guard session.signature != signature else {
            if session.core.phase == .composing, session.presentedTextRevision != session.core.textRevision {
                present(session)
            }
            return
        }
        let first = session.signature.isEmpty
        session.signature = signature; session.revision += 1
        lastPhase = session.core.phase; lastReason = session.core.reason
        files.write(snapshot(session), event: session.event, revision: session.revision)
        Diagnostics.shared.record("notification.reply.phase", info: ["event": session.event.uuidString, "phase": session.core.phase.rawValue, "reason": session.core.reason])
        outcome?(session.event, session.core.phase, session.core.reason, first)
        present(session)
        if session.core.phase == .queued { session.queuedAt = now; session.spokenText = "" }
        if [.cancelled, .unavailable, .delivered].contains(session.core.phase) { retireHeavyState(session) }
    }
    private func present(_ session: Session) {
        guard !session.releaseAcknowledged, !session.presentationDismissed, active == nil || active == session.event else { return }
        session.presentedTextRevision = session.core.textRevision; shown = session.event
        showPresentation?(.init(event: session.event, phase: session.core.phase, reason: session.core.reason,
            spokenText: session.spokenText, replyText: session.core.phase == .composing ? session.core.draftText : ""))
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkBounds() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func checkBounds() {
        for session in sessions.values {
            if session.core.interceptsSpeech, readiness != .ready { cancelSession(session, reason: readiness.rawValue) }
            session.core.tick(now: now); publish(session)
            if session.started == nil, session.core.releaseRequested, !session.releaseAcknowledged, now - session.core.preparedAt > 10 {
                session.releaseAcknowledged = true
                if shown == session.event { shown = nil; showPresentation?(nil) }
            }
            if let queuedAt = session.queuedAt, now - queuedAt >= 60 { retireHeavyState(session) }
            let audioBound = session.core.audioEndedAt ?? session.started.map { $0 + NotificationReplyCore.maxAnnouncementSeconds }
                ?? session.core.preparedAt + NotificationReplyCore.maxSetupSeconds
            if session.core.releaseRequested, !session.releaseAcknowledged,
               now - audioBound > session.core.limits.maxHoldSeconds {
                session.releaseAcknowledged = true; session.lease.cancel()
                if shown == session.event { shown = nil; showPresentation?(nil) }
            }
        }
        let observingArrival = sessions.values.contains { $0.core.phase == .queued && $0.origin != nil }
        if active == nil, deliveryTasks.isEmpty, !observingArrival, sessions.values.allSatisfy({ $0.releaseAcknowledged }) {
            timer?.invalidate(); timer = nil
        }
    }
    private func installObservers(_ session: Session) {
        guard let origin = session.origin else { return }
        var paths = [origin.rollout]
        if !session.question.isEmpty {
            paths.append(origin.home.appendingPathComponent(".codex/state/question-reminders/\(session.thread.uuidString.lowercased())"))
        }
        for path in paths {
            let fd = open(path.path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { session.core.cancel("origin-watch-unavailable", unavailable: true); return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [weak self, weak session] in if let session { self?.checkOrigin(session) } }
            session.observers.append(source); source.resume()
        }
    }
    func waitForPendingDelivery() async {
        for task in deliveryTasks.values { await task.value }
        await files.flush()
    }
    private func checkOrigin(_ session: Session) {
        guard let origin = session.origin else { return }
        guard originTasks[session.event] == nil else { originAgain.insert(session.event); return }
        let queued = session.core.phase == .queued
        let event = session.event
        originTasks[session.event] = Task { [weak self, weak session] in
            let result: Result<Bool, Error> = await Task.detached(priority: .utility) {
                Result { if queued { return try origin.hasArrived(event: event) }; try origin.validate(); return false }
            }.value
            guard let self, let session else { return }
            self.originTasks[session.event] = nil
            switch result {
            case .success(let arrived): if arrived { session.core.delivered() }
            case .failure(let error):
                if session.core.phase != .queued && session.core.phase != .delivered { self.cancelSession(session, reason: Self.reason(error)) }
            }
            self.publish(session)
            if self.originAgain.remove(session.event) != nil { self.checkOrigin(session) }
        }
    }
    private func prune() {
        let completed = sessions.values.filter { $0.releaseAcknowledged && deliveryTasks[$0.event] == nil }
            .sorted { $0.core.preparedAt < $1.core.preparedAt }
        for session in completed.prefix(max(0, sessions.count - 96)) {
            session.observers.forEach { $0.cancel() }
            sessions[session.event] = nil; files.retire(session.event)
        }
    }
    private func retireHeavyState(_ session: Session) {
        session.observers.forEach { $0.cancel() }; session.observers.removeAll()
        originTasks[session.event]?.cancel(); originTasks[session.event] = nil; originAgain.remove(session.event)
        session.spokenText = ""; session.origin = nil
    }
    nonisolated private static func reason(_ error: Error) -> String {
        (error as? NotificationReplyOrigin.Failure)?.rawValue ?? "origin-unavailable"
    }
    nonisolated private static func runQueue(_ command: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 15)
        // Bound only our queue child even if it ignores graceful termination; never signal Desktop. — GPT-6.1 Sol
        deadline.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }; deadline.resume()
        process.waitUntilExit(); deadline.cancel()
        return process.terminationStatus
    }
}

/// Cancellation crosses only the app's existing background validation/queue boundary, without actor-unsafe UI reads. — GPT-6.1 Sol
private final class NotificationReplyLease: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return live }
    func cancel() { lock.lock(); live = false; lock.unlock() }
}

/// Small private status writes are serialized off the UI thread and contain no recognized words. — GPT-6.1 Sol
private final class NotificationReplyFiles {
    let directory: URL
    private let queue = DispatchQueue(label: "HelloChat.notification-reply-files", qos: .utility)
    private var revisions: [UUID: Int] = [:]
    init(directory: URL) { self.directory = directory }
    func path(_ event: UUID) -> URL { directory.appendingPathComponent(event.uuidString.lowercased() + ".json") }
    func write(_ object: [String: Any], event: UUID, revision: Int) {
        queue.async { [self] in
            guard revision > revisions[event, default: 0] else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
                let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                try handle.close()
                guard rename(temporary.path, path(event).path) == 0 else { throw POSIXError(.EIO) }
                revisions[event] = revision
            } catch { Diagnostics.shared.failure("notification.reply.status_failed", error) }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    func retire(_ event: UUID) {
        queue.async { [self] in revisions[event] = nil; try? FileManager.default.removeItem(at: path(event)) }
    }
}
