import AppKit
import CoreAudio
import Foundation

// Read-only Agent Flow microphone diagnostic. It does not gate phrase detection
// or updates: Ethan wants H Chat to keep working while dictating.
// Never consume Agent Flow's media-playback or announcement notifications.
@MainActor final class AgentFlowRecordingMonitor {
    // Previously suppressesPhrases; retained only as diagnostic information.
    private(set) var recordingOrUnknown = false
    var onChange: ((Bool) -> Void)?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var workspaceObservers: [NSObjectProtocol] = []

    static func hasActiveOrUnknownInput(appPresent: Bool, recording: Bool?) -> Bool {
        appPresent && recording != false
    }

    init() {
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, callback) == noErr {
            systemListener = callback
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ethansk.VoiceInkPlusPlus")
            .filter { !$0.isTerminated }
        guard !apps.isEmpty else { removeProcessListeners(); update(false); return }
        guard systemListener != nil else { update(true); return }
        let pids = Set(apps.map(\.processIdentifier))
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { update(true); return }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if size > 0, AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) != noErr {
            update(true); return
        }
        var owned = Set<AudioObjectID>()
        var recording: Bool? = false
        for object in objects {
            guard let pid = VoiceBridge.uintProperty(kAudioProcessPropertyPID, object) else {
                if recording != true { recording = nil }
                continue
            }
            guard pids.contains(pid_t(pid)) else { continue }
            owned.insert(object)
            if processListeners[object] == nil {
                let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
                if AudioObjectAddPropertyListenerBlock(object, &inputAddress, .main, callback) == noErr {
                    processListeners[object] = callback
                } else { recording = nil }
            }
            if let running = VoiceBridge.uintProperty(kAudioProcessPropertyIsRunningInput, object) {
                if running != 0 { recording = true }
            } else if recording != true { recording = nil }
        }
        for object in Array(processListeners.keys) where !owned.contains(object) {
            var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
            if let callback = processListeners.removeValue(forKey: object) {
                AudioObjectRemovePropertyListenerBlock(object, &inputAddress, .main, callback)
            }
        }
        update(Self.hasActiveOrUnknownInput(appPresent: true, recording: recording))
    }

    private func update(_ value: Bool) {
        guard value != recordingOrUnknown else { return }
        recordingOrUnknown = value
        onChange?(value)
    }
    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func removeProcessListeners() {
        for (object, callback) in processListeners {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, callback)
        }
        processListeners.removeAll()
    }
    deinit {
        if let systemListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        for (object, callback) in processListeners {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, callback)
        }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
