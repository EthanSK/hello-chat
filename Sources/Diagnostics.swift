import Foundation
import os
import Darwin

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
                // The headless startup reader now writes metadata too. Serialize
                // append and rotation with the app across processes, off-main.
                let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { close(lock) }
                guard flock(lock, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { flock(lock, LOCK_UN) }
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
    private struct CommandRecord {
        var at: Double
        var time: String
        var label: String
        var summary: String
    }

    // Called on the log queue. A receipt can finish after a newer command, including
    // after log rotation. Keep the latest outcome for each receipt in speech order.
    private func commandRecords() throws -> [CommandRecord] {
        var records: [CommandRecord] = []
        var index: [String: Int] = [:]
        for name in ["events.previous.jsonl", "events.jsonl"] {
            let source = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            for line in data.split(separator: 10) {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      event["event"] as? String == "command.history",
                      let time = event["time"] as? String, let command = event["command"] as? String,
                      let result = event["result"] as? String, let summary = event["summary"] as? String else { continue }
                let at = event["spoken_at"] as? Double ?? dateFormatter.date(from: time)?.timeIntervalSince1970 ?? 0
                let record = CommandRecord(at: at, time: time, label: "\(command) · \(result)", summary: summary)
                if let receipt = event["receipt"] as? String {
                    if let i = index[receipt] { records[i] = record; continue }
                    index[receipt] = records.count
                }
                records.append(record)
            }
        }
        return records.sorted { $0.at < $1.at }
    }

    func latestCommandSummary() -> String? {
        queue.sync { try? commandRecords().last?.summary }
    }

    func commandHistory(limit: Int) throws -> [[String: String]] {
        try queue.sync { try commandRecords().suffix(limit).map { ["time": $0.time, "command": $0.label, "summary": $0.summary] } }
    }

    func exportCommandHistory() throws -> URL {
        try queue.sync {
            var lines = try commandRecords().map {
                "\($0.time)  \($0.label)" + ($0.summary == $0.label ? "" : " — " + $0.summary)
            }
            if lines.isEmpty { lines.append("No spoken commands recorded in this history yet.") }
            lines.append("\nEarlier events and technical details are in the diagnostic logs at \(directory.path).")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("Command history.txt")
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    func flush() { queue.sync {} }
}
