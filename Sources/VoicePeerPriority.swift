// Resolve overlapping native Codex Voice calls independently of speech recognition and Spotify. — GPT-6.2 Astra
import AppKit
import ApplicationServices
import Darwin
import Foundation

struct VoicePeerConfiguration: Equatable {
    enum Role: String, Codable {
        case primary, secondary
        var peer: Self { self == .primary ? .secondary : .primary }
    }
    let machine: String
    let role: Role
    let schedule: VoicePeerSchedule?

    init?(defaults: UserDefaults) {
        guard let configuration = defaults.dictionary(forKey: "voicePeerPriority"),
              let machine = configuration["machine"] as? String,
              let role = (configuration["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        // An incomplete or invalid schedule cannot safely make End decisions.
        let keys = ["secondaryStartHour", "secondaryEndHour", "timeZone"]
        var schedule: VoicePeerSchedule?
        if keys.contains(where: { configuration[$0] != nil }) {
            guard let start = configuration["secondaryStartHour"] as? Int,
                  let end = configuration["secondaryEndHour"] as? Int,
                  let zone = configuration["timeZone"] as? String,
                  let configured = VoicePeerSchedule(startHour: start, endHour: end, timeZone: zone) else { return nil }
            schedule = configured
        }
        self.init(machine: machine, role: role, schedule: schedule)
    }

    init?(machine: String, role: Role, schedule: VoicePeerSchedule? = nil) {
        guard !machine.isEmpty, machine.utf8.count <= 80,
              machine.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              !machine.hasPrefix("-") else { return nil }
        self.machine = machine
        self.role = role
        self.schedule = schedule
    }

    // Foundation rejects opening this bundle's own ID as a separate suite.
    static var installed: Self? { Self(defaults: .standard) }

    func priority(atMilliseconds time: Int64) -> Role? {
        if let schedule { return schedule.winner(atMilliseconds: time) }
        return .primary
    }
}

struct VoicePeerSchedule: Codable, Equatable {
    let startHour: Int
    let endHour: Int
    let timeZone: String

    init?(startHour: Int, endHour: Int, timeZone: String) {
        guard (0..<24).contains(startHour), (0..<24).contains(endHour), startHour != endHour,
              TimeZone(identifier: timeZone) != nil else { return nil }
        self.startHour = startHour
        self.endHour = endHour
        self.timeZone = timeZone
    }

    func winner(atMilliseconds time: Int64) -> VoicePeerConfiguration.Role? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: Double(time) / 1000))
        let secondaryWins = startHour < endHour
            ? (startHour..<endHour).contains(hour)
            : hour >= startHour || hour < endHour
        return secondaryWins ? .secondary : .primary
    }
}

struct VoicePeerCall: Codable, Equatable {
    let thread: UUID
    let session: UUID
    let pid: Int32

    var token: String { "\(thread.uuidString):\(session.uuidString):\(pid)" }

    init?(token: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let thread = UUID(uuidString: String(parts[0])),
              let session = UUID(uuidString: String(parts[1])),
              let pid = Int32(parts[2]), pid > 0 else { return nil }
        self.thread = thread; self.session = session; self.pid = pid
    }

    func matches(_ identifier: String) -> Bool {
        Self(token: identifier + ":\(pid)") == self
    }
}

struct VoicePeerReceipt: Codable, Equatable {
    enum Status: String, Codable { case active, inactive, unknown, changed, resolved, endRequested, ended, disabled }
    let status: Status
    var call: VoicePeerCall? = nil
    var role: VoicePeerConfiguration.Role? = nil
    var startedAtMilliseconds: Int64? = nil
    var schedule: VoicePeerSchedule? = nil
    var decision: VoicePeerDecision? = nil
    var endPending: Bool? = nil

    // Both sides must apply the same priority policy before either can end a call.
    static let protocolVersion = 4
    static let wirePrefix = "HCHAT_VOICE_PEER_V\(protocolVersion) "
    static let endVersion = "v\(protocolVersion)"
}

struct VoicePeerDecision: Codable, Equatable {
    let primary: VoicePeerCall
    let secondary: VoicePeerCall
    let schedule: VoicePeerSchedule?
    let resolvedAtMilliseconds: Int64

