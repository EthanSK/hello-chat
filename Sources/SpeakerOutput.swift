// Configurable spoken speaker destinations and the existing microphone-preserving routing helper.
import Foundation

struct SpeakerDestination: Codable, Identifiable, Equatable {
    var id = UUID()
    var names: String
    var output: String
}

struct SpeakerOutputSettings: Codable, Equatable {
    static let defaultsKey = "speakerOutputSettings"
    private static let previousPrefixes = "Switch speakers\nSwitch audio\nChange audio"
    private static let singularPrefixes = previousPrefixes + "\nSwitch speaker"
    static let defaultPrefixes = singularPrefixes + "\nSwitch back"
    var prefixes = defaultPrefixes
    var destinations: [SpeakerDestination] = []
    var prefixSpellings: [String: [String]]?

    static func builtInSpellings(for prefix: String) -> [String] {
        switch PhraseList.key(prefix) {
        case "switchspeakers": return ["Switch the speakers", "Change speakers"]
        case "switchspeaker": return ["Switch the speaker", "Change speaker"]
        case "switchaudio": return ["Switch the audio", "Switch output"]
        case "changeaudio": return ["Change the audio", "Change output"]
        case "switchback": return ["Switch back over"]
        default: return []
        }
    }

    func cleaned() -> Self {
        var settings = self
        let rows = Self.lines(prefixes)
        settings.prefixes = rows.joined(separator: "\n")
        let keys = Set(rows.map(PhraseList.key))
        settings.prefixSpellings = prefixSpellings?.filter { keys.contains($0.key) }
        if settings.prefixSpellings?.isEmpty == true { settings.prefixSpellings = nil }
        for index in settings.destinations.indices {
            settings.destinations[index].names = Self.lines(destinations[index].names).joined(separator: "\n")
        }
        return settings
    }

    // A shipped spelling must never switch off previously valid commands.
    func omittingConflictingBuiltIns(avoiding otherPatterns: [PhrasePattern]) -> Self {
        var conflicts = SpeakerPhraseConflicts(otherPatterns)
        var settings = self
        let stockPrefixes = Self.lines(prefixes).filter { prefixSpellings?[PhraseList.key($0)] == nil }
        var overrides = prefixSpellings ?? [:]
        for prefix in stockPrefixes { overrides[PhraseList.key(prefix)] = [] }
        settings.prefixSpellings = overrides
        for prefix in stockPrefixes {
            let key = PhraseList.key(prefix)
            for spelling in Self.builtInSpellings(for: prefix) {
                settings.prefixSpellings?[key, default: []].append(spelling)
                if settings.issue != nil || settings.conflictingPhrase(using: &conflicts, alternateSpellings: true) != nil {
                    settings.prefixSpellings?[key]?.removeLast()
                }
            }
        }
        return settings
    }

