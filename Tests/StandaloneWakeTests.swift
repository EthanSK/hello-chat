import Foundation

@main enum StandaloneWakeTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func check(_ text: String, expected: Bool, phrase: String = "Hello Chat", similar: Bool = true) {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 0.8)
            expect(detector.poll(at: 1.6, phrase: phrase, similar: similar) == expected, text)
            expect(!detector.poll(at: 2, phrase: phrase, similar: similar), "Do not replay: \(text)")
        }
        for text in ["Hello Chat", "HelloChat", "Hello Chad", "Hello Chat, how are you?",
                     "Hello Chat can you help me", "Okay hello chat", "I stopped the video hello chat",
                     "That was a long sentence. Hello Chat", "That was a long sentence hello chat",
                     "He said that was all. Hello Chat", "Hello Chat! What time is it?",
                     "Hello Chat is it raining", "Hello Chat does it work on my Mac",
                     "hello chance can you help", "hello chocolate", "hello chatty"] {
            check(text, expected: true)
        }
        for text in ["I said hello chat", "When I say hello chat", "It is called Hello Chat",
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
        for text in ["Helo Chatt", "Hallo Chad", "Yellow Chat", "Hi Chat", "H E L L O C H A T",
                     "The video stopped. Hullo Chart, can you help?"] { check(text, expected: true) }
        for text in ["Hello cat", "Hello that", "Hello shat", "as well chat", "Hello charts"] { check(text, expected: true) }
        for text in ["the hallo chad detection", "I said yellow chat", "the hello cat app",
                     "I said as well chat", "as well chat detection", "that as well. Chat what next", "help chat"] {
            check(text, expected: false)
        }
        check("Computer Listen can you help me", expected: true, phrase: "Computer Listen")
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
        expect(!poll(1.2), "Wait briefly for a stable phrase")
        update("Hello Chat is the phrase", 1.3)
        expect(!poll(2), "Cancel a partial address revised into an obvious mention")
        update("Hello Chat is the phrase. Hello Chat", 3)
        expect(poll(3.6), "An address after a mention still wakes when its utterance ends")
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
        expect(!poll(2), "Spelled UI end cancels the fuzzy pending wake")
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
        expect(!detector.poll(at: 2, phrase: "Hello Chat", similar: true), "Stable text cannot wake while speech continues")
        detector.audio(level: 0, seconds: 0.59)
        expect(!detector.poll(at: 2.6, phrase: "Hello Chat", similar: true), "A shorter pause is not a completed utterance")
        detector.audio(level: 0, seconds: 0.02)
        expect(detector.poll(at: 2.7, phrase: "Hello Chat", similar: true), "Nemotron wakes after the completed pause")
        expect(!detector.poll(at: 3, phrase: "Hello Chat", similar: true), "One completed utterance wakes only once")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1)
        update("Hello Chat", 1); detector.audio(level: 0, seconds: 2)
        expect(!detector.poll(at: 3, phrase: "Hello Chat", similar: true, requireModelEnd: true), "Parakeet waits for native EOU even in a quiet room")
        detector.utteranceEnded()
        expect(detector.poll(at: 3, phrase: "Hello Chat", similar: true, requireModelEnd: true), "Native EOU authorizes the current transcript")
        update("Hello Chat Hello Chat", 4)
        expect(!detector.poll(at: 5, phrase: "Hello Chat", similar: true, requireModelEnd: true), "A previous EOU cannot authorize later words")
        detector.utteranceEnded()
        expect(detector.poll(at: 5, phrase: "Hello Chat", similar: true, requireModelEnd: true), "A new native EOU permits a later wake")
        detector.resetContext(); update("Hello Chat", 6)
        expect(!detector.poll(at: 7, phrase: "Hello Chat", similar: true, requireModelEnd: true), "Session resets discard old EOU evidence")
        detector.utteranceEnded(); update("Hello Chat is the phrase", 7)
        expect(!detector.poll(at: 8, phrase: "Hello Chat", similar: true, requireModelEnd: true), "A late correction invalidates earlier completion evidence")
        let started = Date()
        for _ in 0..<100_000 { precondition(!poll(4), "Idle frames do not repeat a wake") }
        print("Context-aware wake: \(checks) checks passed; 100000 idle polls in \(Date().timeIntervalSince(started))s")
    }
}