    func winner(for configuration: VoicePeerConfiguration) -> VoicePeerConfiguration.Role? {
        guard schedule == configuration.schedule, resolvedAtMilliseconds > 0 else { return nil }
        return configuration.priority(atMilliseconds: resolvedAtMilliseconds)
    }
}

// Either Mac can discover the overlap. The primary records one decision time for both,
// including if a reply is lost or H Chat restarts at a schedule boundary. — GPT-6.2 Astra
final class VoicePeerDecisions {
    static let installed = VoicePeerDecisions(file: AppPaths.support.appendingPathComponent(
        "voice-peer-decisions-\(VoicePeerReceipt.endVersion).json"))
    private let file: URL
    private let lock = NSLock()

    init(file: URL) { self.file = file }

    func resolve(primary: VoicePeerCall, secondary: VoicePeerCall, expires: TimeInterval,
                 primaryStatus: () -> VoicePeerReceipt, now: () -> Date = Date.init) -> VoicePeerReceipt {
        lock.lock()
        defer { lock.unlock() }
        let status = primaryStatus()
        guard status.status == .active, status.role == .primary, status.call == primary else {
            return .init(status: status.status == .unknown ? .unknown : .changed)
        }
        do {
            var decisions: [VoicePeerDecision]
            do { decisions = try JSONDecoder().decode([VoicePeerDecision].self, from: Data(contentsOf: file)) }
            catch CocoaError.fileReadNoSuchFile { decisions = [] }
            let instant = now().timeIntervalSince1970
            guard instant < expires else { return .init(status: .changed) }
            // Discard history only after verifying a different primary session. A late request
            // for an old secondary session cannot erase the decision for its replacement.
            decisions.removeAll { $0.primary != primary }
            if let existing = decisions.first(where: { $0.secondary == secondary }) {
                guard existing.schedule == status.schedule else { return .init(status: .changed) }
                return .init(status: .resolved, decision: existing, endPending: status.endPending)
            }
            let decision = VoicePeerDecision(primary: primary, secondary: secondary, schedule: status.schedule,
                                            resolvedAtMilliseconds: Int64((instant * 1000).rounded(.down)))
            decisions.append(decision)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(decisions).write(to: file, options: .atomic)
            return .init(status: .resolved, decision: decision, endPending: status.endPending)
        } catch { return .init(status: .unknown) }
    }
}

enum VoicePeerControl {
    private static let endReceiptName = "voice-peer-end-\(VoicePeerReceipt.endVersion)"

    static func respond(_ request: VoicePeerMailbox.Request) -> VoicePeerReceipt {
        guard request.valid else { return .init(status: .unknown) }
        switch (request.action, request.call) {
        case (.status, nil): return status()
        case (.resolve, let primary?):
            guard let secondary = request.otherCall else { return .init(status: .unknown) }
            return VoicePeerDecisions.installed.resolve(primary: primary, secondary: secondary,
                                                        expires: request.expires, primaryStatus: status)
        case (.end, let call?): return end(call, request: request)
        case (.confirmEnd, let call?): return confirmation(of: call)
        default: return .init(status: .unknown)
        }
    }

    static func status() -> VoicePeerReceipt {
        guard let configuration = VoicePeerConfiguration.installed else { return .init(status: .disabled) }
        var receipt = localStatus(role: configuration.role, schedule: configuration.schedule)
        if let call = receipt.call {
            guard let pending = pendingEnd(for: call, in: AppPaths.support, at: Date().timeIntervalSince1970) else { return .init(status: .unknown) }
            if pending { receipt.endPending = true }
        }
        return receipt
    }

    // Single-Mac actions need actual local Voice evidence without enabling peer control. — GPT-6.1 Sol
    static func localStatus(role: VoicePeerConfiguration.Role? = nil, schedule: VoicePeerSchedule? = nil) -> VoicePeerReceipt {
        guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate else {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                .contains { !$0.isTerminated }
            return .init(status: running ? .unknown : .inactive, role: role, schedule: schedule)
        }
        let database = VoiceTimeline.databaseURL()
        let before = VoiceTimeline.sessions(database: database, since: launch)?.startedAtMilliseconds
        let state = VoiceBridge.snapshot(requireEnd: true)
        guard state.pid == app.processIdentifier, state.accessibilityAllowed,
              let before, before == VoiceTimeline.sessions(database: database, since: launch)?.startedAtMilliseconds else {
            return .init(status: .unknown)
        }
        if let (id, startedAt) = before.first, before.count == 1, state.endControlAvailable || state.microphone != nil,
           let call = VoicePeerCall(token: id + ":\(app.processIdentifier)") {
            return .init(status: .active, call: call, role: role, startedAtMilliseconds: startedAt, schedule: schedule)
        }
        let absent = before.isEmpty && state.controlsComplete && !state.endControlAvailable && state.microphone == nil
        return .init(status: absent ? .inactive : .unknown, role: role, schedule: schedule)
    }

