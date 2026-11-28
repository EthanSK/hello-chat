// Set the selected Mac output's native volume without selecting a device, unmuting it,
// or changing microphone/alert controls. GateModel and Agent Control share this owner. — GPT-6.1 Sol
import AudioToolbox
import CoreAudio
import Foundation

struct SystemOutputVolume {
    struct Device: Equatable {
        let id: AudioObjectID
        let uid: String
        let name: String
    }
    struct Control: Equatable {
        let selector: AudioObjectPropertySelector
        let element: AudioObjectPropertyElement
        let value: Float
    }
    struct Snapshot {
        let device: Device
        let percent: Int?
        let muted: Bool?
        var adjustable: Bool { percent != nil }
    }
    enum Failure: Error {
        case invalidValue, noOutput, outputChanged, unsupported(String), invalidRead, read(OSStatus), write(OSStatus), unconfirmed
    }
    struct OperationFailure: Error {
        let underlying: Error
        let beforeDispatch: Bool
    }
    struct Hardware {
        var current: () throws -> Device
        var controls: (Device) throws -> [Control]
        var muted: (Device) -> Bool?
        var write: (Device, Control, Float) throws -> Void
    }
    let hardware: Hardware
    init(hardware: Hardware = .native) { self.hardware = hardware }

    func read() throws -> Snapshot {
        let device = try hardware.current()
        let controls = try hardware.controls(device)
        try validate(controls)
        guard try hardware.current() == device else { throw Failure.outputChanged }
        return Snapshot(device: device, percent: controls.map(\.value).max().map { Int(($0 * 100).rounded()) }, muted: hardware.muted(device))
    }

    // Ethan's “Set volume thirty” is absolute volume on the output selected at admission.
    // A later output change refuses instead of adjusting a different speaker. — GPT-6.1 Sol
    func set(_ percent: Int, on expected: Device) throws -> Snapshot {
        var dispatched = false
        do {
            guard (0...100).contains(percent) else { throw Failure.invalidValue }
            guard try hardware.current() == expected else { throw Failure.outputChanged }
            let controls = try hardware.controls(expected)
            guard !controls.isEmpty else { throw Failure.unsupported(expected.name) }
            try validate(controls)
            guard let peak = controls.map(\.value).max() else { throw Failure.unsupported(expected.name) }
            let requested = Float(percent) / 100
            let targets = controls.map { peak > 0 ? $0.value * requested / peak : requested }
            for (control, value) in zip(controls, targets) {
                guard try hardware.current() == expected else { throw Failure.outputChanged }
                // A preferred stereo pair keeps its relative balance. Zeroed channels have
                // no remaining balance to preserve, so both take the requested value. — GPT-6.1 Sol
                if abs(value - control.value) > 0.0001 {
                    dispatched = true
                    try hardware.write(expected, control, value)
                }
            }
            guard try hardware.current() == expected else { throw Failure.outputChanged }
            let actual = try hardware.controls(expected)
            try validate(actual)
            guard actual.map({ ($0.selector, $0.element) }).elementsEqual(controls.map { ($0.selector, $0.element) }, by: ==),
                  zip(actual, targets).allSatisfy({ abs($0.0.value - $0.1) <= 0.005 }),
                  let readback = actual.map(\.value).max(), abs(readback - requested) <= 0.005 else { throw Failure.unconfirmed }
            return Snapshot(device: expected, percent: Int((readback * 100).rounded()), muted: hardware.muted(expected))
        } catch {
            throw OperationFailure(underlying: error, beforeDispatch: !dispatched)
        }
    }

    private func validate(_ controls: [Control]) throws {
        guard controls.allSatisfy({ $0.value.isFinite && (0...1).contains($0.value) }) else { throw Failure.invalidRead }
    }
}

extension SystemOutputVolume.Hardware {
    static let native = Self(current: {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { throw SystemOutputVolume.Failure.read(status) }
        guard id != kAudioObjectUnknown else { throw SystemOutputVolume.Failure.noOutput }
        return try .init(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName))
    }, controls: { device in
        // Prefer the native main control. Some stereo devices expose only their preferred
        // channels; unsupported interfaces never receive simulated keypresses or route changes. — GPT-6.1 Sol
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            if let value = try scalar(device.id, selector, kAudioObjectPropertyElementMain, writable: true) {
                return [.init(selector: selector, element: kAudioObjectPropertyElementMain, value: value)]
            }
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                                                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device.id, &address) else { return [] }
        var pair: [UInt32] = [0, 0], size = UInt32(2 * MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &pair)
        guard status == noErr else { throw SystemOutputVolume.Failure.read(status) }
        guard size == 2 * MemoryLayout<UInt32>.size, pair.allSatisfy({ $0 > 0 }) else { return [] }
        var result: [SystemOutputVolume.Control] = []
        for element in Array(Set(pair)).sorted() {
            guard let value = try scalar(device.id, kAudioDevicePropertyVolumeScalar, element, writable: true) else { return [] }
            result.append(.init(selector: kAudioDevicePropertyVolumeScalar, element: element, value: value))
        }
        return result
    }, muted: { device in
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device.id, &address) else { return nil }
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }, write: { device, control, requested in
        var address = AudioObjectPropertyAddress(mSelector: control.selector, mScope: kAudioObjectPropertyScopeOutput, mElement: control.element)
        var value = requested
        let status = AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        guard status == noErr else { throw SystemOutputVolume.Failure.write(status) }
    })

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw SystemOutputVolume.Failure.read(status) }
        guard let value else { throw SystemOutputVolume.Failure.invalidRead }
        // These CoreAudio string properties return an owned CF object. — GPT-6.1 Sol
        let string = value.takeRetainedValue()
        guard CFStringGetLength(string) > 0 else { throw SystemOutputVolume.Failure.invalidRead }
        return string as String
    }
    private static func scalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ element: AudioObjectPropertyElement, writable: Bool) throws -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var canWrite = DarwinBoolean(false)
        let permission = AudioObjectIsPropertySettable(device, &address, &canWrite)
        guard permission == noErr else { throw SystemOutputVolume.Failure.read(permission) }
        guard !writable || canWrite.boolValue else { return nil }
        var value: Float = 0, size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw SystemOutputVolume.Failure.read(status) }
        guard size == MemoryLayout<Float>.size else { throw SystemOutputVolume.Failure.invalidRead }
        return value
    }
}

// Speech and typed agent actions share one drainable native writer. Quit rejects
// queued requests and waits for a write already in progress, including stereo writes.
// Found and fixed by GPT-6.1 Sol. — GPT-6.1 Sol
@MainActor final class SystemOutputVolumeCommands {
    private let control: SystemOutputVolume
    private var tail: Task<Void, Never>?
    private var stopping = false
    init(control: SystemOutputVolume = .init()) { self.control = control }

    func set(_ percent: Int, on device: SystemOutputVolume.Device,
             beforeWrite: (() throws -> Void)? = nil) async throws -> SystemOutputVolume.Snapshot {
        let previous = tail
        let operation = Task { [self] in
            await previous?.value
            guard !stopping else {
                throw SystemOutputVolume.OperationFailure(underlying: CancellationError(), beforeDispatch: true)
            }
            try beforeWrite?()
            return try await Task.detached { [control] in try control.set(percent, on: device) }.value
        }
        tail = Task { _ = try? await operation.value }
        return try await operation.value
    }
    func stopAccepting() { stopping = true }
    func finish() async { stopping = true; await tail?.value }
    func resume() { stopping = false }
}
