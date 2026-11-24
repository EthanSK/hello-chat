// Exercise paired Voice priority with injected calls and transport. — GPT-6.2 Astra
// The fixture never opens, closes, or queries any real Voice call.
import Foundation


private typealias Role = VoicePeerConfiguration.Role
private typealias Request = VoicePeerMailbox.Request
private let london = VoicePeerSchedule(startHour: 2, endHour: 11, timeZone: "Europe/London")!

private func date(_ utc: String) -> Date { ISO8601DateFormatter().date(from: utc)! }
private func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
private func call(pid: Int32) -> VoicePeerCall { VoicePeerCall(token: "\(UUID()):\(UUID()):\(pid)")! }

@MainActor private final class Pair {
    let directory: URL
    var decisions: VoicePeerDecisions
    var instant: Date
    var primary: VoicePeerReceipt
    var secondary: VoicePeerReceipt
    var inactive: Set<Role> = []
    var presses: [Role] = []
    var confirmations: [VoicePeerCall] = []
    var ended: [VoicePeerCall] = []
    var requests: [(Role, Request)] = []
    var override: ((Role, Request) -> VoicePeerReceipt?)?
    var afterDecision: (() -> Void)?
    var beforePress: (() -> Void)?
    var onPress: (() -> Void)?
    var endsImmediately = true

    init(in root: URL, at instant: Date, schedule: VoicePeerSchedule? = london) {
        directory = root.appendingPathComponent(UUID().uuidString)
        decisions = VoicePeerDecisions(file: directory.appendingPathComponent("decisions.json"))
        self.instant = instant
        let start = milliseconds(instant) - 1000
        primary = .init(status: .active, call: call(pid: 42), role: .primary, startedAtMilliseconds: start, schedule: schedule)
        secondary = .init(status: .active, call: call(pid: 43), role: .secondary, startedAtMilliseconds: start, schedule: schedule)
    }

    func session(_ role: Role) -> VoicePeerCall { (role == .primary ? primary : secondary).call! }

    func status(_ role: Role) -> VoicePeerReceipt {
        var saved = role == .primary ? primary : secondary
        if inactive.contains(role) { return .init(status: .inactive, role: saved.role, schedule: saved.schedule) }
        if let call = saved.call, VoicePeerControl.pendingEnd(for: call, in: directory.appendingPathComponent(role.rawValue),
                                                              at: instant.timeIntervalSince1970) == true { saved.endPending = true }
        return saved
    }

    func observation(_ role: Role) -> VoiceCallObservation {
        let current = status(role).call!
        let id = "\(current.thread):\(current.session)"
        return .init(presence: .active, callIdentifier: id, verifiedCallIdentifier: id)
    }

    func configuration(_ role: Role) -> VoicePeerConfiguration {
        VoicePeerConfiguration(machine: role.peer.rawValue, role: role, schedule: status(role).schedule)!
    }

    func observer(_ role: Role, wait: @escaping (TimeInterval) async throws -> Void = { _ in throw CancellationError() }) -> VoicePeerPriority {
        VoicePeerPriority(configuration: configuration(role), transport: .init(
            local: { self.handle($0, on: role) }, peer: { self.wire($0, to: role.peer) }),
            diagnostics: nil, now: { self.instant }, waitForRetry: wait)
    }

    // Exercise the production outgoing command, CLI parser, and receipt decoder on every peer hop. — GPT-6.2 Astra
    func wire(_ request: Request, to role: Role) -> VoicePeerReceipt {
        let result = VoicePeerMailbox.command(request.arguments!, enabled: { true }, now: instant.timeIntervalSince1970) {
            handle($0, on: role)
        }!
        let json = String(decoding: try! JSONEncoder().encode(result), as: UTF8.self)
        return VoicePeerBridge.decode("bridge output\n" + VoicePeerReceipt.wirePrefix + json)
    }

