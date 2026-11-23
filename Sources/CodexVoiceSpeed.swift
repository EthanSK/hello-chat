// Temporary Codex defaults for H Chat's native new-Voice shortcut.
import Darwin
import Foundation

private enum ConfigWriteError: LocalizedError {
    case versionConflict
    var errorDescription: String? { "Codex settings changed while Voice was opening." }
}

actor CodexVoiceSpeed {
    static let shared = CodexVoiceSpeed()
    static let preferenceKey = "ultrafastForNewVoiceChats"
    static let model = "gpt-6.2-sol"
    static let effort = "high"
    static let tier = "ultrafast"
    private static let requested = ["model": model, "model_reasoning_effort": effort, "service_tier": tier]
    private let receipt: URL
    private var owner: UUID?
    private var sentAt: Date?
    private var latestSessionStart: Date?
    private var expiry: Task<Void, Never>?

    init(receipt: URL = AppPaths.support.appendingPathComponent("VoiceLaunch/defaults.json")) { self.receipt = receipt }

    // Save the actual user-layer entries. A missing key must be removed on restore,
    // so inherited defaults and later unrelated edits continue to work.
    private struct Edit: Codable { let key: String; let previous: String?; let temporary: String }
    private struct Saved: Codable { let file: String; let edits: [Edit] }
    private struct Layer {
        let file: String
        let version: String
        let values: [String: Any]
    }

    static func executable(pid: Int32? = nil) throws -> URL {
        let url: URL
        if let pid {
            guard let app = VoiceBridge.currentApplication(), app.processIdentifier == pid, let bundle = app.bundleURL
            else { throw BridgeError.message("Codex closed while opening Voice.") }
            url = bundle
        } else { url = try VoiceBridge.applicationURL() }
        let resources = url.appendingPathComponent("Contents/Resources")
        let paths = ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"]
        guard let exe = paths.map({ resources.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw BridgeError.message("Couldn't find the Codex configuration tool.") }
        return exe
    }

    private func client(_ exe: URL, _ environment: [String: String]?) throws -> CodexConfigClient {
        let c = CodexConfigClient()
        do {
            try c.start(exe, environment: environment)
            _ = try c.request("initialize", ["clientInfo": ["name": "hello_chat", "version": "1"]])
            try c.notifyInitialized()
            return c
        } catch { c.close(); throw error }
    }

    private func layer(_ client: CodexConfigClient, file: String? = nil) throws -> Layer {
        let settings = try client.request("config/read", ["includeLayers": true])
        let layers = (settings["layers"] as? [[String: Any]] ?? []).compactMap { row -> Layer? in
            guard let name = row["name"] as? [String: Any], name["type"] as? String == "user",
                  let path = name["file"] as? String, let version = row["version"] as? String,
                  let values = row["config"] as? [String: Any], row["disabledReason"] as? String == nil
            else { return nil }
            return Layer(file: path, version: version, values: values)
        }
        guard let selected = file.flatMap({ f in layers.first { $0.file == f } }) ?? (file == nil ? layers.last : nil)
        else { throw client.failure }
        return selected
    }

    private func write(_ values: [(String, String?)], layer: Layer, client: CodexConfigClient) throws {
        let edits: [[String: Any]] = values.map { ["keyPath": $0.0, "mergeStrategy": "replace", "value": $0.1 as Any? ?? NSNull()] }
        let result = try client.request("config/batchWrite", ["edits": edits, "filePath": layer.file,
            "expectedVersion": layer.version, "reloadUserConfig": false])
        guard result["status"] as? String == "ok" else { throw client.failure }
    }

    func prepare(_ id: UUID, executable: URL, environment: [String: String]? = nil) throws {
        guard owner == nil else { throw BridgeError.message("Another Voice chat is opening.") }
        try recover(executable: executable, environment: environment)
        let c = try client(executable, environment)
        defer { c.close() }
        let original = try layer(c)
        let changes = Self.requested.sorted { $0.key < $1.key }.compactMap { key, requested -> Edit? in
            let previous = original.values[key] as? String
            return previous == requested ? nil : Edit(key: key, previous: previous, temporary: requested)
        }
        guard !changes.isEmpty else { return }
        let data = try JSONEncoder().encode(Saved(file: original.file, edits: changes))
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: receipt, options: .atomic)
        owner = id
        do {
            try write(changes.map { ($0.key, $0.temporary) }, layer: original, client: c)
            let updated = try layer(c, file: original.file)
            guard changes.allSatisfy({ updated.values[$0.key] as? String == $0.temporary }) else { throw c.failure }
        } catch ConfigWriteError.versionConflict {
            // The server rejected the entire batch before any change. A concurrent
            // user edit can legitimately equal one of our requested values.
            owner = nil
            try FileManager.default.removeItem(at: receipt)
            throw ConfigWriteError.versionConflict
        } catch {
            owner = nil
            try restore(executable: executable, environment: environment)
            throw error
        }
    }

    func recover(executable: URL, environment: [String: String]? = nil) throws {
        guard owner == nil else { return }
        try restore(executable: executable, environment: environment)
    }
    private func restore(executable: URL, environment: [String: String]?) throws {
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: receipt))
        let c = try client(executable, environment)
        defer { c.close() }
        func restoreOwnedKeys() throws -> Int {
            let current = try layer(c, file: saved.file)
            let owned = saved.edits.filter { current.values[$0.key] as? String == $0.temporary }
            if !owned.isEmpty {
                try write(owned.map { ($0.key, $0.previous) }, layer: current, client: c)
                let checked = try layer(c, file: saved.file)
                guard owned.allSatisfy({ checked.values[$0.key] as? String == $0.previous }) else { throw c.failure }
            }
            return owned.count
        }
        let restored: Int
        do { restored = try restoreOwnedKeys() } catch ConfigWriteError.versionConflict {
            restored = try restoreOwnedKeys()
        }
        try FileManager.default.removeItem(at: receipt)
        Diagnostics.shared.record("voice.defaults.restored", numbers: ["keys": Double(restored)])
    }

    // The floating Voice UI can appear before thread creation. Use the existing
    // local session-start observer. Failed and abandoned launches release immediately.
    func finish(_ id: UUID, sent: Date?, executable: URL, environment: [String: String]? = nil,
                timeout: TimeInterval = 15) throws {
        guard owner == id else { return }
        if let sent, latestSessionStart.map({ $0 < sent }) ?? true {
            sentAt = sent
            expiry?.cancel()
            expiry = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard owner == id else { return }
                Diagnostics.shared.record("voice.defaults.session_unverified")
                do { try release(executable, environment) } catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
            }
        } else { try release(executable, environment) }
    }
    func observedSessionStart(_ date: Date, executable: URL, environment: [String: String]? = nil) throws {
        latestSessionStart = date
        if let sentAt, date >= sentAt, owner != nil { try release(executable, environment) }
    }
    private func release(_ exe: URL, _ environment: [String: String]?) throws {
        expiry?.cancel(); expiry = nil; sentAt = nil; owner = nil
        try restore(executable: exe, environment: environment)
    }
    func shutdown() throws {
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        try release(Self.executable(), nil)
    }
    func recoverOnLaunch() {
        guard owner == nil, FileManager.default.fileExists(atPath: receipt.path) else { return }
        do { try recover(executable: Self.executable()) }
        catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
    }
}

// This short-lived client only reads and writes configuration. It never opens threads or calls.
// Bound the exchange so an unresponsive Codex binary cannot leave H Chat stuck on Start.
private final class CodexConfigClient {
    let failure = BridgeError.message("Couldn’t update the Codex Voice launch settings.")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var buffer = Data()
    private let deadline = ProcessInfo.processInfo.systemUptime + 8

    func start(_ executable: URL, environment: [String: String]?) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw failure }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func notifyInitialized() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"method\":\"initialized\"}\n".utf8))
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["id": nextID, "method": method, "params": params])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        while true {
            let line = try readLine()
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw failure }
            guard reply["id"] as? Int == nextID else { continue }
            if let error = reply["error"] as? [String: Any], let data = error["data"] as? [String: Any],
               data["config_write_error_code"] as? String == "configVersionConflict" {
                throw ConfigWriteError.versionConflict
            }
            guard let result = reply["result"] as? [String: Any] else { throw failure }
            return result
        }
    }

    private func readLine() throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < 16 * 1024 * 1024 else { throw failure }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeout = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&item, 1, timeout)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw failure }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw failure
    }
}
