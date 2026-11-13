import AppKit
import ApplicationServices
import CoreGraphics

enum ZoomShortcutError: Error, Equatable {
    case desktopUnavailable(DesktopSessionState)
    case accessibilityPermissionMissing
    case eventCreationFailed
}

// The same native action as Agentic Mouse's ApplicationZoomActionExecutor: Command-Shift and the
// physical Equals key (24) zooms in; Command and the physical Minus key (27) zooms out. One
// down/up pair goes to the frontmost app through the HID tap; focus, the mouse and menus are
// untouched. Success means the shortcut was sent, not that the app supports zoom.
struct ZoomShortcut {
    typealias EventPoster = (_ keyCode: CGKeyCode, _ flags: CGEventFlags, _ originalFlags: CGEventFlags) -> Bool
    static let equalsKeyCode: CGKeyCode = 24
    static let minusKeyCode: CGKeyCode = 27
    var post: EventPoster = ZoomShortcut.postSystemEvent
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var session: () -> DesktopSessionState = { .current }
    var currentFlags: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }

    static func key(for direction: ZoomDirection) -> (keyCode: CGKeyCode, flags: CGEventFlags) {
        direction == .zoomIn ? (equalsKeyCode, [.maskCommand, .maskShift]) : (minusKeyCode, [.maskCommand])
    }

    func perform(_ direction: ZoomDirection) -> Result<Void, ZoomShortcutError> {
        let state = session()
        guard state == .interactive else { return .failure(.desktopUnavailable(state)) }
        guard accessibilityTrusted() else { return .failure(.accessibilityPermissionMissing) }
        let key = Self.key(for: direction)
        // H Chat's established key-up rule (VoiceBridge): restore the modifiers held before sending,
        // so a synthetic Command/Shift can't linger and a modifier Ethan holds isn't released.
        guard post(key.keyCode, key.flags, currentFlags()) else { return .failure(.eventCreationFailed) }
        return .success(())
    }

    static func postSystemEvent(_ keyCode: CGKeyCode, _ flags: CGEventFlags, _ originalFlags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = originalFlags
        down.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        down.post(tap: .cghidEventTap)
        up.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        up.post(tap: .cghidEventTap)
        return true
    }
}

struct DesktopCommandResult: Equatable {
    let message: String?   // nil: ordinary speech, so the visible status stays unchanged.
    let diagnostic: String // Never contains spoken words or app names.
}

