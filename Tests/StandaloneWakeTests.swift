import Foundation

@main enum StandaloneWakeTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func endCommand(_ detector: inout StandaloneWake, _ text: String, at time: Double = 1) -> Bool {
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: time)
            detector.audio(level: 0, seconds: 0.6)
            return detector.pollEnd(at: time + 0.6, phrase: "Bye Chat", similar: true)
        }
        for text in ["B Chat", "bee chat", "be chat", "H Chat", "the existing Notion UI chat",
                     "I said bye chat", "the bye chat command", "do not bye chat", "don't bye chat",
                     "bye chat is the phrase", "when I say bye chat"] {
            var detector = StandaloneWake()
            expect(!endCommand(&detector, text), "End discussion or negation must stay inert")
        }
        for text in ["Bye Chat", "by chat", "okay, bye chat", "thanks for your help. Bye Chat!"] {
            var detector = StandaloneWake()
            expect(endCommand(&detector, text), "Direct End activates after its pause")
            expect(!endCommand(&detector, text, at: 2), "End does not replay")
        }
        var endRevision = StandaloneWake()
        expect(!endCommand(&endRevision, "I said bye chat"), "Reject a mentioned End")
        expect(!endCommand(&endRevision, "bye chat", at: 2), "A revised mention does not replay")
        expect(endCommand(&endRevision, "bye chat. Bye Chat", at: 3), "A later direct End remains available")
        func muteCommand(_ detector: inout StandaloneWake, _ text: String, at time: Double = 1) -> Bool {
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: time)
            detector.audio(level: 0, seconds: 0.6)
            return detector.pollMicrophone(at: time + 0.6)
        }
        for phrase in ["mute chat", "MUTE CHAT!", "okay, mute chat"] {
            var detector = StandaloneWake()
            expect(muteCommand(&detector, phrase), "Mute command: \(phrase)")
            expect(!muteCommand(&detector, phrase, at: 2), "One toggle per occurrence")
        }
        for mention in ["when I say mute chat", "the silent chat command", "silence chat is the phrase",
                        "please don't mute chat", "do not silence chat", "unmute chat", "mute", "chat"] {
            var detector = StandaloneWake()
            expect(!muteCommand(&detector, mention), "Do not toggle for mention or incomplete command: \(mention)")
        }
        var revisedMute = StandaloneWake()
        expect(muteCommand(&revisedMute, "mute chat"), "First command toggles")
        expect(!muteCommand(&revisedMute, "MUTE CHAT", at: 2), "A revised alias must not toggle again")
        expect(muteCommand(&revisedMute, "MUTE CHAT. mute chat", at: 3), "A later new command toggles again")
        revisedMute.resetContext()
        expect(muteCommand(&revisedMute, "mute chat", at: 4), "New recognition context accepts a new command")
        var precedingWake = StandaloneWake()
        precedingWake.audio(level: 0.2, seconds: 0.1)
        precedingWake.update("hello chad mute chat", at: 1)
        for phrase in StandaloneWake.microphonePhrases {
            precedingWake.cancelPending(phrase: "Hello Chat", endPhrase: phrase, similar: true)
        }
        expect(!precedingWake.poll(at: 1, phrase: "Hello Chat", similar: true),
               "A fuzzy wake before mute cannot unmute again on the following frame")
        precedingWake.update("hello chad mute chat. Hello Chat", at: 2)
        precedingWake.audio(level: 0, seconds: 0.6)
        expect(precedingWake.poll(at: 2, phrase: "Hello Chat", similar: true), "A later fresh wake still works")
        var separatedMute = StandaloneWake()
        separatedMute.audio(level: 0.2, seconds: 0.1)
        separatedMute.update("mute chat", at: 20, timings: [("mute", 0, 0.2), ("chat", 19, 19.3)])
        expect(!separatedMute.poll(at: 20, phrase: "mute chat", similar: false), "Old separated words cannot toggle")
        var timed = StandaloneWake()
        timed.audio(level: 0.2, seconds: 0.1)
        timed.update("hello", at: 1, timings: [("hello", 0, 0.3)])
        expect(!timed.poll(at: 1, phrase: "Hello Chat", similar: true), "Partial address waits for name")
        timed.update("hello chat", at: 20, timings: [("hello", 0, 0.3), ("chat", 19, 19.4)])
        expect(!timed.poll(at: 20, phrase: "Hello Chat", similar: true), "Old hello and later chat do not wake")
        timed.update("hello chat hello chat", at: 30, timings:
            [("hello", 0, 0.3), ("chat", 19, 19.4), ("hello", 29, 29.3), ("chat", 29.5, 29.8)])
        timed.audio(level: 0, seconds: 0.6)
        expect(timed.poll(at: 30, phrase: "Hello Chat", similar: true), "A later fresh complete phrase wakes after its pause")
        func check(_ text: String, expected: Bool, phrase: String = "Hello Chat", similar: Bool = true) {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 0.8)
            expect(detector.poll(at: 1.6, phrase: phrase, similar: similar) == expected, text)
            expect(!detector.poll(at: 2, phrase: phrase, similar: similar), "Do not replay: \(text)")
        }
        for text in ["Hello Chat", "HelloChat", "Hello Chad", "Okay hello chat", "I stopped the video hello chat",
                     "That was a long sentence. Hello Chat", "That was a long sentence hello chat",
                     "He said that was all. Hello Chat", "hello chocolate", "hello chatty"] {
            check(text, expected: true)
        }
        for text in ["Hello Chat, how are you?", "Hello Chat can you help me", "Hello Chat! What time is it?",
                     "Hello Chat is it raining", "Hello Chat does it work on my Mac", "hello chance can you help", "I said hello chat", "When I say hello chat", "It is called Hello Chat",
                     "I'm talking about hello chat", "the hello chat detection isn't good enough",
                     "Why doesn't hello chat work", "Hello Chat is the phrase", "Hello Chat doesn't work",
                     "Hello Chat should work", "She mentioned hello chat yesterday", "It detects hello chat",
                     "When Hello Chat opens Voice", "Hello Chat uses the microphone", "the Hello Chat app",
                     "I said hello chance", "the hello chance detection", "Hello Janet", "An unrelated sentence", "",
                     "in the hood thing can you highlight something that matches hello chat either in exact match or one of the dictionary",
                     "something matching Hello Chat", "maybe he'll chat that's doing the",
                     "maybe he’ll chat that's doing the", "he'll chat", "hellchat", "he'll chats", "he'll chad",
                     "high at", "it's too high at low speed", "was it high at or what"] {
            check(text, expected: false)
        }
        check("Hello Chad", expected: false, similar: false)
        check("Hello chance", expected: false, similar: false)
        check("Hello chance", expected: false, phrase: "Hey Chat")
        for text in ["Helo Chatt", "Hallo Chad", "Yellow Chat", "H E L L O C H A T"] { check(text, expected: true) }
        check("The video stopped. Hullo Chart, can you help?", expected: false)
        for text in ["Hi Chat", "High Chat", "Hi Chad", "H I chat", "H I G H chat",
                     "Oh hi chat", "highchat", "it registered as high chat", "it registered as Hello Chat"] {
            check(text, expected: false)
        }
        for phrase in ["Hi Chat", "High Chat"] {
            check(phrase, expected: true, phrase: phrase)
            check(phrase, expected: true, phrase: phrase, similar: false)
        }
        check("High Chat. Hello Chat", expected: true)
        for text in ["as well chat", "Hello charts"] { check(text, expected: true) }
        for text in ["Hello cat", "Hello that", "Hello shat", "Hey Chat", "hey chat can you help"] { check(text, expected: false) }
        for text in ["the hallo chad detection", "I said yellow chat", "the hello cat app",
                     "I said as well chat", "as well chat detection", "that as well. Chat what next", "help chat"] {
            check(text, expected: false)
        }
        check("Computer Listen can you help me", expected: false, phrase: "Computer Listen")
        check("High At", expected: true, phrase: "High At", similar: false)
        check("it's too high at low speed. Hello Chat", expected: true)
        var detector = StandaloneWake()
        func update(_ text: String, _ at: Double) {
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: at)
        }
        func poll(_ at: Double) -> Bool {
            detector.audio(level: 0, seconds: 0.7)
            return detector.poll(at: at, phrase: "Hello Chat", similar: true)
        }
        detector.audio(level: 0.2, seconds: 0.1); update("Hello Chat", 1)
        expect(!detector.poll(at: 1.01, phrase: "Hello Chat", similar: true), "An address remains pending before its pause")
        update("Hello Chat is the phrase", 1.3)
        expect(!poll(2), "A later mention correction cancels the pending wake")
        update("Hello Chat is the phrase. Hello Chat", 3)
        expect(poll(3.6), "A new address after a mention wakes")
        update("Hello Chat was the phrase. Hello Chat", 4)
        expect(!poll(4.6), "An earlier-word correction must not repeat the wake")
        update("Hello Chat was the phrase. Hello Chat. Hello Chad", 5)
        expect(poll(5.6), "A new later occurrence can wake again")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("he said", 1); expect(!poll(1.6), "No phrase yet")
        detector.audio(level: 0, seconds: 0.4); detector.audio(level: 0.2, seconds: 0.1)
        update("he said hello chat", 2)
        expect(poll(2.6), "A real pause separates a new address from old reporting words")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("a video sentence", 1); detector.resetContext()
        update("hello chat", 2)
        expect(poll(2.6), "Context rollover no longer requires a leading audio pause")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("hello", 1); detector.audio(level: 0, seconds: 0.4)
        detector.audio(level: 0.2, seconds: 0.1); update("hello chat", 2)
        expect(poll(2.6), "An inter-word pause must not hide the start of the wake phrase")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Hello Chat", 1); expect(poll(1.6), "Initial address")
        update("Hello", 2); expect(!poll(2.6), "Shortening revision")
        update("Hello Chat", 3); expect(!poll(3.6), "Do not replay a removed then reinserted address")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Hello Chat Bye Chat", 1)
        detector.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true)
        expect(!poll(2), "An end command before the wake settles must cancel it")
        update("Hello Chat Bye Chat. Hello Chat", 3)
        expect(poll(3.6), "A new greeting after cancellation can wake normally")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Hello Chat Bye Chat Hello Chat", 1)
        detector.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true)
        expect(poll(2), "A later greeting wins even when both commands arrive in one revision")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Helo Chatt U I Chat", 1)
        detector.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true)
        expect(!poll(2), "Uninterrupted discussion after a wake has no command pause")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("as well chat", 1)
        expect(poll(1.6), "The screenshot phrase wakes once")
        update("as well chat can you help", 2)
        expect(!poll(2.6), "Appending words cannot replay the screenshot greeting")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("as well chat Bye Chat", 1)
        detector.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true)
        expect(!poll(2), "A genuine end cancels the pending weak greeting")
        update("as well chat Bye Chat. Hello Chat", 3)
        expect(poll(3.6), "A genuinely later greeting still works after weak-wake cancellation")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("As well chat", 1)
        detector.audio(level: 0, seconds: 0.7)
        expect(detector.poll(at: 2, phrase: "As Well Chat", similar: false),
               "Exact custom wake phrases are unaffected by default alias routing")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Hello Chat", 1)
        detector.audio(level: 0.2, seconds: 1)
        expect(!detector.poll(at: 2, phrase: "Hello Chat", similar: true), "Continued speech cannot satisfy the required pause")
        update("Hello Chat what's the weather like", 2.5)
        expect(!detector.poll(at: 2.6, phrase: "Hello Chat", similar: true), "Words spoken straight after the wake cannot repeat it")
        expect(!detector.poll(at: 3, phrase: "Hello Chat", similar: true), "One address wakes only once")
        for text in ["Hello Chat", "A video sentence. Hello Chat", "Yellow Chat"] {
            detector.reset(); detector.audio(level: 0.05, seconds: 0.1); detector.update(text, at: 1)
            var decisions: [String] = []
            expect(!detector.poll(at: 1.01, phrase: "Hello Chat", similar: true, onDecision: { reason, _, _ in
                decisions.append(reason)
            }), "Noise alone never satisfies the silence gate")
            expect(decisions == ["waiting_for_pause"], "The wait is logged without recognized words")
            detector.audio(level: 0, seconds: 0.6)
            expect(detector.poll(at: 1.6, phrase: "Hello Chat", similar: true), "Quiet audio releases the pending command")
            expect(!detector.poll(at: 4, phrase: "Hello Chat", similar: true), "The address fires only once")
        }
        for text in ["I said Hello Chat", "the Hello Chat", "Hello Chat is the phrase", "Hello Chat can you help"] {
            detector.reset(); detector.audio(level: 0.05, seconds: 3); detector.update(text, at: 1)
            expect(!detector.poll(at: 1.01, phrase: "Hello Chat", similar: true),
                   "Mentions and uninterrupted following speech remain inert")
        }
        detector.reset(); detector.audio(level: 0.05, seconds: 0.1); detector.update("Hello Chat Bye Chat", at: 1)
        detector.cancelPending(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true)
        expect(!detector.poll(at: 4, phrase: "Hello Chat", similar: true), "An end in the same transcript still cancels the wake")
        for (phrase, ending) in [("Hello Chat", false), ("Bye Chat", true), ("Mute Chat", false), ("Unmute Chat", false), ("Silence Chat", false), ("Unsilence Chat", false)] {
            var pending = StandaloneWake()
            pending.audio(level: 0.2, seconds: 0.1)
            pending.update(phrase, at: 100, timings: [(phrase.lowercased().components(separatedBy: " ")[0], 0, 0.2), ("chat", 0.2, 0.4)])
            expect(!pending.poll(at: 1000, phrase: phrase, similar: false, ending: ending), "Wall-clock delay cannot substitute for audio silence")
            pending.audio(level: 0, seconds: 0.59)
            expect(!pending.poll(at: 1001, phrase: phrase, similar: false, ending: ending), "590 ms is too short for every command")
            pending.audio(level: 0, seconds: 0.02)
            expect(pending.poll(at: 1002, phrase: phrase, similar: false, ending: ending), "610 ms releases every command once")
            expect(!pending.poll(at: 1003, phrase: phrase, similar: false, ending: ending), "A paused command cannot replay")
        }
        for gap in [0.1, 0.599, 0.6, 0.8] {
            var laterWords = StandaloneWake()
            laterWords.audio(level: 0.2, seconds: 2)
            laterWords.update("hello chat continue", at: 999, timings: [("hello", 0, 0.2), ("chat", 0.2, 0.4), ("continue", 0.4 + gap, 1.4 + gap)])
            expect(laterWords.poll(at: 999, phrase: "Hello Chat", similar: true) == (gap >= 0.6), "Only the audio timestamp gap permits following words")
        }
        var customMute = StandaloneWake()
        customMute.audio(level: 0.2, seconds: 0.1)
        customMute.update("Quiet Lantern", at: 1)
        customMute.audio(level: 0, seconds: 0.6)
        expect(customMute.pollMicrophone(at: 2, phrases: ["Quiet Lantern"], similar: true), "Saved microphone phrases use the same pause gate")
        var ambient = StandaloneWake()
        ambient.audio(level: 0.08, seconds: 0.1, at: 1.0)
        ambient.update("hello chat", at: 500, timings: [("hello", 0.2, 0.4), ("chat", 0.4, 0.6)])
        expect(!ambient.poll(at: 500, phrase: "Hello Chat", similar: true), "A delayed callback cannot manufacture a speech gap")
        ambient.audio(level: 0.08, seconds: 0.19, at: 1.19)
        expect(!ambient.poll(at: 501, phrase: "Hello Chat", similar: true), "Ambient noise does not shorten the 600 ms word-time gap")
        ambient.audio(level: 0.08, seconds: 0.01, at: 1.2)
        expect(ambient.poll(at: 502, phrase: "Hello Chat", similar: true), "Ambient noise cannot block a timestamped speech pause")
        var continuing = StandaloneWake()
        continuing.audio(level: 0.08, seconds: 2, at: 2)
        continuing.update("hello chat continue", at: 500, timings: [("hello", 0.2, 0.4), ("chat", 0.4, 0.6), ("continue", 0.7, 1.0)])
        expect(!continuing.poll(at: 500, phrase: "Hello Chat", similar: true), "Continuing speech with a short gap stays inert even after a later pause")
        var microphoneAlias = StandaloneWake()
        microphoneAlias.audio(level: 0.08, seconds: 0.1, at: 1.2)
        microphoneAlias.update("mute chad", at: 5, timings: [("mute", 0.2, 0.4), ("chad", 0.4, 0.6)])
        expect(microphoneAlias.pollMicrophone(at: 5, similar: true), "The narrow microphone dictionary uses the same timestamp pause")
        let started = Date()
        for _ in 0..<100_000 { precondition(!poll(4), "Idle frames do not repeat a wake") }
        print("Context-aware wake: \(checks) checks passed; 100000 idle polls in \(Date().timeIntervalSince(started))s")
    }
}