    private func prefixForms(alternateSpellings: Bool) -> [(text: String, connector: String)] {
        Self.lines(prefixes).flatMap { prefix in
            let alternate = prefixSpellings?[PhraseList.key(prefix)] ?? Self.builtInSpellings(for: prefix)
            let forms = alternateSpellings ? [prefix] + alternate : [prefix]
            return forms.flatMap { form in
                Self.connectors(for: prefix).map { (form, $0) }
            }
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    // Upgrade the original editable prefix list once. A custom list or a later deletion wins.
    func upgradingDefaultPrefixes(in defaults: UserDefaults, avoiding otherPatterns: [PhrasePattern]) -> Self? {
        let originalUpgrade = "speakerSingularPrefix20261120"
        let returnUpgrade = "speakerReturnPrefix20261122"
        guard !defaults.bool(forKey: returnUpgrade) else { return nil }
        let isOriginal = !defaults.bool(forKey: originalUpgrade) && prefixes == Self.previousPrefixes
        defer {
            defaults.set(true, forKey: originalUpgrade)
            defaults.set(true, forKey: returnUpgrade)
        }
        guard isOriginal || prefixes == Self.singularPrefixes else { return nil }
        var upgraded = self
        upgraded.prefixes = Self.defaultPrefixes
        let effective = upgraded.omittingConflictingBuiltIns(avoiding: otherPatterns)
        guard effective.issue == nil, effective.conflictingPhrase(with: otherPatterns) == nil else { return nil }
        upgraded.save(to: defaults)
        return upgraded
    }
    // Ethan wants requested dictionary additions in every build, not only his local settings.
    // Add the Headset row once; conflicting/custom destinations and later deletions win. — GPT-6.1 Sol
    func addingHeadsetDefault(in defaults: UserDefaults, avoiding otherPatterns: [PhrasePattern]) -> Self? {
        let key = "speakerHeadsetDefault20261128"
        guard !defaults.bool(forKey: key) else { return nil }
        defer { defaults.set(true, forKey: key) }
        var next = self
        let output = "JLab GO Work Pop"
        let index: Int
        if let existing = next.destinations.firstIndex(where: { $0.output == output }) { index = existing }
        else {
            next.destinations.append(.init(id: UUID(uuidString: "8C59DC3D-E619-405A-A7E9-C82D78638359")!, names: "", output: output))
            index = next.destinations.count - 1
        }
        for name in ["Headset", "Headphones", "JLab", output] where !Self.lines(next.destinations[index].names).contains(name) {
            let before = next.destinations[index].names
            next.destinations[index].names = ([before, name].filter { !$0.isEmpty }).joined(separator: "\n")
            if next.issue != nil || next.conflictingPhrase(with: otherPatterns) != nil { next.destinations[index].names = before }
        }
        if next.destinations[index].names.isEmpty { next.destinations.remove(at: index) }
        guard next != self else { return nil }
        next.save(to: defaults)
        return next
    }
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !PhraseMatcher.words($0).isEmpty }
    }
    // “Switch back now to the kitchen speakers” must still name a configured output.
    // A bare “switch back” never chooses a previous or inferred device.
    private static func connectors(for prefix: String) -> [String] {
        PhraseMatcher.words(prefix) == ["switch", "back"]
            ? [" to", " to the", " now to", " now to the"]
            : ["", " to"]
    }
    // Ambiguous destination names cannot safely choose a device. Identical aliases for one
    // output are harmless; a prefix of another destination could fire before its final word.
    var issue: String? { issue(alternateSpellings: true) }
    private func issue(alternateSpellings: Bool) -> String? {
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
        for (prefix, connector) in prefixForms(alternateSpellings: alternateSpellings) {
            for (words, output) in names {
                let key = PhraseList.key("\(prefix)\(connector) " + words.joined(separator: " "))
                if phrases.contains(where: { other, device in device != output && (key.hasPrefix(other) || other.hasPrefix(key)) }) {
                    return "Speaker phrases for different outputs must be distinct."
                }
                phrases.append((key, output))
            }
        }
        return nil
    }
    func conflictingPhrase(with otherPatterns: [PhrasePattern], alternateSpellings: Bool = true) -> String? {
        var conflicts = SpeakerPhraseConflicts(otherPatterns)
        return conflictingPhrase(using: &conflicts, alternateSpellings: alternateSpellings)
    }

    private func conflictingPhrase(using conflicts: inout SpeakerPhraseConflicts, alternateSpellings: Bool) -> String? {
        guard !conflicts.isEmpty else { return nil }
        return commands(alternateSpellings: alternateSpellings).first { conflicts.contains($0.pattern.text) }?.pattern.text
    }
    // Both recognition engines identify a speaker by its saved output, even when one heard its alias.
    func receiptTarget(_ spoken: String) -> String? {
        let words = PhraseList.key(spoken)
        guard !words.isEmpty, issue == nil else { return nil }
        let outputs = Set(destinations.compactMap { destination -> String? in
            let output = destination.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let forms = Self.lines(destination.names) + [output]
            return forms.contains(where: { PhraseList.key($0) == words }) ? output.lowercased() : nil
        })
        return outputs.count == 1 ? outputs.first : nil
    }
    var commands: [(pattern: PhrasePattern, output: String)] { commands(alternateSpellings: true) }

    // Reserve multiword speaker prefixes while their destination is arriving. A custom bare
    // “Switch” must not take ownership of every app command. Found by Claude Opus 5.5.
    // Fixed by GPT-6.1 Sol. — GPT-6.1 Sol
    func commandPrefixes(alternateSpellings: Bool) -> [PhrasePattern] {
        var seen = Set<String>()
        return prefixForms(alternateSpellings: alternateSpellings).compactMap { form, _ in
            guard PhraseMatcher.words(form).count > 1, seen.insert(PhraseList.key(form)).inserted else { return nil }
            return PhrasePattern(text: form, similar: false)
        }
    }