// Carries out app and zoom commands. Every dependency is injectable; tests never switch, open
// or type. Switch reads running apps only. Open reads a cached catalog of installed apps that is
// built on demand, never on every audio frame and never in the background.
@MainActor final class DesktopCommands {
    struct Environment {
        var session: () -> DesktopSessionState = { .current }
        var running: () -> [AppCandidate] = DesktopCommands.runningApps
        var activate: (AppCandidate) -> Bool = DesktopCommands.activateRunning
        var isFrontmost: (AppCandidate) -> Bool = DesktopCommands.isFrontmost
        var frontmostName: () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }
        var installed: () async -> [AppCandidate] = DesktopCommands.scanInstalled
        var verify: (AppCandidate) -> Bool = DesktopCommands.verifyInstalled
        var open: (AppCandidate) async -> Bool = DesktopCommands.openInstalled
        var sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        var zoom = ZoomShortcut()
    }
    static let catalogLifetime: TimeInterval = 120
    static let confirmationChecks = 10
    static let confirmationInterval = 0.1
    private let environment: Environment
    private var catalog: (apps: [AppCandidate], at: Date)?

    init(environment: Environment = Environment()) { self.environment = environment }

    func perform(_ candidate: AppCommandCandidate) async -> DesktopCommandResult {
        if let unavailable = unavailable() { return unavailable }
        switch candidate.kind {
        case .switchApp:
            return await carry(AppCommandPlanner.decideSwitch(candidate.name, running: environment.running()))
        case .openApp:
            return await carry(AppCommandPlanner.decideOpen(candidate, installed: await installedApps()))
        }
    }

    func zoom(_ direction: ZoomDirection) -> DesktopCommandResult {
        let target = environment.frontmostName() ?? "the front app"
        switch environment.zoom.perform(direction) {
        case .success: return DesktopCommandResult(message: "Sent \(direction.title) to \(target)", diagnostic: "sent")
        case .failure(.desktopUnavailable(let state)): return DesktopCommandResult(message: state.message, diagnostic: "session-\(state.rawValue)")
        case .failure(.accessibilityPermissionMissing):
            return DesktopCommandResult(message: "Allow Accessibility for Hello Chat, then try again.", diagnostic: "accessibility")
        case .failure(.eventCreationFailed): return DesktopCommandResult(message: "Couldn't send \(direction.title).", diagnostic: "event-failed")
        }
    }

    private func carry(_ decision: AppCommandDecision) async -> DesktopCommandResult {
        // The catalog can finish after a lock, stop, or quit. Recheck just before dispatch.
        if let unavailable = unavailable() { return unavailable }
        switch decision {
        case .ignore: return DesktopCommandResult(message: nil, diagnostic: "ignored")
        case .failure(let text): return DesktopCommandResult(message: text, diagnostic: "not-resolved")
        case .activate(let app):
            guard environment.activate(app) else {
                return DesktopCommandResult(message: "Couldn't switch to \(app.displayName).", diagnostic: "activate-failed")
            }
            return await confirm(app, done: "Switched to \(app.displayName)",
                pending: "Asked \(app.displayName) to come forward, but it isn't in front yet.")
        case .open(let app):
            guard environment.verify(app) else {
                catalog = nil
                return DesktopCommandResult(message: "\(app.displayName) is no longer installed there.", diagnostic: "verify-failed")
            }
            guard await environment.open(app) else {
                return DesktopCommandResult(message: "Couldn't open \(app.displayName).", diagnostic: "open-failed")
            }
            return await confirm(app, done: "Opened \(app.displayName)", pending: "Opening \(app.displayName). It isn't in front yet.")
        }
    }

    // Dispatch is not success: report frontmost only when macOS actually shows it.
    private func confirm(_ app: AppCandidate, done: String, pending: String) async -> DesktopCommandResult {
        for check in 0...Self.confirmationChecks {
            if let unavailable = unavailable() { return unavailable }
            if environment.isFrontmost(app) { return DesktopCommandResult(message: done, diagnostic: "frontmost") }
            if check < Self.confirmationChecks { await environment.sleep(Self.confirmationInterval) }
        }
        return DesktopCommandResult(message: pending, diagnostic: "dispatched")
    }

    private func unavailable() -> DesktopCommandResult? {
        if Task.isCancelled { return DesktopCommandResult(message: nil, diagnostic: "cancelled") }
        let state = environment.session()
        return state == .interactive ? nil : DesktopCommandResult(message: state.message, diagnostic: "session-\(state.rawValue)")
    }

    private func installedApps() async -> [AppCandidate] {
        if let catalog, Date().timeIntervalSince(catalog.at) < Self.catalogLifetime { return catalog.apps }
        let apps = await environment.installed()
        catalog = (apps, Date())
        return apps
    }

    nonisolated static func runningApps() -> [AppCandidate] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != own else { return nil }
            var names: [String] = []
            for name in [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent].compactMap({ $0 })
            where !name.isEmpty && !names.contains(name) { names.append(name) }
            return AppCandidate(id: app.bundleIdentifier ?? "pid:\(app.processIdentifier)", names: names,
                                url: app.bundleURL, pid: app.processIdentifier)
        }
    }

    nonisolated static func isFrontmost(_ app: AppCandidate) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let pid = app.pid { return front.processIdentifier == pid }
        return front.bundleIdentifier == app.id && front.bundleURL?.resolvingSymlinksInPath() == app.url?.resolvingSymlinksInPath()
    }

    // Activation only: a quit app is never relaunched by Switch.
    nonisolated static func activateRunning(_ app: AppCandidate) -> Bool {
        guard let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated, running.activationPolicy == .regular,
              (running.bundleIdentifier ?? "pid:\(pid)") == app.id, running.bundleURL == app.url else { return false }
        return running.activate(options: [])
    }

    nonisolated static func scanInstalled() async -> [AppCandidate] {
        let workspace = NSWorkspace.shared
        return await Task.detached(priority: .userInitiated) {
            let apps = InstalledAppCatalog.scan(roots: InstalledAppCatalog.roots(), list: InstalledAppCatalog.listDirectory,
                                                read: InstalledAppCatalog.readBundle)
            return InstalledAppCatalog.preferRegisteredCopies(apps) { workspace.urlForApplication(withBundleIdentifier: $0) }
        }.value
    }

    // Re-read the bundle just before opening: it must still be the same normal application.
    nonisolated static func verifyInstalled(_ app: AppCandidate) -> Bool {
        guard let url = app.url, InstalledAppCatalog.isInstalledLocation(url, roots: InstalledAppCatalog.roots()),
              let info = InstalledAppCatalog.readBundle(url) else { return false }
        return info.id == app.id && (info.packageType == nil || info.packageType == "APPL")
    }

    nonisolated static func openInstalled(_ app: AppCandidate) async -> Bool {
        guard let url = app.url else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); return true }
        catch { return false }
    }
}
