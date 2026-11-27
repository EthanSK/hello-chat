import Foundation

struct CustomScriptPhrases {
    struct Command: Decodable {
        let name: String
        let phrases: [String]
        let executable: String
        let arguments: [String]?
        let workingDirectory: String?
    }

    static let file = AppPaths.support.appendingPathComponent("CustomPhrases.json")
    private let commands: [String: Command]
    let count: Int

    init(data: Data = Data("[]".utf8)) throws {
        let entries = try JSONDecoder().decode([Command].self, from: data)
        var commands: [String: Command] = [:]
        for entry in entries {
            let keys = Set(entry.phrases.map(PhraseList.key))
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !keys.isEmpty, !keys.contains(""), entry.executable.hasPrefix("/"),
                  entry.workingDirectory?.hasPrefix("/") != false else { throw ConfigError.invalidEntry }
            for key in keys {
                guard commands[key] == nil else { throw ConfigError.duplicatePhrase }
                commands[key] = entry
            }
        }
        self.commands = commands
        count = entries.count
    }

    func command(for utterance: String) -> Command? {
        commands[PhraseList.key(utterance)]
    }

    static func load(from file: URL = file) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return try .init() }
        return try .init(data: Data(contentsOf: file))
    }

    static func openableFile() throws -> URL {
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[]\n".utf8).write(to: file, options: .withoutOverwriting)
        }
        return file
    }

    enum ConfigError: LocalizedError {
        case invalidEntry, duplicatePhrase
        var errorDescription: String? {
            switch self {
            case .invalidEntry: return "Give each command a name, a phrase and a full executable path."
            case .duplicatePhrase: return "Two custom commands use the same phrase."
            }
        }
    }
}

extension CustomScriptPhrases.Command {
    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments ?? []
        process.currentDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        return process
    }
}

struct CustomSpeechFinals {
    private var lastEnd = -Double.infinity

    // Apple final results may be repeated or revised for the same span. Only a new span can run a script. — GPT-6.2 Sol
    mutating func accept(start: Double, end: Double) -> Bool {
        guard start.isFinite, end.isFinite, end > start, start + 1e-6 >= lastEnd else { return false }
        lastEnd = end
        return true
    }
}
