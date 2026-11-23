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
        func detect(_ text: String, pauseBefore prefix: String? = nil) -> String? {
            var detector = StandaloneWake(speakerRoute: true)
            detector.audio(level: 0.2, seconds: 0.2)
            let words = PhraseMatcher.words(text)
            let pause = prefix.flatMap { words.firstIndex(of: $0) } ?? words.endIndex
            let timings = words.enumerated().map { index, word in
                let time = Double(index) * 0.15 + (index >= pause ? 0.65 : 0)
                return (word: word, start: time, end: time + 0.12)
            }
            detector.update(text, at: 1, timings: timings)
            guard let first = commands.first,
                  detector.poll(at: 1, phrase: first.pattern.text, similar: false, rejectNegated: true,
                                patterns: commands.map(\.pattern), directOnly: true),
                  let index = detector.acceptedPatternIndex else { return nil }
            precondition(!detector.poll(at: 2, phrase: first.pattern.text, similar: false, rejectNegated: true,
                                        patterns: commands.map(\.pattern), directOnly: true), "An occurrence must not replay")
            return commands[index].output
        }
        precondition(detect("switch speakers") == nil, "A missing target must not change the output")
        precondition(detect("switch speakers computer") == "Scarlett")
        precondition(detect("double starting it now switch speakers computer", pauseBefore: "switch") == "Scarlett")
        for text in ["switch speakers kitchen", "switch speaker, kitchen", "switch audio kitchen",
                     "include vegetables also switch speaker kitchen check recent orders but switch audio kitchen",
                     "check recent orders but switch audio kitchen",
                     "switch back now to the kitchen speakers, I didn't ask for that",
                     "switch back to kitchen", "can you switch back to the kitchen speakers"] {
            precondition(detect(text) == "Soundcore", text)
        }
        for text in ["just recognize switch audio kitchen and it didn't switch", "I should be able to say switch speakers kitchen",
                     "I might also switch speaker kitchen", "don't also switch audio kitchen", "anything but switch speaker kitchen",
                     "also switch audio kitchen later", "I said also switch speakers kitchen"] {
            precondition(detect(text) == nil, text)
        }
        // In the observed microphone transcript, discussion ran into an actual saved phrase.
        // A short pause before the quote must not turn the end of the sentence into a command.
        for text in ["it's a separate case where switch speakers kitchen didn't",
                     "kitchen speakers I didn't ask for that oh it's cause you said it and it picked up L switch speakers computer",
                     "you said switch speakers computer"] {
            precondition(detect(text, pauseBefore: "switch") == nil, text)
        }
        for text in ["we fixed the previous issue switch speakers kitchen",
                     "that's what you said. Switch speakers kitchen"] {
            precondition(detect(text, pauseBefore: "switch") == "Soundcore", text)
        }
        for text in ["whoa it just switched back now to the kitchen speakers", "switch back",
                     "switch back to the unknown speaker", "don't switch back to the kitchen"] {
            precondition(detect(text) == nil, text)
        }
        // Replay the incident in the real opening buffer, speech detector, dispatch callback and
        // cross-process receipt format. Use a fixture for the only hardware-facing operation.
        let call = "01a2045e-2c3c-7663-8973-fb711cbff3b1:1798449c-9a4d-4f56-9e8b-53011287690c"
        let frame = UUID(uuidString: "01a2045e-5606-7e71-8388-60b4d9ab122b")!
        let stamp = 1795369620.998
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let helper = fixture.appendingPathComponent("route.py")
        try! "import json,sys\nprint(json.dumps({'status':'ok','output':sys.argv[-1],'input':'original mic','system':'original alerts','errors':[],'warnings':[]}))".write(to: helper, atomically: true, encoding: .utf8)
        let journal = SpokenCommandJournal(directory: fixture, now: { stamp + 2 })
        var capture = StartupSpeechBuffer(id: UUID(), text: "", wakeRange: nil, phrase: "Hello Chat", similar: true)
        _ = capture.markVoiceOpened()
        var opening = StandaloneWake(speakerRoute: true)
        var calls = 0
        func receipt(claim: Bool) -> String {
            try! journal.decide(action: "speakerOutput", target: "soundcore", session: call, frame: frame,
                                from: stamp - 5, through: stamp + 2, allowFallback: claim)
        }
        for text in ["Can you switch", "Can you switch speaker's kitchen", "Can you switch speakers kitchen"] {
            capture.observe(text)
            opening.audio(level: 0.2, seconds: 0.1)
            opening.update(text, at: 1)
            opening.dispatchSpeaker(at: 1, commands: commands) { output, _ in
                precondition(output == "Soundcore")
                guard case .run(let id) = try! journal.begin("speakerOutput", target: output.lowercased(), session: call, at: stamp - 3.5) else { fatalError() }
                precondition(receipt(claim: true) == "attempted")
                calls += 1
                let outcome = SpeakerOutput.run(output, helper: helper)
                journal.finish(id, outcome.verified ? .confirmed : .unknown)
            }
        }
        precondition(capture.voiceOpened && capture.hasOpeningWords && calls == 1)
        precondition(receipt(claim: true) == "confirmed")
        precondition(detect("switch speakers kitchen. switch speakers computer") == "Scarlett")
        precondition(settings.receiptTarget("KITCHEN") == "soundcore")
        precondition(settings.receiptTarget("Soundcore") == "soundcore")
        precondition(settings.receiptTarget("unknown") == nil)
        var queue = SpeakerOutputQueue()
        let ids = (0..<5).map { _ in UUID() }
        precondition(queue.enqueue("A", receipt: ids[0]).isEmpty)
        precondition(queue.enqueue("B", receipt: ids[1]).isEmpty)
        precondition(queue.enqueue("B", receipt: ids[2]).isEmpty)
        precondition(queue.enqueue("C", receipt: ids[3]) == [ids[1], ids[2]])
        precondition(queue.active?.output == "A" && queue.finished() == [ids[0]])
        precondition(queue.active?.output == "C")
        precondition(queue.enqueue("C", receipt: ids[4]).isEmpty)
        precondition(queue.finished() == [ids[3], ids[4]] && queue.active == nil)
        var streaming = StandaloneWake(speakerRoute: true)
        streaming.audio(level: 0.2, seconds: 0.2)
        func observe(_ text: String, at time: Double) -> Bool {
            streaming.update(text, at: time)
            return streaming.poll(at: time, phrase: commands[0].pattern.text, similar: false, rejectNegated: true,
                                  patterns: commands.map(\.pattern), directOnly: true)
        }
        precondition(observe("switch audio kitchen", at: 1))
        precondition(!observe("switch audio kitchen speakers", at: 2), "Extending a destination name must not dispatch it twice")
        precondition(observe("switch audio kitchen speakers. Switch audio computer", at: 3))
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
        var original = SpeakerOutputSettings(prefixes: "Switch speakers\nSwitch audio\nChange audio", destinations: settings.destinations.dropLast().map { $0 })
        let migrated = original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults)
        precondition(migrated?.prefixes == SpeakerOutputSettings.defaultPrefixes)
        precondition(migrated?.destinations == original.destinations)
        precondition(original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults) == nil, "A removed prefix stays removed")
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        let oldPrefixes = original.prefixes
        isolatedDefaults.set(true, forKey: "speakerSingularPrefix20261120")
        precondition(original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults) == nil, "Preserve a deleted singular prefix")
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        isolatedDefaults.set(true, forKey: "speakerSingularPrefix20261120")
        original.prefixes = oldPrefixes + "\nSwitch speaker"
        precondition(original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults)?.prefixes == SpeakerOutputSettings.defaultPrefixes)
        precondition(original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults) == nil, "Deleting Switch back after migration sticks")
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        original.prefixes = "Move audio"
        precondition(original.upgradingDefaultPrefixes(in: isolatedDefaults, avoiding: defaults) == nil, "Keep custom prefixes")
        settings.save(to: isolatedDefaults)
        precondition(SpeakerOutputSettings.load(from: isolatedDefaults) == settings)
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        defer { try? FileManager.default.removeItem(at: fake) }
        try! "DEFAULT = 'Computer'\nFIRST = 'Kitchen'\nSECOND = 'Bose'\nBLUETOOTH_ADDRESSES = {FIRST: 'a', SECOND: 'b'}\nraise Exception('must not execute')\n".write(to: fake, atomically: true, encoding: .utf8)
        precondition(SpeakerOutput.available(helper: fake, connected: { [] }) == ["Bose", "Computer", "Kitchen"], "Device choices are read without executing the helper")
        let connected = SpeakerOutput.available(helper: fake, connected: { ["Computer", "Mac Speakers", "Duplicate", "Duplicate"] })
        precondition(connected == ["Bose", "Computer", "Kitchen", "Mac Speakers"], "Connected outputs and reconnectable presets merge, excluding duplicate names")
        var edited = SpeakerOutputSettings(prefixes: "Switch audio\n", destinations: [.init(names: "Kitchen\n", output: "Device")],
                                           prefixSpellings: ["deletedphrase": ["Retired"]])
        edited = edited.cleaned()
        precondition(edited.prefixes == "Switch audio" && edited.destinations.first?.names == "Kitchen" && edited.prefixSpellings == nil)
        let collision = PhrasePattern(text: "Switch output Kitchen", similar: false)
        // Compare the index with the original exhaustive recognizer in both prefix directions.
        for pattern in [collision, PhrasePattern(text: "Kitchen", similar: false),
                        PhrasePattern(text: "Switch output kitchen lights", similar: true),
                        PhrasePattern(text: "Switch outputs", similar: false), PhrasePattern(text: "Zoom in", similar: true)] {
            for alternate in [false, true] {
                let reference = edited.commands(alternateSpellings: alternate).first { command in
                    let words = PhraseMatcher.words(command.pattern.text)
                    return !pattern.matches(in: words).isEmpty || PhraseMatcher.words(pattern.text).starts(with: words)
                }?.pattern.text
                precondition(edited.conflictingPhrase(with: [pattern], alternateSpellings: alternate) == reference)
            }
        }
        let safe = edited.omittingConflictingBuiltIns(avoiding: [collision])
        let allowed = safe.commands.map { PhraseList.key($0.pattern.text) }
        precondition(!allowed.contains("switchoutputkitchen") && allowed.contains("switchaudiokitchen") && allowed.contains("switchtheaudiokitchen"))
        precondition(!safe.commands(alternateSpellings: false).contains { PhraseList.key($0.pattern.text) == "switchtheaudiokitchen" })


        try! "import json,sys\nprint(json.dumps({'status':'ok','output':sys.argv[-1], 'warnings':['Input kept']}))\n".write(to: fake, atomically: true, encoding: .utf8)
        let success = SpeakerOutput.run("Example device", helper: fake)
        precondition(success.verified && success.message == "Switched speakers to Example device. Input kept")
        try! "import json\nprint(json.dumps({'status':'ok','output':'Wrong device'}))\n".write(to: fake, atomically: true, encoding: .utf8)
        precondition(SpeakerOutput.run("Example device", helper: fake).phase == .unknown)
        precondition(SpeakerSwitchOutcome.failure("Missing helper", beforeDispatch: true).phase == .failedBeforeDispatch)
        try! "import json,sys\nprint(json.dumps({'status':'failed','errors':['Output unavailable']})); sys.exit(1)\n".write(to: fake, atomically: true, encoding: .utf8)
        let failure = SpeakerOutput.run("Example device", helper: fake)
        precondition(!failure.verified && failure.message == "Output unavailable")
        print("Speaker output configuration, recognition and helper results passed")
    }
}
