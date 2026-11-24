// Agent Bridge invokes --agent-control-v1 to reach the existing signed H Chat desktop process.
import Foundation
import CryptoKit
import Darwin

struct HControlRequest {
    let id: UUID
    let expires: Double
    let operation: String
    let arguments: [String: Any]
    let canonical: Data

    init(_ data: Data) throws {
        guard data.count <= Self.limit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["id", "version", "expiresAt", "operation", "arguments"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let raw = object["id"] as? String, let id = UUID(uuidString: raw),
              let time = object["expiresAt"] as? NSNumber, CFGetTypeID(time) != CFBooleanGetTypeID(),
              let operation = object["operation"] as? String, !operation.isEmpty, operation.utf8.count <= 100,
              let arguments = object["arguments"] as? [String: Any] else { throw HControlFailure.invalid("Invalid version 1 control request.") }
        self.id = id
        self.expires = time.doubleValue
        self.operation = operation
        self.arguments = arguments
        var normalized = object
        normalized["id"] = id.uuidString.lowercased()
        self.canonical = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    var receiptPrefix: Data {
        Data((SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined() + "\n").utf8)
    }

    func current(at now: Double) -> Bool { expires > now && expires <= now + 120 }
    static let limit = 64 * 1024
}

enum HControlFailure: Error {
    case invalid(String), conflict(String), unavailable(String), unknown(String)

    var outcome: HControlOutcome {
        switch self {
        case .invalid(let text): return .init(.invalid, message: text)
        case .conflict(let text): return .init(.conflict, message: text)
        case .unavailable(let text): return .init(.unavailable, message: text)
        case .unknown(let text): return .init(.unknown, message: text)
        }
    }
}

struct HControlOutcome {
    enum State: String { case confirmed, sent, accepted, invalid, conflict, unavailable, unknown }
    let state: State
    let result: Any
    let message: String?
    let afterReceipt: (@MainActor () -> Void)?
    init(_ state: State, _ result: Any = NSNull(), message: String? = nil, afterReceipt: (@MainActor () -> Void)? = nil) {
        self.state = state; self.result = result; self.message = message; self.afterReceipt = afterReceipt
    }
    func receipt(for id: UUID) throws -> Data {
        var object: [String: Any] = ["version": 1, "id": id.uuidString.lowercased(), "state": state.rawValue, "result": result]
        if let message { object["message"] = message }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 512 * 1024 else { throw HControlFailure.unavailable("The result exceeds the control response limit.") }
        return bytes
    }
}

final class HControlMailbox {
    typealias Handler = @MainActor (HControlRequest) async throws -> HControlOutcome
    static let directory = AppPaths.support.appendingPathComponent("agent-control-v1", isDirectory: true)
    let directory: URL
    private let instance = UUID().uuidString
    private let handler: Handler
    private let queue = DispatchQueue(label: "HelloChat.agent-control")
    private var observer: DispatchSourceFileSystemObject?
    private var cleanedAt = Date.distantPast

    init(directory: URL = HControlMailbox.directory, handler: @escaping Handler) {
        self.directory = directory; self.handler = handler
    }

    func start() throws {
        guard observer == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(fd) }
        observer = source
        source.resume()
        let owner = try JSONSerialization.data(withJSONObject: ["instance": instance, "pid": ProcessInfo.processInfo.processIdentifier])
        try owner.write(to: directory.appendingPathComponent("owner"), options: .atomic)
        queue.async { [weak self] in self?.receive() }
    }
    deinit { observer?.cancel() }

    private func receive() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        let clean = Date().timeIntervalSince(cleanedAt) > 60
        if clean { cleanedAt = Date() }
        for file in files {
            let base = file.deletingPathExtension()
            let suffix = file.pathExtension
            guard let id = UUID(uuidString: base.lastPathComponent), ["request","claim","reply"].contains(suffix),
                  let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            if clean, let date = attributes.contentModificationDate, date.timeIntervalSinceNow < -300 {
                try? fm.removeItem(at: file)
                continue
            }
            guard suffix == "request", attributes.fileSize.map({ $0 <= HControlRequest.limit + 37 }) == true,
                  let bytes = try? Data(contentsOf: file), bytes.count > 37,
                  let request = try? HControlRequest(bytes.dropFirst(37)), request.id == id else { continue }
            let claim = base.appendingPathExtension("claim")
            // A durable exclusive claim survives a crash after a shortcut is sent. It is never automatically replayed. — GPT-6.2 Astra
            guard link(file.path, claim.path) == 0 else { continue }
            let owned = bytes.prefix(37) == Data((instance + "\n").utf8)
            Task { @MainActor [handler] in
                let outcome: HControlOutcome
                if !owned { outcome = .init(.unavailable, message: "The receiving H Chat instance changed.") }
                else if !request.current(at: Date().timeIntervalSince1970) { outcome = .init(.invalid, message: "The request expired.") }
                else {
                    do { outcome = try await handler(request) }
                    catch let error as HControlFailure { outcome = error.outcome }
                    catch { outcome = .init(.unknown, message: error.localizedDescription) }
                }
                let response: Data
                do { response = try outcome.receipt(for: id) }
                catch { response = (try? HControlOutcome(.unknown, message: "The result could not be encoded.").receipt(for: id)) ?? Data() }
                do {
                    try (request.receiptPrefix + response).write(to: base.appendingPathExtension("reply"), options: .atomic)
                    outcome.afterReceipt?()
                } catch { /* The durable claim still prevents another dispatch. */ }
            }
        }
    }

