// Gate desktop shortcuts on the current login session without changing security
// settings. Lock/unlock notifications invalidate pending work; they never start it.
import AppKit
import CoreGraphics

enum DesktopSessionState: String {
    case interactive, locked, inactive, unknown

    static func read(_ session: [String: Any]?) -> Self {
        guard let session else { return .unknown }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["kCGSessionLoginDoneKey"] as? Bool == true else { return .inactive }
        return .interactive
    }

    static var current: Self {
        read(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    var message: String {
        self == .locked ? "Unlock your Mac, then try again." : "Switch to this Mac's desktop, then try again."
    }
}

@MainActor final class DesktopSessionMonitor {
    private(set) var state: DesktopSessionState
    var onChange: ((DesktopSessionState) -> Void)?
    private let readState: () -> DesktopSessionState
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(readState: @escaping () -> DesktopSessionState = { .current }, observe: Bool = true) {
        self.readState = readState; state = readState()
        guard observe else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(.inactive) }
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.name.rawValue == "com.apple.screenIsLocked" { self?.update(.locked) }
                    else { self?.refresh() }
                }
            })
        }
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func refresh() { update(readState()) }
    private func update(_ newState: DesktopSessionState) {
        guard newState != state else { return }
        state = newState; onChange?(newState)
    }
}
