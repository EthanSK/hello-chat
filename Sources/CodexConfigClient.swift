// MOVED FROM CodexVoiceSpeed.swift: existing bounded stdio client, now shared with notification relay provisioning. — GPT-6.1 Sol
import Foundation
import Darwin

enum ConfigWriteError: LocalizedError {
    case versionConflict
    var errorDescription: String? { "Codex settings changed while Voice was opening." }
}


final class CodexConfigClient {
    static let configurationFailure = BridgeError.message("Couldn’t update the Codex Voice launch settings.")
    let failure = configurationFailure
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var buffer = Data()
    private let finished = DispatchSemaphore(value: 0)
    private let deadline = ProcessInfo.processInfo.systemUptime + 8

    func start(_ executable: URL, environment: [String: String]?) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [finished] _ in finished.signal() }
        do { try process.run() } catch { throw failure }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    // A persisted blank fork must finish its owning server through stdin EOF, not a termination signal. — GPT-6.1 Sol
    func finishPersisting() throws {
        try input.fileHandleForWriting.close()
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard finished.wait(timeout: .now() + remaining) == .success,
              process.terminationReason == .exit, process.terminationStatus == 0 else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw failure
        }
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