    private static func end(_ call: VoicePeerCall, request: VoicePeerMailbox.Request) -> VoicePeerReceipt {
        guard let configuration = VoicePeerConfiguration.installed else { return .init(status: .disabled) }
        let authorized = authorizesEnd(request, configuration: configuration, local: respond,
                                       peer: { VoicePeerBridge.run(machine: configuration.machine, request: $0) })
        guard authorized else { return .init(status: .changed) }
        guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate,
              app.processIdentifier == call.pid else { return .init(status: .changed) }
        return dispatchEnd(request, directory: AppPaths.support,
                           isCurrent: { VoicePeerConfiguration.installed == configuration
                               && stillCurrent(call, since: launch, expires: request.expires) },
                           press: { try VoiceBridge.pressEnd(pid: call.pid, requireUniqueEnd: true, beforePress: $0) })
    }

    // The receiving Mac checks both the surviving session and the primary's decision.
    // A delayed command for a replaced winner cannot close the remaining call. — GPT-6.2 Astra
    static func authorizesEnd(_ request: VoicePeerMailbox.Request, configuration: VoicePeerConfiguration,
                              local: (VoicePeerMailbox.Request) -> VoicePeerReceipt,
                              peer: (VoicePeerMailbox.Request) -> VoicePeerReceipt) -> Bool {
        guard request.action == .end, let target = request.call, let other = request.otherCall else { return false }
        let isPrimary = configuration.role == .primary
        let primary = isPrimary ? target : other
        let secondary = isPrimary ? other : target
        if isPrimary {
            let survivor = peer(.init(action: .status, call: nil, expires: request.expires))
            guard survivor.status == .active, survivor.role == .secondary, survivor.call == secondary,
                  survivor.schedule == configuration.schedule, survivor.endPending != true else { return false }
        }
        // Resolving on the primary includes a fresh check of its exact active session.
        let resolve = VoicePeerMailbox.Request(action: .resolve, call: primary, expires: request.expires, otherCall: secondary)
        let receipt = isPrimary ? local(resolve) : peer(resolve)
        guard receipt.status == .resolved, isPrimary || receipt.endPending != true, let decision = receipt.decision,
              decision.primary == primary, decision.secondary == secondary else { return false }
        return decision.winner(for: configuration) == configuration.role.peer
    }

    // Both observers may send the same End. Coalesce delivery for its existing request
    // lifetime, then allow a fresh, checked End if the exact losing call is still active. — GPT-6.2 Astra
    static func dispatchEnd(_ request: VoicePeerMailbox.Request, directory: URL,
                            now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
                            isCurrent: @escaping () -> Bool, press: (() throws -> Void) throws -> Void) -> VoicePeerReceipt {
        guard request.action == .end, let call = request.call else { return .init(status: .unknown) }
        let file = directory.appendingPathComponent(endReceiptName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lock = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return .init(status: .unknown) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .init(status: .unknown) }
            guard request.valid(at: now()), isCurrent() else {
                return .init(status: .changed)
            }
            guard let pending = pendingEnd(for: call, in: directory, at: now()) else { return .init(status: .unknown) }
            if pending { return .init(status: .endRequested, call: call) }
            try press {
                guard request.valid(at: now()), isCurrent() else { throw EndError.changed }
                // Advertise the attempt before AX dispatch. A replacement on the other
                // Mac must not treat a call already being ended as the survivor.
                try JSONEncoder().encode(request).write(to: file, options: .atomic)
            }
            return .init(status: .endRequested, call: call)
        } catch EndError.changed { return .init(status: .changed) }
        catch { return .init(status: .unknown) }
    }

    static func pendingEnd(for call: VoicePeerCall, in directory: URL, at now: TimeInterval) -> Bool? {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(endReceiptName))
            let previous = try JSONDecoder().decode(VoicePeerMailbox.Request.self, from: data)
            return previous.call == call && previous.expires > now
        } catch CocoaError.fileReadNoSuchFile { return false }
        catch { return nil }
    }

    static func confirmation(of call: VoicePeerCall) -> VoicePeerReceipt {
        guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate,
              app.processIdentifier == call.pid else { return .init(status: .changed) }
        let ended = VoiceTimeline.hasEnded(database: VoiceTimeline.databaseURL(),
                                           thread: call.thread, session: call.session, since: launch)
        return .init(status: ended == true ? .ended : .unknown, call: call)
    }

    private enum EndError: Error { case changed }

    static func stillCurrent(_ call: VoicePeerCall, since launch: Date, expires: TimeInterval) -> Bool {
        guard Date().timeIntervalSince1970 <= expires,
              let app = VoiceBridge.currentApplication(), app.processIdentifier == call.pid, app.launchDate == launch,
              let sessions = VoiceTimeline.activeSessions(database: VoiceTimeline.databaseURL(), since: launch),
              sessions.count == 1, let identifier = sessions.first else { return false }
        return call.matches(identifier)
    }
}

