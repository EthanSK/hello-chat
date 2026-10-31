import AppKit
import Combine
import IOKit.ps

// Keep the user's listening-toggle choice separate from live capture. Playback
// pauses, input errors and quitting must not save those temporary stops as Off.
// Docking remains opt-in; existing users keep their saved automatic setting.
struct ListeningPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var automatic: Bool {
        get { defaults.bool(forKey: "automaticListening") }
        nonmutating set { defaults.set(newValue, forKey: "automaticListening") }
    }
    var manualEnabled: Bool {
        get { defaults.bool(forKey: "listeningEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "listeningEnabled") }
    }
}

struct ListeningPolicy {
    private(set) var paused = false
    private var previousEligible = false
    mutating func pause() { paused = true }
    mutating func resume() { paused = false }
    mutating func shouldListen(automatic: Bool, onPower: Bool, externalDisplay: Bool, manualEnabled: Bool = false) -> Bool {
        let eligible = onPower && externalDisplay
        if eligible != previousEligible { paused = false }
        previousEligible = eligible
        return automatic ? eligible && !paused : manualEnabled
    }
}

// Ethan's "a minute or two after plugging in": defer automatic model/capture
// until a newly connected dock has stayed eligible for two minutes. An app
// opening with the dock already connected should start listening immediately.
struct DockListeningDelay {
    static let seconds: TimeInterval = 120
    private(set) var deadline: TimeInterval?
    private var immediateStartup: Bool
    init(alreadyDockedAtStartup: Bool = false) { immediateStartup = alreadyDockedAtStartup }
    mutating func invalidateStartup() { immediateStartup = false }
    mutating func cancel() { deadline = nil; immediateStartup = false }
    mutating func remaining(shouldListen: Bool, now: TimeInterval) -> TimeInterval? {
        guard shouldListen else { cancel(); return nil }
        if deadline == nil {
            deadline = now + (immediateStartup ? 0 : Self.seconds)
            immediateStartup = false
        }
        return max(0, deadline! - now)
    }
}

@MainActor final class DockMonitor: ObservableObject {
    @Published private(set) var onPower = false
    @Published private(set) var externalDisplays = 0
    @Published private(set) var powerText = "Checking power…"
    var onChange: (() -> Void)?
    private var powerSource: CFRunLoopSource?
    private var displayObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    var eligible: Bool { onPower && externalDisplays > 0 }

    init() {
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<DockMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func refresh() {
        let old = eligible
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            onPower = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            let battery = sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }.first
            let percent: String
            if let capacity = battery?[kIOPSCurrentCapacityKey] as? Int, let maximum = battery?[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percent = " · \(Int((Double(capacity) / Double(maximum) * 100).rounded()))%"
            } else { percent = "" }
            let charging = battery?[kIOPSIsChargingKey] as? Bool == true
            powerText = (onPower ? "On power" : "On battery") + percent + (charging ? " · Charging" : (onPower ? " · Not charging" : ""))
        } else { onPower = false; powerText = "Power source unavailable" }
        externalDisplays = NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }.count
        if old != eligible { onChange?() }
    }
}
