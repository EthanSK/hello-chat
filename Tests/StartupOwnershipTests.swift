// Exercise registered-job handoff without installing or starting any real job.
import Foundation

@main enum StartupOwnershipTests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/LaunchAgents/test.owned.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: "/test/App.app/Contents/MacOS/App")
        var commands: [[String]] = []
        let program = "program = \(executable.path)\n"
        var job = program + "state = exited\n", loaded: Int32 = 0, kickstart: Int32 = 0
        func run(_ args: [String]) -> (Int32, String) {
            commands.append(args)
            return args[0] == "print" ? (loaded, job) : (kickstart, "")
        }
        func handoff() -> Bool {
            StartupOwnership.handoffIfNeeded(executable: executable, home: home, label: "test.owned", pid: 123, run: run)
        }
        precondition(!handoff() && commands.isEmpty, "Users without a startup job are unchanged")
        let config: [String: Any] = ["Label": "test.owned", "ProgramArguments": [executable.path]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: file)
        precondition(handoff() && commands.last?.first == "kickstart", "A clean Sparkle relaunch returns to the existing job")
        precondition(!commands.contains { $0.contains("-k") }, "Never kill a process to hand off startup")
        commands = []; job = program + "\tpid = 123\n"
        precondition(!handoff() && commands.count == 1, "The launchd-owned process proceeds without a loop")
        commands = []; job = program + "\tpid = 456\n"
        precondition(handoff() && commands.count == 1, "An existing owned process is not restarted")
        commands = []; loaded = 1
        precondition(!handoff() && commands.count == 1, "An unloaded job stays unloaded")
        commands = []; loaded = 0; job = program; kickstart = 1
        precondition(!handoff(), "Failed handoff keeps the normal application available")
        commands = []; job = "program = /different/program\n"; kickstart = 0
        precondition(!handoff() && commands.count == 1, "A loaded job must match the owned executable too")
        var custom = config; custom["ProgramArguments"] = ["/different/program"]
        try PropertyListSerialization.data(fromPropertyList: custom, format: .xml, options: 0).write(to: file)
        commands = []
        precondition(!handoff() && commands.isEmpty, "A customized startup job is never taken over")
        print("Startup ownership: handoff, loop prevention, absent/custom jobs and failure fallback passed")
    }
}
