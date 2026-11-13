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
        var calls: [String] = []
        var localStatus = VoicePeerReceipt(status: .active, call: local, role: .primary)
        var peerStatus = VoicePeerReceipt(status: .active, call: peer, role: .secondary)
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
        let primary = VoicePeerPriority(configuration: .init(machine: "secondary", role: .primary), transport: transport)
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

        calls.removeAll()
        peerStatus = .init(status: .active, call: peer, role: .primary)
        localStatus = .init(status: .active, call: local, role: .secondary)
        let secondary = VoicePeerPriority(configuration: .init(machine: "primary", role: .secondary), transport: transport)
        onLocalEnd = { secondary.observe(.init(presence: .inactive, callIdentifier: nil)) }
        await secondary.observe(active)?.value
        precondition(calls == ["peer", "local", "end-local", "confirm-local"], "A new M1 call yields when the M5 already has Voice")

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
        print("Voice peer priority checks passed")
    }
}