    func commands(alternateSpellings: Bool) -> [(pattern: PhrasePattern, output: String)] {
        guard issue(alternateSpellings: alternateSpellings) == nil else { return [] }
        var result: [(PhrasePattern, String)] = [], seen = Set<String>()
        for (prefix, connector) in prefixForms(alternateSpellings: alternateSpellings) {
            for destination in destinations {
                for name in Self.lines(destination.names) {
                    let phrase = "\(prefix)\(connector) \(name)"
                    if seen.insert(PhraseList.key(phrase)).inserted {
                        result.append((PhrasePattern(text: phrase, similar: false), destination.output.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            }
        }
        return result
    }
}

// The speaker editor used to run every other command's recognizer against every
// prefix/name combination on redraw. Index the same finite spellings once. The
// real matcher still decides shortlisted collisions, including contextual exclusions.
private struct SpeakerPhraseConflicts {
    let patterns: [PhrasePattern]
    var isEmpty: Bool { patterns.isEmpty }
    private var bySpelling: [String: [Int]] = [:]
    private var exactPrefixes: Set<[String]> = []
    private var results: [String: Bool] = [:]

    init(_ patterns: [PhrasePattern]) {
        self.patterns = patterns
        for (index, pattern) in patterns.enumerated() {
            let words = PhraseMatcher.words(pattern.text)
            for end in words.indices { exactPrefixes.insert(Array(words[...end])) }
            let forms = PhraseMatcher.knownSpellings(for: pattern.text, similar: pattern.similar,
                                                     ending: pattern.ending, dictionaries: pattern.dictionaries)
            for key in Set(forms.map(PhraseList.key)) { bySpelling[key, default: []].append(index) }
        }
    }

    mutating func contains(_ phrase: String) -> Bool {
        if let cached = results[phrase] { return cached }
        let words = PhraseMatcher.words(phrase)
        var candidates = Set<Int>()
        for start in words.indices {
            var compact = ""
            for word in words[start...] {
                compact += word
                if let indices = bySpelling[compact] { candidates.formUnion(indices) }
            }
        }
        let conflict = exactPrefixes.contains(words) || candidates.contains { index in
            let pattern = patterns[index], matches = pattern.matches(in: words)
            guard pattern.isBareNavigation else { return !matches.isEmpty }
            // “Switch back to Kitchen” contains Back but cannot address navigation.
            // Keep real leading/polite Back prefixes blocked before their destination
            // arrives. Other commands retain their previous strict ownership.
            // Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
            var detector = StandaloneWake()
            detector.update(phrase, at: 0)
            return matches.contains { detector.permitsDirectCommandPrefix(in: $0.start..<$0.end) }
        }
        results[phrase] = conflict
        return conflict
    }
}

extension StandaloneWake {
    /// A physical output command owns its words even while Voice is collecting its opening.
    /// Deliver the selected output and its word range together so the app and receipt use the same match.
    mutating func dispatchSpeaker(at time: Double, commands: [(pattern: PhrasePattern, output: String)],
                                  onDecision: ((String, Double, Double) -> Void)? = nil,
                                  dispatch: (String, Range<Int>) -> Void) {
        guard let first = commands.first,
              poll(at: time, phrase: first.pattern.text, similar: false, rejectNegated: true,
                   patterns: commands.map(\.pattern), directOnly: true, embeddedCommand: true, onDecision: onDecision),
              let index = acceptedPatternIndex, commands.indices.contains(index), let range = acceptedRange
        else { return }
        dispatch(commands[index].output, range)
    }
}

// Bluetooth selection can take seconds. Serialize physical output changes and keep the
// most recent requested destination. Equivalent requests share the same verified result.
struct SpeakerOutputQueue {
    struct Request {
        let output: String
        var receipts: [UUID]
    }
    private(set) var active: Request?
    private var pending: Request?

    mutating func enqueue(_ output: String, receipt: UUID) -> [UUID] {
        let request = Request(output: output, receipts: [receipt])
        guard active != nil else { active = request; return [] }
        if pending?.output == output { pending?.receipts.append(receipt); return [] }
        let superseded = pending?.receipts ?? []
        if active?.output == output {
            pending = nil
            active?.receipts.append(receipt)
        } else {
            pending = request
        }
        return superseded
    }

    mutating func finished() -> [UUID] {
        let receipts = active?.receipts ?? []
        active = pending
        pending = nil
        return receipts
    }
}

struct SpeakerOutputResult: Decodable {
    let status: String
    let output: String?
    let warnings: [String]?
    let errors: [String]?
}

struct SpeakerSwitchOutcome {
    let phase: SpokenCommandJournal.Phase
    let message: String
    var verified: Bool { phase == .confirmed }
    static func failure(_ message: String, beforeDispatch: Bool = false) -> Self {
        Self(phase: beforeDispatch ? .failedBeforeDispatch : .unknown, message: message)
    }
}

enum SpeakerOutput {
    private static var helper: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/skills/live-voice-mode/scripts/switch-output.py")
    }
    static var helperInstalled: Bool { FileManager.default.isReadableFile(atPath: helper.path) }
    // CoreAudio's output inventory plus the helper's reconnectable favourites.
    // This lists devices only. The same helper verifies and switches the route later.
    static func available(helper: URL = Self.helper, connected: () -> [String] = connectedOutputs) -> [String] {
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return [] }
        let devices = Dictionary(grouping: connected(), by: { $0 })
        let names = Set(devices.keys).union(configured(helper))
        return names.filter { devices[$0, default: []].count < 2 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func connectedOutputs() -> [String] {
        let locations = ["/opt/homebrew/bin/SwitchAudioSource", "/usr/local/bin/SwitchAudioSource"]
        guard let tool = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let data = read(URL(fileURLWithPath: tool), arguments: ["-a", "-t", "output", "-f", "json"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        struct Device: Decodable { let name: String }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap {
            (try? decoder.decode(Device.self, from: Data($0.utf8)))?.name
        }
    }
    private static func configured(_ helper: URL) -> [String] {
        // Parse constants without importing the helper: opening settings must never execute
        // future top-level helper code or perform an audio operation.
        let reader = """
        import ast, json, sys
        tree = ast.parse(open(sys.argv[1], encoding='utf-8').read())
        values = {n.targets[0].id: n.value.value for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)}
        table = next(n.value for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id == 'BLUETOOTH_ADDRESSES')
        print(json.dumps([values['DEFAULT'], *[values[k.id] for k in table.keys]]))
        """
        guard let data = read(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", reader, helper.path])
        else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    private static func read(_ path: URL, arguments: [String]) -> Data? {
        let process = Process(), pipe = Pipe()
        process.executableURL = path
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
    // The shared helper snapshots input before connecting Bluetooth, verifies routing, and restores
    // only known speaker-microphone takeovers. Never duplicate that policy in the app.
    static func switchTo(_ output: String, dispatchBefore: Double? = nil) -> SpeakerSwitchOutcome {
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return .failure("Audio switch helper not found.", beforeDispatch: true) }
        guard available().contains(output) else { return .failure("Output is unavailable or has a duplicate name.", beforeDispatch: true) }
        return run(output, helper: helper, dispatchBefore: dispatchBefore)
    }
    static func run(_ output: String, helper: URL, dispatchBefore: Double? = nil) -> SpeakerSwitchOutcome {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, "--", output]
        process.standardOutput = pipe
        // The helper returns structured errors on stdout. An unread stderr pipe can fill
        // and block both the helper and H Chat's completion receipt. Found and fixed by GPT-6.1 Sol.
        process.standardError = FileHandle.nullDevice
        do {
            guard dispatchBefore.map({ ProcessInfo.processInfo.systemUptime <= $0 }) != false else {
                return .failure("The speaker request expired.", beforeDispatch: true)
            }
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let result = try? JSONDecoder().decode(SpeakerOutputResult.self, from: data) else { return .failure("Couldn't read audio switch result.") }
            if result.status == "ok", (result.errors ?? []).isEmpty, process.terminationStatus == 0 {
                guard result.output == output else { return .failure("The selected output didn't match the requested speaker.") }
                let message = (["Switched speakers to \(output)"] + (result.warnings ?? [])).joined(separator: ". ")
                return SpeakerSwitchOutcome(phase: .confirmed, message: message)
            }
            let errors = (result.errors ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return .failure(errors.isEmpty ? "Couldn't switch speakers." : errors.joined(separator: " "))
        } catch { return .failure("Couldn't start audio switch: \(error.localizedDescription)", beforeDispatch: true) }
    }
}
