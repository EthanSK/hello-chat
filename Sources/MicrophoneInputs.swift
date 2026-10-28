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
}

@MainActor final class MicrophoneInputs: ObservableObject {
    @Published private(set) var devices: [MicrophoneInput] = []
    @Published private(set) var systemDefault: AudioDeviceID = 0
    @Published var selectedUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "" {
        didSet {
            guard selectedUID != oldValue else { return }
            UserDefaults.standard.set(selectedUID, forKey: "inputDeviceUID")
            onRouteChange?()
        }
    }
    var onRouteChange: (() -> Void)?
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var selected: MicrophoneInput? { MicrophoneRoute.resolve(uid: selectedUID, devices: devices, systemDefault: systemDefault) }
    var selectedName: String { selected?.name ?? "Microphone unavailable" }

    init() {
        refresh()
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
    deinit {
        for (var address, block) in registrations {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
    func refresh() {
        let old = selected
        devices = Self.available()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0; var size = UInt32(MemoryLayout.size(ofValue: value))
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) != noErr { value = 0 }
        systemDefault = value
        if old?.id != selected?.id { onRouteChange?() }
    }
    static func available() -> [MicrophoneInput] {
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
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
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
}
