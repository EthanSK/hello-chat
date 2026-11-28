// Exercise the exact-call Model Bar handoff with inert process/native dependencies. — GPT-6.1 Sol
import AppKit
import Foundation

@MainActor private final class Fixture {
    let call = VoicePeerCall(token: "\(UUID()):\(UUID()):123")!
    var selected = CodexChatSpeed.Speed.standard
    var model = "GPT-6.1 Sol Extra high"
    var current = true, openAllowed = true, restoreWorks = true
    var badReply = "", reads = 0, transactions = 0, requests: [ModelBarVoiceSpeed.Request] = []
    var environment: ModelBarVoiceSpeed.Environment {
        var e = ModelBarVoiceSpeed.Environment()
        e.current = { self.current ? .init(status: .active, call: self.call) : .init(status: .inactive) }
        e.title = { _ in "Exact test Voice" }
        e.open = { _ in self.openAllowed }
        e.read = { _ in
            self.reads += 1
            return .init(status: "observed", thread: self.call.thread, speed: self.selected,
                         model: self.badReply == "changed-model" && self.reads > 1 ? "Another model" : self.model)
        }
        e.transact = { _, _, apply in
            self.transactions += 1
            let result = await apply()
            return self.restoreWorks ? result : .init(status: "defaultsUnconfirmed", thread: self.call.thread, speed: nil, model: nil)
        }
        e.relay = { r in
            self.requests.append(r)
            if self.badReply == "no-receipt" { return nil }
            if !r.verifyOnly { self.selected = CodexSpeed.allCases.first { $0.relayValue == r.speed }! }
            if self.badReply == "changed-call" { self.current = false }
            return .init(requestId: self.badReply == "wrong-id" ? UUID() : r.requestId,
                         callToken: self.badReply == "wrong-call" ? "\(UUID()):\(UUID()):123" : r.callToken,
                         expiresAtMs: self.badReply == "wrong-expiry" ? r.expiresAtMs + 1 : r.expiresAtMs,
                         result: r.verifyOnly ? "already-selected" : "applied", selectedSpeed: r.speed,
                         displaySpeed: self.badReply == "wrong-display" ? "wrong" : r.speed,
                         model: "gpt-6.1-sol", reasoning: "xhigh", reason: nil)
        }
        return e
    }
}

@main enum ModelBarVoiceSpeedTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }
        let good = Fixture()
        let result = await ModelBarVoiceSpeed.perform(call: good.call, environment: good.environment)
        check(result.succeeded && result.speed == .ultrafast && result.model == good.model, "Exact selection and original model readback")
        check(good.transactions == 1 && good.requests.count == 2, "One restoration transaction, one mutation, one read-only verification")
        check(!good.requests[0].verifyOnly && good.requests[1].verifyOnly && good.requests[0].requestId != good.requests[1].requestId,
              "Post-restore observation is explicitly read-only, never a mutation replay")
        check(good.requests.allSatisfy { VoicePeerCall(token: $0.callToken) == good.call && $0.chatTitle == "Exact test Voice" }, "Both operations retain exact call and composer title")
        for speed in CodexSpeed.allCases {
            let f = Fixture(); f.selected = speed == .standard ? .fast : .standard
            let result = await ModelBarVoiceSpeed.perform(call: f.call, speed: speed, environment: f.environment)
            check(result.succeeded && result.speed == speed && f.requests.count == 2, "Requested \(speed) confirms both native and bar state")
            check(f.requests.allSatisfy { $0.speed == speed.relayValue }, "Apply and post-restore verification keep the exact requested tier")
        }
        let invalidated = Fixture()
        check(!(await ModelBarVoiceSpeed.perform(call: invalidated.call, valid: { false }, environment: invalidated.environment)).succeeded
              && invalidated.requests.isEmpty, "An obsolete recognition occurrence cannot navigate or change speed")
        let already = Fixture(); already.selected = .ultrafast
        check(await ModelBarVoiceSpeed.perform(call: already.call, environment: already.environment).succeeded
              && already.transactions == 0 && already.requests.count == 2 && already.requests.allSatisfy(\.verifyOnly),
              "Already-selected native state uses only read-only bar verification without a temporary defaults mutation")
        for bad in ["wrong-id", "wrong-call", "wrong-expiry", "wrong-display", "no-receipt", "changed-call", "changed-model"] {
            let f = Fixture(); f.badReply = bad
            check(!(await ModelBarVoiceSpeed.perform(call: f.call, environment: f.environment)).succeeded, "Refuse \(bad)")
            check(f.requests.filter { !$0.verifyOnly }.count == 1, "Uncertain \(bad) never sends a second mutation")
        }
        let restoration = Fixture(); restoration.restoreWorks = false
        let notRestored = await ModelBarVoiceSpeed.perform(call: restoration.call, environment: restoration.environment)
        check(notRestored.status == "defaultsUnconfirmed" && restoration.requests.count == 1, "Restoration failure remains visible and prevents final success")
        let closed = Fixture(); closed.current = false
        check(!(await ModelBarVoiceSpeed.perform(call: closed.call, environment: closed.environment)).succeeded
              && closed.requests.isEmpty && closed.transactions == 0, "Missing or changed call makes no request")
        let background = Fixture(); background.openAllowed = false
        check(!(await ModelBarVoiceSpeed.perform(call: background.call, environment: background.environment)).succeeded
              && background.requests.isEmpty, "Failed exact navigation does not operate whichever app is in front")
        var launch = ModelBarVoiceLaunch()
        let now = Date(), other = VoicePeerCall(token: "\(UUID()):\(UUID()):999")!
        let state = VoicePeerReceipt(status: .active, call: good.call, startedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000) + 10)
        var ordered = ModelBarVoiceLaunch()
        ordered.arm(sent: now, pid: good.call.pid)
        check(ordered.takeNavigation(.init(status: .unknown), at: now) == nil, "No Show Voice before genuine identity")
        check(ordered.takeNavigation(state, at: now) == good.call, "Exact Show Voice is admitted before a unique title is required")
        check(ordered.takeNavigation(state, at: now) == nil && ordered.pending?.call == good.call, "No replay of navigation while title/composer is pending")
        check(ordered.take(state, at: now, composerReady: false) == nil, "Showing the correct chat alone does not authorize a speed read")
        check(ordered.take(state, at: now, composerReady: true) == good.call, "Only the same ready chat reaches the speed action")
        check(launch.take(state, at: now) == nil, "An unrelated native call cannot arm automatic speed")
        launch.arm(sent: now, pid: good.call.pid)
        check(launch.take(.init(status: .unknown), at: now) == nil && launch.pending != nil, "Unknown metadata waits for the existing observer")
        check(launch.take(.init(status: .active, call: other, startedAtMilliseconds: state.startedAtMilliseconds), at: now) == nil,
              "A different desktop PID cannot consume the pending call")
        check(launch.take(.init(status: .active, call: good.call, startedAtMilliseconds: state.startedAtMilliseconds! - 1000), at: now) == nil,
              "An old session cannot inherit a fresh launch request")
        check(launch.take(state, at: now, composerReady: false) == nil && launch.pending != nil,
              "An unresolved temporary title keeps the one handoff pending without a native mutation")
        check(launch.take(state, at: now, composerReady: true) == good.call && launch.take(state, at: now) == nil, "The exact new call is handed off once after its title is ready")
        launch.arm(sent: now, pid: good.call.pid)
        check(launch.take(state, at: now.addingTimeInterval(31)) == nil && launch.pending == nil, "An expired opening cannot make a late selection")
        launch.arm(sent: now, pid: good.call.pid); launch.cancel()
        check(launch.take(state, at: now) == nil, "Quit/cancellation retires the pending selection")
        launch.arm(sent: now, pid: good.call.pid)
        _ = launch.take(state, at: now, composerReady: false)
        let replacement = VoicePeerCall(token: "\(UUID()):\(UUID()):\(good.call.pid)")!
        let next = VoicePeerReceipt(status: .active, call: replacement, startedAtMilliseconds: state.startedAtMilliseconds! + 1000)
        check(launch.take(next, at: now.addingTimeInterval(2)) == nil && launch.pending == nil,
              "A replacement call cannot inherit a launch whose first identified call was waiting for its title")
        check(launch.readiness == .callReplaced, "Replacement is retained as the actual readiness decision")
        launch.arm(sent: now, pid: good.call.pid)
        _ = launch.take(state, at: now, composerReady: false)
        check(launch.pending?.call == good.call && launch.readiness == .titlePending, "The first genuine identity is bound before its title is available")
        check(launch.take(.init(status: .unknown), at: now) == nil && launch.pending?.call == good.call && launch.readiness == .identityUnconfirmed,
              "A temporary unknown read cannot discard or replace the bound call")
        check(launch.take(state, at: now) == good.call && launch.readiness == .ready, "The same call can recover and proceed exactly once")
        launch.arm(sent: now, pid: good.call.pid)
        _ = launch.take(state, at: now, composerReady: false)
        check(launch.take(.init(status: .inactive), at: now) == nil && launch.pending == nil && launch.readiness == .callEnded,
              "A proven End while the title is pending retires the request without a later expiry or relay")
        check(launch.take(next, at: now.addingTimeInterval(2)) == nil, "A call after the proven End cannot revive the old request")
        print("Passed \(checks) exact-call Model Bar handoff checks")
    }
}
