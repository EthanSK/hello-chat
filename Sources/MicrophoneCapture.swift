import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// Input-only capture from exactly one Core Audio device.
//
// Why not AVAudioEngine: its macOS input node starts on the system default
// input and follows default-input changes through a process-private
// CADefaultDeviceAggregate, even after CurrentDevice is pinned. Reproduced on
// 2026-10-23 (task 01a169b4-3dd6-7760-8ead-0454aadd603d): connecting a Bose
// Flex 2 SoundLink made macOS route default input to the speaker. HelloChat's
// engine left the pinned built-in microphone, started IO on the Bose input,
// and switched the speaker from A2DP to its SCO call profile for about two
// minutes while the listener received no audio.
//
// A HAL output unit with output IO disabled, input IO enabled and CurrentDevice
// set before AudioUnitInitialize opens only that device and never follows the
// default. A Bluetooth microphone is opened only when it is the selected input.
final class MicrophoneCapture {
    let device: AudioDeviceID
    // Float32, non-interleaved, at the device's own rate and channel count:
    // AUHAL input does not resample. SpeechPCM.mono still selects channel 1.
    let format: AVAudioFormat
    private let unit: AudioUnit
    // Lifetime: start() gives the unit a +1 reference used as the refCon of
    // both callbacks. stop() releases it only after the unit is disposed, so
    // no input callback or property listener can reach a freed object. The
    // owner must call stop(); deinit only disposes a capture never started.
    private var unitReference: Unmanaged<MicrophoneCapture>?
    private var initialized = false
    private var observing = false
    private var stopped = false
    // Set once in start() before any callback can run; never changed after.
    private var bufferFrames: AVAudioFrameCount = 4096
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onConfigurationChange: (@Sendable () -> Void)?
    // Touched only by the input thread between AudioOutputUnitStart and
    // AudioOutputUnitStop, and by stop() after the unit is disposed.
    private var scratch: AVAudioPCMBuffer?
    private var pending: AVAudioPCMBuffer?
    private static let observed = [kAudioOutputUnitProperty_CurrentDevice, kAudioOutputUnitProperty_IsRunning, kAudioUnitProperty_StreamFormat]

