// Real phrase admission, numeric arguments and shared repetition with injected
// actions only. No Apple Events, live audio or saved user settings. — GPT-6.1 Sol
import Foundation

@main enum SpotifyVolumePhraseTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let speedConfiguration = PhraseConfiguration(rows: [.setSpeedPhrase: ["Set speed"]])
        let speedPrefix = PhrasePattern(slot: .setSpeedPhrase, text: "Set speed", similar: true,
            dictionaries: PhraseDictionaries(savedByTrigger: [:], active: speedConfiguration))
        func speeds(_ text: String, prefixes: [PhrasePattern]? = nil) -> [ChatSpeedPhrase.Command] {
            var detector = ChatSpeedPhrase()
            detector.audio(level: 0.2, seconds: 0.1, at: 0)
            detector.update(text, at: 1, timings: nil)
            return detector.poll(at: 1, prefixes: prefixes ?? [speedPrefix])
        }
        for speed in CodexSpeed.allCases {
            for prefix in ["Set speed", "Set speed to", "Set the speed", "Set the speed to"] {
                check(speeds(prefix + " " + speed.rawValue).map(\.value) == [speed], "Exact named speed: " + prefix + " " + speed.rawValue)
            }
        }
        for spelling in ["ultra-fast", "ultra fast", "ultrafast"] {
            check(speeds("Set speed " + spelling).map(\.value) == [.ultrafast], "Spoken Ultra spelling: " + spelling)
        }
        for text in ["Set speed", "Set speed ultra", "Set speed turbo", "Set speed fast tomorrow", "Don't set speed fast", "I said set speed fast", "The phrase set speed fast", "Can you add set speed fast"] {
            check(speeds(text).isEmpty, "Incomplete/unsupported/mentioned/planned speed: " + text)
        }
        let customSpeed = PhrasePattern(text: "Chat pace", similar: false)
        check(speeds("Chat pace Fast", prefixes: [customSpeed]).map(\.value) == [.fast], "Shared editable prefix")
        check(speeds("Set speed Fast", prefixes: [customSpeed]).isEmpty, "Deleted speed prefix stays deleted")
        check(speeds("Set speed Fast", prefixes: []).isEmpty, "Disabled speed action has no active pattern")
        var speedRevision = ChatSpeedPhrase()
        speedRevision.audio(level: 0.2, seconds: 0.1, at: 0)
        speedRevision.update("Set speed Fast", at: 1, timings: nil)
        let firstSpeed = speedRevision.poll(at: 1, prefixes: [speedPrefix])
        speedRevision.update("Set speed Ultrafast", at: 2, timings: nil)
        let secondSpeed = speedRevision.poll(at: 2, prefixes: [speedPrefix])
        check(firstSpeed.first?.value == .fast && secondSpeed.first?.value == .ultrafast && firstSpeed.first?.id == secondSpeed.first?.id && secondSpeed.first?.revised == true,
              "A revised named speed retains one occurrence/receipt")
        check(speedRevision.poll(at: 3, prefixes: [speedPrefix]).isEmpty, "An unchanged speed final never replays")
        speedRevision.reset(); speedRevision.audio(level: 0.2, seconds: 0.1, at: 0)
        speedRevision.update("Set speed Fast. Bye Chat", at: 1, timings: nil)
        speedRevision.cancelPending(prefixes: [speedPrefix], endPatterns: [PhrasePattern(text: "Bye Chat", similar: false, ending: true)])
        check(speedRevision.poll(at: 1, prefixes: [speedPrefix]).isEmpty, "End cancels pending speed")
        let configuration = PhraseConfiguration(rows: [.spotifyVolumePhrase: ["Spotify volume"]])
        let prefix = PhrasePattern(slot: .spotifyVolumePhrase, text: "Spotify volume", similar: true,
                                   dictionaries: PhraseDictionaries(savedByTrigger: [:], active: configuration))
        func detect(_ text: String, final: Bool = true, prefixes: [PhrasePattern]? = nil) -> [SpotifyVolumePhrase.Command] {
            var detector = SpotifyVolumePhrase()
            detector.audio(level: 0.2, seconds: 0.1, at: 0)
            detector.update(text, at: 1, timings: nil)
            if final { detector.endUtterance() }
            return detector.poll(at: 1, prefixes: prefixes ?? [prefix])
        }
        for value in 0...100 {
            for suffix in [String(value), "\(value) percent", "\(value)%", "\(value) per cent"] {
                check(detect("Spotify volume " + suffix).map(\.volume) == [value], "Numeric volume: " + suffix)
            }
        }
        for (text, expected) in [("zero", 0), ("one", 1), ("nineteen", 19), ("twenty one", 21), ("forty", 40),
                                 ("forty-five", 45), ("ninety nine", 99), ("one hundred", 100), ("a hundred", 100)] {
            check(detect("Spotify volume " + text).map(\.volume) == [expected], "Spoken volume: " + text)
        }
        for text in ["Spotify volume", "Spotify volume -5", "Spotify volume +5", "Spotify volume minus five",
                     "Spotify volume negative five", "Spotify volume 101", "Spotify volume one hundred five",
                     "Spotify volume forty point five", "Spotify volume 40.5", "Spotify volume forty dollars",
                     "Spotify volume forty tomorrow", "Spotify volume forty when I leave", "Spotify volume forty seconds",
                     "I said Spotify volume forty", "Don’t Spotify volume forty", "The phrase Spotify volume forty",
                     "Spotify volume forty is the setting", "Can you add Spotify volume forty"] {
            check(detect(text).isEmpty, "Reject incomplete, invalid or discussed volume: " + text)
        }
        for text in ["Spotify volume forty", "Please Spotify volume forty", "Can you Spotify volume forty please"] {
            check(detect(text).map(\.volume) == [40], "Polite command: " + text)
            check(detect(text, final: false).map(\.volume) == [40], "No utterance-end requirement")
        }
        for text in ["Spotify volume to forty", "Set Spotify volume forty", "Set Spotify volume to forty", "Spot ify volume forty", "Spotify volume forty all over the factory"] {
            check(detect(text, final: false).map(\.volume) == [40], "Configured spelling or continuing speech: " + text)
        }
        for text in ["Spotify volume two forty", "Spotify volume too forty"] {
            check(detect(text).map(\.volume) == [40], "Recognized to homophone before a following value")
        }
        check(detect("Spotify volume two").map(\.volume) == [2], "A standalone two remains the value 2")
        let custom = PhrasePattern(slot: .spotifyVolumePhrase, text: "Music level", similar: false, dictionaries: .init())
        check(detect("Music level thirty", prefixes: [custom]).map(\.volume) == [30], "Editable custom prefix")
        check(detect("Spotify volume thirty", prefixes: [custom]).isEmpty, "Removing a prefix stays effective")
        var detector = SpotifyVolumePhrase()
        detector.audio(level: 0.2, seconds: 0.1, at: 0)
        detector.update("Spotify volume forty", at: 1, timings: nil)
        let initial = detector.poll(at: 1, prefixes: [prefix])
        check(initial.map(\.volume) == [40], "Admit a value immediately without waiting for silence")
        detector.update("Spotify volume forty five", at: 2, timings: nil)
        let revision = detector.poll(at: 2, prefixes: [prefix])
        check(revision.map(\.volume) == [45] && revision.first?.id == initial.first?.id && revision.first?.revised == true,
              "Complete the compound number on the same logical command")
        check(detector.poll(at: 3, prefixes: [prefix]).isEmpty, "Duplicate final cannot repeat volume")
        detector.endUtterance()
        let timed = PhraseMatcher.words("Spotify volume forty five").enumerated().map { (word: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.2) }
        detector.update("Spotify volume forty five", at: 4, timings: timed)
        detector.endUtterance()
        check(detector.poll(at: 4, prefixes: [prefix]).isEmpty, "Replacing arrival timing cannot replay volume")
        detector.reset(); detector.audio(level: 0.2, seconds: 0.1, at: 0)
        detector.update("Spotify volume forty. Bye Chat", at: 1, timings: nil)
        detector.cancelPending(prefixes: [prefix], endPatterns: [PhrasePattern(text: "Bye Chat", similar: false, ending: true)])
        detector.endUtterance()
        check(detector.poll(at: 1, prefixes: [prefix]).isEmpty, "Explicit End cancels unstarted volume")
        for (text, enabled, expected) in [("Spotify volume forty", true, 1), ("Spotify volume forty percent three times", true, 3),
                                           ("Spotify volume 40 3 times", true, 3), ("Spotify volume forty percent three times", false, 1)] {
            guard let command = detect(text).first else { fatalError("Expected volume command: " + text) }
            let scheduler = RepeatedCommands()
            scheduler.update(PhraseMatcher.words(text), timings: nil); scheduler.endUtterance()
            var calls = 0
            func run(_ id: UUID) { calls += 1; scheduler.finish(id, .confirmed) }
            _ = scheduler.begin(id: UUID(), range: command.range, repeats: enabled, requiresTimes: true, run: run)
            check(calls == expected, "Volume argument is not a count; explicit times and disabled repetition work")
        }
        check(PhraseSlot.spotifyVolumePhrase.settingsTitle == "Spotify volume" && PhraseSlot.musicSlots.contains(.spotifyVolumePhrase), "Home row has its own title and music placement")
        check(CommandRepetition.enabled(PhraseSlot.spotifyVolumePhrase.rawValue), "New action inherits default-on repetition")
        for inFlight in [false, true] {
            let scheduler = RepeatedCommands(), root = UUID()
            var steps: [UUID] = [], values: [Int] = [], target = 40
            var progress: RepeatedCommands.Progress?
            scheduler.onProgress = { progress = $0 }
            scheduler.update(["spotify", "volume", "forty"], timings: nil)
            _ = scheduler.begin(id: root, range: 0..<3, repeats: true, requiresTimes: true, valueArgument: true) { id in steps.append(id); values.append(target) }
            if !inFlight { scheduler.finish(steps[0], .confirmed) }
            scheduler.update(["spotify", "volume", "forty", "five"], timings: nil)
            scheduler.endUtterance() // Production reports final text before its frame callback.
            check(scheduler.reviseValue(root, range: 0..<4, finishingUtterance: true) { target = 45; return true }, "Admit final-frame argument correction")
            if inFlight { scheduler.finish(steps[0], .confirmed) }
            check(values == [40, 45] && progress?.requested == 1 && progress?.completed == 0, "Correct an absolute value within one logical run")
            scheduler.finish(steps[1], .confirmed)
            check(progress?.id == root && progress?.requested == 1 && progress?.completed == 1 && progress?.outcome == .confirmed, "One receipt confirms the completed value")
            scheduler.cancelPending()
            check(!scheduler.reviseValue(root, range: 0..<4, finishingUtterance: true) { fatalError("Cancelled value must not authorize") }, "End prevents a later argument correction")
        }
        var shifted = SpotifyVolumePhrase()
        func timings(_ text: String, from start: Double) -> [(word: String, start: Double, end: Double)] {
            PhraseMatcher.words(text).enumerated().map { (word: $0.element, start: start + Double($0.offset) * 0.2, end: start + Double($0.offset) * 0.2 + 0.12) }
        }
        shifted.audio(level: 0.2, seconds: 0.1, at: 0)
        shifted.update("Spotify volume forty. Spotify volume sixty", at: 1, timings: timings("Spotify volume forty. Spotify volume sixty", from: 0))
        let pair = shifted.poll(at: 1, prefixes: [prefix])
        check(pair.map(\.volume) == [40, 60], "Two sentence-delimited value commands have separate owners")
        shifted.update("Spotify volume sixty", at: 2, timings: timings("Spotify volume sixty", from: 0.6))
        let relocated = shifted.poll(at: 2, prefixes: [prefix])
        check(relocated.allSatisfy { $0.id == pair[1].id }, "Deleting an earlier prefix cannot steal its receipt")
        shifted.update("Spotify volume sixty five", at: 3, timings: timings("Spotify volume sixty five", from: 0.6))
        let corrected = shifted.poll(at: 3, prefixes: [prefix])
        check(corrected.map(\.volume) == [65] && corrected[0].id == pair[1].id, "A relocated command keeps its own value-revision identity")
        var streaming = SpotifyVolumePhrase(), current = "", target = 0, roots: [UUID] = []
        let shared = RepeatedCommands(), root = UUID()
        var runs = 0
        streaming.audio(level: 0.2, seconds: 0.1, at: 0)
        func run(_ step: UUID) { runs += 1; check(target == 40, "Repeated value stays at 40"); shared.finish(step, .confirmed) }
        for token in ["Spotify", "volume", "forty", "per", "cent", "three", "times"] {
            current += (current.isEmpty ? "" : " ") + token
            shared.update(PhraseMatcher.words(current), timings: nil)
            streaming.update(current, at: Double(current.count), timings: nil)
            for command in streaming.poll(at: Double(current.count), prefixes: [prefix]) {
                check(!command.invalid, "Partial repeat wording is pending, not a failed volume")
                if command.revised {
                    _ = shared.reviseValue(root, range: command.range, reapply: target != command.volume) { target = command.volume; return true }
                } else {
                    roots.append(command.id); target = command.volume
                    _ = shared.begin(id: root, range: command.range, repeats: true, requiresTimes: true, valueArgument: true, run: run)
                }
            }
        }
        check(roots.count == 1 && runs == 3, "Word-by-word percent/count speech executes three total logical runs, not additional replays")
        print("SpotifyVolumePhrase: \(checks) checks passed; no live actions.")
    }
}
