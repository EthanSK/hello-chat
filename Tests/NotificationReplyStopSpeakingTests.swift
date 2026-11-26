// Exercise Shut up with timed recognition only; no microphone, audio, app control or delivery. — GPT-6.1 Sol
import Foundation

@main struct NotificationReplyStopSpeakingTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    static func recognition(_ text: String, _ times: [Double], stable: Int? = nil, batch: UUID = UUID(), confirmed: Int = 0) -> NotificationReplyCore.Recognition {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        precondition(words.count == times.count)
        return .init(batch: batch, text: text, words: zip(words, times).map { .init(text: $0.0, start: $0.1, end: $0.1 + 0.1) }, stableWords: stable ?? words.count, confirmedStartWords: confirmed)
    }
    static func announcing(_ enabled: Bool = true, commands: NotificationReplyCore.Commands = .init(), spokenText: String = "A normal notification.") -> NotificationReplyCore {
        var core = NotificationReplyCore(at: 0, commands: commands, manualFinish: true, stopSpeaking: enabled, spokenText: spokenText)
        core.audioStarted(at: 10)
        return core
    }
    static func assertNoStop(_ core: NotificationReplyCore, _ name: String) {
        check(core.reason != "user-stop-speaking" && !core.canDispatch, name)
    }
    static func main() {
        let command = recognition("Shut up", [11, 11.2])
        var core = announcing(); core.observe(command, now: 11.4)
        check(core.phase == .cancelled && core.reason == "user-stop-speaking", "Stable command stops the negotiated current announcement")
        check(core.releaseRequested && !core.canDispatch && core.body == nil && core.acceptedCount == 0, "Stopping releases unsent without manufacturing a Reply")
        check(core.finalizeThrough == nil && core.draftText.isEmpty, "Terminal stop retires recognition")
        core.audioEnded(at: 12, completed: false, now: 12); core.queued(); core.delivered()
        core.observe(recognition("Reply yes End reply", [13, 13.2, 14, 14.2]), now: 14.5)
        check(core.reason == "user-stop-speaking" && core.phase == .cancelled, "Late callbacks cannot reopen or submit the stopped attempt")

        core = announcing(false); core.observe(command, now: 11.4)
        check(core.phase == .announcing && core.finalizeThrough == nil, "Legacy false cannot promise a speech stop")
        core.audioEnded(at: 12, completed: true, now: 12)
        check(core.phase == .waiting, "Legacy speech keeps its ordinary Reply window")
        core = NotificationReplyCore(at: 0, stopSpeaking: true)
        core.observe(command, now: 11.4)
        check(core.phase == .preparing && core.finalizeThrough == nil, "No audio admission means no stop")
        core = NotificationReplyCore(at: 0, stopSpeaking: true)
        core.audioStarted(at: 10); core.observe(command, now: 11.4)
        check(core.reason == "user-stop-speaking", "The pure opt-in is explicit rather than inferred from manual composition")
        core = NotificationReplyCore(at: 19, stopSpeaking: true)
        core.audioStarted(at: 20); core.observe(command, now: 21)
        assertNoStop(core, "Old timed words cannot stop the next announcement")

        core = announcing(); core.audioEnded(at: 10.5, completed: true, now: 10.5)
        core.observe(command, now: 11.4)
        check(core.phase == .waiting && core.finalizeThrough == nil, "After actual audio exit Shut up cannot close the Reply window")
        core.observe(recognition("Reply shut up is what I said", [12, 12.2, 12.4, 12.6, 12.8, 13, 13.2]), now: 13.5)
        check(core.phase == .composing && core.draftText == "shut up is what I said", "Shut up remains body text once Reply starts")
        core.observe(recognition("End reply", [14, 14.2]), now: 14.5)
        check(core.canDispatch && core.body == "shut up is what I said", "Existing native End preserves spoken body words")

        for times in [[9, 9.2], [9.9, 10.1], [11, 12], [12, 11], [15, 15.2]] {
            core = announcing(); core.observe(recognition("Shut up", times), now: 12.5)
            assertNoStop(core, "Pre-audio, discontinuous, reversed or future words cannot stop: \(times)")
        }
        core = announcing(); core.observe(recognition("Shut up", [10, 10.2]), now: 10.4)
        check(core.reason == "user-stop-speaking", "Actual audio-start boundary is admitted")

        let batch = UUID()
        core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch, confirmed: 2), now: 11.4)
        check(core.phase == .announcing && core.finalizeThrough == 11.45, "A partial requests the existing native final immediately; START-only confirmation is insufficient")
        core.observe(recognition("Shut up", [11, 11.2], batch: batch), now: 11.5)
        check(core.reason == "user-stop-speaking", "Unchanged native stable control confirms the stop")
        core = announcing()
        core.observe(recognition("Shut", [11]), now: 11.2)
        check(core.phase == .announcing && core.finalizeThrough == nil, "An incomplete control word does not request a stop")
        core.observe(recognition("up", [11.2]), now: 11.4)
        check(core.reason == "user-stop-speaking", "A complete timed command may span recognition batches")

        core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.observe(recognition("Shut down", [11, 11.2], stable: 0, batch: batch), now: 11.5)
        check(core.phase == .announcing && core.finalizeThrough == nil, "A changed-away control does not mute speech")
        core.observe(recognition("Shut up", [11, 11.2], batch: batch), now: 11.6)
        assertNoStop(core, "A late stable version cannot revive the rejected timed occurrence")
        core.observe(recognition("Shut up", [12, 12.2]), now: 12.4)
        check(core.reason == "user-stop-speaking", "A fresh later command still works")

        for changed in [recognition("Do not shut up", [10.5, 10.7, 11, 11.2], batch: batch), recognition("Shut up", [11.2, 11.4], batch: batch)] {
            core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch), now: 11.4)
            core.observe(changed, now: 11.7)
            assertNoStop(core, "A changed native prefix or changed timed control is not confirmation")
        }
        core = announcing(); core.observe(recognition("Old words. Shut up", [2, 3, 11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.observe(recognition("Revised earlier announcement words. Shut up", [1, 2, 3, 4, 11, 11.2], batch: batch), now: 11.6)
        check(core.reason == "user-stop-speaking", "Retokenized words wholly before actual audio do not invalidate the unchanged command")

        for text in ["do not shut up", "don't shut up", "never shut up", "say shut up", "say. Shut up", "said shut up", "the command shut up", "the phrase shut up", "\"Shut up\"", "‘Shut up’"] {
            let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            core = announcing(); core.observe(recognition(text, words.indices.map { 11 + Double($0) * 0.2 }), now: 14)
            assertNoStop(core, "Negation, mention or quoted command stays silent: \(text)")
            check(core.finalizeThrough == nil, "Rejected mention does not request native finalization")
        }
        core = announcing(); core.observe(recognition("Say.", [11]), now: 11.2)
        core.observe(recognition("Shut up", [11.3, 11.5]), now: 11.7)
        assertNoStop(core, "A nearby mention in the preceding batch still blocks a new-batch command")
        core = announcing(); core.observe(recognition("Do not shut up", [11, 11.2, 13, 13.2]), now: 13.5)
        assertNoStop(core, "An ordinary pause does not turn a negated in-announcement phrase into a command")
        core = announcing(); core.observe(recognition("Do not", [11, 11.2]), now: 11.4)
        core.observe(recognition("Shut up", [13, 13.2]), now: 13.5)
        assertNoStop(core, "Negation also survives a pause between recognition batches")
        for text in ["never ever shut up", "do not ever shut up", "don't ever shut up", "he said please shut up"] {
            let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            core = announcing(); core.observe(recognition(text, words.indices.map { 11 + Double($0) * 0.2 }), now: 14)
            assertNoStop(core, "A nearby modifier cannot hide negation or a mention: \(text)")
        }
        core = announcing(); core.observe(recognition("Please shut up", [11, 11.2, 11.4]), now: 11.7)
        check(core.reason == "user-stop-speaking", "A polite prefix without negation or mention still permits the command")
        core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.observe(recognition("Shut up is the phrase", [11, 11.2, 11.35, 11.55, 11.75], batch: batch), now: 12)
        assertNoStop(core, "Native confirmation growing into a same-clause mention is not a stop")
        core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.observe(recognition("Shut up. Later room words", [11, 11.2, 11.6, 11.8, 12], batch: batch), now: 12.3)
        check(core.reason == "user-stop-speaking", "A confirmed canonical control survives later separate-sentence room speech")

        let aliases = NotificationReplyCore.Commands(stopSpeakingSpellings: ["Stop reading", "Enough for now"])
        for (text, times) in [("Stop reading", [11.0, 11.2]), ("Enough for now", [11, 11.2, 11.4]), ("Shut up", [11, 11.2])] {
            core = announcing(commands: aliases); core.observe(recognition(text, times), now: 12)
            check(core.reason == "user-stop-speaking", "Exact frozen configured form is honored: \(text)")
        }
        for forms in [NotificationReplyCore.Commands(stopSpeakingSpellings: []), NotificationReplyCore.Commands(stopSpeakingSpellings: ["Stop reading"], alternateSpellings: false)] {
            core = announcing(commands: forms); core.observe(recognition("Stop reading", [11, 11.2]), now: 11.5)
            assertNoStop(core, "Empty or globally disabled aliases are not reinserted")
        }
        core = announcing(commands: aliases)
        core.observe(recognition("Stop reading", [11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.observe(recognition("Stop reading tomorrow", [11, 11.2, 11.4], batch: batch), now: 11.7)
        assertNoStop(core, "An alias continued into ordinary text cannot stop")

        for ownText in ["Shut up", "The SHUT-UP command is available", "You can say shut up to stop"] {
            core = announcing(spokenText: ownText); core.observe(command, now: 11.4)
            assertNoStop(core, "Known notification wording is conservatively ambiguous: \(ownText)")
            check(core.finalizeThrough == nil, "Echo-like text never triggers finalization")
        }
        core = announcing(commands: aliases, spokenText: "The Shut up command is available")
        core.observe(recognition("Stop reading", [11, 11.2]), now: 11.5)
        check(core.reason == "user-stop-speaking", "A configured form absent from the announcement remains usable")
        core = announcing(commands: aliases, spokenText: "Stop reading is an alternate spelling")
        core.observe(recognition("Stop reading", [11, 11.2]), now: 11.5)
        assertNoStop(core, "Own-text ambiguity also applies to configured forms")

        core = announcing(); core.observe(recognition("Shut up", [11, 11.2], stable: 0, batch: batch), now: 11.4)
        core.audioEnded(at: 11.45, completed: true, now: 11.45)
        check(core.phase == .waiting && core.finalizeThrough == nil, "Actual exit clears pending stop before opening the ordinary opportunity")
        core.observe(recognition("Shut up", [11, 11.2], batch: batch), now: 11.6)
        check(core.phase == .waiting, "Late native confirmation after exit cannot stop a completed announcement")
        core.cancel("recognition-audio-gap"); core.observe(command, now: 12)
        check(core.reason == "recognition-audio-gap", "A real capture-loss cancellation is retained")
        print("Notification speech stop: \(checks) pure checks passed; no microphone, audio, app or delivery.")
    }
}
