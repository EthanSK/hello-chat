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
    enum Readiness: String { case ready, disabled, listeningOff, listenerUnavailable, voiceActive, voiceUnknown, desktopUnavailable, codexUnavailable }
    enum Failure: String, Error { case invalidEvent, busy, differentInstance, unavailable }
    struct Presentation { let event: UUID; let phase: NotificationReplyCore.Phase; let reason: String; let spokenText: String; var replyText = ""; var commandSeconds = NotificationReplyCore.Limits().commandSeconds; var confirmingReply = false; var canSayStopSpeaking = false; var deliveryPending = false; var deliveryCommitted = false }
    let settings: NotificationReplySettings
    let instance = UUID()
    @Published private(set) var lastPhase: NotificationReplyCore.Phase?
    @Published private(set) var lastReason = ""
    var currentReadiness: () -> Readiness = { .listenerUnavailable }
    var commandForms: () -> NotificationReplyCore.Commands = { .init() }
    var resetRecognition: (() -> Void)?
    var finalizeRecognition: ((Double) -> Void)?
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
    private var relayCleanupTasks: [UUID: Task<Void, Never>] = [:]
    var queueCommand: ([String]) throws -> Int32 = NotificationReplyCoordinator.runQueue
    var provisionRelay: (NotificationReplyOrigin, URL, () -> Bool) throws -> NotificationReplyRelay = NotificationReplyRelay.prepare
    var wakeRelay: (Int32, UUID) async -> Bool = { pid, id in
        guard let link = URL(string: "codex://threads/wake/" + id.uuidString.lowercased()) else { return false }
        return await VoiceBridge.openChat(pid, link, activate: false)
    }
    var archiveRelay: (NotificationReplyRelay, URL) throws -> Void = { try $0.archive(executable: $1) }
    var clock: () -> Double = { Diagnostics.now }
    var wallClock: () -> Double = { Date().timeIntervalSince1970 }
    var captureOrigin: (UUID, UUID?, String) async throws -> NotificationReplyOrigin = { thread, turn, question in
        try await Task.detached(priority: .utility) { try NotificationReplyOrigin.capture(thread: thread, turn: turn, question: question) }.value
    }
    var validateOrigin: (NotificationReplyOrigin) throws -> Void = { try $0.validate() }
    var validateSubmittedOrigin: (NotificationReplyOrigin, NotificationReplyOrigin.ReplyIdentity) throws -> Void = { try $0.validate(reply: $1) }
    // Reuse ShowVoiceCommand's verified native deep-link route; never navigate by current selection. — GPT-6.1 Sol
    var openOrigin: (Int32, UUID) async -> Bool = { pid, thread in
        guard let link = URL(string: "codex://threads/" + thread.uuidString.lowercased()) else { return false }
        return await VoiceBridge.openChat(pid, link)
    }
    private var now: Double { clock() }
    var interceptsSpeech: Bool { active.flatMap { sessions[$0]?.core.interceptsSpeech } ?? false }
    var isComposing: Bool { active.flatMap { sessions[$0]?.core.phase } == .composing }
    var hasOpenAttempt: Bool { sessions.values.contains { !$0.releaseAcknowledged || ($0.relay != nil && $0.core.canDispatch) } || !deliveryTasks.isEmpty }
    // Ethan permits Reply while Agent Flow records. Speech suppression belongs to the speaker;
    // this existing shared listener still respects Voice, desktop, settings and frame-loss guards. — GPT-6.1 Sol
    var readiness: Readiness { !settings.enabled ? .disabled : currentReadiness() }
    var lifecycleCounts: (sessions: Int, watchers: Int, textBytes: Int, checkingBounds: Bool) {
        (sessions.count, sessions.values.reduce(0) { $0 + $1.observers.count },
         sessions.values.reduce(0) { $0 + $1.spokenText.utf8.count + ($1.core.body?.utf8.count ?? 0) }, timer != nil)
    }

    init(settings: NotificationReplySettings? = nil, directory: URL = AppPaths.support.appendingPathComponent("notification-replies-v1")) {
        self.settings = settings ?? NotificationReplySettings()
        files = NotificationReplyFiles(directory: directory)
        self.settings.changed = { [weak self] in self?.cancelAll("settings-changed") }
        recoverRelayCleanup()
    }

    func prepare(event: UUID, thread: UUID, turn: UUID?, question: String, spokenText: String, manualFinish: Bool = false, stopSpeaking: Bool = false) async throws -> [String: Any] {
        recoverRelayCleanup()
        guard !spokenText.isEmpty, spokenText.count <= 2048, question.count <= 160 else { throw Failure.invalidEvent }
        if let existing = sessions[event] {
            guard existing.thread == thread, existing.turn == turn, existing.question == question,
                  existing.core.manualFinish == manualFinish,
                  existing.core.stopSpeaking == stopSpeaking,
                  existing.spokenFingerprint == Data(SHA256.hash(data: Data(spokenText.utf8))) else { throw Failure.invalidEvent }
            return snapshot(existing)
        }
        guard !interceptsSpeech else { throw Failure.busy }
        prune()
        let session = Session(event: event, thread: thread, turn: turn, question: question, spokenText: spokenText, at: now, limits: settings.limits, commands: commandForms(), manualFinish: manualFinish, stopSpeaking: stopSpeaking)
        let admitted = readiness
        sessions[event] = session; startTimer()
        if admitted == .ready, session.core.phase == .preparing { active = event; resetRecognition?() }
        if admitted != .ready { session.core.cancel(admitted.rawValue, unavailable: true) }
        publish(session)
        if admitted == .ready, session.core.phase == .preparing {
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
        guard session.fallback == nil else { throw Failure.invalidEvent }
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
        guard session.fallback == nil else { throw Failure.invalidEvent }
        if let ended = session.core.audioEndedAt {
            guard ended == uptime else { throw Failure.invalidEvent }; return snapshot(session)
        }
        guard validClock(uptime, wall, maxAge: 5), let started = session.started, uptime >= started else {
            session.core.cancel("audio-end-stale"); publish(session); return snapshot(session)
        }
        session.core.audioEnded(at: uptime, completed: completed, now: now)
        publish(session); return snapshot(session)
    }
    func fallbackReady(event: UUID, instance: UUID, deliveredUptime: Double, deliveredWall: Double,
                       skipReason: String, expiresAt: Double) async throws -> [String: Any] {
        let session = try selected(event, instance)
        if let fallback = session.fallback {
            guard fallback.uptime == deliveredUptime, fallback.wall == deliveredWall, fallback.reason == skipReason else { throw Failure.invalidEvent }
            return snapshot(session) // An identical callback never opens or extends a second window.
        }
        guard ["agent-flow-speech-denied", "audio-unavailable-before-start"].contains(skipReason), session.started == nil,
              session.core.phase == .preparing, session.core.opportunityAt == nil,
              validClock(deliveredUptime, deliveredWall, maxAge: NotificationReplyCore.maxSetupSeconds),
              let origin = session.origin else { throw Failure.invalidEvent }
        let validate = validateOrigin
        do { try await Task.detached(priority: .utility) { try validate(origin) }.value }
        catch { cancelSession(session, reason: Self.reason(error)); return snapshot(session) }
        guard sessions[event] === session, session.core.phase == .preparing,
              session.started == nil, session.fallback == nil, !session.presentationDismissed else { return snapshot(session) }
        guard wallClock() < expiresAt else { cancelSession(session, reason: "fallback-request-expired"); return snapshot(session) }
        guard now - session.core.preparedAt <= NotificationReplyCore.maxSetupSeconds else {
            cancelSession(session, reason: "announcement-setup-limit"); return snapshot(session)
        }
        guard readiness == .ready else { cancelSession(session, reason: readiness.rawValue); return snapshot(session) }
        session.fallback = .init(uptime: deliveredUptime, wall: deliveredWall, reason: skipReason)
        // The old banner's time is retained separately. This FIRST opportunity begins
        // when this actor synchronously presents Say Reply, after both facts are known. — GPT-6.1 Sol
        session.core.fallbackReady(at: now)
        publish(session); return snapshot(session)
    }
    func cancel(event: UUID, instance: UUID, reason: String) throws -> [String: Any] {
        let session = try selected(event, instance)
        cancelSession(session, reason: "client-cancelled"); return snapshot(session)
    }
    func status(event: UUID, instance: UUID) throws -> [String: Any] {
        let session = try selected(event, instance)
        if session.core.interceptsSpeech, readiness != .ready { cancelSession(session, reason: readiness.rawValue) }
        session.core.ownerSeen(at: now)
        publish(session)
        return snapshot(session)
    }

    func mediaReleased(event: UUID, instance: UUID, released: Bool, expiresAt: Double = .infinity) throws -> [String: Any] {
        let session = try selected(event, instance)
        guard !session.releaseAcknowledged else { return snapshot(session) }
        session.releaseAcknowledged = true
        if shown == event, !released || !session.core.canDispatch { shown = nil; showPresentation?(nil) }
        guard released, session.core.canDispatch, readiness == .ready, let origin = session.origin,
              let body = session.core.body, let desktop = currentDesktop() else {
            if session.core.interceptsSpeech { session.core.cancel(released ? "media-release-before-dispatch" : "media-release-unconfirmed") }
            session.lease.cancel(); publish(session); return snapshot(session)
        }
        let claims = files.directory.appendingPathComponent("dispatch-claims"), lease = session.lease
        let executable = desktop.executable, pid = desktop.pid
        let spokenText = session.spokenText, validate = validateOrigin, wall = wallClock
        let provision = provisionRelay
        // The short client callback must admit the durable transition before expiry. The app then owns
        // the existing finite arrival budget; the later host send gets its own fresh guarded request. — GPT-6.1 Sol
        let deadline = wall() + 60
        session.replyIdentity = try origin.replyIdentity(event: event, spokenText: spokenText, body: body)
        // Reserve before provisioning; the original chat is NEVER queued as a fallback for an uncertain relay. — GPT-6.1 Sol
        deliveryTasks[event] = Task { [weak self, weak session] in
            let result: Result<NotificationReplyRelay, Error> = await Task.detached(priority: .utility) {
                Result {
                    let valid = { lease.valid && wall() < deadline && kill(pid, 0) == 0 }
                    try origin.reserve(event: event, claims: claims, validate: { try validate(origin) }, valid: {
                        valid() && wall() < expiresAt
                    })
                    return try provision(origin, executable, valid)
                }
            }.value
            guard let self, let session, self.sessions[event] === session else { return }
            switch result {
            case .success(let relay):
                session.relay = .init(relay: relay, executable: executable, pid: pid, expires: deadline)
                session.replyIdentity = session.replyIdentity?.acceptingRelay(from: relay.thread)
                do {
                    guard lease.valid, self.readiness == .ready, wall() < deadline,
                          let current = self.currentDesktop(), current.pid == pid, current.executable == executable,
                          let appExecutable = Bundle.main.executableURL else { throw Failure.unavailable }
                    try validate(origin)
                    let prompt = try relay.brokerPrompt(event: event, instance: self.instance, appExecutable: appExecutable, expiresAt: deadline)
                    let relay = relay.bindingBroker(prompt)
                    session.relay = .init(relay: relay, executable: executable, pid: pid, expires: deadline)
                    self.installRelayObserver(session)
                    try self.files.recordRelay(relay, event: event, executable: executable)
                    let run = self.queueCommand
                    try await Task.detached(priority: .utility) {
                        guard lease.valid, wall() < deadline else { throw Failure.unavailable }
                        guard try run([executable.path, "queue", "--thread", relay.thread.uuidString.lowercased(), "--message=" + prompt]) == 0 else {
                            throw NotificationReplyOrigin.Failure.submissionUnknown
                        }
                    }.value
                    guard lease.valid, wall() < deadline, self.readiness == .ready,
                          let latest = self.currentDesktop(), latest.pid == pid, latest.executable == executable,
                          await self.wakeRelay(pid, relay.thread) else { throw NotificationReplyRelay.Failure.relayWakeUnknown }
                    // This accepted a broker prompt, not the reply at its destination. Keep that distinction until actual arrival. — GPT-6.1 Sol
                } catch {
                    session.lease.cancel(); session.core.cancel("relay-start-unconfirmed", unavailable: true)
                }
            case .failure(let error): session.core.cancel(Self.reason(error), unavailable: true)
            }
            self.deliveryTasks[event] = nil
            self.publish(session)
            self.checkOrigin(session)
        }
        return snapshot(session)
    }

    /// The relay may obtain the exact envelope once, at the host-send boundary; never from its initial prompt. — GPT-6.1 Sol
    func claimRelaySend(event: UUID, instance: UUID, relayThread: UUID, expiresAt: Double) async throws -> [String: Any] {
        let session = try selected(event, instance)
        guard let relay = session.relay, relay.relay.thread == relayThread, !relay.sendClaimed,
              session.releaseAcknowledged, session.core.canDispatch, session.lease.valid,
              readiness == .ready, !session.presentationDismissed, wallClock() < relay.expires,
              wallClock() < expiresAt, let origin = session.origin, let body = session.core.body,
              let current = currentDesktop(), current.pid == relay.pid, current.executable == relay.executable else { throw Failure.unavailable }
        let validate = validateSubmittedOrigin, identity = session.replyIdentity
        guard let identity else { throw Failure.unavailable }
        try await Task.detached(priority: .utility) {
            try validate(origin, identity)
            guard try relay.relay.isActiveBroker() else { throw Failure.unavailable }
        }.value
        // Actor suspension can admit a cancellation, different process, or a competing claim. Recheck before disclosing data. — GPT-6.1 Sol
        guard sessions[event] === session, session.relay === relay, !relay.sendClaimed, session.lease.valid,
              session.core.canDispatch, readiness == .ready, !session.presentationDismissed,
              wallClock() < min(relay.expires, expiresAt), let latest = currentDesktop(),
              latest.pid == relay.pid, latest.executable == relay.executable else { throw Failure.unavailable }
        try files.claimRelaySend(event)
        relay.sendClaimed = true
        publish(session)
        return ["eventID": event.uuidString.lowercased(), "instance": instance.uuidString.lowercased(),
                "relayThreadID": relayThread.uuidString.lowercased(), "threadID": session.thread.uuidString.lowercased(),
                "message": try origin.candidateMessage(event: event, spokenText: session.spokenText, body: body),
                "sendBeforeWall": min(relay.expires, expiresAt)]
    }

    func recognized(_ recognition: NotificationReplyCore.Recognition) {
        guard let id = active, let session = sessions[id] else { return }
        guard readiness == .ready else { cancelAll(readiness.rawValue); return }
        session.core.observe(recognition, now: now)
        if let requested = session.core.finalizeThrough { finalizeRecognition?(requested) }
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
        if session.core.interceptsSpeech { cancelSession(session, reason: "user-dismissed") }
    }
    func cancelAll(_ reason: String) {
        for session in sessions.values where session.core.interceptsSpeech || session.core.canDispatch || deliveryTasks[session.event] != nil {
            cancelSession(session, reason: reason)
        }
    }
    func shutdown() async {
        cancelAll("app-closing")
        timer?.invalidate(); timer = nil
        for task in originTasks.values { task.cancel() }; originTasks.removeAll()
        for task in deliveryTasks.values { await task.value }
        for task in relayCleanupTasks.values { await task.value }
        showPresentation?(nil); await files.flush()
    }
    private func cancelSession(_ session: Session, reason: String) {
        session.lease.cancel()
        // An in-flight queue command may already have succeeded. Its receipt decides queued/unknown; cancellation cannot promise unsent. — GPT-6.1 Sol
        if deliveryTasks[session.event] == nil {
            session.core.cancel(session.relay?.sendClaimed == true ? "relay-send-unconfirmed" : reason,
                                unavailable: session.relay?.sendClaimed == true)
        }
        publish(session)
    }

    private final class Session {
        struct Fallback { let uptime: Double; let wall: Double; let reason: String }
        let event: UUID, thread: UUID, turn: UUID?
        let question: String
        var spokenText: String
        let spokenFingerprint: Data
        var core: NotificationReplyCore
        var origin: NotificationReplyOrigin?
        var started: Double?
        var fallback: Fallback?
        var releaseAcknowledged = false
        var presentationDismissed = false
        var cuePlayed = false
        var queuedAt: Double?
        var releaseRequestedAt: Double?
        var replyIdentity: NotificationReplyOrigin.ReplyIdentity?
        var navigationAttempted = false
        final class Relay {
            let relay: NotificationReplyRelay
            let executable: URL
            let pid: Int32
            let expires: Double
            var sendClaimed = false, checkingCleanup = false, cleanupFinished = false
            var observer: DispatchSourceFileSystemObject?
            init(relay: NotificationReplyRelay, executable: URL, pid: Int32, expires: Double) {
                self.relay = relay; self.executable = executable; self.pid = pid; self.expires = expires
            }
            deinit { observer?.cancel() }
        }
        var relay: Relay?
        var revision = 0, signature = ""
        var presentedTextRevision = -1
        var observers: [DispatchSourceFileSystemObject] = []
        let lease = NotificationReplyLease()
        init(event: UUID, thread: UUID, turn: UUID?, question: String, spokenText: String, at: Double, limits: NotificationReplyCore.Limits, commands: NotificationReplyCore.Commands, manualFinish: Bool, stopSpeaking: Bool) {
            self.event = event; self.thread = thread; self.turn = turn; self.question = question; self.spokenText = spokenText
            spokenFingerprint = Data(SHA256.hash(data: Data(spokenText.utf8)))
            core = .init(at: at, limits: limits, commands: commands, manualFinish: manualFinish, stopSpeaking: stopSpeaking, spokenText: spokenText)
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
                "manualFinish": session.core.manualFinish,
                "stopSpeaking": session.core.stopSpeaking,
                "ownerLeaseSeconds": NotificationReplyCore.ownerLeaseSeconds,
                "ownerLeaseExpiresUptime": session.core.ownerLeaseExpiresUptime as Any? ?? NSNull(),
                "opportunityKind": session.fallback != nil ? "visual" : session.core.audioEndedAt != nil ? "audio" : "none",
                "opportunityUptime": session.core.opportunityAt as Any? ?? NSNull(),
                "visualDeliveredUptime": session.fallback?.uptime as Any? ?? NSNull(),
                "visualDeliveredWall": session.fallback?.wall as Any? ?? NSNull(),
                "maxSetupSeconds": NotificationReplyCore.maxSetupSeconds,
                "maxAnnouncementSeconds": NotificationReplyCore.maxAnnouncementSeconds,
                "maxHoldSeconds": limits.maxHoldSeconds,
                "limits": ["commandSeconds": limits.commandSeconds, "idleSeconds": limits.idleSeconds, "replySeconds": limits.replySeconds,
                           "confirmationSeconds": limits.confirmationSeconds, "endConfirmationSeconds": limits.endConfirmationSeconds,
                           "commandDrainSeconds": limits.commandDrainSeconds, "maxHoldSeconds": limits.maxHoldSeconds]]
    }
    private func publish(_ session: Session) {
        if session.core.releaseRequested, session.releaseRequestedAt == nil { session.releaseRequestedAt = now }
        if session.core.acceptedCount > 0, !session.cuePlayed { session.cuePlayed = true; acceptedReply?() }
        if session.core.releaseRequested, active == session.event {
            active = nil; resetRecognition?()
        }
        let signature = session.core.phase.rawValue + ":" + session.core.reason + ":" + String(session.core.confirmingReply) + ":" + String(session.releaseAcknowledged) + ":" + String(session.relay?.sendClaimed ?? false)
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
        Diagnostics.shared.record("notification.reply.phase", info: ["notification_event": session.event.uuidString, "phase": session.core.phase.rawValue, "reason": session.core.reason,
            "confirming_start": String(session.core.confirmingReply)])
        outcome?(session.event, session.core.phase, session.core.reason, first)
        present(session)
        if session.releaseAcknowledged, !session.core.canDispatch, shown == session.event {
            shown = nil; showPresentation?(nil)
        }
        if session.core.phase == .queued {
            session.queuedAt = now
            if session.releaseAcknowledged { session.spokenText = "" }
        }
        if [.cancelled, .unavailable, .delivered].contains(session.core.phase) { retireHeavyState(session) }
    }
    private func present(_ session: Session) {
        guard (!session.releaseAcknowledged || session.core.canDispatch), !session.presentationDismissed, active == nil || active == session.event else { return }
        session.presentedTextRevision = session.core.textRevision; shown = session.event
        showPresentation?(.init(event: session.event, phase: session.core.phase, reason: session.core.reason,
            spokenText: session.spokenText, replyText: session.core.phase == .composing ? session.core.draftText : "", commandSeconds: session.core.limits.commandSeconds,
            confirmingReply: session.core.confirmingReply, canSayStopSpeaking: session.core.canSayStopSpeaking,
            deliveryPending: session.releaseAcknowledged && session.core.canDispatch, deliveryCommitted: session.relay?.sendClaimed ?? false))
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
            if let relay = session.relay, wallClock() >= relay.expires {
                if session.core.canDispatch { cancelSession(session, reason: "relay-send-unconfirmed") }
                if !relay.cleanupFinished { checkRelayCleanup(session) }
                relay.observer?.cancel(); relay.observer = nil
                retireHeavyState(session)
            }
            if session.started == nil, session.core.opportunityAt == nil, session.core.releaseRequested, !session.releaseAcknowledged, now - session.core.preparedAt > 10 {
                session.releaseAcknowledged = true
                if shown == session.event { shown = nil; showPresentation?(nil) }
            }
            if let queuedAt = session.queuedAt, now - queuedAt >= 60 { retireHeavyState(session) }
            let audioBound = session.core.manualFinish ? session.releaseRequestedAt ?? now : session.core.opportunityAt ?? session.started.map { $0 + NotificationReplyCore.maxAnnouncementSeconds }
                ?? session.core.preparedAt + NotificationReplyCore.maxSetupSeconds
            let releaseBound = session.core.manualFinish ? 7 : session.core.limits.maxHoldSeconds
            if session.core.releaseRequested, !session.releaseAcknowledged,
               now - audioBound > releaseBound {
                session.releaseAcknowledged = true; session.lease.cancel()
                if shown == session.event { shown = nil; showPresentation?(nil) }
            }
        }
        let observingArrival = sessions.values.contains { session in
            (session.core.phase == .queued && session.origin != nil) ||
            (session.relay.map { wallClock() < $0.expires && (!$0.cleanupFinished || session.origin != nil) } ?? false)
        }
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
    private func installRelayObserver(_ session: Session) {
        guard let relay = session.relay else { return }
        let fd = open(relay.relay.rollout.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { cancelSession(session, reason: "relay-watch-unavailable"); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self, weak session] in if let session { self?.checkRelayCleanup(session) } }
        relay.observer = source; source.resume()
    }
    private func checkRelayCleanup(_ session: Session) {
        guard let relay = session.relay, !relay.checkingCleanup, !relay.cleanupFinished else { return }
        relay.checkingCleanup = true
        let archive = archiveRelay
        relayCleanupTasks[session.event] = Task { [weak self, weak session] in
            let result: Result<NotificationReplyRelay.Ownership, Error> = await Task.detached(priority: .utility) {
                Result {
                    let owner = try relay.relay.ownership()
                    guard owner == .completed else { return owner }
                    do { try archive(relay.relay, relay.executable) }
                    catch NotificationReplyRelay.Failure.relayTakenOver { return .relinquished }
                    return .completed
                }
            }.value
            guard let self, let session else { return }
            self.relayCleanupTasks[session.event] = nil
            relay.checkingCleanup = false
            if case .success(let owner) = result, owner != .running {
                relay.cleanupFinished = true; relay.observer?.cancel(); relay.observer = nil
                self.files.forgetRelay(session.event)
                if owner == .relinquished { self.cancelSession(session, reason: "relay-no-longer-owned") }
                self.checkOrigin(session)
            }
            if case .failure = result {
                Diagnostics.shared.record("notification.reply.relay_archive_unconfirmed", info: ["notification_event": session.event.uuidString])
            }
            if self.wallClock() >= relay.expires { self.retireHeavyState(session) }
        }
    }
    private var recoveringRelays = false
    private func recoverRelayCleanup() {
        let directory = files.directory.appendingPathComponent("dispatch-claims")
        guard !recoveringRelays,
              ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).contains(where: { $0.hasSuffix(".relay.json") }),
              let desktop = currentDesktop() else { return }
        let live = Set(sessions.values.compactMap { $0.relay?.relay.thread })
        recoveringRelays = true
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                // Only terminal, durably registered owned relays are recoverable; this path can NEVER send a reply. — GPT-6.1 Sol
                let candidates = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                for path in candidates.filter({ $0.lastPathComponent.hasSuffix(".relay.json") }).prefix(96) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    guard let record = try? NotificationReplyRelay.CleanupRecord.read(path), !live.contains(record.relay.thread),
                          record.executable == desktop.executable else { continue }
                    do {
                        let owner = try record.relay.ownership()
                        if owner == .relinquished { try? FileManager.default.removeItem(at: path) }
                        else if owner == .completed {
                            do { try record.relay.archive(executable: desktop.executable); try? FileManager.default.removeItem(at: path) }
                            catch NotificationReplyRelay.Failure.relayTakenOver { try? FileManager.default.removeItem(at: path) }
                        }
                    } catch { if record.alreadyArchived { try? FileManager.default.removeItem(at: path) } }
                }
            }.value
            self?.recoveringRelays = false
        }
    }
    func waitForPendingDelivery() async {
        for task in deliveryTasks.values { await task.value }
        for task in relayCleanupTasks.values { await task.value }
        await files.flush()
    }
    private func checkOrigin(_ session: Session) {
        guard let origin = session.origin else { return }
        guard originTasks[session.event] == nil else { originAgain.insert(session.event); return }
        let queued = session.core.phase == .queued || session.relay?.sendClaimed == true
        let event = session.event
        let reply = session.replyIdentity, validate = validateSubmittedOrigin
        originTasks[session.event] = Task { [weak self, weak session] in
            let result: Result<Bool, Error> = await Task.detached(priority: .utility) {
                Result {
                    if queued, let reply { return try origin.hasArrived(reply: reply) }
                    if let reply { try validate(origin, reply) } else { try origin.validate() }
                    return false
                }
            }.value
            guard let self, let session else { return }
            self.originTasks[session.event] = nil
            switch result {
            case .success(let arrived):
                if arrived {
                    if let relay = session.relay, relay.sendClaimed {
                        // Saved exact host-tool arrival is authoritative even if a later cancellation made navigation ineligible. — GPT-6.1 Sol
                        session.core.relayDelivered()
                        await self.openAcceptedOrigin(session, origin: origin, desktop: (relay.executable, relay.pid))
                    } else { session.core.delivered() }
                }
            case .failure(let error):
                // A pre-dispatch check may finish after our own exact message arrives.
                // Recheck with its new digest; do not revoke another cancellation reason. — GPT-6.1 Sol
                if reply == nil, session.replyIdentity != nil, self.deliveryTasks[event] != nil {
                    self.originAgain.remove(event); self.checkOrigin(session); return
                }
                if session.core.phase != .queued && session.core.phase != .delivered { self.cancelSession(session, reason: Self.reason(error)) }
            }
            self.publish(session)
            if self.originAgain.remove(session.event) != nil { self.checkOrigin(session) }
        }
    }
    private func openAcceptedOrigin(_ session: Session, origin: NotificationReplyOrigin,
                                    desktop: (executable: URL, pid: Int32)) async {
        guard !session.navigationAttempted, let reply = session.replyIdentity else { return }
        session.navigationAttempted = true
        let validate = validateSubmittedOrigin
        let valid = await Task.detached(priority: .utility) { (try? validate(origin, reply)) != nil }.value
        guard valid, session.lease.valid, !session.presentationDismissed, readiness == .ready, !Task.isCancelled,
              let current = currentDesktop(), current.pid == desktop.pid, current.executable == desktop.executable else { return }
        let opened = await openOrigin(desktop.pid, session.thread)
        Diagnostics.shared.record("notification.reply.navigation", info: ["notification_event": session.event.uuidString,
            "thread": session.thread.uuidString, "opened": String(opened)])
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
        session.spokenText = ""
        // A claimed host send may arrive after cancellation. Retain only its digest and existing watcher until the same finite bound. — GPT-6.1 Sol
        if let relay = session.relay, relay.sendClaimed, wallClock() < relay.expires,
           session.core.phase != .delivered { return }
        session.observers.forEach { $0.cancel() }; session.observers.removeAll()
        originTasks[session.event]?.cancel(); originTasks[session.event] = nil; originAgain.remove(session.event)
        session.spokenText = ""; session.origin = nil; session.replyIdentity = nil
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
    func recordRelay(_ relay: NotificationReplyRelay, event: UUID, executable: URL) throws {
        let path = directory.appendingPathComponent("dispatch-claims/" + event.uuidString.lowercased() + ".relay.json")
        let bytes = try JSONEncoder().encode(NotificationReplyRelay.CleanupRecord(relay: relay, executable: executable))
        let fd = open(path.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NotificationReplyCoordinator.Failure.unavailable }
        defer { close(fd) }
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count, fsync(fd) == 0 else { throw NotificationReplyCoordinator.Failure.unavailable }
    }
    func forgetRelay(_ event: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("dispatch-claims/" + event.uuidString.lowercased() + ".relay.json"))
    }
    func claimRelaySend(_ event: UUID) throws {
        let claims = directory.appendingPathComponent("dispatch-claims")
        try FileManager.default.createDirectory(at: claims, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(claims.appendingPathComponent(event.uuidString.lowercased() + ".relay-send").path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NotificationReplyCoordinator.Failure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NotificationReplyCoordinator.Failure.unavailable }
    }
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
