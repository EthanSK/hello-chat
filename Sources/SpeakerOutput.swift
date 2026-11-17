// Configurable spoken speaker destinations and the existing microphone-preserving routing helper.
import Foundation

struct SpeakerDestination: Codable, Identifiable, Equatable {
    var id = UUID()
    var names: String
    var output: String
}

struct SpeakerOutputSettings: Codable, Equatable {
    static let defaultsKey = "speakerOutputSettings"
    var prefixes = "Switch speakers\nSwitch audio\nChange audio"
    var destinations: [SpeakerDestination] = []

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !PhraseMatcher.words($0).isEmpty }
    }
    // Ambiguous destination names cannot safely choose a device. Identical aliases for one
    // output are harmless; a prefix of another destination could fire before its final word.
    var issue: String? {
        var names: [([String], String)] = []
        for destination in destinations {
            let output = destination.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty, !Self.lines(destination.names).isEmpty else { return "Enter a name and output for each speaker." }
            for name in Self.lines(destination.names) {
                let words = PhraseMatcher.words(name)
                if names.contains(where: { old, device in device != output && (words.starts(with: old) || old.starts(with: words)) }) {
                    return "Speaker names for different outputs must be distinct."
                }
                names.append((words, output))
            }
        }
        // Different prefix/name combinations can also produce the same complete command.
        var phrases: [(String, String)] = []
        for prefix in Self.lines(prefixes) {
            for destination in destinations {
                let output = destination.output.trimmingCharacters(in: .whitespacesAndNewlines)
                for name in Self.lines(destination.names) {
                    for connector in ["", " to"] {
                        let key = PhraseList.key("\(prefix)\(connector) \(name)")
                        if phrases.contains(where: { other, device in device != output && (key.hasPrefix(other) || other.hasPrefix(key)) }) {
                            return "Speaker phrases for different outputs must be distinct."
                        }
                        phrases.append((key, output))
                    }
                }
            }
        }
        return nil
    }
    func conflictingPhrase(with otherPatterns: [PhrasePattern]) -> String? {
        commands.first { command in
            let words = PhraseMatcher.words(command.pattern.text)
            return otherPatterns.contains { pattern in
                !pattern.matches(in: words).isEmpty || PhraseMatcher.words(pattern.text).starts(with: words)
            }
        }?.pattern.text
    }
    var commands: [(pattern: PhrasePattern, output: String)] {
        guard issue == nil else { return [] }
        var result: [(PhrasePattern, String)] = [], seen = Set<String>()
        for prefix in Self.lines(prefixes) {
            for destination in destinations {
                for name in Self.lines(destination.names) {
                    for connector in ["", " to"] {
                        let phrase = "\(prefix)\(connector) \(name)"
                        if seen.insert(PhraseList.key(phrase)).inserted {
                            result.append((PhrasePattern(text: phrase, similar: false), destination.output.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                }
            }
        }
        return result
    }
}

struct SpeakerOutputResult: Decodable {
    let status: String
    let output: String?
    let warnings: [String]?
    let errors: [String]?
}

enum SpeakerOutput {
    private static var helper: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills/live-voice-mode/scripts/switch-output.py")
    }
    // Read the helper's own protected devices, including disconnected Bluetooth outputs. This
    // avoids copying Ethan's device configuration into H Chat or exposing unprotected routes.
    static func available(helper: URL = Self.helper) -> [String] {
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return [] }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Parse constants without importing the helper: opening settings must never execute
        // future top-level helper code or perform an audio operation.
        let reader = """
        import ast, json, sys
        tree = ast.parse(open(sys.argv[1], encoding='utf-8').read())
        values = {n.targets[0].id: n.value.value for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)}
        table = next(n.value for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id == 'BLUETOOTH_ADDRESSES')
        print(json.dumps([values['DEFAULT'], *[values[k.id] for k in table.keys]]))
        """
        process.arguments = ["-c", reader, helper.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch { return [] }
    }
    // The shared helper snapshots input before connecting Bluetooth, verifies routing, and restores
    // only known speaker-microphone takeovers. Never duplicate that policy in the app.
    static func switchTo(_ output: String) -> String {
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return "Audio switch helper not found." }
        guard available().contains(output) else { return "Speaker is not configured for microphone preservation." }
        return run(output, helper: helper)
    }
    static func run(_ output: String, helper: URL) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, "--", output]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let result = try? JSONDecoder().decode(SpeakerOutputResult.self, from: data) else { return "Couldn't read audio switch result." }
            if result.status == "ok", process.terminationStatus == 0 {
                let message = "Switched speakers to \(result.output ?? output)"
                return ([message] + (result.warnings ?? [])).joined(separator: ". ")
            }
            return (result.errors ?? ["Couldn't switch speakers."]).joined(separator: " ")
        } catch { return "Couldn't start audio switch: \(error.localizedDescription)" }
    }
}
