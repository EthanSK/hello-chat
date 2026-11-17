// Exercise speaker command configuration and recognition without changing system audio.
import Foundation

@main struct SpeakerOutputTests {
    static func main() {
        var settings = SpeakerOutputSettings()
        settings.destinations = [SpeakerDestination(names: "kitchen\nkitchen speakers", output: "Soundcore"),
                                 SpeakerDestination(names: "computer\nthis computer", output: "Scarlett"),
                                 SpeakerDestination(names: "Bose", output: "Bose")]
        precondition(settings.issue == nil)
        let defaults = PhraseSlot.allCases.filter { $0 != .switchAppPhrase && $0 != .openAppPhrase }
            .map { PhrasePattern(slot: $0, text: $0.defaultText, similar: true, dictionaries: .init()) }
        precondition(settings.conflictingPhrase(with: defaults) == nil, "Default speaker commands coexist with built-in Voice and media commands")
        let commands = settings.commands
        func detect(_ text: String) -> String? {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.2)
            detector.update(text, at: 1)
            guard let first = commands.first,
                  detector.poll(at: 1, phrase: first.pattern.text, similar: false, rejectNegated: true,
                                patterns: commands.map(\.pattern), directOnly: true),
                  let index = detector.acceptedPatternIndex else { return nil }
            precondition(!detector.poll(at: 2, phrase: first.pattern.text, similar: false, rejectNegated: true,
                                        patterns: commands.map(\.pattern), directOnly: true), "An occurrence must not replay")
            return commands[index].output
        }
        precondition(detect("switch speakers to kitchen") == "Soundcore")
        precondition(detect("change audio computer") == "Scarlett")
        precondition(detect("switch audio to Bose") == "Bose")
        precondition(detect("don't switch speakers to kitchen") == nil)
        precondition(detect("I said switch speakers to kitchen") == nil)
        precondition(detect("switch speakers to kitchen settings") == nil)
        let conflicting = [PhrasePattern(text: "switch audio to Bose", similar: false)]
        precondition(settings.conflictingPhrase(with: conflicting) != nil, "Existing commands keep ownership")
        let contained = [PhrasePattern(text: "audio to Bose", similar: false)]
        precondition(settings.conflictingPhrase(with: contained) != nil, "Contained commands must not fire alongside a speaker switch")
        var overlap = SpeakerOutputSettings(prefixes: "Switch\nSwitch audio", destinations: [
            SpeakerDestination(names: "audio", output: "First"), SpeakerDestination(names: "bose", output: "Second")])
        precondition(overlap.issue != nil, "A complete speaker phrase cannot prefix a different destination")
        overlap.destinations[0].names = "desk"
        precondition(overlap.issue == nil)
        settings.prefixes = "Route sound"
        precondition(settings.commands.contains { $0.pattern.text == "Route sound to kitchen" })
        settings.destinations.append(SpeakerDestination(names: "kitchen speaker", output: "Other"))
        precondition(settings.issue != nil && settings.commands.isEmpty, "Overlapping names must not choose different outputs")
        let suiteName = "HelloChatSpeakerTests." + UUID().uuidString
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        settings.save(to: isolatedDefaults)
        precondition(SpeakerOutputSettings.load(from: isolatedDefaults) == settings)
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        defer { try? FileManager.default.removeItem(at: fake) }
        try! "DEFAULT = 'Computer'\nFIRST = 'Kitchen'\nSECOND = 'Bose'\nBLUETOOTH_ADDRESSES = {FIRST: 'a', SECOND: 'b'}\nraise Exception('must not execute')\n".write(to: fake, atomically: true, encoding: .utf8)
        precondition(SpeakerOutput.available(helper: fake) == ["Bose", "Computer", "Kitchen"], "Device choices are read without executing the helper")
        try! "import json,sys\nprint(json.dumps({'status':'ok','output':sys.argv[-1], 'warnings':['Input kept']}))\n".write(to: fake, atomically: true, encoding: .utf8)
        precondition(SpeakerOutput.run("Example device", helper: fake) == "Switched speakers to Example device. Input kept")
        try! "import json,sys\nprint(json.dumps({'status':'failed','errors':['Output unavailable']})); sys.exit(1)\n".write(to: fake, atomically: true, encoding: .utf8)
        precondition(SpeakerOutput.run("Example device", helper: fake) == "Output unavailable")
        print("Speaker output configuration, recognition and helper results passed")
    }
}
