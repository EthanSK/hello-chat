import Foundation

@main enum StandaloneWakeTests {
    static func main() {
        for (words, shouldShow) in [("show voice", true), ("please show voice", true),
                                     ("I said show voice", false), ("don't show voice", false),
                                     ("show voice settings", false)] {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(words, at: 1)
            let phrase = PhraseSlot.showVoicePhrase.defaultText
            precondition(detector.poll(at: 1, phrase: phrase, similar: false, rejectNegated: true, directOnly: true) == shouldShow)
            precondition(!detector.poll(at: 2, phrase: phrase, similar: false, rejectNegated: true, directOnly: true))
        }
        var successiveShow = StandaloneWake()
        let showPhrase = PhraseSlot.showVoicePhrase.defaultText
        for number in 1...4 {
            successiveShow.audio(level: 0.2, seconds: 0.1, at: Double(number))
            successiveShow.update(Array(repeating: "Show voice", count: number).joined(separator: ". "), at: Double(number))
            precondition(successiveShow.poll(at: Double(number), phrase: showPhrase, similar: false,
                rejectNegated: true, directOnly: true), "Each fresh direct Show Voice occurrence is accepted")
            precondition(!successiveShow.poll(at: Double(number) + 0.1, phrase: showPhrase, similar: false,
                rejectNegated: true, directOnly: true), "The same occurrence cannot be replayed")
        }
        var catWake = StandaloneWake()
        catWake.audio(level: 0.2, seconds: 0.1)
        catWake.update("Hello cat", at: 1)
        precondition(catWake.poll(at: 1, phrase: "Hello Chat", similar: true, rejectNegated: true),
                     "Ethan's exact Hello cat spelling starts the existing wake command")
        var exactWake = StandaloneWake()
        exactWake.audio(level: 0.2, seconds: 0.1); exactWake.update("Hello cat", at: 1)
        precondition(!exactWake.poll(at: 1, phrase: "Hello Chat", similar: false, rejectNegated: true),
                     "Explicitly disabled alternate spellings remain disabled")
        precondition(PhraseSlot.wakePhrase.stockSpellings(for: "Hello Chat").contains("hello cat"),
                     "The existing dictionary editor exposes the same Hello cat recognition spelling")
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        // Synthetic ASR batches, not recorded YouTube: speech stays loud and narration keeps
        // arriving after the command. No quiet frame or sentence-ending punctuation is supplied.
        expect(StandaloneWake.commandPauseSeconds == 0, "Playback commands have no added silence wait")
        for phrase in ["Hello Chat", "Bye Chat", "Mute Chat", "Unmute Chat", "Silence Chat", "Unsilence Chat", "Pause video", "Play video", "Pause music", "Play music", "Zoom in", "Zoom out", "Switch speakers kitchen"] {
            var detector = StandaloneWake()
            let direct = ["Pause music", "Play music", "Zoom in", "Zoom out", "Switch speakers kitchen"].contains(phrase)
            let text = phrase + " the narrator keeps talking about the next scene"
            detector.audio(level: 0.2, seconds: 0.1, at: 1)
            detector.update(text, at: 1)
            expect(detector.poll(at: 1, phrase: phrase, similar: false, rejectNegated: true,
                ending: phrase == "Bye Chat", directOnly: direct), "Complete fixed command fires in its first batch despite continuing playback: \(phrase)")
            for revision in 1...5 {
                detector.audio(level: 0.2, seconds: 0.1, at: 1 + Double(revision) / 10)
                detector.update(text + String(repeating: " more narration", count: revision), at: 1 + Double(revision) / 10)
                expect(!detector.poll(at: 1 + Double(revision) / 10, phrase: phrase, similar: false,
                    rejectNegated: true, ending: phrase == "Bye Chat", directOnly: direct), "Continuing playback cannot replay a consumed command")
            }
        }
        // Both music phrases share a single occurrence count because the hardware key is a toggle.
        let music = PhraseSlot.musicSlots.map { PhrasePattern(slot: $0, text: $0.defaultText, similar: true, dictionaries: .init()) }
        func musicPoll(_ detector: inout StandaloneWake, at time: Double = 1) -> Bool {
            detector.poll(at: time, phrase: "Pause music", similar: true, rejectNegated: true, patterns: music, directOnly: true)
        }
        for text in ["Pause music", "Play music", "Please play music", "PAUSE, MUSIC!"] {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            expect(musicPoll(&detector), "A direct music phrase is accepted")
            expect(!musicPoll(&detector, at: 2), "Polling the same occurrence never toggles twice")
        }
        for text in ["I said play music", "Don't pause music", "The pause music phrase", "Play video", "Pause video", "Play music later"] {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            expect(!musicPoll(&detector), "Music rejects discussion, negation, trailing plans and video commands: \(text)")
        }
        var revisedMusic = StandaloneWake()
        revisedMusic.audio(level: 0.2, seconds: 0.1)
        revisedMusic.update("Play music", at: 1)
        expect(musicPoll(&revisedMusic), "First music recognition sends one toggle")
        revisedMusic.update("Pause music", at: 2)
        expect(!musicPoll(&revisedMusic, at: 2), "A revised Play/Pause hypothesis shares its consumed occurrence")
        revisedMusic.update("Pause music. Play music", at: 3)
        expect(musicPoll(&revisedMusic, at: 3), "A genuinely new second occurrence can send one more press")
        var cancelledMusic = StandaloneWake()
        cancelledMusic.audio(level: 0.2, seconds: 0.1); cancelledMusic.update("Play music. Bye chat", at: 1)
        cancelledMusic.cancelPending(patterns: music, endPatterns: [PhrasePattern(text: "Bye chat", similar: true, ending: true)])
        expect(!musicPoll(&cancelledMusic), "End consumes a pending music command rather than replaying it")
        var customMusic = StandaloneWake()
        customMusic.audio(level: 0.2, seconds: 0.1); customMusic.update("Resume tunes", at: 1)
        expect(customMusic.poll(at: 1, phrase: "Resume tunes", similar: true, rejectNegated: true,
            patterns: [PhrasePattern(slot: .playMusicPhrase, text: "Resume tunes", similar: true, dictionaries: .init())], directOnly: true),
            "A custom music phrase uses the same detector")
        for text in ["by H chat", "the actions can be exposed by H chat, but Apple's phrase", "written by H chad", "handled by H chats", "B Y H C H A T"] {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            expect(!detector.pollEnd(at: 1, phrase: "Bye Chat", similar: true), "Discussion of H Chat cannot become a generated End address")
        }
        var revisedOccurrences = StandaloneWake()
        revisedOccurrences.audio(level: 0.2, seconds: 0.1, at: 2)
        revisedOccurrences.update("I said mute chat. Mute chat", at: 1, timings: [("i", 0, 0.1), ("said", 0.1, 0.2), ("mute", 0.2, 0.3), ("chat", 0.3, 0.4), ("mute", 1, 1.1), ("chat", 1.1, 1.2)])
        expect(revisedOccurrences.poll(at: 1, phrase: "Mute Chat", similar: true, rejectNegated: true), "The direct occurrence after a mention is accepted")
        revisedOccurrences.update("Mute chat", at: 2, timings: [("mute", 1, 1.1), ("chat", 1.1, 1.2)])
        expect(!revisedOccurrences.poll(at: 2, phrase: "Mute Chat", similar: true, rejectNegated: true), "Removing earlier words cannot replay the old occurrence")
        revisedOccurrences.update("Mute chat. Mute chat", at: 3, timings: [("mute", 1, 1.1), ("chat", 1.1, 1.2), ("mute", 3, 3.1), ("chat", 3.1, 3.2)])
        expect(revisedOccurrences.poll(at: 3, phrase: "Mute Chat", similar: true, rejectNegated: true), "A new timed occurrence survives removal of an earlier match")
        revisedOccurrences.update("Muted chat. Mute chat", at: 4, timings: [("muted", 1.02, 1.12), ("chat", 1.12, 1.22), ("mute", 3.02, 3.12), ("chat", 3.12, 3.22)])
        expect(!revisedOccurrences.poll(at: 4, phrase: "Mute Chat", similar: true, rejectNegated: true), "Small timing and spelling revisions cannot replay accepted commands")
        var cancelledTimedWake = StandaloneWake()
        cancelledTimedWake.audio(level: 0.2, seconds: 0.1, at: 3)
        cancelledTimedWake.update("Hello Chat. Mute Chat", at: 1, timings: [("hello", 0, 0.2), ("chat", 0.2, 0.4), ("mute", 1, 1.2), ("chat", 1.2, 1.4)])
        cancelledTimedWake.cancelPending(phrase: "Hello Chat", endPhrase: "Mute Chat", similar: true)
        expect(!cancelledTimedWake.poll(at: 2, phrase: "Hello Chat", similar: true), "Timed cancellation consumes the prior wake too")
        for text in ["unsilenced chat", "unsilenced chad"] {
            var detector = StandaloneWake(requiredPause: 0.6)
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 0.59)
            expect(!detector.poll(at: 1.59, phrase: "unsilence chat", similar: true, rejectNegated: true), "Spelling tolerance keeps the full pause")
            detector.audio(level: 0, seconds: 0.01)
            expect(detector.poll(at: 1.6, phrase: "unsilence chat", similar: true, rejectNegated: true), "Observed real-word variants activate after the pause")
            expect(!detector.poll(at: 2, phrase: "unsilence chat", similar: true, rejectNegated: true), "A variant fires only once")
        }
        for text in ["do not unsilenced chat", "I said unsilenced chat", "the unsilenced chat command", "silenced chat", "unmute chat"] {
            var detector = StandaloneWake(requiredPause: 0.6)
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1); detector.audio(level: 0, seconds: 0.6)
            expect(!detector.poll(at: 1.6, phrase: "unsilence chat", similar: true, rejectNegated: true), "Variants preserve negation, mention and direction boundaries")
        }
        for phrase in ["Hello Chat", "Bye Chat", "Mute Chat", "Unmute Chat", "Silent Chat", "Silence Chat", "Unsilenced Chat"] {
            var immediate = StandaloneWake()
            immediate.audio(level: 0.2, seconds: 0.1, at: 0.1)
            immediate.update(phrase, at: 1)
            let configured = phrase == "Unsilenced Chat" ? "Unsilence Chat" : phrase
            expect(immediate.poll(at: 1, phrase: configured, similar: true, rejectNegated: true, ending: phrase == "Bye Chat"), "Trial accepts the complete recognized phrase without a quiet frame")
            expect(!immediate.poll(at: 1, phrase: configured, similar: true, rejectNegated: true, ending: phrase == "Bye Chat"), "Immediate mode retains occurrence deduplication")
        }
        for text in ["do not mute chat", "I said unsilenced chat", "the silence chat command"] {
            var immediate = StandaloneWake()
            immediate.audio(level: 0.2, seconds: 0.1)
            immediate.update(text, at: 1)
            for phrase in ["Mute Chat", "Silence Chat", "Unsilence Chat"] {
                expect(!immediate.poll(at: 1, phrase: phrase, similar: true, rejectNegated: true), "Immediate mode keeps mention and negation filters")
            }
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
            var detector = StandaloneWake(requiredPause: 0.6)
            expect(!endCommand(&detector, text), "End discussion or negation must stay inert")
        }
        for text in ["Bye Chat", "by chat", "okay, bye chat", "thanks for your help. Bye Chat!"] {
            var detector = StandaloneWake(requiredPause: 0.6)
            expect(endCommand(&detector, text), "Direct End activates after its pause")
            expect(!endCommand(&detector, text, at: 2), "End does not replay")
        }
        var endRevision = StandaloneWake(requiredPause: 0.6)
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
            var detector = StandaloneWake(requiredPause: 0.6)
            expect(muteCommand(&detector, phrase), "Mute command: \(phrase)")
            expect(!muteCommand(&detector, phrase, at: 2), "One toggle per occurrence")
        }
        for mention in ["when I say mute chat", "the silent chat command", "silence chat is the phrase",
                        "please don't mute chat", "do not silence chat", "unmute chat", "mute", "chat"] {
            var detector = StandaloneWake(requiredPause: 0.6)
            expect(!muteCommand(&detector, mention), "Do not toggle for mention or incomplete command: \(mention)")
        }
        var revisedMute = StandaloneWake(requiredPause: 0.6)
        expect(muteCommand(&revisedMute, "mute chat"), "First command toggles")
        expect(!muteCommand(&revisedMute, "MUTE CHAT", at: 2), "A revised alias must not toggle again")
        expect(muteCommand(&revisedMute, "MUTE CHAT. mute chat", at: 3), "A later new command toggles again")
        revisedMute.resetContext()
        expect(muteCommand(&revisedMute, "mute chat", at: 4), "New recognition context accepts a new command")
        var instantWake = StandaloneWake()
        instantWake.audio(level: 0.2, seconds: 0.1)
        instantWake.update("hello chat", at: 1, timings: [("hello", 1, 1), ("chat", 1, 1)])
        expect(instantWake.poll(at: 1, phrase: "Hello Chat", similar: true), "Fallback instant can accept a fresh command")
        instantWake.update("hello chad", at: 2, timings: [("hello", 1, 1), ("chad", 2, 2)])
        expect(!instantWake.poll(at: 2, phrase: "Hello Chat", similar: true), "A zero-duration consumed phrase cannot replay when its last word is corrected")
        var cancelledInstant = StandaloneWake()
        cancelledInstant.audio(level: 0.2, seconds: 0.1)
        cancelledInstant.update("hello chat mute chat", at: 1, timings: [("hello", 1, 1), ("chat", 1, 1), ("mute", 1, 1), ("chat", 1, 1)])
        cancelledInstant.cancelPending(phrase: "Hello Chat", endPhrase: "Mute Chat", similar: true)
        cancelledInstant.update("hello chad mute chat", at: 2, timings: [("hello", 1, 1), ("chad", 2, 2), ("mute", 1, 1), ("chat", 1, 1)])
        expect(!cancelledInstant.poll(at: 2, phrase: "Hello Chat", similar: true), "A cancelled instantaneous wake remains consumed after a correction")
        var precedingWake = StandaloneWake(requiredPause: 0.6)
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
        var separatedMute = StandaloneWake(requiredPause: 0.6)
        separatedMute.audio(level: 0.2, seconds: 0.1)
        separatedMute.update("mute chat", at: 20, timings: [("mute", 0, 0.2), ("chat", 19, 19.3)])
        expect(!separatedMute.poll(at: 20, phrase: "mute chat", similar: false), "Old separated words cannot toggle")
        var timed = StandaloneWake(requiredPause: 0.6)
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
            var detector = StandaloneWake(requiredPause: 0.6)
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 0.8)
            expect(detector.poll(at: 1.6, phrase: phrase, similar: similar) == expected, text)
            expect(!detector.poll(at: 2, phrase: phrase, similar: similar), "Do not replay: \(text)")
        }
        for text in ["Hello Chat", "HelloChat", "Hello Chad", "Okay hello chat", "I stopped the video hello chat",
                     "That was a long sentence. Hello Chat", "That was a long sentence hello chat",
                     "He said that was all. Hello Chat", "hello chance", "hello charts"] {
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
        for text in ["Hallo Chat", "Hallo Chad", "Yellow Chat", "H E L L O C H A T"] { check(text, expected: true) }
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
        check("Hello cat", expected: true)
        for text in ["Hello that", "Hello shat", "Hey Chat", "hey chat can you help"] { check(text, expected: false) }
        for text in ["the hallo chad detection", "I said yellow chat", "the hello cat app",
                     "I said as well chat", "as well chat detection", "that as well. Chat what next", "help chat"] {
            check(text, expected: false)
        }
        check("Computer Listen can you help me", expected: false, phrase: "Computer Listen")
        check("High At", expected: true, phrase: "High At", similar: false)
        check("it's too high at low speed. Hello Chat", expected: true)
        var detector = StandaloneWake(requiredPause: 0.6)
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
            var pending = StandaloneWake(requiredPause: 0.6)
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
            var laterWords = StandaloneWake(requiredPause: 0.6)
            laterWords.audio(level: 0.2, seconds: 2)
            laterWords.update("hello chat continue", at: 999, timings: [("hello", 0, 0.2), ("chat", 0.2, 0.4), ("continue", 0.4 + gap, 1.4 + gap)])
            expect(laterWords.poll(at: 999, phrase: "Hello Chat", similar: true) == (gap >= 0.6), "Only the audio timestamp gap permits following words")
        }
        var customMute = StandaloneWake(requiredPause: 0.6)
        customMute.audio(level: 0.2, seconds: 0.1)
        customMute.update("Quiet Lantern", at: 1)
        customMute.audio(level: 0, seconds: 0.6)
        expect(customMute.pollMicrophone(at: 2, phrases: ["Quiet Lantern"], similar: true), "Saved microphone phrases use the same pause gate")
        var ambient = StandaloneWake(requiredPause: 0.6)
        ambient.audio(level: 0.08, seconds: 0.1, at: 1.0)
        ambient.update("hello chat", at: 500, timings: [("hello", 0.2, 0.4), ("chat", 0.4, 0.6)])
        expect(!ambient.poll(at: 500, phrase: "Hello Chat", similar: true), "A delayed callback cannot manufacture a speech gap")
        ambient.audio(level: 0.08, seconds: 0.19, at: 1.19)
        expect(!ambient.poll(at: 501, phrase: "Hello Chat", similar: true), "Ambient noise does not shorten the 600 ms word-time gap")
        ambient.audio(level: 0.08, seconds: 0.01, at: 1.2)
        expect(ambient.poll(at: 502, phrase: "Hello Chat", similar: true), "Ambient noise cannot block a timestamped speech pause")
        var continuing = StandaloneWake(requiredPause: 0.6)
        continuing.audio(level: 0.08, seconds: 2, at: 2)
        continuing.update("hello chat continue", at: 500, timings: [("hello", 0.2, 0.4), ("chat", 0.4, 0.6), ("continue", 0.7, 1.0)])
        expect(!continuing.poll(at: 500, phrase: "Hello Chat", similar: true), "Continuing speech with a short gap stays inert even after a later pause")
        var microphoneAlias = StandaloneWake(requiredPause: 0.6)
        microphoneAlias.audio(level: 0.08, seconds: 0.1, at: 1.2)
        microphoneAlias.update("mute chad", at: 5, timings: [("mute", 0.2, 0.4), ("chad", 0.4, 0.6)])
        expect(microphoneAlias.pollMicrophone(at: 5, similar: true), "The narrow microphone dictionary uses the same timestamp pause")
        let started = Date()
        for _ in 0..<100_000 { precondition(!poll(4), "Idle frames do not repeat a wake") }
        print("Context-aware wake: \(checks) checks passed; 100000 idle polls in \(Date().timeIntervalSince(started))s")
    }
}
