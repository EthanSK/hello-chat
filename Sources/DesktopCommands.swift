// Native desktop-command execution with injectable senders; parsing stays in AppCommands.swift.
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

// Ethan's Play music / Pause music both mean the hardware toggle, not a directional Spotify or
// browser API. This is the same system-defined NSEvent pair as toggle-current-media, kept native
// and self-contained in the public app. Build both halves before sending; never retry or add a delay.
struct MediaPlayPauseShortcut {
    enum Failure: Error, Equatable {
        case desktopUnavailable(DesktopSessionState), accessibilityPermissionMissing, eventCreationFailed
    }
    var session: () -> DesktopSessionState = { .current }
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var makeEvents: () -> [CGEvent]? = MediaPlayPauseShortcut.events
    var post: ([CGEvent]) -> Void = { events in events.forEach { $0.post(tap: .cghidEventTap) } }

    func perform() -> Result<Void, Failure> {
        let state = session()
        guard state == .interactive else { return .failure(.desktopUnavailable(state)) }
        guard accessibilityTrusted() else { return .failure(.accessibilityPermissionMissing) }
        guard let events = makeEvents(), events.count == 2 else { return .failure(.eventCreationFailed) }
        post(events)
        return .success(()) // Submission only: macOS chooses the current media session.
    }
    static func events() -> [CGEvent]? {
        let events = [0x0A, 0x0B].compactMap { state in
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: (16 << 16) | (state << 8), data2: -1)?.cgEvent
        }
        return events.count == 2 ? events : nil
    }
}

struct DesktopCommandResult: Equatable {
    let message: String?   // nil: ordinary speech, so the visible status stays unchanged.
    let diagnostic: String // Never contains spoken words or app names.
}

