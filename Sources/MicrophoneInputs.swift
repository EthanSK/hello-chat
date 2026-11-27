import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Combine

struct MicrophoneInput: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum MicrophoneRoute {
    // Empty UID follows the system default. A missing explicit device never
    // silently switches to another microphone.
    static func resolve(uid: String, devices: [MicrophoneInput], systemDefault: AudioDeviceID) -> MicrophoneInput? {
        uid.isEmpty ? devices.first { $0.id == systemDefault } : devices.first { $0.uid == uid }
    }
    /// Priority order uses the first connected saved microphone, matched by its stable UID. With none
    /// connected H Chat keeps its system-default rule; Agent Flow uses a built-in-first fallback.
    /// It never substitutes a different device with the same model UID. — Claude Opus 5.5; GPT-6.1 Sol
    static func resolve(priority: [MicrophonePriority.Entry], devices: [MicrophoneInput], systemDefault: AudioDeviceID) -> MicrophoneInput? {
        firstConnected(priority, devices: devices) ?? resolve(uid: "", devices: devices, systemDefault: systemDefault)
    }
    static func firstConnected(_ priority: [MicrophonePriority.Entry], devices: [MicrophoneInput]) -> MicrophoneInput? {
        for entry in priority {
            if let input = devices.first(where: { $0.uid == entry.uid }) { return input }
        }
        return nil
    }
    /// Device numbers can be reused after a disconnect. Compare the permanent UID too, while a
    /// name-only change keeps capture running. Found and fixed by GPT-6.1 Sol.
    static func sameInput(_ lhs: MicrophoneInput?, _ rhs: MicrophoneInput?) -> Bool {
        lhs?.id == rhs?.id && lhs?.uid == rhs?.uid
    }
    /// Which rule chose the command microphone. Home and diagnostics use it, so logs never need the
    /// device's name or UID. — Claude Opus 5.5
    enum Rule: String {
        case systemDefault = "system_default"
        case chosen
        case priorityOrder = "priority_order"
        case priorityFallback = "priority_fallback"
    }
}

/// Ethan's “priority order” for the Command microphone, translated from Agent Flow's Audio Input
/// Priority Order. It's off by default, so an upgrade keeps the current route. The single
/// `inputDeviceUID` choice stays saved separately and applies again when this is turned off.
/// Disconnected rows keep their UID and last known name. — Claude Opus 5.5
struct MicrophonePriority: Equatable {
    struct Entry: Identifiable, Equatable {
        let uid: String
        var name: String
        var id: String { uid }
    }
    var enabled = false
    private(set) var entries: [Entry] = []

    init(enabled: Bool = false, entries: [Entry] = []) {
        self.enabled = enabled
        self.entries = Self.sanitized(entries)
    }
    /// Reads `["enabled": Bool, "devices": [["uid": String, "name": String]]]`. A malformed value is
    /// off and empty; malformed rows are skipped, and a repeated UID keeps its first place. — Claude Opus 5.5
    init(saved: Any?) {
        let saved = saved as? [String: Any] ?? [:]
        let rows = (saved["devices"] as? [Any] ?? []).compactMap { row -> Entry? in
            guard let row = row as? [String: Any], let uid = row["uid"] as? String else { return nil }
            return Entry(uid: uid, name: row["name"] as? String ?? "")
        }
        self.init(enabled: saved["enabled"] as? Bool ?? false, entries: rows)
    }
    var saved: [String: Any] {
        ["enabled": enabled, "devices": entries.map { ["uid": $0.uid, "name": $0.name] }]
    }
    mutating func add(_ input: MicrophoneInput) {
        entries = Self.sanitized(entries + [Entry(uid: input.uid, name: input.name)])
    }
    mutating func move(uid: String, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.uid == uid }), entries.indices.contains(index + offset) else { return }
        entries.insert(entries.remove(at: index), at: index + offset)
    }
    mutating func remove(uid: String) {
        entries.removeAll { $0.uid == uid }
    }
    /// A connected microphone's current name replaces its saved one, so a later disconnected row
    /// still shows a recent name. Renaming never changes the route. — Claude Opus 5.5
    mutating func updateNames(from devices: [MicrophoneInput]) {
        for index in entries.indices {
            if let input = devices.first(where: { $0.uid == entries[index].uid }), !input.name.isEmpty {
                entries[index].name = input.name
            }
        }
    }
    private static func sanitized(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { !$0.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.uid).inserted }
    }
    static let defaultsKey = "inputDevicePriority"
}

@MainActor final class MicrophoneInputs: ObservableObject {
    @Published private(set) var devices: [MicrophoneInput] = []
    @Published private(set) var systemDefault: AudioDeviceID = 0
    @Published var selectedUID: String {
        didSet {
            guard selectedUID != oldValue else { return }
            defaults.set(selectedUID, forKey: Self.selectedUIDKey)
            // Priority order owns the route while it's on. This single choice is kept for when it's
            // turned off, so changing it meanwhile doesn't restart listening. — Claude Opus 5.5
            if !priority.enabled { onRouteChange?() }
        }
    }
    // The one home for priority order. Its edits save at once and notify only when the chosen
    // microphone actually changes, so reordering lower rows or a rename keeps audio running. — Claude Opus 5.5
    @Published private(set) var priority: MicrophonePriority
    var onRouteChange: (() -> Void)?
    private let defaults: UserDefaults
    private let hardware: Hardware
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var selected: MicrophoneInput? {
        priority.enabled
            ? MicrophoneRoute.resolve(priority: priority.entries, devices: devices, systemDefault: systemDefault)
            : MicrophoneRoute.resolve(uid: selectedUID, devices: devices, systemDefault: systemDefault)
    }
    var selectedName: String { selected?.name ?? "Microphone unavailable" }
    var routeRule: MicrophoneRoute.Rule {
        guard priority.enabled else { return selectedUID.isEmpty ? .systemDefault : .chosen }
        return activePriorityUID == nil ? .priorityFallback : .priorityOrder
    }
    /// The saved row actually in use. Nil while priority order is off or nothing listed is connected,
    /// so the editor never marks an unused or disconnected row Active. — Claude Opus 5.5
    var activePriorityUID: String? {
        priority.enabled ? MicrophoneRoute.firstConnected(priority.entries, devices: devices)?.uid : nil
    }

