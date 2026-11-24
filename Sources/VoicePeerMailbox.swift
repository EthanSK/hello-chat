// The Agent Bridge SSH process can reach the filesystem but its background
// macOS session cannot reliably discover GUI applications. The signed H Chat
// already running in the desktop session handles all native Voice checks.
import Darwin
import Foundation

final class VoicePeerMailbox {
    enum Action: String, Codable {
        case status = "--voice-peer-status"
        case resolve = "--voice-peer-resolve"
        case end = "--voice-peer-end"
        case confirmEnd = "--voice-peer-confirm-end"
    }

    struct Request: Codable {
        let action: Action
        let call: VoicePeerCall?
        let expires: TimeInterval
        var otherCall: VoicePeerCall? = nil

        static let queryLifetime: TimeInterval = 4
        var valid: Bool { valid(at: Date().timeIntervalSince1970) }

        func valid(at now: TimeInterval) -> Bool {
            guard expires > now, expires <= now + 15 else { return false }
            switch action {
            case .status: return call == nil && otherCall == nil
            case .resolve, .end: return (call?.pid ?? 0) > 0 && (otherCall?.pid ?? 0) > 0
            case .confirmEnd: return (call?.pid ?? 0) > 0 && otherCall == nil
            }
        }

        var arguments: [String]? {
            switch action {
            case .status: return [action.rawValue]
            case .confirmEnd:
                guard let call else { return nil }
                return [action.rawValue, call.token]
            case .resolve, .end:
                guard let call, let otherCall else { return nil }
                return [action.rawValue, call.token, otherCall.token, String(expires), VoicePeerReceipt.endVersion]
            }
        }

        static func parse(_ arguments: [String], now: TimeInterval) -> Self? {
            guard let command = arguments.first, let action = Action(rawValue: command) else { return nil }
            let request: Self
            switch (action, arguments.count) {
            case (.status, 1):
                request = .init(action: action, call: nil, expires: now + queryLifetime)
            case (.confirmEnd, 2):
                request = .init(action: action, call: VoicePeerCall(token: arguments[1]), expires: now + queryLifetime)
            case (.resolve, 5), (.end, 5):
                guard arguments[4] == VoicePeerReceipt.endVersion, let expires = TimeInterval(arguments[3]) else { return nil }
                request = .init(action: action, call: VoicePeerCall(token: arguments[1]), expires: expires,
                                otherCall: VoicePeerCall(token: arguments[2]))
            default: return nil
            }
            return request.valid(at: now) ? request : nil
        }
    }

    // CLI requests enter the signed desktop app through this same versioned parser. — GPT-6.2 Astra
    static func command(_ arguments: [String], enabled: () -> Bool = { VoicePeerConfiguration.installed != nil },
                        now: TimeInterval = Date().timeIntervalSince1970,
                        send: (Request) -> VoicePeerReceipt = { submit($0) }) -> VoicePeerReceipt? {
        guard let flag = arguments.first, Action(rawValue: flag) != nil else { return nil }
        guard enabled() else { return .init(status: .disabled) }
        guard let request = Request.parse(arguments, now: now) else { return .init(status: .unknown) }
        return send(request)
    }

    // Keep an in-flight request from an older executable out of the new
    // listener too. The CLI and desktop app can briefly straddle an update.
    private static let directory = AppPaths.support.appendingPathComponent(
        "voice-peer-\(VoicePeerReceipt.endVersion)", isDirectory: true)
    private let directory: URL
    private let handler: (Request) -> VoicePeerReceipt
    private let queue = DispatchQueue(label: "com.ethansk.HeyChat.voice-peer-mailbox", qos: .utility)
    private var observer: DispatchSourceFileSystemObject?

    init(directory: URL = VoicePeerMailbox.directory, handler: @escaping (Request) -> VoicePeerReceipt) {
        self.directory = directory
        self.handler = handler
    }

    func start() {
        guard observer == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return }
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { close(fd) }
        observer = source
        source.resume()
        queue.async { [weak self] in self?.receive() }
    }

    func stop() {
        observer?.cancel()
        observer = nil
    }

    private func receive() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        for file in files {
            let extensionless = file.deletingPathExtension()
            guard UUID(uuidString: extensionless.lastPathComponent) != nil else { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if file.pathExtension == "reply",
               let date = values?.contentModificationDate, date.timeIntervalSinceNow < -30 {
                try? FileManager.default.removeItem(at: file)
            }
            guard file.pathExtension == "request" else { continue }
            let data = values?.fileSize.map { $0 < 4096 } == true ? try? Data(contentsOf: file) : nil
            // Only the running H Chat instance can consume requests, on this
            // serial queue. Delete before replying even when the request expired.
            guard (try? FileManager.default.removeItem(at: file)) != nil,
                  let data, let request = try? JSONDecoder().decode(Request.self, from: data),
                  request.valid else { continue }
            let result = handler(request)
            try? JSONEncoder().encode(result).write(to: extensionless.appendingPathExtension("reply"), options: .atomic)
        }
    }

    static func submit(_ request: Request, directory: URL = VoicePeerMailbox.directory) -> VoicePeerReceipt {
        let unknown = VoicePeerReceipt(status: .unknown)
        guard request.valid else { return unknown }
        let transaction = directory.appendingPathComponent(UUID().uuidString)
        let input = transaction.appendingPathExtension("request")
        let output = transaction.appendingPathExtension("reply")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        do { try JSONEncoder().encode(request).write(to: input, options: .atomic) }
        catch { return unknown }
        let deadline = min(request.expires + 1, Date().timeIntervalSince1970 + 4)
        repeat {
            if let data = try? Data(contentsOf: output),
               let receipt = try? JSONDecoder().decode(VoicePeerReceipt.self, from: data) { return receipt }
            Thread.sleep(forTimeInterval: 0.08)
        } while Date().timeIntervalSince1970 < deadline
        return unknown
    }
}