    static func submit(_ request: HControlRequest, directory: URL = directory) throws -> Data {
        let base = directory.appendingPathComponent(request.id.uuidString.lowercased())
        let input = base.appendingPathExtension("request")
        let reply = base.appendingPathExtension("reply")
        func prior() throws -> Data? {
            guard let existing = try? Data(contentsOf: input) else { return nil }
            guard existing.dropFirst(37) == request.canonical else {
                throw HControlFailure.conflict("This request ID already belongs to different arguments.")
            }
            guard let record = try? Data(contentsOf: reply), record.starts(with: request.receiptPrefix) else { return nil }
            return Data(record.dropFirst(request.receiptPrefix.count))
        }
        if let response = try prior() { return response }
        guard request.current(at: Date().timeIntervalSince1970) else {
            if FileManager.default.fileExists(atPath: base.appendingPathExtension("claim").path) { throw HControlFailure.unknown("The request was claimed, but no final receipt is available.") }
            throw HControlFailure.invalid("The expiry must be within the next 120 seconds.")
        }
        guard let owner = try? Data(contentsOf: directory.appendingPathComponent("owner")),
              let fields = try? JSONSerialization.jsonObject(with: owner) as? [String: Any],
              let instance = fields["instance"] as? String, UUID(uuidString: instance) != nil,
              let pid = fields["pid"] as? Int32, pid > 0, kill(pid, 0) == 0 else {
            if FileManager.default.fileExists(atPath: base.appendingPathExtension("claim").path) { throw HControlFailure.unknown("H Chat stopped after claiming the request.") }
            throw HControlFailure.unavailable("Open H Chat on this Mac.")
        }
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try (Data((instance + "\n").utf8) + request.canonical).write(to: temporary, options: .atomic)
        if link(temporary.path, input.path) != 0, errno != EEXIST { throw POSIXError(.EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + min(120, max(0, request.expires - Date().timeIntervalSince1970)) + 0.25
        let acceptedAt = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let response = try prior() { return response }
            if ProcessInfo.processInfo.systemUptime >= acceptedAt, let claim = try? Data(contentsOf: base.appendingPathExtension("claim")) {
                guard claim.prefix(37) == Data((instance + "\n").utf8) else {
                    throw HControlFailure.unknown("An earlier H Chat instance claimed the request. Its result is unknown.")
                }
                return try HControlOutcome(.accepted, message: "H Chat claimed the request. Resubmit the same envelope to retrieve its final receipt.").receipt(for: request.id)
            }
            Thread.sleep(forTimeInterval: 0.08)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw HControlFailure.unknown("No completion receipt arrived. Reuse this exact request to check for its receipt.")
    }

    static func command() -> Int32 {
        let request: HControlRequest
        do {
            // Pipes can deliver short fragments. Stop reading at the limit even if the caller never closes stdin. — GPT-6.2 Astra
            var data = Data()
            while data.count <= HControlRequest.limit {
                let part = FileHandle.standardInput.readData(ofLength: min(8192, HControlRequest.limit + 1 - data.count))
                if part.isEmpty { break }; data.append(part)
            }
            request = try HControlRequest(data)
        } catch { FileHandle.standardError.write(Data("Invalid H Chat control request.\n".utf8)); return 2 }
        let data: Data
        do { data = try submit(request) }
        catch {
            let failure = (error as? HControlFailure)?.outcome ?? .init(.unknown, message: error.localizedDescription)
            guard let encoded = try? failure.receipt(for: request.id) else { return 2 }
            data = encoded
        }
        FileHandle.standardOutput.write(data + Data([10]))
        return 0
    }
}