@MainActor final class VoicePeerPriority {
    struct Transport {
        var local: (VoicePeerMailbox.Request) async -> VoicePeerReceipt
        var peer: (VoicePeerMailbox.Request) async -> VoicePeerReceipt

        static func live(_ machine: String) -> Self {
            .init(local: { request in await Task.detached(priority: .utility) { VoicePeerControl.respond(request) }.value },
                  peer: { request in await Task.detached(priority: .utility) {
                      VoicePeerBridge.run(machine: machine, request: request)
                  }.value })
        }
    }

    private let configuration: VoicePeerConfiguration?
    private let transport: Transport?
    private let diagnostics: Diagnostics?
    private let now: () -> Date
    private let waitForRetry: (TimeInterval) async throws -> Void
    private enum CheckResult { case finished, singleCall, retry }
    private static let maximumRetryDelay: TimeInterval = 60
    private var observedCall: String?
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay = VoicePeerMailbox.Request.queryLifetime
    var enabled: Bool { configuration != nil }

    init(configuration: VoicePeerConfiguration? = VoicePeerConfiguration.installed, transport: Transport? = nil,
         diagnostics: Diagnostics? = .shared, now: @escaping () -> Date = Date.init,
         waitForRetry: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.configuration = configuration
        self.transport = transport ?? configuration.map { .live($0.machine) }
        self.diagnostics = diagnostics
        self.now = now
        self.waitForRetry = waitForRetry
    }

    @discardableResult func observe(_ observation: VoiceCallObservation) -> Task<Void, Never>? {
        guard enabled else { return nil }
        if observation.presence == .inactive { stop(); return nil }
        guard observation.presence == .active, let identifier = observation.verifiedCallIdentifier else {
            if let observedCall, let id = observation.callIdentifier, id != observedCall { stop() }
            return nil
        }
        guard identifier != observedCall else { return nil }
        stop()
        observedCall = identifier
        return check(identifier)
    }

    @discardableResult private func check(_ identifier: String) -> Task<Void, Never>? {
        guard let configuration, let transport else { return nil }
        task = Task { [weak self] in
            guard let self else { return }
            let result = await self.resolveOverlap(identifier, configuration: configuration, transport: transport)
            guard !Task.isCancelled, self.observedCall == identifier else { return }
            self.task = nil
            switch result {
            case .finished: break
            case .singleCall:
                // A new peer normally checks immediately. Also catch a missed start
                // while this same local call stays open, even without another AX event.
                self.retryDelay = VoicePeerMailbox.Request.queryLifetime
                self.scheduleCheck(identifier, after: Self.maximumRetryDelay)
            case .retry:
                let delay = self.retryDelay
                self.retryDelay = min(delay * 2, Self.maximumRetryDelay)
                self.scheduleCheck(identifier, after: delay)
            }
        }
        return task
    }

