// Exercise configured notification controls through the real pure core; no microphone, model, app or delivery. — GPT-6.1 Sol
import Foundation

@main struct NotificationReplySpellingTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1; precondition(value(), name)
    }
    static func waiting(_ commands: NotificationReplyCore.Commands = .init()) -> NotificationReplyCore {
        var core = NotificationReplyCore(at: 0, commands: commands)
        core.audioStarted(); core.audioEnded(at: 10, completed: true, now: 10)
        return core
    }
    static func heard(_ text: String, batch: UUID = UUID(), start: Double = 11,
                      stable: Int? = nil, confirmed: Int = 0) -> NotificationReplyCore.Recognition {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return .init(batch: batch, text: text, words: words.enumerated().map {
            .init(text: $0.element, start: start + Double($0.offset) * 0.2, end: start + Double($0.offset) * 0.2 + 0.1)
        }, stableWords: stable ?? words.count, confirmedStartWords: confirmed)
    }
    // Inspect retained heavy state without exposing a production mutation or test-only control API. — GPT-6.1 Sol
    static func retainedCommands(_ core: NotificationReplyCore) -> NotificationReplyCore.Commands {
        Mirror(reflecting: core).children.first { $0.label == "commands" }!.value as! NotificationReplyCore.Commands
    }
    static func main() {
        check(NotificationReplyCore.Commands.defaultReplySpellings.isEmpty, "No invented initial Reply spellings")
        check(NotificationReplyCore.Commands.defaultEndReplySpellings == ["And reply"], "Requested observed spelling is built-in")
        let normalized = NotificationReplyCore.Commands(replySpellings: ["REPLY!", "respond now", "Respond, now", ""],
            endReplySpellings: ["And reply", "AND REPLY!", ""])
        check(normalized.replyForms == [["reply"], ["respond", "now"]], "Normalize/deduplicate exact token forms")
        check(normalized.endReplyForms == [["end", "reply"], ["and", "reply"]], "Canonical remains with configured end forms")
        let batch = UUID()
        var core = waiting()
        core.observe(heard("Reply yes And reply", batch: batch, stable: 2), now: 12)
        check(core.phase == .composing && core.finalizeThrough != nil && !core.canDispatch, "Partial And reply needs native confirmation")
        check(core.draftText == "yes", "Pending control is excluded from displayed body")
        core.observe(heard("Reply yes And reply", batch: batch), now: 12.1)
        check(core.canDispatch && core.body == "yes" && core.reason == "end-reply", "Native-final And reply sends only body")
        core.observe(heard("Reply yes And reply", batch: batch), now: 12.2)
        check(core.acceptedCount == 1 && core.body == "yes", "Duplicate result cannot duplicate activation/body")
        core.queued(); core.observe(heard("Reply duplicate End reply"), now: 13)
        check(core.phase == .queued && core.body == nil, "Terminal event cannot send twice")

        core = waiting()
        core.observe(heard("Reply read that and reply", batch: batch, stable: 3), now: 12.2)
        check(core.finalizeThrough != nil, "Ambiguous suffix initially requests native validation")
        core.observe(heard("Reply read that and reply tomorrow", batch: batch), now: 12.3)
        check(core.phase == .composing && !core.canDispatch && core.draftText == "read that and reply tomorrow",
              "A continued normal sentence keeps every alias word as body")
        check(core.finalizeThrough == nil, "Continued alias clears its obsolete finalize request")
        core.observe(heard("Reply read that and reply tomorrow. End reply", batch: batch), now: 13)
        check(core.body == "read that and reply tomorrow.", "Later deliberate canonical End preserves earlier normal phrase")

        core = waiting()
        core.observe(heard("Reply yes End reply", batch: batch, stable: 2), now: 12)
        core.observe(heard("Reply yes End reply background words", batch: batch), now: 12.4)
        check(core.canDispatch && core.body == "yes", "Canonical timed End still cuts off later room words")
        core = waiting()
        core.observe(heard("Reply yes And reply", batch: batch, stable: 2), now: 12)
        core.observe(heard("Reply yes another reply", batch: batch), now: 12.4)
        check(core.phase == .composing && !core.canDispatch && core.draftText == "yes another reply", "Revised-away alias never sends")
        for text in ["Reply do not And reply", "Reply never And reply", "Reply say And reply", "Reply saying And reply",
                     "Reply phrase And reply", "Reply command And reply", "Reply don't And reply"] {
            core = waiting(); core.observe(heard(text), now: 13)
            check(!core.canDispatch && core.phase == .composing, "Negated/mentioned alias stays body: " + text)
        }
        core = waiting(); core.observe(heard("Reply use that command. And reply"), now: 13)
        check(core.body == "use that command.", "Punctuation separates a real control from the preceding sentence")
        for text in ["Reply And reply", "Reply um And reply"] {
            core = waiting(); core.observe(heard(text), now: 12)
            check(core.phase == .cancelled && core.reason == "no-reply-content" && !core.canDispatch, "Empty/hesitation-only aliases send nothing")
        }
        core = waiting(); core.observe(heard("Reply reply to Sunny. And reply"), now: 13)
        check(core.body == "reply to Sunny.", "A genuine leading reply word remains body")

        for commands in [NotificationReplyCore.Commands(endReplySpellings: []), .init(alternateSpellings: false)] {
            core = waiting(commands); core.observe(heard("Reply yes And reply"), now: 12)
            check(core.phase == .composing && core.draftText == "yes And reply", "Empty override and global-off retain canonical only")
            core.observe(heard("End reply", start: 13), now: 13.5)
            check(core.canDispatch && core.body == "yes And reply", "Canonical End remains available with aliases disabled")
        }
        let custom = NotificationReplyCore.Commands(replySpellings: ["Respond now"], endReplySpellings: ["End response now"])
        core = waiting(custom); core.observe(heard("Respond now reply to Sunny. End response now"), now: 13)
        check(core.canDispatch && core.body == "reply to Sunny.", "Variable-length controls remove only their full spans")
        core = waiting(custom)
        core.observe(heard("Respond now yes", batch: batch, stable: 0, confirmed: 1), now: 11.8)
        check(core.phase == .waiting, "Incomplete agreeing prefix cannot activate a multiword start")
        core.observe(heard("Respond now yes", batch: batch, stable: 0, confirmed: 2), now: 11.9)
        check(core.phase == .composing && core.acceptedCount == 1, "Same inference-prefix start policy covers every control word")
        core.observe(heard("Recall now yes", batch: batch, stable: 0), now: 12)
        check(core.phase == .cancelled && core.reason == "reply-prefix-revised", "Revised accepted multiword start cancels unsent")
        core = waiting()
        core.observe(heard("Reply yes And reply", stable: 0, confirmed: 4), now: 12)
        check(core.phase == .composing && !core.canDispatch && core.finalizeThrough != nil,
              "Inference-prefix confirmation can start but never finish an alias reply")

        core = waiting(custom)
        core.observe(heard("Respond", start: 11), now: 11.15)
        check(core.phase == .waiting, "Cross-batch start cannot activate before complete")
        let middle = UUID(), last = UUID()
        core.observe(heard("now yes End", batch: middle, start: 11.2), now: 11.9)
        check(core.phase == .composing && core.draftText == "yes End", "Cross-batch start preserves following body")
        core.observe(heard("response now", batch: last, start: 11.8, stable: 0), now: 12.3)
        check(!core.canDispatch && core.finalizeThrough != nil && core.draftText == "yes", "Cross-batch custom End requests final confirmation")
        core.observe(heard("response now", batch: last, start: 11.8), now: 12.4)
        check(core.canDispatch && core.body == "yes", "Cross-batch native final preserves body and strips all controls")

        core = waiting(); core.observe(heard("And reply"), now: 11.5)
        check(core.phase == .waiting && core.acceptedCount == 0, "End alias cannot start a reply")
        core = waiting(); core.observe(heard("Reply yes And reply", batch: batch, stable: 2), now: 12)
        core.tick(now: 15.6)
        check(core.reason == "end-command-unconfirmed" && !core.canDispatch, "No native final still cancels within unchanged bound")
        core = waiting(); core.observe(heard("Reply yes", batch: batch), now: 12); core.cancel("new-user-message")
        core.observe(heard("And reply", start: 13), now: 14)
        check(core.phase == .cancelled && !core.canDispatch, "A late alias cannot revive cancellation")

        let large = NotificationReplyCore.Commands(endReplySpellings: (0..<2000).map { "finish number \($0)" })
        core = waiting(large)
        check(retainedCommands(core) == large, "Active attempt retains its frozen dictionary")
        core.observe(heard("Reply yes finish number 1999"), now: 13)
        check(core.canDispatch && retainedCommands(core) == large, "Releasing keeps the frozen dictionary until its outcome commits")
        core.queued()
        check(core.phase == .queued && core.reason == "end-reply" && core.body == nil &&
              retainedCommands(core) == .init(alternateSpellings: false), "Queued attempt retires heavy forms while preserving its outcome")
        core.delivered()
        check(core.phase == .delivered && retainedCommands(core) == .init(alternateSpellings: false), "Delivered receipt retains only minimal command tables")
        for unavailable in [false, true] {
            core = waiting(large); core.observe(heard("Reply yes"), now: 12)
            core.cancel("test-cancel", unavailable: unavailable)
            check(core.phase == (unavailable ? .unavailable : .cancelled) && core.reason == "test-cancel" &&
                  core.draftText.isEmpty && !core.canDispatch && retainedCommands(core) == .init(alternateSpellings: false),
                  "Cancelled/unavailable attempts retire dictionaries and captured spans while preserving the outcome")
        }
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<200 {
            core = waiting(large); core.observe(heard("Reply yes finish number 1999"), now: 13)
            check(core.canDispatch && core.body == "yes", "Maximum configured dictionary resolves exact suffix")
        }
        print("200 maximum-dictionary attempts \(ProcessInfo.processInfo.systemUptime - started)s")
        let varied = NotificationReplyCore.Commands(endReplySpellings: (0..<2000).map {
            Array(repeating: "w", count: $0 % 55 + 1).joined(separator: " ") + " x\($0)"
        })
        core = waiting(varied)
        let texts = ["reply"] + Array(repeating: "word", count: 6400)
        let full = NotificationReplyCore.Recognition(batch: UUID(), text: texts.joined(separator: " "),
            words: texts.enumerated().map { .init(text: $0.element, start: 11 + Double($0.offset) * 0.01, end: 11.005 + Double($0.offset) * 0.01) },
            stableWords: texts.count)
        let worstStarted = ProcessInfo.processInfo.systemUptime
        core.observe(full, now: 76)
        check(core.phase == .composing && !core.canDispatch, "Near32KB body and2000 varied-length forms stay bounded and unsent")
        print("Near32KB/2000-varied-form admission \(ProcessInfo.processInfo.systemUptime - worstStarted)s")
        print("Notification spellings: \(checks) checks passed. Synthetic timed words only.")
    }
}
