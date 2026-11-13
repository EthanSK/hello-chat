// Check paired Macs at the start of a native Codex call and end only the
// identified secondary call. H Chat's own observer drives this independently
// of speech recognition, Spotify, or a Voice agent getting a tool turn.
import AppKit
import ApplicationServices
import Darwin
import Foundation

struct VoicePeerConfiguration {
    enum Role: String, Codable {
        case primary, secondary
        var peer: Self { self == .primary ? .secondary : .primary }
    }
    let machine: String
    let role: Role

    init?(defaults: UserDefaults) {
        guard let configuration = defaults.dictionary(forKey: "voicePeerPriority"),
              let machine = configuration["machine"] as? String,
              let role = (configuration["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        self.init(machine: machine, role: role)
    }

    init?(machine: String, role: Role) {
        guard !machine.isEmpty, machine.utf8.count <= 80,
              machine.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              !machine.hasPrefix("-") else { return nil }
        self.machine = machine
        self.role = role
    }

    // Foundation rejects opening this bundle's own ID as a separate suite.
    static var installed: Self? { Self(defaults: .standard) }
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
    enum Status: String, Codable { case active, inactive, unknown, changed, endRequested, ended, disabled }
    let status: Status
    var call: VoicePeerCall? = nil
    var role: VoicePeerConfiguration.Role? = nil

    static let wirePrefix = "HCHAT_VOICE_PEER_V1 "
}

enum VoicePeerControl {
    static func respond(_ request: VoicePeerMailbox.Request) -> VoicePeerReceipt {
        switch (request.action, request.call) {
        case (.status, nil): return status()
        case (.end, let call?): return end(call, expires: request.expires)
        case (.confirmEnd, let call?): return confirmation(of: call)
        default: return .init(status: .unknown)
        }
    }

    static func status() -> VoicePeerReceipt {
        guard let role = VoicePeerConfiguration.installed?.role else { return .init(status: .disabled) }
        guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate else {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                .contains { !$0.isTerminated }
            return .init(status: running ? .unknown : .inactive, role: role)
        }
        let database = VoiceTimeline.databaseURL()
        let before = VoiceTimeline.activeSessions(database: database, since: launch)
        let state = VoiceBridge.snapshot(requireEnd: true)
        guard state.pid == app.processIdentifier, state.accessibilityAllowed,
              let before, before == VoiceTimeline.activeSessions(database: database, since: launch) else {
            return .init(status: .unknown)
        }
        if let id = before.first, before.count == 1, state.endControlAvailable || state.microphone != nil,
           let call = VoicePeerCall(token: id + ":\(app.processIdentifier)") {
            return .init(status: .active, call: call, role: role)
        }
        let absent = before.isEmpty && state.controlsComplete && !state.endControlAvailable && state.microphone == nil
        return .init(status: absent ? .inactive : .unknown, role: role)
    }

    static func end(_ call: VoicePeerCall, expires: TimeInterval) -> VoicePeerReceipt {
        guard VoicePeerConfiguration.installed?.role == .secondary else { return .init(status: .disabled) }
        // Two startups can both identify the same M1 call. Share one
        // dispatch receipt between the SSH command and the app process.
        let directory = AppPaths.support
        let file = directory.appendingPathComponent("voice-peer-end")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lock = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return .init(status: .unknown) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .init(status: .unknown) }
            guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate,
                  app.processIdentifier == call.pid, stillCurrent(call, since: launch, expires: expires) else {
                return .init(status: .changed)
            }
            // The same exact End button used for local recovery. Check the
            // identity after the AX scan so a replacement call survives.
            if (try? String(contentsOf: file, encoding: .utf8)) == call.token {
                return .init(status: .endRequested, call: call)
            }
            try VoiceBridge.pressEnd(pid: call.pid, requireUniqueEnd: true, beforePress: {
                guard stillCurrent(call, since: launch, expires: expires) else { throw EndError.changed }
                try call.token.write(to: file, atomically: true, encoding: .utf8)
            })
            return .init(status: .endRequested, call: call)
        } catch EndError.changed { return .init(status: .changed) }
        catch { return .init(status: .unknown) }
    }

    static func confirmation(of call: VoicePeerCall) -> VoicePeerReceipt {
        guard let app = VoiceBridge.currentApplication(), let launch = app.launchDate,
              app.processIdentifier == call.pid else { return .init(status: .changed) }
        let ended = VoiceTimeline.hasEnded(database: VoiceTimeline.databaseURL(),
                                           thread: call.thread, session: call.session, since: launch)
        return .init(status: ended == true ? .ended : .unknown, call: call)
    }

    private enum EndError: Error { case changed }

    private static func stillCurrent(_ call: VoicePeerCall, since launch: Date, expires: TimeInterval) -> Bool {
        guard Date().timeIntervalSince1970 <= expires,
              let app = VoiceBridge.currentApplication(), app.processIdentifier == call.pid, app.launchDate == launch,
              let sessions = VoiceTimeline.activeSessions(database: VoiceTimeline.databaseURL(), since: launch),
              sessions.count == 1, let identifier = sessions.first else { return false }
        return call.matches(identifier)
    }
}