// Carries out app and zoom commands. Every dependency is injectable; tests never switch, open
// or type. An exact running match needs only the running apps. Anything else reads a cached
// catalog of installed apps that is built on demand, never per audio frame or in the background.
@MainActor final class DesktopCommands {
    struct Environment {
        var session: () -> DesktopSessionState = { .current }
        var running: () -> [AppCandidate] = DesktopCommands.runningApps
        var activate: (AppCandidate) async -> Bool = DesktopCommands.activateRunning
        var isFrontmost: (AppCandidate) -> Bool = DesktopCommands.isFrontmost
        var frontmostName: () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }
        var installed: () async -> [AppCandidate] = DesktopCommands.scanInstalled
        var verify: (AppCandidate) -> Bool = DesktopCommands.verifyInstalled
        var open: (AppCandidate) async -> Bool = DesktopCommands.openInstalled
        var sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        var zoom = ZoomShortcut()
        var mediaPlayPause = MediaPlayPauseShortcut()
    }
    static let catalogLifetime: TimeInterval = 120
    static let confirmationChecks = 10
    static let confirmationInterval = 0.1
    private let environment: Environment
    private var catalog: (apps: [AppCandidate], at: Date)?

    init(environment: Environment = Environment()) { self.environment = environment }

    // `dispatched` runs once, when macOS accepts the switch/open request or the zoom keys are sent:
    // before front-app confirmation, and never for ignored, unresolved, blocked or cancelled work.
    // Switch app and Open app share this one action; the candidate's section only picks its sound.
    func perform(_ candidate: AppCommandCandidate, spellings: AppNameSpellings = .init(), dispatched: () -> Void = {}) async -> DesktopCommandResult {
        if let unavailable = unavailable() { return unavailable }
        if let decision = AppCommandPlanner.decideRunning(candidate, running: environment.running(), spellings: spellings) {
            return await carry(decision, dispatched: dispatched)
        }
        let installed = await installedApps()
        return await carry(AppCommandPlanner.decide(candidate, running: environment.running(), installed: installed, spellings: spellings), dispatched: dispatched)
    }

    func repetitionCandidate(_ candidate: AppCommandCandidate, spellings: AppNameSpellings) async -> AppCommandCandidate {
        let words = PhraseMatcher.words(candidate.name)
        let hasCount = (1..<max(1, words.count)).contains { end in
            if case .value(_, let used) = CommandRepetition.count(in: words, after: end) { return end + used == words.count }
            return false
        }
        guard hasCount else { return candidate }
        let apps = AppCommandPlanner.merged(running: environment.running(), installed: await installedApps())
        return candidate.separatingCount(among: apps, spellings: spellings)
    }

    // The editor derives its app menu from the same bounded catalog as command execution.
    // Group copies only for display; resolution keeps its ambiguity and verified-path checks.
    func spellingChoices() async -> [AppCandidate] {
        let apps = AppCommandPlanner.merged(running: environment.running(), installed: await installedApps())
        var seen: Set<String> = []
        return apps.filter { seen.insert($0.id).inserted }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func zoom(_ direction: ZoomDirection, dispatched: () -> Void = {}) -> DesktopCommandResult {
        let target = environment.frontmostName() ?? "the front app"
        switch environment.zoom.perform(direction) {
        case .success:
            dispatched()
            return DesktopCommandResult(message: "Sent \(direction.title) to \(target)", diagnostic: "sent")
        case .failure(.desktopUnavailable(let state)): return DesktopCommandResult(message: state.message, diagnostic: "session-\(state.rawValue)")
        case .failure(.accessibilityPermissionMissing):
            return DesktopCommandResult(message: "Allow Accessibility for Hello Chat, then try again.", diagnostic: "accessibility")
        case .failure(.eventCreationFailed): return DesktopCommandResult(message: "Couldn't send \(direction.title).", diagnostic: "event-failed")
        }
    }

    func toggleCurrentMedia(dispatched: () -> Void = {}) -> DesktopCommandResult {
        switch environment.mediaPlayPause.perform() {
        case .success:
            dispatched()
            return DesktopCommandResult(message: "Sent Play/Pause to the current media session", diagnostic: "sent")
        case .failure(.desktopUnavailable(let state)):
            return DesktopCommandResult(message: state.message, diagnostic: "session-\(state.rawValue)")
        case .failure(.accessibilityPermissionMissing):
            return DesktopCommandResult(message: "Allow Accessibility for Hello Chat, then try again.", diagnostic: "accessibility")
        case .failure(.eventCreationFailed):
            return DesktopCommandResult(message: "Couldn't send Play/Pause.", diagnostic: "event-failed")
        }
    }

    func openIdentified(_ app: AppCandidate, valid: () -> Bool) async -> DesktopCommandResult {
        let running = environment.running().first { $0.id == app.id }
        return await carry(running.map(AppCommandDecision.activate) ?? .open(app), valid: valid, dispatched: {})
    }

    private func carry(_ decision: AppCommandDecision, valid: () -> Bool = { true }, dispatched: () -> Void) async -> DesktopCommandResult {
        // The catalog can finish after a lock, stop, or quit. Recheck just before dispatch.
        if let unavailable = unavailable() { return unavailable }
        guard valid() else { return .init(message: "The app request expired.", diagnostic: "expired") }
        switch decision {
        case .ignore: return DesktopCommandResult(message: nil, diagnostic: "ignored")
        case .failure(let text): return DesktopCommandResult(message: text, diagnostic: "not-resolved")
        case .activate(let app):
            guard await environment.activate(app) else {
                return DesktopCommandResult(message: "Couldn't switch to \(app.displayName).", diagnostic: "activate-failed")
            }
            if let unavailable = unavailable() { return unavailable }
            dispatched()
            return await confirm(app, done: "Switched to \(app.displayName)",
                pending: "Asked \(app.displayName) to come forward, but it isn't in front yet.")
        case .open(let app):
            guard environment.verify(app) else {
                catalog = nil
                return DesktopCommandResult(message: "\(app.displayName) is no longer installed there.", diagnostic: "verify-failed")
            }
            guard valid() else { return .init(message: "The app request expired.", diagnostic: "expired") }
            guard await environment.open(app) else {
                return DesktopCommandResult(message: "Couldn't open \(app.displayName).", diagnostic: "open-failed")
            }
            if let unavailable = unavailable() { return unavailable }
            dispatched()
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

    // Extraction of the native routes into AppActivation, also used by Codex navigation.
    // Desktop commands retain their separate foreground result and existing dispatch policy. — GPT-6.1 Sol
    static func activateRunning(_ app: AppCandidate) async -> Bool {
        guard let pid = app.pid, let url = app.url else { return false }
        return await AppActivation.request(pid: pid, bundleID: app.id, url: url)
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
        return await openApplication(at: url) != nil
    }

    // Reuses a running instance rather than starting a second one. Returns the process it opened.
    nonisolated static func openApplication(at url: URL) async -> Int32? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do { return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier }
        catch { return nil }
    }
}
