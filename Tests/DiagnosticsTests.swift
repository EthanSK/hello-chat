import Foundation

@main enum DiagnosticsTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Diagnostics(directory: directory, limit: 1024)
        for index in 0..<100 { log.record("fixture.event", numbers: ["index": Double(index)], info: ["scope": "test"]) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(files.count == 2, "Keep only the current and previous bounded log")
        for file in files {
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
        print("Passed diagnostics checks: valid ordered JSON, bounded rotation, private file permissions and bounded recent events.")
    }
}
