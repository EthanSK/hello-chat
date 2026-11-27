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
        precondition(timed.completed(through: 3.2, quietFinals: []) == ["fingerbot"])
        let both = first + [("finger", 4.0, 4.3), ("bot", 4.3, 4.65)]
        timed.update("Fingerbot. Finger bot.", timings: both)
        precondition(timed.completed(through: 7.0, quietFinals: []) == ["finger bot"])
        precondition(timed.completed(through: 7.5, quietFinals: ["Fingerbot finger bot"]).isEmpty)
        for lead in ["I said", "Don't"] {
            var quoted = TimedCustomSpeech()
            let words = PhraseMatcher.words(lead)
            let spans = words.enumerated().map { i, word in (word, Double(i) * 0.2, Double(i + 1) * 0.2) }
            quoted.update(lead + ". Fingerbot.", timings: spans + [("fingerbot", 3.0, 3.6)])
            precondition(quoted.completed(through: 6, quietFinals: []).allSatisfy { config.command(for: $0) == nil })
        }
        var extended = TimedCustomSpeech()
        extended.update("Fingerbot", timings: first)
        precondition(extended.completed(through: 2.0, quietFinals: []).isEmpty)
        extended.update("Fingerbot works", timings: first + [("works", 1.25, 1.6)])
        precondition(extended.completed(through: 4.0, quietFinals: []).allSatisfy { config.command(for: $0) == nil })
        var unaligned = TimedCustomSpeech()
        unaligned.update("Fingerbot", timings: [("fingerbot", 0.5, 0.5)])
        precondition(unaligned.completed(through: 4.0, quietFinals: []).isEmpty)
        precondition(unaligned.completed(through: 4.0, quietFinals: ["Fingerbot"]) == ["Fingerbot"])
        print("Custom phrases: exact forms, mentions, collisions, duplicate finals and one local fixture process passed")
    }
}