    func handle(_ request: Request, on role: Role) -> VoicePeerReceipt {
        requests.append((role, request))
        if let receipt = override?(role, request) { return receipt }
        guard request.valid(at: instant.timeIntervalSince1970) else { return .init(status: .unknown) }
        switch request.action {
        case .status: return status(role)
        case .resolve:
            let result = decisions.resolve(primary: request.call!, secondary: request.otherCall!, expires: request.expires,
                                           primaryStatus: { status(role) }, now: { instant })
            afterDecision?()
            return result
        case .end:
            guard VoicePeerControl.authorizesEnd(request, configuration: configuration(role),
                    local: { handle($0, on: role) }, peer: { wire($0, to: role.peer) }) else { return .init(status: .changed) }
            return VoicePeerControl.dispatchEnd(request, directory: directory.appendingPathComponent(role.rawValue),
                now: { self.instant.timeIntervalSince1970 },
                isCurrent: { self.status(role).status == .active && self.status(role).call == request.call },
                press: { check in
                    beforePress?()
                    try check()
                    presses.append(role)
                    if endsImmediately {
                        ended.append(request.call!)
                        inactive.insert(role)
                    }
                    onPress?()
                })
        case .confirmEnd:
            confirmations.append(request.call!)
            return .init(status: ended.contains(request.call!) ? .ended : .unknown, call: request.call)
        }
    }
}

@main enum VoicePeerPriorityTests {
    @MainActor static func main() async {
        let thread = UUID(), session = UUID()
        let identifier = "\(thread):\(session)"
        let local = VoicePeerCall(token: identifier + ":42")!
        var shown: [URL] = []
        for status in [VoicePeerReceipt.Status.inactive, .unknown, .changed, .disabled, .ended, .active] {
            let result = await ShowVoiceCommand.perform(resolve: { .init(status: status) }, recent: {
                precondition(status == .inactive); return .none
            }, open: { _, _ in
                fatalError("A missing or ambiguous call must never navigate")
            })
            precondition(result == (status == .inactive ? .inactive : .unknown))
        }
        let show = await ShowVoiceCommand.perform(resolve: { .init(status: .active, call: local) }, recent: { fatalError("Do not consult history during a call") }, open: { pid, link in
            precondition(pid == local.pid)
            shown.append(link)
            return true
        })
        precondition(show == .opened && shown.map(\.absoluteString) == ["codex://threads/" + thread.uuidString.lowercased()])
        let failedShow = await ShowVoiceCommand.perform(resolve: { .init(status: .active, call: local) }, open: { _, _ in false })
        precondition(failedShow == .failed)
        let last = UUID()
        let previous = await ShowVoiceCommand.perform(resolve: { .init(status: .inactive) },
            recent: { .thread(last) }, open: { pid, link in
                precondition(pid == nil && link.absoluteString == "codex://threads/" + last.uuidString.lowercased())
                return true
            })
        precondition(previous == .openedPrevious && previous.didOpen)
        let unavailable = await ShowVoiceCommand.perform(resolve: { .init(status: .inactive) },
            recent: { .unknown }, open: { _, _ in fatalError("Unknown history cannot navigate") })
        precondition(unavailable == .unknown)
        var checks = 0
        let race = await ShowVoiceCommand.perform(resolve: {
            checks += 1
            return checks == 1 ? .init(status: .inactive) : .init(status: .active, call: local)
        }, recent: { .thread(last) }, open: { pid, link in
            precondition(pid == local.pid && link.lastPathComponent == thread.uuidString.lowercased())
            return true
        })
        precondition(race == .opened)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePeerPriority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        await checkOrdersAndGaps(in: directory)
        await checkBoundariesAndRetries(in: directory)
        await checkConcurrentDecisions(in: directory)
        await checkGuards(in: directory)
        checkProtocol(local: local, directory: directory.appendingPathComponent("mailbox"))
        precondition(VoicePeerSchedule(startHour: 24, endHour: 11, timeZone: "Europe/London") == nil)
        precondition(VoicePeerSchedule(startHour: 2, endHour: 11, timeZone: "Invalid/Zone") == nil)
        let overnight = VoicePeerSchedule(startHour: 22, endHour: 7, timeZone: "Europe/London")!
        precondition(overnight.winner(atMilliseconds: milliseconds(date("2026-11-23T04:00:00Z"))) == .secondary)
        precondition(overnight.winner(atMilliseconds: milliseconds(date("2026-11-23T12:00:00Z"))) == .primary)
        precondition(VoicePeerCall(token: identifier + ":0") == nil)
        precondition(VoicePeerConfiguration(machine: "-option", role: .primary) == nil)
        precondition(VoicePeerConfiguration(machine: "bad host", role: .primary) == nil)
        precondition(VoicePeerPriority(configuration: nil).observe(.init(presence: .active, callIdentifier: identifier, verifiedCallIdentifier: identifier)) == nil)
        let defaultsName = "VoicePeerPriorityTests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        precondition(VoicePeerConfiguration(defaults: defaults) == nil)
        defaults.set(["machine": "paired-mac", "role": "primary"], forKey: "voicePeerPriority")
        precondition(VoicePeerConfiguration(defaults: defaults)?.machine == "paired-mac")
        precondition(VoicePeerConfiguration(defaults: defaults)?.role == .primary)
        defaults.set(["machine": "paired-mac", "role": "primary", "secondaryStartHour": 2], forKey: "voicePeerPriority")
        precondition(VoicePeerConfiguration(defaults: defaults) == nil)
        defaults.set(["machine": "paired-mac", "role": "primary", "secondaryStartHour": 2,
                      "secondaryEndHour": 11, "timeZone": "Europe/London"], forKey: "voicePeerPriority")
        precondition(VoicePeerConfiguration(defaults: defaults)?.schedule == london)
        print("Voice peer priority checks passed")
    }

