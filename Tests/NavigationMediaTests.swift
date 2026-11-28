// Verify actual native event objects and injected submission; never post events to the user’s apps. — GPT-6.1 Sol
import AppKit
import ApplicationServices
import Foundation

@main enum NavigationMediaTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        check(PhraseSlot.nextTrackPhrase.settingsTitle == "Next track", "Next Track has its own Home title")
        let play = MediaPlayPauseShortcut.events()!.map { NSEvent(cgEvent: $0)! }
        let next = MediaPlayPauseShortcut.nextTrackEvents()!.map { NSEvent(cgEvent: $0)! }
        check(play.count == 2 && play[0].data1 >> 16 == 16 && play[1].data1 >> 16 == 16, "Existing Play/Pause stays16")
        check(next.count == 2 && next[0].data1 >> 16 == 17 && next[1].data1 >> 16 == 17, "Next Track is17, never Fast Forward19")
        check((next[0].data1 >> 8) & 0xff == 0x0A && (next[1].data1 >> 8) & 0xff == 0x0B, "One immediate key down/up pair")
        var mediaPosts = 0
        var media = MediaPlayPauseShortcut(session: { .interactive }, accessibilityTrusted: { true },
            makeEvents: MediaPlayPauseShortcut.nextTrackEvents, post: { mediaPosts += $0.count })
        if case .failure = media.perform() { fatalError("Expected injected submit") }
        check(mediaPosts == 2, "Exactly two events, no repeat or sleep")
        media.accessibilityTrusted = { false }; _ = media.perform()
        check(mediaPosts == 2, "Permission refusal posts nothing")
        for direction in HistoryNavigation.Direction.allCases {
            let events = HistoryNavigation.events(direction)!
            check(events.map(\.type) == [.otherMouseDown, .otherMouseUp], "Ordinary auxiliary mouse button pair")
            check(events.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(direction.button) }, "Back3/Forward4 native buttons")
            check(events[0].location == events[1].location, "Cursor position is preserved")
            var posts: [pid_t] = []
            var action = HistoryNavigation(session: { .interactive }, trusted: { true }, frontmost: { 42 }, makeEvents: { _ in events }, post: { pair, pid in
                precondition(pair.count == 2); posts.append(pid)
            })
            check(action.perform(direction, expectedPID: 42) && posts == [42], "Submit only to the exact active process")
            check(!action.perform(direction, expectedPID: 43) && posts == [42], "A focus change cannot retarget a repeat")
            action.trusted = { false }; check(!action.perform(direction, expectedPID: 42), "No Accessibility grant means no input")
        }
        for slot in [PhraseSlot.nextTrackPhrase, .backPhrase, .forwardPhrase] {
            let config = PhraseConfiguration(rows: [slot: [slot.defaultText]])
            let pattern = PhrasePattern(slot: slot, text: slot.defaultText, similar: true,
                dictionaries: PhraseDictionaries(savedByTrigger: [:], active: config))
            for text in [slot.defaultText] + slot.stockSpellings(for: slot.defaultText) {
                var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
                check(detector.poll(at: 1, phrase: pattern.text, similar: true, rejectNegated: true, patterns: [pattern], directOnly: true), "Shipped navigation/media form: " + text)
                check(!detector.poll(at: 2, phrase: pattern.text, similar: true, rejectNegated: true, patterns: [pattern], directOnly: true), "One admitted occurrence")
            }
            for text in ["Don't " + slot.defaultText, "I said " + slot.defaultText, "The command " + slot.defaultText, slot.defaultText + " tomorrow"] {
                var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
                check(!detector.poll(at: 1, phrase: pattern.text, similar: true, rejectNegated: true, patterns: [pattern], directOnly: true), "Mention/negation/future control cannot dispatch")
            }
        }
        let navConfig = PhraseConfiguration(rows: [.backPhrase: ["Back"], .forwardPhrase: ["Forward"]])
        let navDictionary = PhraseDictionaries(savedByTrigger: [:], active: navConfig)
        let navPatterns = [PhraseSlot.backPhrase, .forwardPhrase].map {
            PhrasePattern(slot: $0, text: $0.defaultText, similar: true, dictionaries: navDictionary)
        }
        var speaker = SpeakerOutputSettings(); speaker.destinations = [.init(names: "Kitchen", output: "Fixture")]
        check(speaker.conflictingPhrase(with: navPatterns) == nil, "Back cannot disable existing Switch back speaker routes")
        for prefix in ["Back", "Please go back", "Forward"] {
            speaker.prefixes = prefix
            check(speaker.conflictingPhrase(with: navPatterns) != nil, "A genuine navigation prefix remains a conflict")
        }
        let suite = "HChatHeadsetDefault-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let seeded = SpeakerOutputSettings().addingHeadsetDefault(in: defaults, avoiding: [])!
        check(seeded.receiptTarget("headset") == "jlab go work pop" && seeded.receiptTarget("headphones") == "jlab go work pop", "Headset is a shipped default")
        var deleted = seeded; deleted.destinations = []
        check(deleted.addingHeadsetDefault(in: defaults, avoiding: []) == nil, "A later deletion stays effective")
        defaults.removePersistentDomain(forName: suite)
        var custom = SpeakerOutputSettings(); custom.destinations = [.init(names: "Headset", output: "User’s other headset")]
        let merged = custom.addingHeadsetDefault(in: defaults, avoiding: []) ?? custom
        check(merged.receiptTarget("Headset") == "user’s other headset" && merged.destinations.first == custom.destinations.first, "Saved personal routing wins")
        print("Passed \(checks) native navigation, Next Track and shipped-default checks; no event posted")
    }
}