    convenience init() {
        self.init(defaults: .standard, hardware: .coreAudio)
        observeHardware()
    }
    /// Injected preferences and device reads let tests and display-only previews use the real
    /// selection rules without CoreAudio listeners. Loading never writes a migration. — Claude Opus 5.5
    init(defaults: UserDefaults, hardware: Hardware) {
        self.defaults = defaults
        self.hardware = hardware
        selectedUID = defaults.string(forKey: Self.selectedUIDKey) ?? ""
        priority = MicrophonePriority(saved: defaults.object(forKey: MicrophonePriority.defaultsKey))
        refresh()
    }
    deinit {
        for (var address, block) in registrations {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
    func refresh() {
        let old = selected
        devices = hardware.devices()
        systemDefault = hardware.systemDefault()
        updatePriority { $0.updateNames(from: devices) }
        if !MicrophoneRoute.sameInput(old, selected) { onRouteChange?() }
    }
    /// An explicit single-microphone request takes over from priority order in one route decision.
    /// The saved order remains available. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol.
    func selectSingle(uid: String) {
        selectedUID = uid
        setPriorityEnabled(false)
    }
    func setPriorityEnabled(_ enabled: Bool) { updatePriority { $0.enabled = enabled } }
    func addToPriority(_ input: MicrophoneInput) { updatePriority { $0.add(input) } }
    func movePriority(uid: String, by offset: Int) { updatePriority { $0.move(uid: uid, by: offset) } }
    func removeFromPriority(uid: String) { updatePriority { $0.remove(uid: uid) } }
    private func updatePriority(_ change: (inout MicrophonePriority) -> Void) {
        let old = selected
        var next = priority
        change(&next)
        guard next != priority else { return }
        priority = next
        defaults.set(next.saved, forKey: MicrophonePriority.defaultsKey)
        if !MicrophoneRoute.sameInput(old, selected) { onRouteChange?() }
    }
    private func observeHardware() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                registrations.append((address, block))
            }
        }
    }
    /// Read-only device sources. Neither can change the macOS default input or output. — Claude Opus 5.5
    struct Hardware {
        let devices: () -> [MicrophoneInput]
        let systemDefault: () -> AudioDeviceID
        static var coreAudio: Hardware { Hardware(devices: MicrophoneInputs.available, systemDefault: MicrophoneInputs.defaultInputDevice) }
    }
    nonisolated static func available() -> [MicrophoneInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // AVAudioEngine may create private aggregate devices when input and
            // output differ. They are implementation details, not user inputs.
            var hiddenAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var hidden: UInt32 = 0; var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &hiddenAddress, 0, nil, &hiddenSize, &hidden) == noErr, hidden != 0 { return nil }
            var compositionAddress = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(id, &compositionAddress) {
                var composition: Unmanaged<CFDictionary>?; var compositionSize = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
                if AudioObjectGetPropertyData(id, &compositionAddress, 0, nil, &compositionSize, &composition) == noErr,
                   let dictionary = composition?.takeRetainedValue() as? [String: Any],
                   (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true { return nil }
            }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MicrophoneInput(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    nonisolated static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: value))
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) != noErr { value = 0 }
        return value
    }
    nonisolated private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func select(_ device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw BridgeError.message("Microphone input is unavailable.") }
        try ensureSelected(device, current: { currentDevice(on: input) }, set: {
            var id = device
            return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        })
    }
    // Selecting an already selected device can generate a configuration change.
    // Keep reusing the input unit and make route application idempotent.
    static func ensureSelected(_ device: AudioDeviceID, current: () -> AudioDeviceID?, set: () -> OSStatus) throws {
        if current() == device { return }
        let status = set()
        guard status == noErr else { throw BridgeError.message("Could not select microphone (\(status)).") }
        guard current() == device else { throw BridgeError.message("Microphone selection wasn't applied. Listening stopped.") }
    }
    static func currentDevice(on input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var actual: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr else { return nil }
        return actual
    }
    // Format/readback metadata only: never retain samples or change the route.
    static func formatDiagnostics(on input: AVAudioInputNode) -> [String: Double] {
        let hardware = input.inputFormat(forBus: 0), client = input.outputFormat(forBus: 0)
        var values: [String: Double] = ["node_input_rate": hardware.sampleRate, "node_input_channels": Double(hardware.channelCount), "node_output_rate": client.sampleRate, "node_output_channels": Double(client.channelCount), "current_device": Double(currentDevice(on: input) ?? 0)]
        if let unit = input.audioUnit {
            for (name, scope) in [("au_input", kAudioUnitScope_Input), ("au_output", kAudioUnitScope_Output)] {
                var format = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 1, &format, &size) == noErr {
                    values[name + "_rate"] = format.mSampleRate
                    values[name + "_channels"] = Double(format.mChannelsPerFrame)
                }
            }
        }
        return values
    }
    private static let selectedUIDKey = "inputDeviceUID"
}