    @MainActor private static func checkOrdersAndGaps(in root: URL) async {
        let times: [(String, Role)] = [
            ("2026-11-23T01:59:59Z", .primary), ("2026-11-23T02:00:00Z", .secondary),
            ("2026-11-23T10:59:59Z", .secondary), ("2026-11-23T11:00:00Z", .primary),
            ("2026-11-23T12:27:00Z", .primary), ("2026-03-29T00:59:59Z", .primary),
            ("2026-03-29T01:00:00Z", .secondary), ("2026-03-29T10:00:00Z", .primary),
            ("2026-10-25T00:30:00Z", .primary), ("2026-10-25T01:30:00Z", .primary), ("2026-10-25T02:00:00Z", .secondary)
        ]
        var count = 0
        for (utc, winner) in times {
            for first in [Role.primary, .secondary] {
                for gap: Int64 in [0, 1, 29_999, 30_000, 30_001, 180_000, 43_200_000] {
                    for initiator in [Role.primary, .secondary] {
                        let pair = Pair(in: root, at: date(utc))
                        if first == .primary { pair.primary.startedAtMilliseconds! -= gap }
                        else { pair.secondary.startedAtMilliseconds! -= gap }
                        let observer = pair.observer(initiator)
                        let active = pair.observation(initiator)
                        let task = observer.observe(active)
                        precondition(observer.observe(active) == nil, "Duplicate local notifications started another check")
                        await task?.value
                        precondition(pair.presses == [winner.peer] && pair.status(winner).status == .active,
                                     "\(utc) first=\(first) gap=\(gap) initiator=\(initiator) ended=\(pair.presses)")
                        precondition(pair.confirmations == [pair.session(winner.peer)])
                        count += 1
                    }
                }
            }
        }
        print("\(count) schedule, call-order and start-gap combinations passed")
    }

