import Foundation
import os

// Small, serialized event logs. Never pass recognized words or audio here.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    let directory: URL
    private let queue = DispatchQueue(label: "com.ethansk.HeyChat.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: "com.ethansk.HeyChat", category: "timing")
    private let limit: Int
    private let dateFormatter = ISO8601DateFormatter()
    private let recentLock = NSLock()
    private var recent: [String] = []
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HelloChat"), limit: Int = 512 * 1024) {
        self.directory = directory; self.limit = limit
    }
    func record(_ event: String, numbers: [String: Double] = [:], info: [String: String] = [:]) {
        let time = Date()
        queue.async { [self] in
            var value: [String: Any] = ["time": dateFormatter.string(from: time), "event": event]
            for (key, number) in numbers where number.isFinite { value[key] = number }
            for (key, text) in info { value[key] = String(text.prefix(240)) }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            recentLock.lock()
            recent.append(line)
            if recent.count > 40 { recent.removeFirst(recent.count - 40) }
            recentLock.unlock()
            logger.info("\(line, privacy: .public)")
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("events.jsonl")
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count + 1 > limit {
                    let old = directory.appendingPathComponent("events.previous.jsonl")
                    if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
                    if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: old) }
                }
                if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10]))
            } catch { logger.error("Diagnostic file write failed: \(String(describing: type(of: error)), privacy: .public)") }
        }
    }
    func failure(_ event: String, _ error: Error) {
        let error = error as NSError
        record(event, numbers: ["code": Double(error.code)], info: ["domain": error.domain])
    }
    func tail() -> String {
        recentLock.lock(); defer { recentLock.unlock() }
        return recent.suffix(8).joined(separator: "\n")
    }
    func flush() { queue.sync {} }
}