    init(device: AudioDeviceID) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw BridgeError.message("Microphone input is unavailable.") }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "Could not open microphone")
        guard let unit = created else { throw BridgeError.message("Microphone input is unavailable.") }
        let format: AVAudioFormat
        do { format = try Self.configure(unit, device: device) }
        catch { AudioComponentInstanceDispose(unit); throw error }
        self.unit = unit; self.device = device; self.format = format
    }
    deinit { stop() }

    /// Starts input IO once. On failure the unit is already disposed.
    /// `onBuffer` runs on Core Audio's real-time input thread and receives an
    /// owned `bufferFrames` buffer the capture never touches again.
    /// `onConfigurationChange` runs on a Core Audio notification thread when
    /// the device, its hardware format or the running state changes.
    func start(bufferFrames: AVAudioFrameCount, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
               onConfigurationChange: @escaping @Sendable () -> Void) throws {
        guard !stopped, unitReference == nil, bufferFrames > 0 else { throw BridgeError.message("Microphone capture can't be restarted.") }
        self.bufferFrames = bufferFrames; self.onBuffer = onBuffer; self.onConfigurationChange = onConfigurationChange
        let reference = Unmanaged.passRetained(self)
        unitReference = reference
        do {
            var callback = AURenderCallbackStruct(inputProc: Self.inputCallback, inputProcRefCon: reference.toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Could not receive microphone audio")
            try Self.check(AudioUnitInitialize(unit), "Could not prepare microphone")
            initialized = true
            var maximum: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, &size) != noErr || maximum == 0 { maximum = 4096 }
            scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximum)
            // Observe before starting, so a failure during start still reaches the owner.
            observing = true
            for property in Self.observed {
                try Self.check(AudioUnitAddPropertyListener(unit, property, Self.propertyChanged, reference.toOpaque()), "Could not observe microphone")
            }
            try Self.check(AudioOutputUnitStart(unit), "Could not start microphone")
        } catch { stop(); throw error }
    }

    /// Idempotent; call from the owner, never from a callback. Stopping and
    /// disposing the unit ends its input and listener callbacks; only then are
    /// the buffers cleared and the callbacks' reference released.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if observing, let reference = unitReference {
            for property in Self.observed { AudioUnitRemovePropertyListenerWithUserData(unit, property, Self.propertyChanged, reference.toOpaque()) }
        }
        AudioOutputUnitStop(unit)
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
        scratch = nil; pending = nil
        unitReference?.release(); unitReference = nil
    }

    /// Hardware-side format; differs from `format` after a device rate/channel change.
    var deviceFormat: AudioStreamBasicDescription? { stopped ? nil : Self.streamFormat(of: unit, scope: kAudioUnitScope_Input) }
    var currentDevice: AudioDeviceID? { stopped ? nil : Self.currentDevice(of: unit) }
    var isRunning: Bool {
        guard !stopped else { return false }
        var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size) == noErr && running != 0
    }
    // Format/readback metadata only: never retains samples or changes the route.
    func formatDiagnostics() -> [String: Double] {
        var values: [String: Double] = ["current_device": Double(currentDevice ?? 0)]
        guard !stopped else { return values }
        for (name, scope) in [("au_input", kAudioUnitScope_Input), ("au_output", kAudioUnitScope_Output)] {
            if let format = Self.streamFormat(of: unit, scope: scope) {
                values[name + "_rate"] = format.mSampleRate
                values[name + "_channels"] = Double(format.mChannelsPerFrame)
            }
        }
        return values
    }

    /// Copies rendered frames into fixed-size chunks. Each completed chunk is
    /// newly allocated, handed to `emit` and never referenced again, so the
    /// receiver owns it. Channel order is preserved.
    static func append(_ source: AVAudioPCMBuffer, to pending: inout AVAudioPCMBuffer?, capacity: AVAudioFrameCount, emit: (AVAudioPCMBuffer) -> Void) {
        guard let input = source.floatChannelData, capacity > 0 else { return }
        let channels = Int(source.format.channelCount)
        var offset: AVAudioFrameCount = 0
        while offset < source.frameLength {
            if pending == nil { pending = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: capacity) }
            guard let chunk = pending, let output = chunk.floatChannelData else { return }
            let count = min(source.frameLength - offset, chunk.frameCapacity - chunk.frameLength)
            for channel in 0..<channels {
                (output[channel] + Int(chunk.frameLength)).update(from: input[channel] + Int(offset), count: Int(count))
            }
            chunk.frameLength += count; offset += count
            if chunk.frameLength == chunk.frameCapacity { pending = nil; emit(chunk) }
        }
    }

    private static let inputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        Unmanaged<MicrophoneCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
    }
    // Real-time input thread only. Render and copy reuse the scratch buffer;
    // one owned buffer is allocated per completed chunk (~85 ms at 48 kHz),
    // as the former engine tap also delivered fresh buffers.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        if (scratch?.frameCapacity ?? 0) < frames { scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) }
        guard let scratch else { return kAudio_MemFullError }
        scratch.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr else { return status }
        if let onBuffer { Self.append(scratch, to: &pending, capacity: bufferFrames, emit: onBuffer) }
        return noErr
    }

    // Core Audio notification thread. Device and format are applied before
    // observation begins; start's own running notice settles in the owner.
    private static let propertyChanged: AudioUnitPropertyListenerProc = { refCon, _, property, scope, element in
        // Only the hardware side (input scope, element 1) changes by itself.
        if property == kAudioUnitProperty_StreamFormat, scope != kAudioUnitScope_Input || element != 1 { return }
        Unmanaged<MicrophoneCapture>.fromOpaque(refCon).takeUnretainedValue().onConfigurationChange?()
    }

    private static func configure(_ unit: AudioUnit, device: AudioDeviceID) throws -> AVAudioFormat {
        var enable: UInt32 = 1, disable: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, flagSize), "Could not enable microphone input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize), "Could not disable audio output")
        // Always set explicitly, even if it already reads back as this device:
        // an unset CurrentDevice is what tracks the system default.
        var selected = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "Could not select microphone")
        guard currentDevice(of: unit) == device else { throw BridgeError.message("Microphone selection wasn't applied. Listening stopped.") }
        guard let hardware = streamFormat(of: unit, scope: kAudioUnitScope_Input), hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
              hardware.mChannelsPerFrame > 0,
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame) else {
            throw BridgeError.message("No supported microphone is available.")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, interleaved: false, channelLayout: layout)
        var client = format.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Could not set microphone format")
        return format
    }
    private static func streamFormat(of unit: AudioUnit, scope: AudioUnitScope) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 1, &format, &size) == noErr ? format : nil
    }
    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var device: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr ? device : nil
    }
    // OSStatus errors keep their code (Diagnostics.failure logs domain/code).
    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status != noErr else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(action) (\(status))."])
    }
}
