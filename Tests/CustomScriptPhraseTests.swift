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
        print("Custom phrases: exact forms, mentions, collisions, duplicate finals and one local fixture process passed")
    }
}
