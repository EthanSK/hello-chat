// Extra phrases per section (Ethan, 14 November 2026): + rows and slash entry share one store, and
// every listed phrase reaches the same detector, occurrence count, sound section and startup capture.
// Pure inputs and a disposable defaults suite only: no microphone, Voice call or key event.
import Foundation

@main enum PhraseListTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }

        let suite = "HelloChat-PhraseDefaults-\(UUID().uuidString)"
        let savedDefaults = UserDefaults(suiteName: suite)!
        defer { savedDefaults.removePersistentDomain(forName: suite) }
        savedDefaults.set(["switchAppPhrase": ["Jump to"], "openAppPhrase": ["Launch app"], "futurePhrase": ["Keep me"]], forKey: PhraseList.defaultsKey)
        PhraseList.seedDefaults(in: savedDefaults)
        var seeded = PhraseList.decode(savedDefaults.object(forKey: PhraseList.defaultsKey))
        check(seeded[.wakePhrase] == ["Hey Chat"] && seeded[.sleepPhrase] == ["Goodbye Chat"], "New default wake and End rows are editable saved rows")
        check(seeded[.switchAppPhrase] == ["Jump to", "Switch up", "Switch to", "Switch"] && seeded[.openAppPhrase] == ["Launch app"], "Both app families' saved custom rows survive")
        for (slot, text) in [(PhraseSlot.wakePhrase, "Hey Chat"), (.sleepPhrase, "Goodbye Chat")] {
            let patterns = ([slot.defaultText] + (seeded[slot] ?? [])).map { PhrasePattern(slot: slot, text: $0, similar: false, dictionaries: .init()) }
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            check(detector.poll(at: 1, phrase: slot.defaultText, similar: false, rejectNegated: true, ending: slot.ending, patterns: patterns), "New default row works even with alternate spellings off")
            check(!detector.poll(at: 2, phrase: slot.defaultText, similar: false, ending: slot.ending, patterns: patterns), "New default row cannot replay")
            detector.reset(); detector.audio(level: 0.2, seconds: 0.1); detector.update("I said " + text, at: 1)
            check(!detector.poll(at: 1, phrase: slot.defaultText, similar: false, rejectNegated: true, ending: slot.ending, patterns: patterns), "New default row preserves the mention guard")
        }
        check((savedDefaults.dictionary(forKey: PhraseList.defaultsKey)?["futurePhrase"] as? [String]) == ["Keep me"], "Future-build preferences survive seeding")
        seeded[.wakePhrase] = nil
        savedDefaults.set(PhraseList.encode(seeded, preserving: savedDefaults.object(forKey: PhraseList.defaultsKey)), forKey: PhraseList.defaultsKey)
        PhraseList.seedDefaults(in: savedDefaults)
        check(PhraseList.decode(savedDefaults.object(forKey: PhraseList.defaultsKey))[.wakePhrase] == nil, "Removing a seeded row is respected on later launches")
        savedDefaults.removePersistentDomain(forName: suite)
        savedDefaults.set("Listen Lantern", forKey: "wakePhrase")
        savedDefaults.set("Goodnight Lantern", forKey: "sleepPhrase")
        savedDefaults.set("Jump to", forKey: "switchAppPhrase")
        PhraseList.seedDefaults(in: savedDefaults)
        check(PhraseList.decode(savedDefaults.object(forKey: PhraseList.defaultsKey)).isEmpty, "Custom primary phrases don't silently gain the new defaults")
        check(savedDefaults.string(forKey: "wakePhrase") == "Listen Lantern" && savedDefaults.string(forKey: "switchAppPhrase") == "Jump to", "Custom main text is untouched")
        let groups = PhraseSlot.fieldGroups(PhraseSlot.desktopSlots)
        check(groups == [[.switchAppPhrase, .openAppPhrase], [.zoomInPhrase], [.zoomOutPhrase]], "One app setting includes both legacy fields without duplicating or losing rows")

        // Slash entry: trimmed pieces, empty pieces ignored, applied only at submit or focus loss.
        check(PhraseList.pieces("Open app / Switch app") == ["Open app", "Switch app"], "Typed example becomes two phrases")
        check(PhraseList.pieces(" / Zoom in //  Bigger /") == ["Zoom in", "Bigger"], "Spaces and empty pieces are ignored")
        check(PhraseList.commit("Hello Chat", others: []) == nil, "Ordinary editing is never rewritten")
        check(PhraseList.commit("Open app / Switch app", others: [])! == ("Open app", ["Switch app"]), "First piece stays in the row")
        check(PhraseList.commit("Hello chat / Hey Lantern / hello-chat / Bye Chat", others: ["hey lantern", "Bye Chat"])! == ("Hello chat", []),
              "Pieces already listed, or repeated, aren't added twice")
        check(PhraseList.commit("/ Switch app", others: [])! == ("Switch app", []) && PhraseList.commit("/", others: [])! == ("", []),
              "A leading or lone slash leaves no empty phrase")
        check(PhraseList.commit("Zoom in / !!! / Bigger", others: [])! == ("Zoom in", ["Bigger"]), "A piece without letters or numbers is ignored")

        // Rows: pieces land directly below the row they were typed in; existing rows keep their place and identity.
        let launch = PhraseRow("Launch app"), sized = PhraseRow("Bigger / Larger"), huge = PhraseRow("Huge")
        let fromMain = PhraseList.commit(main: "Open app / Switch app", rows: [launch], at: nil)
        check(fromMain.main == "Open app" && fromMain.rows.map(\.text) == ["Switch app", "Launch app"] && fromMain.rows[1].id == launch.id,
              "Main row: first piece stays, the rest go directly below it")
        let fromRow = PhraseList.commit(main: "Zoom in", rows: [sized, huge], at: 0)
        check(fromRow.main == "Zoom in" && fromRow.rows.map(\.text) == ["Bigger", "Larger", "Huge"] && fromRow.rows[0].id == sized.id
              && fromRow.rows[2].id == huge.id, "Extra row: first piece stays in that row, the rest follow it")
        let plain = PhraseList.commit(main: "Zoom in", rows: [huge], at: 0)
        check(plain.main == "Zoom in" && plain.rows == [huge], "Without a slash nothing changes")
        let repeated = PhraseList.commit(main: "Zoom in", rows: [PhraseRow("zoom in / Huge"), huge], at: 0)
        check(repeated.rows.map(\.text) == ["zoom in", "Huge"], "A typed repeat stays visible for its note; a listed piece isn't added again")
        let blank = PhraseRow(" "), symbols = PhraseRow("!!!"), slashOnly = PhraseRow(" / ")
        check(PhraseList.commit(main: "Zoom in", rows: [blank, huge], at: 0).rows == [huge]
              && PhraseList.commit(main: "Zoom in", rows: [symbols], at: 0).rows.isEmpty
              && PhraseList.commit(main: "Zoom in", rows: [slashOnly], at: 0).rows.isEmpty, "An extra row left without a phrase is removed")
        check(PhraseList.commit(main: "", rows: [huge], at: nil) == ("", [huge]) && PhraseList.commit(main: " / ", rows: [], at: nil) == ("", []),
              "The main row is never removed")

        // One store: blank rows aren't saved, another build's keys are kept, unknown sections are ignored.
        let saved: [String: [String]] = ["wakePhrase": ["Hey Lantern"], "futurePhrase": ["Keep me"]]
        check(PhraseList.decode(saved) == [.wakePhrase: ["Hey Lantern"]] && PhraseList.decode(nil).isEmpty
              && PhraseList.decode(["wakePhrase": 3]).isEmpty, "Saved rows load by section")
        let encoded = PhraseList.encode([.wakePhrase: ["Hey Lantern", " ", ""], .zoomInPhrase: [""], .openAppPhrase: ["Launch app"]], preserving: saved)
        check(encoded == ["wakePhrase": ["Hey Lantern"], "openAppPhrase": ["Launch app"], "futurePhrase": ["Keep me"]],
              "Blank rows stay out of the saved list")
        check(PhraseList.decode(encoded) == [.wakePhrase: ["Hey Lantern"], .openAppPhrase: ["Launch app"]], "Round trip")

        // Configuration: main phrases first, then extra rows, in section order.
        func rows(_ extra: [PhraseSlot: [String]] = [:], main: [PhraseSlot: String] = [:]) -> PhraseConfiguration {
            PhraseConfiguration(rows: Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map {
                ($0, [main[$0] ?? $0.defaultText] + (extra[$0] ?? []))
            }))
        }
        let defaults = rows()
        check(PhraseSlot.allCases.allSatisfy { defaults.phrases(for: $0) == [$0.defaultText] } && defaults.issues.isEmpty,
              "Defaults are unchanged and have no issues")
        check(defaults.allPhrases == PhraseSlot.allCases.map(\.defaultText), "Recognizer hints keep the earlier order")
        let extras = rows([.wakePhrase: ["Hey Lantern", ""], .zoomInPhrase: ["Bigger"]])
        check(extras.phrases(for: .wakePhrase) == ["Hello Chat", "Hey Lantern"] && extras.phrases(for: .zoomInPhrase) == ["Zoom in", "Bigger"],
              "Extra rows join their section; blank rows are ignored")
        let endTakesWake = rows([.sleepPhrase: ["hello-chat"]])
        check(endTakesWake.issue(.sleepPhrase, row: 1) == .conflict(.wakePhrase) && endTakesWake.phrases(for: .sleepPhrase) == ["Bye Chat"]
              && endTakesWake.phrases(for: .wakePhrase) == ["Hello Chat"], "A new End row can't take over the wake phrase")
        let wakeTakesEnd = rows([.wakePhrase: ["ByeChat"]])
        check(wakeTakesEnd.issue(.wakePhrase, row: 1) == .conflict(.sleepPhrase) && wakeTakesEnd.phrases(for: .sleepPhrase) == ["Bye Chat"],
              "An extra row never beats another section's main phrase, even earlier in the list")
        let samePrimary = rows(main: [.wakePhrase: "Bye Chat"])
        check(samePrimary.issue(.sleepPhrase, row: 0) == .conflict(.wakePhrase) && samePrimary.phrases(for: .sleepPhrase).isEmpty,
              "Matching main phrases keep the earlier rule: End is off until they differ")
        let extraClash = rows([.mutePhrase: ["Hush"], .unmutePhrase: ["hush"]])
        check(extraClash.issue(.unmutePhrase, row: 1) == .conflict(.mutePhrase) && extraClash.phrases(for: .unmutePhrase) == ["Unmute Chat"],
              "Opposite commands never share a phrase")
        let shared = rows([.silencePhrase: ["Silent chat"], .switchAppPhrase: ["Open app"], .wakePhrase: ["Hello chat"]])
        check(shared.issue(.silencePhrase, row: 1) == .duplicate(.silentPhrase) && shared.issue(.switchAppPhrase, row: 1) == .duplicate(.openAppPhrase)
              && shared.issue(.wakePhrase, row: 1) == .duplicate(.wakePhrase), "A repeat for the same action is redundant, not a conflict")
        check(shared.phrases(for: .silencePhrase) == ["Silence Chat"] && shared.phrases(for: .openAppPhrase) == ["Open app"],
              "The first section keeps a shared phrase, and its sound")
        check(PhraseSlot.switchAppPhrase.action == .app && PhraseSlot.openAppPhrase.action == .app
              && PhraseAction.app.slots == [.switchAppPhrase, .openAppPhrase] && PhraseAction.silenceSpeakers.slots == [.silentPhrase, .silencePhrase],
              "Switch app and Open app are one action, as Silent and Silence are")

        // Routing: listed phrases share a detector and its occurrence count.
        let hello = PhrasePattern(slot: .wakePhrase, text: "Hello Chat", similar: true, dictionaries: .init())
        let lantern = PhrasePattern(slot: .wakePhrase, text: "Hey Lantern", similar: true, dictionaries: .init())
        check(!lantern.similar && hello.similar, "Only the default phrase uses alternate spellings")
        func wakes(_ text: String) -> Bool {
            var wake = StandaloneWake()
            wake.audio(level: 0.2, seconds: 0.1); wake.update(text, at: 1)
            return wake.poll(at: 1, phrase: hello.text, similar: true, patterns: [hello, lantern])
        }
        check(wakes("Hey Lantern") && wakes("Hello chat") && !wakes("I said hey lantern") && !wakes("Hey lanterns"),
              "An extra wake phrase wakes exactly, with the usual mention rule")
        var once = StandaloneWake()
        once.audio(level: 0.2, seconds: 0.1); once.update("Hey Lantern", at: 1)
        check(once.poll(at: 1, phrase: hello.text, similar: true, patterns: [hello, lantern]), "Extra wake acts")
        once.update("Hello chat", at: 2)
        check(!once.poll(at: 2, phrase: hello.text, similar: true, patterns: [hello, lantern]), "A revision to another wake phrase doesn't wake twice")

        let bye = PhrasePattern(slot: .sleepPhrase, text: "Bye Chat", similar: true, dictionaries: .init())
        let goodnight = PhrasePattern(slot: .sleepPhrase, text: "Goodnight Chat", similar: true, dictionaries: .init())
        func ends(_ text: String) -> Bool {
            var end = StandaloneWake()
            end.audio(level: 0.2, seconds: 0.1); end.update(text, at: 1)
            return end.poll(at: 1, phrase: bye.text, similar: true, rejectNegated: true, ending: true, patterns: [bye, goodnight])
        }
        check(goodnight.ending && ends("Goodnight chat") && !ends("Don't goodnight chat") && !ends("The goodnight chat phrase"),
              "An extra End phrase keeps End's negation and mention rules")
        var consumed = StandaloneWake()
        consumed.audio(level: 0.2, seconds: 0.1); consumed.update("Hello chat. Goodnight chat.", at: 1)
        consumed.cancelPending(patterns: [hello, lantern], endPatterns: [bye, goodnight])
        check(!consumed.poll(at: 1, phrase: hello.text, similar: true, patterns: [hello, lantern]), "An extra End phrase consumes earlier wakes")

        // Audio actions: the matched pattern's index picks its section's sound.
        let silent = PhrasePattern(slot: .silentPhrase, text: "Silent Chat", similar: true, dictionaries: .init())
        let silence = PhrasePattern(slot: .silencePhrase, text: "Silence Chat", similar: true, dictionaries: .init())
        let hush = PhrasePattern(slot: .silencePhrase, text: "Hush Chat", similar: true, dictionaries: .init())
        var speakers = StandaloneWake()
        speakers.audio(level: 0.2, seconds: 0.1); speakers.update("Hush chat", at: 1)
        check(speakers.poll(at: 1, phrase: silent.text, similar: true, rejectNegated: true, patterns: [silent, silence, hush])
              && speakers.acceptedPatternIndex == 2, "An extra audio phrase identifies its own section")
        speakers.update("Silent chat", at: 2)
        check(!speakers.poll(at: 2, phrase: silent.text, similar: true, rejectNegated: true, patterns: [silent, silence, hush]),
              "One spoken occurrence toggles once across the action's phrases")

        // Startup capture anchors on any listed wake phrase, and repeats of either aren't the opening.
        var opening = StartupSpeechBuffer(id: UUID(), text: "Hey Lantern, what time is it?", wakeRange: 0..<2, patterns: [hello, lantern])
        check(opening.alignment == .wake && opening.text == "what time is it?" && opening.hasOpeningWords, "Extra wake anchors the opening")
        opening.observe("Hey Lantern. Hello chat.")
        check(!opening.hasOpeningWords, "Repeating mixed wake phrases is still only a wake")
        var mainOnly = StartupSpeechBuffer(id: UUID(), text: "Hello chat. Hey Lantern.", wakeRange: 0..<2, pattern: hello)
        check(mainOnly.hasOpeningWords, "Without the extra phrase, its words would count as the opening")
        mainOnly.observe("Hello chat.")
        check(!mainOnly.hasOpeningWords, "Main phrase behavior is unchanged")

        print("Passed \(checks) phrase list checks")
    }
}
