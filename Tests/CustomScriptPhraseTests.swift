import Foundation

@main enum CustomScriptPhraseTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.sh")
        try Data("printf '%s\\n' \"$1\" >> result.txt\n".utf8).write(to: script)
        let phrases = ["Fingerbot", "Fingerbots", "Fingerboard"]
        let entry: [String: Any] = [
            "name": "Fixture", "phrases": phrases, "executable": "/bin/sh",
            "arguments": [script.path, "one literal; argument"], "workingDirectory": directory.path
        ]
        let config = try CustomScriptPhrases(data: JSONSerialization.data(withJSONObject: [entry]))
        for form in ["Fingerbot", "Fingerbots", "finger bot", "finger bots.", "finger-bot", "finger-bots",
                     "fingerboard", "Finger board"] {
            precondition(config.command(for: form)?.name == "Fixture", form)
        }
        for mention in ["I said Finger bots", "Does fingerboard work?", "Finger bot is your command",
                        "don't finger bot", "Finger bot twice", "finger bot finger bot"] {
            precondition(config.command(for: mention) == nil, mention)
        }
        do {
            _ = try CustomScriptPhrases(data: JSONSerialization.data(withJSONObject: [entry, entry]))
            preconditionFailure("Overlapping commands must not both claim one phrase")
        } catch CustomScriptPhrases.ConfigError.duplicatePhrase {}

        let file = directory.appendingPathComponent("CustomPhrases.json")
        try config.save(replacing: [], to: file)
        let loaded = try CustomScriptPhrases.load(from: file)
        precondition(loaded.entries == config.entries)
        let added = CustomScriptPhrases.Command(name: "Another", phrases: ["Local test"],
                                                executable: "/usr/bin/true", arguments: nil, workingDirectory: nil)
        let edited = try CustomScriptPhrases(entries: loaded.entries + [added])
        try edited.save(replacing: loaded.entries, to: file)
        let reloaded = try CustomScriptPhrases.load(from: file)
        precondition(reloaded.entries == edited.entries && reloaded.command(for: "finger bot") == loaded.entries.first)
        do {
            try config.save(replacing: loaded.entries, to: file)
            preconditionFailure("A stale editor must preserve newer changes")
        } catch CustomScriptPhrases.ConfigError.changed {}
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)

        var finals = CustomSpeechFinals()
        for (text, start, end) in [("I said finger bots", 0.0, 1.0), ("Finger bots", 1.5, 2.0),
                                   ("finger-bots", 1.5, 2.0), ("fingerboard", 1.501, 2.02)] {
            guard finals.accept(start: start, end: end), let command = config.command(for: text) else { continue }
            let process = try command.launch { _ in }
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        let result = try String(contentsOf: directory.appendingPathComponent("result.txt"), encoding: .utf8)
        precondition(result == "one literal; argument\n", "Exactly one script invocation with literal arguments")
        precondition(finals.accept(start: 2.5, end: 3.0), "A new utterance may run the command again")
        var timed = TimedCustomSpeech()
        let first = [("fingerbot", 0.5, 1.1)]
        timed.update("Fingerbot", timings: first)
        precondition(timed.completed(through: 2.9, quietFinals: []).isEmpty)
        precondition(timed.completed(through: 3.2, quietFinals: []) == [CustomCommandUtterance("fingerbot")])
        let both = first + [("finger", 4.0, 4.3), ("bot", 4.3, 4.65)]
        timed.update("Fingerbot. Finger bot.", timings: both)
        precondition(timed.completed(through: 7.0, quietFinals: []) == [CustomCommandUtterance("finger bot", wordRange: 1..<3)])
        precondition(timed.completed(through: 7.5, quietFinals: [CustomCommandUtterance("Fingerbot finger bot")]).isEmpty)
        for forms in [[("fingerbot", 1.4, 1.8)], [("finger", 1.4, 1.6), ("bot", 1.6, 1.8)]] {
            var between = TimedCustomSpeech()
            let words = [("test", 0.1, 0.5)] + forms + [("another", 2.7, 2.9), ("word", 2.9, 3.2)]
            let phrase = words.map { $0.0 }.joined(separator: " ")
            between.update(phrase, timings: words)
            let detections = between.completed(through: 4.0, quietFinals: []).filter { config.command(for: $0.text) != nil }
            precondition(detections.count == 1)
            precondition(detections.first?.wordRange == 1..<(1 + forms.count))
            between.update(phrase, timings: words)
            precondition(between.completed(through: 4.1, quietFinals: []).allSatisfy { config.command(for: $0.text) == nil })
        }
        // The recording's decoder placed a 640 ms gap between the two words
        // and the punctuation at the first following word's start time.
        var modelClock = TimedCustomSpeech()
        let decoded = [("test", 1.92, 2.0), ("finger", 3.52, 3.84), ("bot", 4.48, 4.64),
                       ("this", 4.64, 4.72), ("is", 4.80, 4.88), ("different", 5.12, 5.20)]
        modelClock.update("Test finger bot. This is different.", timings: decoded)
        let accepted = modelClock.completed(through: 8, quietFinals: []).filter { config.command(for: $0.text) != nil }
        precondition(accepted == [CustomCommandUtterance("finger bot", wordRange: 1..<3)])
        for lead in ["I said", "Don't"] {
            var quoted = TimedCustomSpeech()
            let words = PhraseMatcher.words(lead)
            let spans = words.enumerated().map { i, word in (word, Double(i) * 0.2, Double(i + 1) * 0.2) }
            quoted.update(lead + ". Fingerbot.", timings: spans + [("fingerbot", 3.0, 3.6)])
            precondition(quoted.completed(through: 6, quietFinals: []).allSatisfy { config.command(for: $0.text) == nil })
        }
        var mentionedAcrossPause = TimedCustomSpeech()
        mentionedAcrossPause.update("Fingerbot was mentioned", timings: first + [("was", 1.95, 2.1), ("mentioned", 2.1, 2.5)])
        precondition(mentionedAcrossPause.completed(through: 5, quietFinals: []).allSatisfy { config.command(for: $0.text) == nil })
        var extended = TimedCustomSpeech()
        extended.update("Fingerbot", timings: first)
        precondition(extended.completed(through: 2.0, quietFinals: []).isEmpty)
        extended.update("Fingerbot works", timings: first + [("works", 1.25, 1.6)])
        precondition(extended.completed(through: 4.0, quietFinals: []).allSatisfy { config.command(for: $0.text) == nil })
        var unaligned = TimedCustomSpeech()
        unaligned.update("Fingerbot", timings: [("fingerbot", 0.5, 0.5)])
        precondition(unaligned.completed(through: 4.0, quietFinals: []).isEmpty)
        precondition(unaligned.completed(through: 4.0, quietFinals: [CustomCommandUtterance("Fingerbot")]) == [CustomCommandUtterance("Fingerbot")])
        print("Custom phrases: exact forms, mentions, collisions, duplicate finals and one local fixture process passed")
    }
}
