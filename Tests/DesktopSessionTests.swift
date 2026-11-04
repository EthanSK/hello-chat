// Exercise session classification and unlock transitions without locking the Mac.
import Foundation

@main enum DesktopSessionTests {
    @MainActor static func main() {
        precondition(DesktopSessionState.read(nil) == .unknown)
        precondition(DesktopSessionState.read([:]) == .inactive)
        let ready: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        precondition(DesktopSessionState.read(ready) == .interactive)
        var locked = ready; locked["CGSSessionScreenIsLocked"] = true
        precondition(DesktopSessionState.read(locked) == .locked)
        var inactive = ready; inactive["kCGSSessionOnConsoleKey"] = false
        precondition(DesktopSessionState.read(inactive) == .inactive)
        var current = DesktopSessionState.interactive, transitions: [DesktopSessionState] = []
        let monitor = DesktopSessionMonitor(readState: { current }, observe: false)
        monitor.onChange = { transitions.append($0) }
        current = .locked; monitor.refresh(); monitor.refresh()
        current = .interactive; monitor.refresh()
        precondition(transitions == [.locked, .interactive], "Lock/unlock invalidates once per state change")
        print("Desktop session classification and lock/unlock transitions passed; no real session change")
    }
}
