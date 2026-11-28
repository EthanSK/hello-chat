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
        let invalid = RepeatedCommands(); var invalidCalls = 0
        invalid.update(["zoom", "zero"], timings: nil)
        precondition(invalid.begin(id: UUID(), range: 0..<1, repeats: true) { _ in invalidCalls += 1 } == nil)
        precondition(invalidCalls == 0, "An invalid initial count must fail before dispatch")

        let pending = RepeatedCommands(); calls = 0; let pendingID = UUID()
        pending.update(["switch", "speaker", "kitchen", "3"], timings: nil)
        var steps: [UUID] = []
        pending.begin(id: pendingID, range: 0..<3, repeats: true) { step in calls += 1; steps.append(step) }
        precondition(calls == 1)
        pending.finish(steps[0], .confirmed); precondition(calls == 2)
        pending.finish(steps[0], .unknown); precondition(calls == 2, "Duplicate teardown cannot complete the next step")
        pending.cancelPending(); pending.finish(pendingID, .confirmed); precondition(calls == 2)

        let scoped = RepeatedCommands(); var scopedCalls: [String] = []; var inFlight: UUID?
        var scopedOutcomes: [RepeatedCommands.Outcome] = []
        scoped.onProgress = { if let outcome = $0.outcome { scopedOutcomes.append(outcome) } }
        scoped.update(["zoom", "in", "three"], timings: nil)
        scoped.begin(id: UUID(), range: 0..<2, repeats: true, command: "zoomInPhrase") { step in
            scopedCalls.append("zoom"); inFlight = step
        }
        scoped.update(["pause", "music", "two"], timings: nil)
        scoped.begin(id: UUID(), range: 0..<2, repeats: true, command: "pauseMusicPhrase") { step in
            scopedCalls.append("pause"); scoped.finish(step, .submitted)
        }
        scoped.cancelPending(command: "zoomInPhrase")
        precondition(scopedCalls == ["zoom"], "Disabling a command cannot pretend its in-flight action was undone")
        scoped.finish(inFlight!, .submitted)
        precondition(scopedCalls == ["zoom", "pause", "pause"], "Only that command's remaining steps stop; another command keeps its order")
        precondition(!scopedOutcomes.contains(.failedBeforeDispatch), "An action already sent never becomes fallback permission")
        scoped.update(["zoom", "in", "ten"], timings: nil); scoped.poll()
        precondition(scopedCalls == ["zoom", "pause", "pause"], "A revised transcript cannot revive cancelled repeats")

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

        let independent = RepeatedCommands(); var independentCalls: [UUID] = []
        independent.update(["speaker"], timings: nil)
        independent.begin(id: UUID(), range: 0..<1, repeats: true) { independentCalls.append($0) }
        independent.begin(id: UUID(), range: 0..<1, repeats: true) { independentCalls.append($0) }
        precondition(independentCalls.count == 2, "Single actions reach their own queues without waiting for Bluetooth")
        independentCalls.forEach { independent.finish($0, .confirmed) }

        for expected in [RepeatedCommands.Outcome.confirmed, .submitted, .unknown] {
            let cancelled = RepeatedCommands(); var result: RepeatedCommands.Progress?
            cancelled.onProgress = { result = $0 }
            cancelled.update(["speaker"], timings: nil)
            let active = cancelled.begin(id: UUID(), range: 0..<1, repeats: true) { _ in }!
            cancelled.cancelPending(); cancelled.finish(active, expected)
            precondition(result?.outcome == expected, "A cancelled queue preserves an in-flight result")
        }
        let discarded = RepeatedCommands(); var discardCalls = 0; var discardedProgress: RepeatedCommands.Progress?
        discarded.onProgress = { discardedProgress = $0 }
        discarded.update(["mute", "three"], timings: nil)
        precondition(discarded.begin(id: UUID(), range: 0..<1, repeats: true, discard: true) { _ in discardCalls += 1 } == nil)
        discarded.poll()
        precondition(discardCalls == 0 && discardedProgress?.requested == 3 && discardedProgress?.outcome == .superseded,
                     "Busy Voice requests stay discarded, rather than running later")
        for text in [["fixture", "zero"], ["fixture", "101"]] {
            let invalid = RepeatedCommands(); invalid.update(text, timings: nil)
            precondition(invalid.begin(id: UUID(), range: 0..<1, repeats: true) { _ in preconditionFailure("Invalid count dispatched") } == nil)
        }

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
        let delayed = RepeatedCommands(); var now = 100.0
        delayed.clock = { now }; delayed.update(["next", "track"], timings: nil)
        let delayedStep = delayed.begin(id: UUID(), range: 0..<2, repeats: false, firstDispatchBefore: 102) { _ in }!
        precondition(delayed.shouldRun(delayedStep))
        now = 126
        precondition(!delayed.shouldRun(delayedStep), "A delayed first effect cannot use a fresh-looking receipt")
        delayed.finish(delayedStep, .superseded)
        let launched = RepeatedCommands(); launched.clock = { now }; launched.update(["fixture"], timings: nil)
        let launching = launched.begin(id: UUID(), range: 0..<1, repeats: false, firstDispatchBefore: 127) { _ in }!
        launched.didDispatch(launching); now = 150
        precondition(launched.shouldRun(launching), "A real accepted app launch retains its bounded subsequent readiness workflow")
        let nativePermit = launched.dispatchPermission(for: launching)!
        launched.cancelPending()
        precondition(!nativePermit.permits(), "The same thread-safe permit refuses native follow-up after cancellation")
        now = 126
        let repeated = RepeatedCommands(); repeated.clock = { now }
        repeated.update(["next", "track", "two"], timings: nil)
        var repeatSteps: [UUID] = []
        let first = repeated.begin(id: UUID(), range: 0..<2, repeats: true, firstDispatchBefore: 127) { repeatSteps.append($0) }!
        precondition(repeated.shouldRun(first)); repeated.finish(first, .submitted)
        now = 150
        precondition(repeatSteps.count == 2 && repeated.shouldRun(repeatSteps[1]), "An already-started explicit repeat sequence retains its ordinary lifetime")
        repeated.finish(repeatSteps[1], .submitted)
        for _ in 0..<100000 { idle.poll() }
        print("100000 idle repeat polls after 256 completed commands: \(Date().timeIntervalSince(started)) seconds")
        print("Repeat-count parsing, every-action scheduling, default-on settings, partial revisions, End priority, async ownership and uncertain-action stops passed; no live effects.")
    }
}
