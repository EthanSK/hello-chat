import Foundation
import Darwin

@main enum DiagnosticsTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Diagnostics(directory: directory, limit: 1024)
        for index in 0..<100 { log.record("fixture.event", numbers: ["index": Double(index)], info: ["scope": "test"]) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(files.count == 3, "Keep only current/previous bounded logs and the shared lock")
        for file in files where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            precondition(data.count <= 1024)
            for line in data.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let tail = log.tail().split(separator: "\n")
        precondition(tail.count == 8)
        let last = try JSONSerialization.jsonObject(with: Data(tail.last!.utf8)) as! [String: Any]
        precondition(last["index"] as? Double == 99)
        func descriptorCount() -> Int { (0..<getdtablesize()).reduce(0) { $0 + (fcntl($1, F_GETFD) >= 0 ? 1 : 0) } }
        let descriptorsBefore = descriptorCount()
        // App and headless reader may log at the same time. Their appends and
        // rotations must remain whole JSON lines, with one bounded lock file.
        let other = Diagnostics(directory: directory, limit: 1024)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            (index.isMultiple(of: 2) ? log : other).record("parallel.fixture", numbers: ["index": Double(index)])
        }
        log.flush(); other.flush()
        precondition(descriptorCount() <= descriptorsBefore, "Diagnostic lock descriptors must close after each write")
        let finalFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(finalFiles.count == 3)
        for file in finalFiles where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            precondition(data.count <= 1024)
            for line in data.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
        }
        print("Passed diagnostics checks: valid ordered JSON, bounded rotation, private file permissions and bounded recent events.")
    }
}
