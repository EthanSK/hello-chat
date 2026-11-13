// The Agent Bridge SSH process can reach the filesystem but its background
// macOS session cannot reliably discover GUI applications. The signed H Chat
// already running in the desktop session handles all native Voice checks.
import Darwin
import Foundation

final class VoicePeerMailbox {
    enum Action: String, Codable { case status, end, confirmEnd }

    struct Request: Codable {
        let action: Action
        let call: VoicePeerCall?
        let expires: TimeInterval

        var valid: Bool {
            let now = Date().timeIntervalSince1970
            guard expires > now, expires <= now + 15 else { return false }
            return action == .status ? call == nil : (call?.pid ?? 0) > 0
        }
    }

    private static let directory = AppPaths.support.appendingPathComponent("voice-peer", isDirectory: true)
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