    @MainActor private static func checkBoundariesAndRetries(in root: URL) async {
        for (before, after, loser) in [("2026-11-23T01:59:59Z", "2026-11-23T02:00:00Z", Role.secondary),
                                       ("2026-11-23T10:59:59Z", "2026-11-23T11:00:00Z", .primary)] {
            let pair = Pair(in: root, at: date(before))
            pair.endsImmediately = false
            pair.afterDecision = {
                pair.instant = date(after)
                pair.afterDecision = nil
            }
            let first = pair.observer(.primary), second = pair.observer(.secondary)
            let a = first.observe(pair.observation(.primary)), b = second.observe(pair.observation(.secondary))
            await a?.value
            await b?.value
            precondition(pair.presses == [loser], "Concurrent observers straddling a boundary pressed different controls")
            precondition(pair.requests.filter { $0.1.action == .end }.allSatisfy { $0.0 == loser })
            precondition(pair.confirmations.count == 2, "Both unconfirmed attempts should check the exact session")
            // Drop the in-memory coordinator and retry after the dispatch receipt expires.
            pair.decisions = VoicePeerDecisions(file: pair.directory.appendingPathComponent("decisions.json"))
            pair.instant.addTimeInterval(10)
            pair.endsImmediately = true
            let restarted = pair.observer(loser.peer)
            await restarted.observe(pair.observation(loser.peer))?.value
            precondition(pair.presses == [loser, loser] && pair.status(loser.peer).status == .active)

            let replacement = Pair(in: root, at: date(before))
            replacement.endsImmediately = false
            let initial = replacement.observer(loser)
            await initial.observe(replacement.observation(loser))?.value
            replacement.instant = date(after)
            if loser.peer == .primary { replacement.primary.call = call(pid: 42) } else { replacement.secondary.call = call(pid: 43) }
            let arriving = replacement.observer(loser.peer)
            await arriving.observe(replacement.observation(loser.peer))?.value
            precondition(replacement.presses == [loser], "A session with an in-flight End cannot authorize ending its new peer")
        }

        for (failingAction, firstStatus) in [(VoicePeerMailbox.Action.status, VoicePeerReceipt.Status.unknown),
                                             (.status, .inactive), (.resolve, .unknown), (.end, .unknown)] {
            let pair = Pair(in: root, at: date("2026-11-23T01:59:59Z"))
            var failOnce = true
            pair.override = { _, request in
                guard request.action == failingAction, failOnce else { return nil }
                failOnce = false
                return .init(status: firstStatus)
            }
            let ticks = AsyncStream<Void>.makeStream()
            let observer = pair.observer(.secondary, wait: { _ in
                for await _ in ticks.stream { break }
            })
            await observer.observe(pair.observation(.secondary))?.value
            precondition(pair.presses.isEmpty)
            pair.instant = date("2026-11-23T02:00:00Z")
            ticks.continuation.yield()
            let timeout = ContinuousClock.now + .seconds(2)
            while pair.confirmations.isEmpty && ContinuousClock.now < timeout { await Task.yield() }
            let losingRole: Role = failingAction == .end ? .secondary : .primary
            precondition(pair.presses == [losingRole] && pair.confirmations == [pair.session(losingRole)],
                         "A \(firstStatus) \(failingAction) reply must recover without another notification or changing a recorded choice")
            ticks.continuation.finish()
            await observer.shutdown()
        }

        let pair = Pair(in: root, at: date("2026-11-23T12:27:00Z"))
        let secondary = pair.observer(.secondary)
        pair.onPress = { secondary.observe(.init(presence: .inactive, callIdentifier: nil)) }
        await secondary.observe(pair.observation(.secondary))?.value
        precondition(pair.confirmations == [pair.secondary.call!], "Local hang-up still needs exact End confirmation")
    }

