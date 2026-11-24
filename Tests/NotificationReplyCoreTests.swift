// Exercise notification replies with timed recognition only; never open a microphone or deliver a chat. — GPT-6.1 Sol
import Foundation

@main struct NotificationReplyCoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !condition() { fatalError(name) }
    }
    static func recognition(_ text: String, times: [Double], stable: Int? = nil, batch: UUID = UUID()) -> NotificationReplyCore.Recognition {
        let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        precondition(tokens.count == times.count)
        return .init(batch: batch, text: text, words: zip(tokens, times).map {
            .init(text: $0.0, start: $0.1, end: $0.1 + 0.1)
        }, stableWords: stable ?? tokens.count)
    }
    static func waiting() -> NotificationReplyCore {
        var core = NotificationReplyCore(at: 0)
        core.audioStarted(); core.audioEnded(at: 10, completed: true, now: 10)
        return core
    }
    static func main() {
        var core = waiting()
        let batch = UUID()
        core.observe(recognition("Reply yes", times: [11, 11.2], batch: batch), now: 13.4)
        check(core.phase == .composing, "late recognition uses spoken time")
        check(core.acceptedCount == 1, "one accepted cue boundary")
        core.tick(now: 20)
        check(core.phase == .composing && core.body == nil, "a pause never submits")
        core.observe(recognition("Reply yes, do that. End reply.", times: [11, 11.2, 20, 20.2, 21, 21.2], stable: 4, batch: batch), now: 21.4)
        check(core.phase == .composing && core.finalizeThrough != nil, "partial End cannot submit")
        core.observe(recognition("Reply yes, do that. End reply.", times: [11, 11.2, 20, 20.2, 21, 21.2], batch: batch), now: 21.7)
        check(core.canDispatch && core.releaseRequested, "only confirmed End requests release")
        check(core.body == "yes, do that.", "preserve body punctuation")
        check(core.acceptedCount == 1, "revisions never accept Reply twice")
        core.queued(); core.queued()
        check(core.phase == .queued && core.body == nil, "drop body after queue reservation")
        core.observe(recognition("Reply duplicate End reply", times: [11, 12, 13, 13.2]), now: 22)
        check(core.phase == .queued, "terminal recognition cannot replay")
        core.delivered(); check(core.phase == .delivered, "arrival is distinct from queue acceptance")

        core = waiting()
        core.observe(recognition("Reply reply to Sunny. End reply", times: [11, 11.2, 11.4, 11.6, 12, 12.2]), now: 12.6)
        check(core.body == "reply to Sunny.", "a genuine leading reply is content")
        core = waiting()
        core.observe(recognition("Reply run that command. End reply.", times: [11, 11.2, 11.4, 11.6, 12, 12.2]), now: 12.6)
        check(core.body == "run that command.", "a complete sentence ending in command doesn't swallow the separate End command")
        core = waiting()
        core.observe(recognition("Reply do not end reply", times: [11, 11.2, 11.4, 11.6, 11.8]), now: 12)
        check(!core.canDispatch, "a negated End mention isn't a send boundary")
        core = waiting()
        core.observe(recognition("Reply End reply", times: [11, 11.5, 11.7]), now: 12)
        check(core.phase == .cancelled && core.reason == "no-reply-content" && !core.canDispatch, "control-only sends nothing")
        core = waiting()
        core.observe(recognition("Reply um End reply", times: [11, 11.2, 11.5, 11.7]), now: 12)
        check(!core.canDispatch, "hesitations alone send nothing")
        core = waiting()
        core.observe(recognition("Reply Okay End reply", times: [11, 11.2, 11.5, 11.7]), now: 12)
        check(core.body == "Okay", "Okay is a meaningful whole answer")

        core = waiting()
        core.observe(recognition("you can reply", times: [10.8, 11, 11.2]), now: 11.5)
        check(core.phase == .waiting, "embedded reply does not activate")
        core.processed(through: 13, now: 13); core.tick(now: 14.6)
        check(core.phase == .cancelled && core.reason == "no-command", "no command releases without sending")
        core = waiting()
        core.observe(recognition("Reply", times: [9.5]), now: 10.5)
        check(core.phase == .waiting, "notification echo before exit is excluded")
        core.observe(recognition("Reply", times: [12.2]), now: 13)
        check(core.phase == .waiting, "spoken outside the two-second window is excluded")
        core = waiting()
        let unstable = UUID()
        core.observe(recognition("Reply", times: [11], stable: 0, batch: unstable), now: 11.3)
        check(core.phase == .waiting && core.finalizeThrough != nil, "volatile activation needs confirmation")
        core.observe(recognition("Really", times: [11], batch: unstable), now: 11.6)
        core.processed(through: 13, now: 13); core.tick(now: 14.6)
        check(core.acceptedCount == 0 && !core.canDispatch, "revised-away activation remains silent")

        core = waiting()
        core.observe(recognition("Reply yes", times: [11, 11.3]), now: 11.6)
        core.observe(recognition("do that", times: [20, 20.2]), now: 20.5)
        let ending = UUID()
        core.observe(recognition("End", times: [21], batch: ending), now: 21.2)
        check(core.phase == .composing, "split End does not submit early")
        core.observe(recognition("End reply", times: [21, 21.3], batch: ending), now: 21.6)
        check(core.body == "yes do that", "multiple recognized utterances preserve the complete reply")
        core = waiting()
        core.observe(recognition("Reply yes", times: [11, 11.3]), now: 11.6)
        core.tick(now: 72)
        check(core.phase == .cancelled && core.reason == "idle-safety-limit" && core.body == nil, "idle limit cancels unsent")
        core = NotificationReplyCore(at: 0, limits: .init(idleSeconds: 180, replySeconds: 10))
        core.audioEnded(at: 10, completed: true, now: 10)
        core.observe(recognition("Reply yes", times: [11, 11.3]), now: 11.6)
        core.tick(now: 22)
        check(core.reason == "reply-limit" && !core.canDispatch, "total limit cancels unsent")
        core = waiting()
        core.audioEnded(at: 10, completed: true, now: 10)
        core.observe(recognition("Reply yes", times: [11, 11.3]), now: 11.6)
        core.cancel("new-user-message")
        core.observe(recognition("End reply", times: [12, 12.2]), now: 12.5)
        check(!core.canDispatch && core.body == nil, "stale/cancelled session cannot be revived")
        core = NotificationReplyCore(at: 0)
        core.audioEnded(at: 10, completed: false, now: 10)
        check(core.phase == .cancelled, "failed announcement never opens a window")
        core = waiting()
        core.observe(.init(batch: UUID(), text: "Reply", words: [], stableWords: 0), now: 11)
        check(core.reason == "recognition-timing-unavailable", "missing event timing fails closed")
        check(NotificationReplyCore.Limits(replySeconds: 999).replySeconds == 180, "maximum remains bounded")
        check(NotificationReplyCore.Limits(replySeconds: .nan).replySeconds == 120, "invalid settings use the default")
        check(NotificationReplyCore.Limits().confirmationSeconds == 1.5 && NotificationReplyCore.Limits().commandDrainSeconds == 2.1,
              "native End allowance leaves the initial no-command timing unchanged")
        for (setup, announcement) in [(70.0, 10.0), (179.0, 40.0)] {
            core = NotificationReplyCore(at: 0, limits: .init(idleSeconds: 180, replySeconds: 120))
            for at in stride(from: 5.0, through: setup, by: 5) { core.ownerSeen(at: at); core.tick(now: at) }
            core.ownerSeen(at: setup); core.tick(now: setup)
            core.audioStarted(at: setup)
            let exit = setup + announcement, reply = exit + 1
            core.tick(now: exit - 0.1)
            core.audioEnded(at: exit, completed: true, now: exit)
            let batch = UUID()
            core.observe(recognition("Reply yes", times: [reply, reply + 0.2], batch: batch), now: reply + 0.4)
            core.tick(now: reply + 119)
            check(core.phase == .composing, "slow setup/announcement retain the full permitted reply")
            core.observe(recognition("Reply yes End reply", times: [reply, reply + 0.2, reply + 119.3, reply + 119.5], batch: batch), now: reply + 120.2)
            check(core.canDispatch, "late native End retains its separate confirmation after a slow setup")
        }
        core = NotificationReplyCore(at: 0); core.audioStarted(at: 0); core.tick(now: 45.1)
        check(core.reason == "announcement-limit", "announcement remains finitely bounded independently of setup and reply")
        print("Notification reply core: \(checks) checks passed")
    }
}
