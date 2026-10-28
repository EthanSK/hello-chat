import Foundation

actor LoadProbe {
    var active = 0
    var maximum = 0
    var completed = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1; completed += 1 }
}

@main enum SpeechPreparationTests {
    static func main() async throws {
        let gate = SpeechPreparationGate(), probe = LoadProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.withPermit {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(2))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximum, completed = await probe.completed
        precondition(maximum == 1 && completed == 20, "Concurrent preparations must never overlap or disappear")
        let holding = Task {
            try await gate.withPermit {
                await probe.enter()
                try await Task.sleep(for: .milliseconds(80))
                await probe.leave()
            }
        }
        while await probe.active == 0 { await Task.yield() }
        let cancelled = Task<Void, Error> {
            try await gate.withPermit { fatalError("A cancelled preparation must not load models") }
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        try await holding.value
        do { try await cancelled.value; fatalError("Cancellation must be reported") } catch is CancellationError { }
        try await gate.withPermit { }

        var rollover = SpeechRollover()
        rollover.consumed(seconds: 44.5, quiet: true)
        precondition(!rollover.shouldReset)
        rollover.consumed(seconds: 0.6, quiet: false)
        precondition(!rollover.shouldReset, "Keep speech crossing the old45second boundary")
        rollover.consumed(seconds: 0.4, quiet: true)
        precondition(!rollover.shouldReset, "Wait for pending encoder audio to be quiet")
        rollover.consumed(seconds: 0.41, quiet: true)
        precondition(rollover.shouldReset)
        rollover = SpeechRollover()
        rollover.consumed(seconds: 120, quiet: false)
        precondition(rollover.shouldReset, "Noisy input must still have bounded recognition state")
        var onset = SpeechOnset()
        precondition(!onset.consumed(seconds: 1, quiet: true))
        precondition(!onset.consumed(seconds: 1, quiet: true))
        precondition(onset.consumed(seconds: 0.1, quiet: false), "Restart once at speech onset after a quiet gap")
        precondition(!onset.consumed(seconds: 0.1, quiet: false), "Continuous speech must not repeatedly restart")
        precondition(!onset.consumed(seconds: 0.2, quiet: true))
        precondition(!onset.consumed(seconds: 0.1, quiet: false), "Short word gaps keep context")
        print("Passed speech lifetime checks: serialized20loads, cancellation, speech across45seconds, quiet rollover and120second hard limit.")
    }
}