@MainActor final class VoicePeerPriority {
    struct Transport {
        var localStatus: () async -> VoicePeerReceipt
        var peerStatus: () async -> VoicePeerReceipt
        var endLocal: (VoicePeerCall, TimeInterval) async -> VoicePeerReceipt
        var endPeer: (VoicePeerCall, TimeInterval) async -> VoicePeerReceipt
        var confirmLocal: (VoicePeerCall) async -> VoicePeerReceipt
        var confirmPeer: (VoicePeerCall) async -> VoicePeerReceipt

        static func live(_ machine: String) -> Self {
            .init(localStatus: { await Task.detached(priority: .utility) { VoicePeerControl.status() }.value },
                  peerStatus: { await Task.detached(priority: .utility) {
                      VoicePeerBridge.run(machine: machine, arguments: "--voice-peer-status")
                  }.value },
                  endLocal: { call, expires in await Task.detached(priority: .utility) {
                      VoicePeerControl.end(call, expires: expires)
                  }.value },
                  endPeer: { call, expires in await Task.detached(priority: .utility) {
                      VoicePeerBridge.run(machine: machine, arguments: "--voice-peer-end \(call.token) \(Int(expires))")
                  }.value },
                  confirmLocal: { call in await Task.detached(priority: .utility) {
                      VoicePeerControl.confirmation(of: call)
                  }.value },
                  confirmPeer: { call in await Task.detached(priority: .utility) {
                      VoicePeerBridge.run(machine: machine, arguments: "--voice-peer-confirm-end \(call.token)")
                  }.value })
        }
    }

    private let configuration: VoicePeerConfiguration?
    private let transport: Transport?
    private var task: Task<Void, Never>?
    private var observedCall: String?
    private var attemptedCall: String?
    var enabled: Bool { configuration != nil }

    init(configuration: VoicePeerConfiguration? = VoicePeerConfiguration.installed, transport: Transport? = nil) {
        self.configuration = configuration
        self.transport = transport ?? configuration.map { .live($0.machine) }
    }

    @discardableResult func observe(_ observation: VoiceCallObservation) -> Task<Void, Never>? {
        guard let configuration, let transport else { return nil }
        if observation.presence == .inactive { stop(); return nil }
        guard observation.presence == .active, let identifier = observation.verifiedCallIdentifier else {
            if observedCall != nil, let id = observation.callIdentifier, id != observedCall { stop() }
            return nil
        }
        guard identifier != attemptedCall else { return nil }
        task?.cancel()
        observedCall = identifier
        attemptedCall = identifier
        task = Task { [weak self] in
            let peer = await transport.peerStatus()
            guard !Task.isCancelled, self?.observedCall == identifier else { return }
            guard peer.status == .active, peer.role == configuration.role.peer, let peerCall = peer.call else {
                Diagnostics.shared.record("voice.peer.checked", info: ["status": peer.status.rawValue])
                return
            }
            let local = await transport.localStatus()
            guard !Task.isCancelled, self?.observedCall == identifier, local.status == .active,
                  local.role == configuration.role, let localCall = local.call, localCall.matches(identifier) else { return }
            // Bound the lifetime of the exact End request. Late SSH delivery
            // cannot act on an old decision after the caller's check is stale.
            let expires = Date().timeIntervalSince1970 + 8
            let result = configuration.role == .primary
                ? await transport.endPeer(peerCall, expires) : await transport.endLocal(localCall, expires)
            // The local observer can see the successful M1 hang-up first and
            // cancel this startup task. The End already sent still needs its
            // read-only confirmation even when the observation has changed.
            guard result.status == .endRequested else {
                Diagnostics.shared.record("voice.peer.end", info: ["status": result.status.rawValue])
                return
            }
            let after = configuration.role == .primary ? await transport.confirmPeer(peerCall) : await transport.confirmLocal(localCall)
            let confirmed = after.status == .ended && after.call == result.call
            Diagnostics.shared.record("voice.peer.end", info: ["status": confirmed ? "confirmed" : "unconfirmed"])
        }
        return task
    }

    func stop() {
        task?.cancel(); task = nil
        observedCall = nil; attemptedCall = nil
    }

    func shutdown() async {
        let pending = task
        stop()
        await pending?.value
    }
}

enum VoicePeerBridge {
    static func run(machine: String, arguments: String) -> VoicePeerReceipt {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binary = home.appendingPathComponent("bin/agent-bridge")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return .init(status: .unknown) }
        // The paired-host CLI supplies the installed SSH route. Its remote
        // command is fixed except for a validated session token and expiry.
        let process = Process(), output = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = binary
        process.arguments = ["run", machine, "/Applications/HelloChat.app/Contents/MacOS/HelloChat \(arguments)"]
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
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let prefix = VoicePeerReceipt.wirePrefix
        let rows = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }
        guard rows.count == 1, let row = rows.first else { return .init(status: .unknown) }
        return (try? JSONDecoder().decode(VoicePeerReceipt.self, from: Data(row.dropFirst(prefix.count).utf8)))
            ?? .init(status: .unknown)
    }
}
