// Repetition scheduling uses simulated completions, never desktop input or live Voice. — GPT-6.1 Sol
import Foundation

@main enum CommandRepetitionTests {
    @MainActor static func main() {
        for (text, expected) in [("five", 5), ("5", 5), ("five times", 5), ("twenty five times", 25),
                                 ("one hundred", 100), ("100 times", 100)] {
            guard case .value(let count, _) = CommandRepetition.count(in: text.components(separatedBy: " "), after: 0) else { fatalError(text) }
            precondition(count == expected)
        }
        for text in ["zero", "0", "minus five", "101", "five percent", "two point five", "five tomorrow"] {
            precondition(CommandRepetition.count(in: text.components(separatedBy: " "), after: 0) == .invalid, text)
        }
        for text in ["please", "for", "to", "on the screen"] {
            precondition(CommandRepetition.count(in: text.components(separatedBy: " "), after: 0) == .absent)
        }
        let defaults = UserDefaults(suiteName: "RepetitionTests.\(UUID())")!
        precondition(CommandRepetition.enabled("future-command", defaults: defaults))
        CommandRepetition.setEnabled(false, command: "future-command", defaults: defaults)
        precondition(!CommandRepetition.enabled("future-command", defaults: defaults))

        for action in ["zoom", "app", "speakers", "video", "music", "wake", "end", "mute", "showVoice", "future-action"] {
            let engine = RepeatedCommands(); var calls = 0
            engine.update([action, "5", "times"], timings: nil)
            precondition(engine.begin(id: UUID(), range: 0..<1, repeats: true) { id in
                calls += 1; engine.finish(id, .submitted)
            } != nil)
            precondition(calls == 5)
            engine.update([action, "five", "times"], timings: nil); engine.poll()
            precondition(calls == 5, "Revision must not repeat a completed total")
        }
        let partial = RepeatedCommands(); var calls = 0
        partial.update(["zoom", "in"], timings: nil)
        let id = UUID()
        partial.begin(id: id, range: 0..<2, repeats: true) { id in calls += 1; partial.finish(id, .confirmed) }
        precondition(calls == 1)
        partial.update(["zoom", "in", "five"], timings: nil)
        precondition(calls == 1, "Update cannot dispatch before End priority checks")
        partial.poll(); precondition(calls == 5)
        partial.update(["zoom", "in", "5", "times"], timings: nil); partial.poll(); precondition(calls == 5)
        partial.update(["zoom", "in", "two"], timings: nil); partial.poll(); precondition(calls == 5)

        let disabled = RepeatedCommands(); calls = 0
        disabled.update(["pause", "music", "five"], timings: nil)
        disabled.begin(id: UUID(), range: 0..<2, repeats: false) { id in calls += 1; disabled.finish(id, .submitted) }
        disabled.update(["pause", "music", "ten"], timings: nil); disabled.poll(); precondition(calls == 1)

        let pending = RepeatedCommands(); calls = 0; let pendingID = UUID()
        pending.update(["switch", "speaker", "kitchen", "3"], timings: nil)
        var steps: [UUID] = []
        pending.begin(id: pendingID, range: 0..<3, repeats: true) { step in calls += 1; steps.append(step) }
        precondition(calls == 1)
        pending.finish(steps[0], .confirmed); precondition(calls == 2)
        pending.finish(steps[0], .unknown); precondition(calls == 2, "Duplicate teardown cannot complete the next step")
        pending.cancelPending(); pending.finish(pendingID, .confirmed); precondition(calls == 2)

        let failed = RepeatedCommands(); calls = 0
        failed.update(["rewind", "5", "seconds", "three", "times"], timings: nil)
        failed.begin(id: UUID(), range: 0..<3, repeats: true) { id in calls += 1; failed.finish(id, .unknown) }
        precondition(calls == 1, "An uncertain relative action cannot be replayed")
        let invalidInFlight = RepeatedCommands(); var phases: [RepeatedCommands.Outcome] = []; var active: UUID?
        invalidInFlight.onProgress = { if let outcome = $0.outcome { phases.append(outcome) } }
        invalidInFlight.update(["zoom", "in"], timings: nil)
        invalidInFlight.begin(id: UUID(), range: 0..<2, repeats: true) { active = $0 }
        invalidInFlight.update(["zoom", "in", "zero"], timings: nil)
        precondition(phases.isEmpty, "Invalid suffix cannot release an in-flight action for fallback")
        invalidInFlight.finish(active!, .submitted)
        precondition(!phases.contains(.failedBeforeDispatch))

        let ordered = RepeatedCommands(); var pendingSteps: [(UUID, String)] = []; var orderedCalls: [String] = []
        ordered.update(["rewind", "three", "times"], timings: nil)
        ordered.begin(id: UUID(), range: 0..<1, repeats: true) { step in orderedCalls.append("rewind"); pendingSteps.append((step, "rewind")) }
        ordered.update(["pause", "two", "times"], timings: nil)
        ordered.begin(id: UUID(), range: 0..<1, repeats: true) { step in orderedCalls.append("pause"); pendingSteps.append((step, "pause")) }
        precondition(orderedCalls == ["rewind"], "A later command waits for the preceding requested actions")
        while !pendingSteps.isEmpty { let step = pendingSteps.removeFirst(); ordered.finish(step.0, .confirmed) }
        precondition(orderedCalls == ["rewind", "rewind", "rewind", "pause", "pause"], "Every requested repetition runs in spoken order")

        let rewind = RepeatedCommands(); calls = 0
        rewind.update(["rewind", "video", "five"], timings: nil)
        rewind.begin(id: UUID(), range: 0..<2, repeats: true, requiresTimes: true) { step in calls += 1; rewind.finish(step, .confirmed) }
        precondition(calls == 1, "A rewind distance cannot become a repeat count")
        rewind.update(["rewind", "video", "five", "times"], timings: nil); rewind.poll()
        precondition(calls == 5)

        let distant = RepeatedCommands(); calls = 0
        distant.update(["zoom", "in", "five"], timings: [("zoom",1,1.2),("in",1.2,1.4),("five",3,3.3)])
        distant.begin(id: UUID(), range: 0..<2, repeats: true) { step in calls += 1; distant.finish(step, .submitted) }
        precondition(calls == 1, "A later separate number is not this command's count")

        let app = RepeatedCommands(); calls = 0
        app.update(["open", "chrome", "five", "times"], timings: nil)
        let appStep = app.begin(id: UUID(), range: 0..<4, repeats: true) { _ in calls += 1 }!
        precondition(app.setArgumentRange(0..<2, for: appStep))
        app.finish(appStep, .confirmed)
        // Complete the asynchronous native runs by the tokens supplied by a real caller.
        precondition(calls == 2, "Resolving an app name can expose its trailing count before first dispatch completes")

        let idle = RepeatedCommands()
        for _ in 0..<256 {
            idle.update(["zoom", "in"], timings: nil)
            idle.begin(id: UUID(), range: 0..<2, repeats: true) { step in idle.finish(step, .submitted) }
        }
        let started = Date()
        for _ in 0..<100000 { idle.poll() }
        print("100000 idle repeat polls after 256 completed commands: \(Date().timeIntervalSince(started)) seconds")
        print("Repeat-count parsing, every-action scheduling, default-on settings, partial revisions, End priority, async ownership and uncertain-action stops passed; no live effects.")
    }
}
