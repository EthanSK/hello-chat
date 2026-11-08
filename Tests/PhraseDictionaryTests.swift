// Regression tests for the default-only dictionaries shared by detection and transcript styling.
import Foundation

@main enum PhraseDictionaryTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let alias = "custom lantern"
        for slot in PhraseSlot.allCases {
            let key = PhraseMatcher.words(slot.defaultText).joined()
            let dictionaries = PhraseDictionaries([key: [alias]])
            let pattern = PhrasePattern(slot: slot, text: slot.defaultText, similar: true, dictionaries: dictionaries)
            check(pattern.matches(in: PhraseMatcher.words(alias)).count == 1, "Override works in every slot")
            check(pattern.kind(for: alias) == .dictionary, "Override is marked as dictionary")
            check(pattern.matches(in: PhraseMatcher.words(slot.defaultText)).count == 1, "Default phrase always remains")
            check(PhraseMatcher.knownSpellings(for: slot.defaultText, similar: true, ending: slot.ending, dictionaries: dictionaries) == [slot.defaultText, alias], "Displayed spellings agree")
            check(!PhraseMatcher.hasOpenEndedWakeVariants(slot.defaultText, similar: true, ending: slot.ending, dictionaries: dictionaries), "Overrides disable generated open-ended matching")
            for spelling in PhraseMatcher.knownSpellings(for: slot.defaultText, similar: true, ending: slot.ending).dropFirst().prefix(8) {
                check(pattern.matches(in: PhraseMatcher.words(spelling)).isEmpty, "Override replaces the built-in dictionary")
            }
            let off = PhrasePattern(slot: slot, text: slot.defaultText, similar: false, dictionaries: dictionaries)
            check(off.matches(in: PhraseMatcher.words(alias)).isEmpty, "Global off disables overrides")
            let empty = PhrasePattern(slot: slot, text: slot.defaultText, similar: true, dictionaries: PhraseDictionaries([key: []]))
            check(empty.matches(in: PhraseMatcher.words(alias)).isEmpty, "Blank dictionary means only the base phrase")
            let edited = PhrasePattern(slot: slot, text: "New Lantern", similar: true, dictionaries: dictionaries)
            check(edited.matches(in: ["new", "lantern"]).count == 1 && edited.matches(in: ["new", "lanter"]).isEmpty, "Custom words match exactly")
            check(edited.matches(in: PhraseMatcher.words(alias)).isEmpty, "Stored dictionary stays dormant for custom words")
            let otherDefault = slot == .mutePhrase ? PhraseSlot.unsilencePhrase : .mutePhrase
            let otherText = otherDefault.defaultText
            let moved = PhrasePattern(slot: slot, text: otherText, similar: true, dictionaries: .init([PhraseMatcher.words(otherText).joined(): [alias]]))
            check(moved.matches(in: PhraseMatcher.words(alias)).isEmpty, "Another slot's default stays custom here")
            let highlighted = PhraseHighlights.runs(in: "Custom lantern. \(slot.defaultText).", phrase: "", similar: true, patterns: [pattern])
            check(highlighted.filter { $0.kind != nil }.count == 2, "Detection and highlighting share patterns")
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(alias, at: 1)
            check(detector.poll(at: 1, phrase: pattern.text, similar: true, rejectNegated: true, ending: slot.ending, patterns: [pattern]), "Explicit dictionary detection has no added pause")
            check(!detector.poll(at: 2, phrase: pattern.text, similar: true, rejectNegated: true, ending: slot.ending, patterns: [pattern]), "One occurrence is consumed once")
            var mention = StandaloneWake()
            mention.audio(level: 0.2, seconds: 0.1); mention.update("I said custom lantern", at: 1)
            check(!mention.poll(at: 1, phrase: pattern.text, similar: true, rejectNegated: true, patterns: [pattern]), "Dictionary does not bypass mention filtering")
            var negated = StandaloneWake()
            negated.audio(level: 0.2, seconds: 0.1); negated.update("Do not custom lantern", at: 1)
            check(!negated.poll(at: 1, phrase: pattern.text, similar: true, rejectNegated: true, patterns: [pattern]), "Dictionary does not bypass negation")
        }
        let wake = PhrasePattern(slot: .wakePhrase, text: "Hello Chat", similar: true, dictionaries: .init(["hellochat": ["open lantern"]]))
        let end = PhrasePattern(slot: .sleepPhrase, text: "Bye Chat", similar: true, dictionaries: .init(["byechat": ["close lantern"]]))
        var cancelled = StandaloneWake()
        cancelled.audio(level: 0.2, seconds: 0.1); cancelled.update("Open lantern. Close lantern.", at: 1)
        cancelled.cancelPending(patterns: [wake], endPattern: end)
        check(!cancelled.poll(at: 1, phrase: wake.text, similar: true, patterns: [wake]), "End override consumes a preceding wake override")
        let sharedAlias = PhraseDictionaries(["silentchat": ["lamp"], "silencechat": ["lamp"], "byechat": ["close"]])
        let speakers = [PhrasePattern(slot: .silentPhrase, text: "Silent Chat", similar: true, dictionaries: sharedAlias),
                        PhrasePattern(slot: .silencePhrase, text: "Silence Chat", similar: true, dictionaries: sharedAlias)]
        var duplicate = StandaloneWake()
        duplicate.audio(level: 0.2, seconds: 0.1); duplicate.update("lamp close", at: 1)
        duplicate.cancelPending(patterns: speakers, endPattern: .init(slot: .sleepPhrase, text: "Bye Chat", similar: true, dictionaries: sharedAlias))
        duplicate.update("lamp close lamp", at: 2)
        check(duplicate.poll(at: 2, phrase: "Silent Chat", similar: true, patterns: speakers), "Shared-action aliases use the same occurrence count after End")
        check(try PhraseDictionary.parse("  Orange Lantern \r\norange-lantern\n\nBlue Lantern") == ["Orange Lantern", "Blue Lantern"], "Input trims, normalizes CRLF, removes duplicates, preserves spelling")
        check(try PhraseDictionary.parse("") == [], "Empty dictionary is explicit exact-only")
        for invalid in ["!!!", "A\0B", String(repeating: "a", count: 121), String(repeating: "a", count: PhraseDictionary.maximumBytes + 1)] {
            do { _ = try PhraseDictionary.parse(invalid); preconditionFailure("Invalid dictionary accepted") }
            catch { checks += 1 }
        }
        for slot in PhraseSlot.allCases {
            for other in PhraseSlot.allCases where other != slot {
                let sameAction = Set([slot, other]) == Set([.silentPhrase, .silencePhrase])
                do {
                    _ = try PhraseDictionary.parse(other.defaultText, for: slot)
                    check(sameAction, "Other built-in commands cannot become an opposite dictionary alias")
                } catch { check(!sameAction, "Silent/Silence retain their shared action") }
            }
        }
        do { _ = try PhraseDictionary.parse("Valid\r\n!!!") ; preconditionFailure("Invalid CRLF line accepted") }
        catch PhraseDictionary.ValidationError.invalidLine(let line) { check(line == 2, "CRLF reports physical line numbers") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("dictionary.txt")
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        do { _ = try PhraseDictionary.read(file); preconditionFailure("Non-UTF8 accepted") } catch { checks += 1 }
        try Data("\u{feff}Orange Lantern\nBlue Lantern".utf8).write(to: file)
        check(try PhraseDictionary.read(file) == ["Orange Lantern", "Blue Lantern"], "UTF8 BOM imports")
        let suite = "HChatDictionaryTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for slot in PhraseSlot.allCases {
            check(slot.savedValue(in: defaults) == slot.defaultText, "Defaults use consistent capitalization")
            defaults.set("my CuSTom phrase", forKey: slot.rawValue)
            check(slot.savedValue(in: defaults) == "my CuSTom phrase", "Custom saved text is preserved verbatim")
        }
        print("Passed \(checks) phrase dictionary checks")
    }
}
