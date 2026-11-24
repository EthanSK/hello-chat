// Injected Dot controls: no Accessibility action, navigation, microphone or real call.
import Foundation

@main enum DotCallCommandTests {
    @MainActor static func main() async {
        typealias S = DotCallCommand.Snapshot
        var checks = 0
        func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks += 1 }
        func probe(_ action: DotCallCommand.Action, before: S, opened: S? = nil, after: S? = nil, press: DotCallCommand.Press = .sent) async -> (DotCallCommand.Result, Int, Int, Int) {
            var state = before, opens = 0, presses = 0, confirms = 0
            let result = await DotCallCommand.perform(action, using: .init(
                read: { state },
                open: { opens += 1; if let opened { state = opened }; return opened != nil },
                press: { _ in presses += 1; return press },
                confirm: { _ in confirms += 1; return after ?? state }))
            return (result, opens, presses, confirms)
        }
        let inactive = S(state: .inactive, pid: 42, mayStart: true)
        let active = S(state: .active, pid: 42)
        let starting = S(state: .starting, pid: 42)
        let unknown = S(state: .unknown, pid: 42, mayStart: true)
        var p = await probe(.start, before: active)
        check(p.0.confirmed && p.2 == 0 && p.1 == 0, "Already active Start never toggles")
        p = await probe(.start, before: starting)
        check(p.0.submitted && p.2 == 0, "Already starting never starts twice or claims connected")
        p = await probe(.hangUp, before: inactive)
        check(p.0.confirmed && p.2 == 0 && p.1 == 0, "Inactive Hang up neither opens nor starts")
        p = await probe(.start, before: S(state: .inactive, pid: 42, mayStart: false))
        check(p.0.beforeDispatch && p.2 == 0 && p.1 == 0, "Unavailable or active Voice blocks Dot Start")
        p = await probe(.start, before: S(state: .inactive, pid: 42, block: .voice))
        check(p.0.status == "voice" && p.0.beforeDispatch && p.2 == 0, "Voice refusal is distinguished from a disabled Dot control")
        p = await probe(.start, before: S(state: .unavailable, pid: 42, block: .accessibility))
        check(p.0.status == "accessibility" && p.1 == 0 && p.2 == 0, "Missing permission does not ask to reopen Dot")
        for action in DotCallCommand.Action.allCases {
            p = await probe(action, before: S(state: .ambiguous, pid: 42, mayStart: true))
            check(p.0.beforeDispatch && p.2 == 0 && p.1 == 0, "Ambiguous controls remain untouched")
        }
        p = await probe(.start, before: S(state: .inactive, pid: nil, mayStart: true), opened: inactive, after: active)
        check(p.0.confirmed && p.1 == 1 && p.2 == 1 && p.3 == 1, "Closed app opens, waits, starts once and verifies")
        p = await probe(.start, before: unknown, opened: inactive, after: active)
        check(p.0.confirmed && p.1 == 1 && p.2 == 1, "Missing Dot controls open only the supported Dot destination")
        p = await probe(.start, before: unknown, opened: S(state: .inactive, pid: 43, mayStart: true), after: active)
        check(p.0.status == "changed" && p.2 == 0, "Process replacement stops before dispatch")
        p = await probe(.hangUp, before: unknown, opened: active, after: inactive)
        check(p.0.beforeDispatch && p.0.status == "notFound" && p.1 == 0 && p.2 == 0, "Hang up never navigates to find a call")
        p = await probe(.hangUp, before: active, after: inactive)
        check(p.0.confirmed && p.1 == 0 && p.2 == 1, "Hang up identifies and stops only an active Dot call")
        p = await probe(.hangUp, before: S(state: .unavailable, pid: nil, block: .accessibility), opened: active)
        check(p.1 == 0 && p.2 == 0, "Unavailable Hang up never launches the app")
        p = await probe(.start, before: inactive, after: starting)
        check(p.0.submitted && !p.0.confirmed && p.2 == 1, "Starting is submitted, not connected")
        p = await probe(.start, before: inactive, after: unknown)
        check(!p.0.beforeDispatch && !p.0.confirmed && p.2 == 1, "Unconfirmed dispatch never becomes a second permitted attempt")
        p = await probe(.start, before: inactive, press: .notSent)
        check(p.0.beforeDispatch && p.3 == 0, "Proven pre-send rejection can permit fallback")
        p = await probe(.start, before: inactive, press: .uncertain)
        check(!p.0.beforeDispatch && p.0.status == "unconfirmed" && p.3 == 0 && p.2 == 1, "AX uncertainty never grants a replay")
        p = await probe(.hangUp, before: active, after: S(state: .inactive, pid: 43))
        check(!p.0.confirmed && !p.0.beforeDispatch, "Completion belongs to the same native process")
        let cancelled = Task { @MainActor in await probe(.start, before: inactive, after: active) }
        cancelled.cancel()
        p = await cancelled.value
        check(p.2 == 0, "Cancelled before dispatch never starts a call")
        var detector = CommandPhraseDetectors<DotCallCommand.Action>()
        let patterns: [DotCallCommand.Action: [PhrasePattern]] = [.start: [PhrasePattern(text: "Call Dot", similar: false)], .hangUp: [PhrasePattern(text: "Hang up", similar: false)]]
        for (text, action) in [("Call Dot", DotCallCommand.Action.start), ("Hang up", .hangUp)] {
            detector.reset(); detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            check(detector.poll(at: 1, aliases: patterns, directOnly: true).map(\.command) == [action], "Default Dot phrase reaches only its action")
            check(detector.poll(at: 2, aliases: patterns, directOnly: true).isEmpty, "Duplicate transcript cannot replay")
        }
        for text in ["I said Call Dot", "Do not Call Dot", "Can you add Call Dot", "If I say Hang up", "Don't Hang up", "We should Call Dot tomorrow"] {
            detector.reset(); detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            check(detector.poll(at: 1, aliases: patterns, directOnly: true).isEmpty, "Mentions, negation and plans stay inert: " + text)
        }
        check(CodexCallControlScope.classify([("AXButton", "Mute microphone"), ("AXGroup", "Call controls"), ("AXWindow", "Your dot")]) == .dot, "Dot-only microphone fixture is excluded from Voice")
        check(CodexCallControlScope.classify([("AXButton", "Mute microphone"), ("AXGroup", "Voice chat"), ("AXWindow", "Codex")]) == .voice, "Genuine Voice fixture keeps its microphone")
        check(CodexCallControlScope.classify([("AXButton", "Mute microphone")]) == .unknown, "Incomplete ancestry cannot prove Voice ownership")
        let suite = UserDefaults(suiteName: "DotChecks-" + UUID().uuidString)!
        for slot in PhraseSlot.dotSlots {
            check(CommandRepetition.enabled(slot.rawValue, defaults: suite), "Every Dot command inherits default-on repetitions")
            suite.set(false, forKey: CommandRepetition.preferencePrefix + slot.rawValue)
            check(!CommandRepetition.enabled(slot.rawValue, defaults: suite), "Per-Dot repeat preference disables counts")
        }
        check(PhraseSlot.dotSlots.count == 2 && !PhraseSlot.voiceSlots.contains(.callDotPhrase) && !PhraseSlot.voiceSlots.contains(.hangUpDotPhrase), "Dot settings never become Codex Voice audio controls")
        print("Dot command ownership, directional controls, uncertainty, cancellation, phrases and repetition: \(checks) injected checks passed; no real calls.")
    }
}
