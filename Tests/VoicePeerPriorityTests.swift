// Exercise startup peer arbitration with injected native/bridge results.
// The fixture never opens, closes, or queries any real Voice call.
import Foundation

@main enum VoicePeerPriorityTests {
    @MainActor static func main() async {
        let thread = UUID(), session = UUID()
        let identifier = "\(thread):\(session)"
        let local = VoicePeerCall(token: identifier + ":42")!
        let peer = VoicePeerCall(token: "\(UUID()):\(UUID()):43")!
        let active = VoiceCallObservation(presence: .active, callIdentifier: identifier, verifiedCallIdentifier: identifier)
        let ledgerOnly = VoiceCallObservation(presence: .active, callIdentifier: identifier)
        let observingSince = Date(timeIntervalSince1970: 100)
        var calls: [String] = []
        var localStatus = VoicePeerReceipt(status: .active, call: local, role: .primary, startedAtMilliseconds: 200_000)
        var peerStatus = VoicePeerReceipt(status: .active, call: peer, role: .secondary, startedAtMilliseconds: 229_999)
        var onLocalEnd: (() -> Void)?
        let transport = VoicePeerPriority.Transport(
            localStatus: { calls.append("local"); return localStatus },
            peerStatus: { calls.append("peer"); return peerStatus },
            endLocal: { call, deadline in
                precondition(call == local && deadline > Date().timeIntervalSince1970)
                calls.append("end-local")
                localStatus = .init(status: .inactive)
                onLocalEnd?()
                return .init(status: .endRequested, call: call)
            },
            endPeer: { call, deadline in
                precondition(call == peer && deadline > Date().timeIntervalSince1970)
                calls.append("end-peer")
                peerStatus = .init(status: .inactive)
                return .init(status: .endRequested, call: call)
            },
            confirmLocal: { call in calls.append("confirm-local"); return .init(status: .ended, call: call) },
            confirmPeer: { call in calls.append("confirm-peer"); return .init(status: .ended, call: call) })
        let primary = VoicePeerPriority(configuration: .init(machine: "secondary", role: .primary),
                                        transport: transport, observingSince: observingSince, diagnostics: nil)
        precondition(primary.observe(ledgerOnly) == nil && calls.isEmpty)
        await primary.observe(active)?.value
        precondition(calls == ["peer", "local", "end-peer", "confirm-peer"])
        precondition(primary.observe(active) == nil, "Repeat AX notifications do not send another End")
        primary.stop()

        calls.removeAll()
        peerStatus = .init(status: .active, call: peer, role: .primary)
        await primary.observe(active)?.value
        precondition(calls == ["peer"], "A role mismatch cannot end either Mac")
        primary.stop()

        calls.removeAll()
        peerStatus = .init(status: .active, call: peer, role: .secondary)
        localStatus = .init(status: .active, call: peer, role: .primary)
        await primary.observe(active)?.value
        precondition(calls == ["peer", "local"], "A replacement local call invalidates the earlier request")
        primary.stop()

        calls.removeAll()
        peerStatus = .init(status: .unknown)
        await primary.observe(active)?.value
        precondition(calls == ["peer"], "Unknown peer state cannot authorize an End")
        primary.stop()

        let secondary = VoicePeerPriority(configuration: .init(machine: "primary", role: .secondary),
                                          transport: transport, observingSince: observingSince, diagnostics: nil)
        func checkSecondary(localStart: Int64, peerStart: Int64?, expected: [String]) async {
            calls.removeAll()
            secondary.stop()
            peerStatus = .init(status: .active, call: peer, role: .primary, startedAtMilliseconds: peerStart)
            localStatus = .init(status: .active, call: local, role: .secondary, startedAtMilliseconds: localStart)
            await secondary.observe(active)?.value
            precondition(calls == expected, "Local start \(localStart), peer start \(String(describing: peerStart)): \(calls)")
        }
        onLocalEnd = { secondary.observe(.init(presence: .inactive, callIdentifier: nil)) }
        await checkSecondary(localStart: 230_000, peerStart: 200_000,
                             expected: ["peer", "local", "end-local", "confirm-local"])
        await checkSecondary(localStart: 230_001, peerStart: 200_000,
                             expected: ["peer", "local", "end-peer", "confirm-peer"])
        await checkSecondary(localStart: 200_000, peerStart: 230_001, expected: ["peer", "local"])
        await checkSecondary(localStart: 230_001, peerStart: nil, expected: ["peer", "local"])
        await checkSecondary(localStart: 99_999, peerStart: 60_000, expected: ["peer", "local"])

        let london = VoicePeerSchedule(startHour: 2, endHour: 11, timeZone: "Europe/London")!
        func milliseconds(_ utc: String) -> Int64 {
            Int64(ISO8601DateFormatter().date(from: utc)!.timeIntervalSince1970 * 1000)
        }
        let scheduleCases: [(String, VoicePeerConfiguration.Role)] = [
            ("2026-11-23T01:59:59Z", .primary), ("2026-11-23T02:00:00Z", .secondary),
            ("2026-11-23T10:59:59Z", .secondary), ("2026-11-23T11:00:00Z", .primary),
            ("2026-03-29T00:59:59Z", .primary), ("2026-03-29T01:00:00Z", .secondary),
            ("2026-03-29T10:00:00Z", .primary),
            ("2026-10-25T00:30:00Z", .primary), ("2026-10-25T01:30:00Z", .primary),
            ("2026-10-25T02:00:00Z", .secondary),
        ]
        for (utc, winner) in scheduleCases {
            precondition(london.winner(atMilliseconds: milliseconds(utc)) == winner, "UK schedule at \(utc)")
        }
        precondition(VoicePeerSchedule(startHour: 24, endHour: 11, timeZone: "Europe/London") == nil)
        precondition(VoicePeerSchedule(startHour: 2, endHour: 11, timeZone: "Invalid/Zone") == nil)
        let overnight = VoicePeerSchedule(startHour: 22, endHour: 7, timeZone: "Europe/London")!
        precondition(overnight.winner(atMilliseconds: milliseconds("2026-11-23T04:00:00Z")) == .secondary)
        precondition(overnight.winner(atMilliseconds: milliseconds("2026-11-23T12:00:00Z")) == .primary)

        onLocalEnd = nil
        func checkScheduled(_ role: VoicePeerConfiguration.Role, firstLocal: Bool, firstUTC: String,
                            gap: Int64, peerSchedule: VoicePeerSchedule?, expected: [String]) async {
            let first = milliseconds(firstUTC), later = first + gap
            let observer = VoicePeerPriority(configuration: .init(machine: "peer", role: role, schedule: london),
                                             transport: transport, observingSince: observingSince, diagnostics: nil)
            calls.removeAll()
            localStatus = .init(status: .active, call: local, role: role,
                                startedAtMilliseconds: firstLocal ? first : later, schedule: london)
            peerStatus = .init(status: .active, call: peer, role: role.peer,
                               startedAtMilliseconds: firstLocal ? later : first, schedule: peerSchedule)
            await observer.observe(active)?.value
            precondition(calls == ["peer", "local"] + expected, "Arbitration at \(firstUTC) on \(role): \(calls)")
        }
        for (first, winner) in [("2026-11-23T01:59:59Z", VoicePeerConfiguration.Role.primary),
                                ("2026-11-23T10:59:59Z", .secondary)] {
            // The same pair viewed from opposite Macs must end the same call.
            await checkScheduled(.primary, firstLocal: true, firstUTC: first, gap: 30_000, peerSchedule: london,
                                 expected: winner == .primary ? ["end-peer", "confirm-peer"] : ["end-local", "confirm-local"])
            await checkScheduled(.secondary, firstLocal: false, firstUTC: first, gap: 30_000, peerSchedule: london,
                                 expected: winner == .secondary ? ["end-peer", "confirm-peer"] : ["end-local", "confirm-local"])
        }
        await checkScheduled(.secondary, firstLocal: false, firstUTC: "2026-11-23T12:00:00Z",
                             gap: 30_001, peerSchedule: london, expected: ["end-peer", "confirm-peer"])
        await checkScheduled(.primary, firstLocal: false, firstUTC: "2026-11-23T03:00:00Z",
                             gap: 30_001, peerSchedule: london, expected: ["end-peer", "confirm-peer"])
        await checkScheduled(.secondary, firstLocal: false, firstUTC: "2026-11-23T03:00:00Z",
                             gap: 1, peerSchedule: nil, expected: [])

        precondition(VoicePeerCall(token: identifier + ":0") == nil)
        precondition(VoicePeerConfiguration(machine: "-option", role: .primary) == nil)
        precondition(VoicePeerConfiguration(machine: "bad host", role: .primary) == nil)
        precondition(VoicePeerPriority(configuration: nil, transport: transport).observe(active) == nil)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePeerMailbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = VoicePeerMailbox.Request(action: .end, call: local, expires: Date().timeIntervalSince1970 - 1)
        let noSession = VoicePeerMailbox.Request(action: .end, call: nil, expires: Date().timeIntervalSince1970 + 4)
        let status = VoicePeerMailbox.Request(action: .status, call: nil, expires: Date().timeIntervalSince1970 + 4)
        precondition(VoicePeerMailbox.submit(expired, directory: directory).status == .unknown)
        precondition(VoicePeerMailbox.submit(noSession, directory: directory).status == .unknown)
        precondition(VoicePeerMailbox.submit(status, directory: directory).status == .unknown)
        let mailbox = VoicePeerMailbox(directory: directory) { request in
            precondition(request.action == .status)
            return .init(status: .active, call: local, role: .secondary)
        }
        mailbox.start()
        let received = VoicePeerMailbox.submit(status, directory: directory)
        precondition(received == .init(status: .active, call: local, role: .secondary))
        mailbox.stop()
        print("Voice peer priority checks passed")
    }
}
