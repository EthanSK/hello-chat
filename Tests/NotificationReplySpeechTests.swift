// Exercise the actual timing adapter and reply core together, with no capture/model or live queue. — GPT-6.1 Sol
import Foundation

@main struct NotificationReplySpeechTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1; if !condition() { fatalError(name) }
    }
    static func main() {
        var adapter = NotificationReplySpeech()
        _ = adapter.observe(text: nil, timings: nil, inputTime: 1, capturedAt: 99, finalWords: nil, ended: false)
        var core = NotificationReplyCore(at: 90)
        core.audioEnded(at: 100, completed: true, now: 100)
        let words: [(word: String, start: Double, end: Double)] = [("reply", 3, 3.1), ("yes", 3.2, 3.3)]
        guard let first = adapter.observe(text: "Reply yes", timings: words, inputTime: 3.5, capturedAt: 101.5, finalWords: nil, ended: false, revision: 2) else { fatalError("first frame") }
        core.observe(first, now: 101.5)
        check(core.phase == .waiting, "one volatile hypothesis isn't confirmed")
        guard let pending = adapter.observe(text: nil, timings: nil, inputTime: 3.8, capturedAt: 101.8, finalWords: nil, ended: false, revision: 2) else { fatalError("pending input") }
        core.observe(pending, now: 101.8)
        check(core.phase == .waiting && pending.confirmedStartWords == 0, "undecoded input is not another agreeing inference")
        guard let second = adapter.observe(text: nil, timings: nil, inputTime: 4, capturedAt: 102, finalWords: nil, ended: false, revision: 3) else { fatalError("second frame") }
        core.observe(second, now: 102)
        check(core.phase == .composing, "continuous neural Reply plus answer starts without an utterance pause")
        check(core.draftText == "yes", "the live preview derives reply words from the same core, excluding the start control")
        check(second.stableWords == 0, "prefix confirmation is not native finalization")
        core.tick(now: 104)
        check(core.phase == .composing, "continuous answer outlives the initial opportunity")
        check(first.words[0].start == second.words[0].start, "old words don't move on no-new-text frames")
        check(abs(second.words[0].start - 101) < 0.00001, "priming is included in the fixed input anchor")
        check(adapter.hostTime(forDecodedTime: 3.92) == 101.92, "decoded watermark remains distinct from full input")
        var revised = core
        guard let correction = adapter.observe(text: "Really yes", timings: [("really", 3, 3.1), ("yes", 3.2, 3.3)], inputTime: 4.5, capturedAt: 102.5, finalWords: nil, ended: false) else { fatalError("correction") }
        revised.observe(correction, now: 102.5)
        check(revised.reason == "reply-prefix-revised" && !revised.canDispatch, "a genuinely revised activation cancels unsent")

        let finishWords = words + [("end", 6, 6.1), ("reply", 6.2, 6.3)]
        // Keep the same recognition batch as the admitted capture.
        guard let partialEnd = adapter.observe(text: "Reply yes End reply", timings: finishWords, inputTime: 6.5, capturedAt: 104.5, finalWords: nil, ended: false) else { fatalError("partial End") }
        core.observe(partialEnd, now: 104.5)
        check(core.draftText == "yes", "the candidate End control is excluded from the draft")
        check(core.phase == .composing, "agreeing partial End is still not a send boundary")
        var trailing = core
        let laterFinal = NotificationReplyCore.Recognition(batch: partialEnd.batch,
            text: "Reply yes End reply background speech", words: partialEnd.words + [
                .init(text: "background", start: 104.5, end: 104.6), .init(text: "speech", start: 104.7, end: 104.8)], stableWords: 6)
        trailing.observe(laterFinal, now: 105)
        check(trailing.canDispatch && trailing.body == "yes", "a real final confirms the requested prefix before later background words")
        var changedEnd = core
        let changedWords = partialEnd.words.enumerated().map { index, word in
            NotificationReplyCore.Word(text: index == 2 ? "another" : word.text, start: word.start, end: word.end)
        }
        changedEnd.observe(.init(batch: partialEnd.batch, text: "Reply yes another reply", words: changedWords, stableWords: 4), now: 105)
        check(!changedEnd.canDispatch, "a changed-away native End prefix cannot send")
        core.tick(now: 106.4)
        check(core.phase == .composing, "native Nemotron's two-second quiet period doesn't expire an End candidate")
        guard let finalEnd = adapter.observe(text: nil, timings: nil, inputTime: 9, capturedAt: 107, finalWords: nil, ended: true) else { fatalError("final End") }
        core.observe(finalEnd, now: 107)
        check(core.canDispatch && core.body == "yes", "native final End finishes the continuous answer")

        var drifting = NotificationReplySpeech()
        let initial = drifting.observe(text: "reply", timings: [("reply", 9.9, 10)], inputTime: 10, capturedAt: 100, finalWords: nil, ended: false, revision: 10)
        for step in 1...10 {
            let delta = Double(step) / 20
            let next = drifting.observe(text: nil, timings: nil, inputTime: 10 + delta, capturedAt: 100 + delta, finalWords: nil, ended: false, revision: 10)
            check(next?.words.first?.start == initial?.words.first?.start, "input frames between decoder chunks retain one word time")
            check(next?.confirmedStartWords == 0, "frames without another decoder result cannot confirm Reply")
        }
        let oldBatch = drifting.batch
        drifting.boundary()
        let rollover = drifting.observe(text: "reply", timings: [("reply", 1.4, 1.5)], inputTime: 1.5, capturedAt: 200.1, finalWords: nil, ended: false)
        check(rollover?.batch != oldBatch && abs((rollover?.words.first?.start ?? 0) - 200) < 0.00001, "rollover establishes a new prime/lead-in anchor")
        var late = NotificationReplyCore(at: 90)
        late.audioEnded(at: 100, completed: true, now: 100)
        late.tick(now: 105)
        check(late.phase == .waiting, "wall time cannot close an unprocessed opportunity")
        late.processed(through: 103, now: 106); late.tick(now: 107)
        check(late.phase == .waiting, "bounded late-result confirmation follows decoded progress")
        late.tick(now: 107.6)
        check(late.reason == "no-command", "processed empty opportunity eventually cancels")
        print("Notification reply adapter: \(checks) checks passed")
    }
}