    private func resolveOverlap(_ identifier: String, configuration: VoicePeerConfiguration, transport: Transport) async -> CheckResult {
        func request(_ action: VoicePeerMailbox.Action, call: VoicePeerCall? = nil, other: VoicePeerCall? = nil,
                     lifetime: TimeInterval = VoicePeerMailbox.Request.queryLifetime) -> VoicePeerMailbox.Request {
            .init(action: action, call: call, expires: now().timeIntervalSince1970 + lifetime, otherCall: other)
        }
        let peer = await transport.peer(request(.status))
        guard !Task.isCancelled, observedCall == identifier else { return .finished }
        if peer.status != .active {
            diagnostics?.record("voice.peer.checked", info: ["status": peer.status.rawValue])
            return peer.status == .inactive ? .singleCall : .retry
        }
        guard peer.role == configuration.role.peer, peer.schedule == configuration.schedule, let peerCall = peer.call else { return .retry }
        let local = await transport.local(request(.status))
        guard !Task.isCancelled, observedCall == identifier else { return .finished }
        guard local.status == .active, local.role == configuration.role, local.schedule == configuration.schedule,
              let localCall = local.call, localCall.matches(identifier) else { return .retry }

        let isPrimary = configuration.role == .primary
        let primary = isPrimary ? localCall : peerCall
        let secondary = isPrimary ? peerCall : localCall
        let authority = isPrimary ? transport.local : transport.peer
        let receipt = await authority(request(.resolve, call: primary, other: secondary, lifetime: 8))
        guard !Task.isCancelled, observedCall == identifier else { return .finished }
        guard receipt.status == .resolved, let decision = receipt.decision,
              decision.primary == primary, decision.secondary == secondary,
              let winner = decision.winner(for: configuration) else { return .retry }

        let endPeer = winner == configuration.role
        let target = endPeer ? peerCall : localCall
        let surviving = endPeer ? localCall : peerCall
        let send = endPeer ? transport.peer : transport.local
        let result = await send(request(.end, call: target, other: surviving, lifetime: 8))
        guard result.status == .endRequested, result.call == target else {
            diagnostics?.record("voice.peer.end", info: ["status": result.status.rawValue])
            return .retry
        }
        // An observer can see its own hang-up during dispatch. Confirm that exact
        // session even if the observer has already stopped or seen its replacement.
        let after = await send(request(.confirmEnd, call: target))
        let confirmed = after.status == .ended && after.call == target
        diagnostics?.record("voice.peer.end", info: ["status": confirmed ? "confirmed" : "unconfirmed"])
        guard confirmed else { return .retry }
        return endPeer ? .singleCall : .finished
    }

    private func scheduleCheck(_ identifier: String, after delay: TimeInterval) {
        retryTask = Task { [weak self, waitForRetry] in
            do { try await waitForRetry(delay) } catch { return }
            guard let self, !Task.isCancelled, self.observedCall == identifier else { return }
            self.retryTask = nil
            self.check(identifier)
        }
    }

    func stop() {
        task?.cancel(); task = nil
        retryTask?.cancel(); retryTask = nil
        observedCall = nil
        retryDelay = VoicePeerMailbox.Request.queryLifetime
    }

    func shutdown() async {
        let pending = task
        stop()
        await pending?.value
    }
}

enum VoicePeerBridge {
    static func run(machine: String, request: VoicePeerMailbox.Request) -> VoicePeerReceipt {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binary = home.appendingPathComponent("bin/agent-bridge")
        guard request.valid, let arguments = request.arguments,
              FileManager.default.isExecutableFile(atPath: binary.path) else { return .init(status: .unknown) }
        // The paired-host CLI supplies the installed SSH route. Its remote
        // command is fixed except for a validated session token and expiry.
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = binary
        process.arguments = ["run", machine, "/Applications/HelloChat.app/Contents/MacOS/HelloChat \(arguments.joined(separator: " "))"]
        var environment = ProcessInfo.processInfo.environment
        // Launch agents may start with a minimal environment. The paired
        // CLI needs the login user's home and standard macOS commands.
        environment["HOME"] = home.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return .init(status: .unknown) }
        guard done.wait(timeout: .now() + 12) == .success else {
            if process.isRunning { process.terminate() }
            return .init(status: .unknown)
        }
        guard process.terminationStatus == 0 else { return .init(status: .unknown) }
        return decode(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    static func decode(_ text: String) -> VoicePeerReceipt {
        let prefix = VoicePeerReceipt.wirePrefix
        let rows = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }
        guard rows.count == 1, let row = rows.first else { return .init(status: .unknown) }
        return (try? JSONDecoder().decode(VoicePeerReceipt.self, from: Data(row.dropFirst(prefix.count).utf8)))
            ?? .init(status: .unknown)
    }
}
