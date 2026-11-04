// Sparkle relaunches with Launch Services. Before taking the instance lock or
// starting capture, hand that new process back to an existing owned launchd job
// so its abnormal-exit recovery remains active after updates.
import Foundation
import Darwin

enum StartupOwnership {
    static func handoffIfNeeded(executable: URL? = Bundle.main.executableURL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               label: String = "com.ethansk.hello-chat", pid: Int32 = getpid(),
                               run: ([String]) -> (Int32, String) = launchctl) -> Bool {
        guard let executable else { return false }
        let file = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let data = try? Data(contentsOf: file),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              config["Label"] as? String == label,
              config["ProgramArguments"] as? [String] == [executable.path] else { return false }
        let job = "gui/\(getuid())/\(label)"
        let (status, description) = run(["print", job])
        // A user-unloaded or customized job stays untouched. No bootstrap,
        // forced nonzero exit, -k restart, or new persistent helper is needed.
        guard status == 0 else { return false }
        guard description.split(separator: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "program = \(executable.path)"
        }) else { return false }
        let owner = description.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            return parts.count == 2 && parts[0] == "pid" ? Int32(parts[1]) : nil
        }.first
        if owner == pid { return false }
        if let owner, owner > 0 { return true }
        return run(["kickstart", job]).0 == 0
    }

    private static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (-1, "") }
    }
}