    private static func checkConcurrentDecisions(in root: URL) async {
        let file = root.appendingPathComponent("concurrent/decisions.json")
        let store = VoicePeerDecisions(file: file)
        let primary = call(pid: 42), secondary = call(pid: 43)
        let active = VoicePeerReceipt(status: .active, call: primary, role: .primary, schedule: london)
        let boundary = date("2026-11-23T11:00:00Z")
        // Local observer and incoming mailbox resolve on different production threads. — GPT-6.2 Astra
        let times = await withTaskGroup(of: Int64.self, returning: Set<Int64>.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let now = index.isMultiple(of: 2) ? boundary : boundary.addingTimeInterval(-1)
                    let reply = store.resolve(primary: primary, secondary: secondary, expires: boundary.timeIntervalSince1970 + 8,
                                              primaryStatus: { active }, now: { now })
                    precondition(reply.status == .resolved && reply.decision?.primary == primary && reply.decision?.secondary == secondary)
                    return reply.decision!.resolvedAtMilliseconds
                }
            }
            var result: Set<Int64> = []
            for await time in group { result.insert(time) }
            return result
        }
        precondition(times.count == 1, "Concurrent requests must receive the same resolution time")
        let next = call(pid: secondary.pid)
        func resolve(_ other: VoicePeerCall, at now: Date) -> VoicePeerDecision? {
            store.resolve(primary: primary, secondary: other, expires: now.timeIntervalSince1970 + 8,
                          primaryStatus: { active }, now: { now }).decision
        }
        let later = boundary.addingTimeInterval(10)
        precondition(resolve(next, at: later)?.resolvedAtMilliseconds == milliseconds(later))
        precondition(times.contains(resolve(secondary, at: later)!.resolvedAtMilliseconds))
        precondition(resolve(next, at: later.addingTimeInterval(5))?.resolvedAtMilliseconds == milliseconds(later),
                     "A late request cannot evict a replacement session's decision")
    }

    @MainActor private static func checkGuards(in root: URL) async {
        let instant = date("2026-11-23T12:27:00Z")
        for role in [Role.primary, .secondary] {
            let pair = Pair(in: root, at: instant)
            let observer = pair.observer(role)
            let active = pair.observation(role)
            precondition(observer.observe(.init(presence: .active, callIdentifier: active.callIdentifier)) == nil)
            pair.inactive.insert(role.peer)
            await observer.observe(active)?.value
            precondition(pair.presses.isEmpty, "An unpaired call remains active")
            pair.inactive.remove(role.peer)
            let arriving = pair.observer(role.peer)
            await arriving.observe(pair.observation(role.peer))?.value
            precondition(pair.presses == [.secondary], "A later overlap must be seen by the arriving Mac")
        }

        let guards = Pair(in: root, at: instant)
        let observer = guards.observer(.primary)
        let active = guards.observation(.primary)
        guards.secondary.role = .primary
        await observer.observe(active)?.value
        observer.stop()
        guards.secondary.role = .secondary
        guards.secondary.schedule = nil
        await observer.observe(active)?.value
        observer.stop()
        guards.secondary.schedule = london
        guards.primary.call = call(pid: 42)
        await observer.observe(active)?.value
        precondition(guards.presses.isEmpty, "Role, schedule or observed session mismatch cannot authorize End")

        // Exercise rejection in the receiving app even when a correctly versioned End reaches it.
        for (when, loser) in [("2026-11-23T12:27:00Z", Role.secondary), ("2026-11-23T05:00:00Z", .primary)] {
            let pair = Pair(in: root, at: date(when))
            let target = pair.status(loser).call!, survivor = pair.status(loser.peer).call!
            let expires = pair.instant.timeIntervalSince1970 + 8
            let validEnd = Request(action: .end, call: target, expires: expires, otherCall: survivor)
            let wrongEnd = Request(action: .end, call: survivor, expires: expires, otherCall: target)
            precondition(pair.wire(wrongEnd, to: loser.peer).status == .changed)
            let replacement = call(pid: survivor.pid)
            if loser.peer == .primary { pair.primary.call = replacement } else { pair.secondary.call = replacement }
            precondition(pair.wire(validEnd, to: loser).status == .changed, "The surviving call was replaced")
            if loser.peer == .primary { pair.primary.call = survivor } else { pair.secondary.call = survivor }
            pair.beforePress = {
                if loser == .primary { pair.primary.call = call(pid: target.pid) } else { pair.secondary.call = call(pid: target.pid) }
            }
            precondition(pair.wire(validEnd, to: loser).status == .changed && pair.presses.isEmpty,
                         "The losing call was replaced during the native control scan")
        }

        let unscheduled = Pair(in: root, at: instant, schedule: nil)
        let fallback = unscheduled.observer(.secondary)
        await fallback.observe(unscheduled.observation(.secondary))?.value
        precondition(unscheduled.presses == [.secondary], "A configured pair without a schedule keeps the primary")

        let request = Request(action: .end, call: call(pid: 42), expires: instant.timeIntervalSince1970 + 8, otherCall: call(pid: 43))
        let dir = root.appendingPathComponent("native-failure")
        var now = instant.timeIntervalSince1970
        var presses = 0
        let failed = VoicePeerControl.dispatchEnd(request, directory: dir, now: { now }, isCurrent: { true }) { check in
            try check()
            throw CocoaError(.fileWriteUnknown)
        }
        let pending = VoicePeerControl.dispatchEnd(request, directory: dir, now: { now }, isCurrent: { true }) { _ in
            preconditionFailure("An ambiguous native press is still in flight")
        }
        now += 9
        let fresh = Request(action: .end, call: request.call, expires: now + 8, otherCall: request.otherCall)
        let retried = VoicePeerControl.dispatchEnd(fresh, directory: dir, now: { now }, isCurrent: { true }) { check in
            try check()
            presses += 1
        }
        precondition(failed.status == .unknown && pending.status == .endRequested && retried.status == .endRequested && presses == 1,
                     "A failed native press cannot leave a permanent success receipt")
        let next = Request(action: .end, call: call(pid: 42), expires: now + 8, otherCall: request.otherCall)
        let stale = VoicePeerControl.dispatchEnd(next, directory: dir, now: { now }, isCurrent: { true }) { check in
            now += 9
            try check()
            presses += 1
        }
        precondition(stale.status == .changed && presses == 1)
    }

    private static func checkProtocol(local: VoicePeerCall, directory: URL) {
        let now = Date().timeIntervalSince1970
        let other = call(pid: 43)
        let request = Request(action: .end, call: local, expires: now + 8, otherCall: other)
        let arguments = request.arguments!
        var sent = 0
        let successful = VoicePeerReceipt(status: .endRequested, call: local)
        func command(_ arguments: [String]) -> VoicePeerReceipt? {
            VoicePeerMailbox.command(arguments, enabled: { true }, now: now) { parsed in
                precondition(parsed.action == .end && parsed.call == local && parsed.otherCall == other && parsed.expires == request.expires)
                sent += 1
                return successful
            }
        }
        precondition(command(arguments) == successful)
        for old in ["v2", "v3"] {
            precondition(command(Array(arguments.dropLast()) + [old])?.status == .unknown)
            precondition(command(["--voice-peer-end", local.token, String(Int(now + 8)), old])?.status == .unknown)
            let oldReply = "HCHAT_VOICE_PEER_\(old.uppercased()) " + String(decoding: try! JSONEncoder().encode(successful), as: UTF8.self)
            precondition(VoicePeerBridge.decode(oldReply).status == .unknown)
        }
        precondition(command(Array(arguments.dropLast()))?.status == .unknown && sent == 1)
        precondition(command(["--unrelated"]) == nil)
        let expired = Request(action: .end, call: local, expires: now - 1, otherCall: other)
        let missing = Request(action: .end, call: local, expires: now + 4)
        let status = Request(action: .status, call: nil, expires: now + 4)
        precondition(VoicePeerMailbox.submit(expired, directory: directory).status == .unknown)
        precondition(VoicePeerMailbox.submit(missing, directory: directory).status == .unknown)
        precondition(VoicePeerMailbox.submit(status, directory: directory).status == .unknown)
        // Use two real serial mailbox listeners for the receiver's check back to the winner.
        // Only the native status and button press are fixtures. — GPT-6.2 Astra
        for (utc, loser) in [("2020-01-01T02:00:00Z", Role.primary), ("2020-01-01T11:00:00Z", .secondary)] {
            let root = directory.appendingPathComponent(loser.rawValue)
            let decisions = VoicePeerDecisions(file: root.appendingPathComponent("decisions.json"))
            func path(_ role: Role) -> URL { root.appendingPathComponent(role.rawValue) }
            func session(_ role: Role) -> VoicePeerCall { role == .primary ? local : other }
            func send(_ request: Request, to role: Role) -> VoicePeerReceipt {
                VoicePeerMailbox.command(request.arguments!, enabled: { true },
                                         send: { VoicePeerMailbox.submit($0, directory: path(role)) })!
            }
            func handle(_ request: Request, on role: Role) -> VoicePeerReceipt {
                let active = VoicePeerReceipt(status: .active, call: session(role), role: role, schedule: london)
                switch request.action {
                case .status: return active
                case .resolve:
                    return decisions.resolve(primary: request.call!, secondary: request.otherCall!, expires: request.expires,
                                             primaryStatus: { active }, now: { date(utc) })
                case .end:
                    let config = VoicePeerConfiguration(machine: "peer", role: role, schedule: london)!
                    guard VoicePeerControl.authorizesEnd(request, configuration: config,
                        local: { handle($0, on: role) }, peer: { send($0, to: role.peer) }) else { return .init(status: .changed) }
                    return VoicePeerControl.dispatchEnd(request, directory: path(role), isCurrent: { request.call == session(role) },
                                                        press: { try $0() })
                case .confirmEnd: return .init(status: .unknown)
                }
            }
            let primary = VoicePeerMailbox(directory: path(.primary)) { handle($0, on: .primary) }
            let secondary = VoicePeerMailbox(directory: path(.secondary)) { handle($0, on: .secondary) }
            primary.start()
            secondary.start()
            defer { primary.stop(); secondary.stop() }
            for role in [loser.peer, loser] {
                let end = Request(action: .end, call: session(role), expires: Date().timeIntervalSince1970 + 8, otherCall: session(role.peer))
                let reply = send(end, to: role)
                precondition(reply.status == (role == loser ? .endRequested : .changed))
                precondition(VoicePeerControl.pendingEnd(for: session(role), in: path(role), at: Date().timeIntervalSince1970) == (role == loser))
            }
        }
    }
}
