import AVFoundation
import CoreAudio
import Foundation

@main struct InputPolicyTests {
    @MainActor static func main() throws {
        let suite = "HelloChat.ListeningPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ListeningPreferences(defaults: defaults)
        precondition(!preferences.automatic && !preferences.manualEnabled,
                     "A fresh install neither requires a dock nor starts capture without the toggle")
        for enabled in [true, false, true] {
            preferences.manualEnabled = enabled
            defaults.synchronize()
            let restarted = ListeningPreferences(defaults: UserDefaults(suiteName: suite)!)
            precondition(restarted.manualEnabled == enabled, "Both toggle choices survive a fresh preferences instance")
            var manual = ListeningPolicy()
            for power in [false, true] {
                for display in [false, true] {
                    precondition(manual.shouldListen(automatic: restarted.automatic, onPower: power,
                        externalDisplay: display, manualEnabled: restarted.manualEnabled) == enabled,
                        "Normal listening follows the saved toggle on battery and without any external screen")
                }
            }
            manual.pause()
            precondition(manual.shouldListen(automatic: false, onPower: false,
                externalDisplay: false, manualEnabled: restarted.manualEnabled) == enabled,
                "A temporary runtime pause must not rewrite the saved choice")
        }
        // Existing installations already own this key. Loading the new manual
        // preference must neither migrate nor disable their opt-in dock mode.
        defaults.set(true, forKey: "automaticListening")
        let existing = ListeningPreferences(defaults: UserDefaults(suiteName: suite)!)
        precondition(existing.automatic && existing.manualEnabled)
        var existingPolicy = ListeningPolicy()
        precondition(!existingPolicy.shouldListen(automatic: true, onPower: false,
            externalDisplay: false, manualEnabled: existing.manualEnabled))
        precondition(existingPolicy.shouldListen(automatic: true, onPower: true,
            externalDisplay: true, manualEnabled: false), "Dock mode keeps its existing startup behavior")

        let builtIn = MicrophoneInput(id: 1, uid: "builtin", name: "MacBook Pro Microphone")
        let usb = MicrophoneInput(id: 2, uid: "usb", name: "USB")
        let devices = [builtIn, usb]
        precondition(MicrophoneRoute.resolve(uid: "", devices: devices, systemDefault: 2) == usb)
        precondition(MicrophoneRoute.resolve(uid: "", devices: devices, systemDefault: 1) == builtIn)
        precondition(MicrophoneRoute.resolve(uid: "builtin", devices: devices, systemDefault: 2) == builtIn)
        precondition(MicrophoneRoute.resolve(uid: "usb", devices: [builtIn], systemDefault: 1) == nil)
        precondition(MicrophoneRoute.resolve(uid: "", devices: [], systemDefault: 0) == nil)
        var hardwareDevice: AudioDeviceID = 2
        var routeWrites = 0
        func apply(_ device: AudioDeviceID) throws {
            try MicrophoneInputs.ensureSelected(device, current: { hardwareDevice }, set: {
                routeWrites += 1; hardwareDevice = device; return noErr
            })
        }
        try apply(1)
        for _ in 0..<20 { try apply(1) }
        precondition(routeWrites == 1, "Repeated engine setup must not reselect its pinned device and trigger another change")
        try apply(2)
        precondition(routeWrites == 2 && hardwareDevice == 2, "A real requested route change is still applied")
        do {
            try MicrophoneInputs.ensureSelected(1, current: { 2 }, set: { noErr })
            fatalError("Failed device readback must stop setup")
        } catch is BridgeError { }
        var policy = ListeningPolicy()
        precondition(!policy.shouldListen(automatic: false, onPower: true, externalDisplay: true))
        precondition(policy.shouldListen(automatic: true, onPower: true, externalDisplay: true))
        policy.pause()
        precondition(!policy.shouldListen(automatic: true, onPower: true, externalDisplay: true))
        precondition(!policy.shouldListen(automatic: true, onPower: false, externalDisplay: true))
        precondition(policy.shouldListen(automatic: true, onPower: true, externalDisplay: true))
        precondition(!policy.shouldListen(automatic: true, onPower: true, externalDisplay: false))
        precondition(!policy.shouldListen(automatic: true, onPower: false, externalDisplay: false))
        precondition(policy.shouldListen(automatic: true, onPower: true, externalDisplay: true))
        policy.pause(); policy.resume()
        precondition(policy.shouldListen(automatic: true, onPower: true, externalDisplay: true))

        // An already-connected dock starts at launch. A later connection and
        // any reconnect still use the unchanged two-minute policy.
        var launchDelay = DockListeningDelay(alreadyDockedAtStartup: true)
        precondition(launchDelay.remaining(shouldListen: true, now: 10) == 0,
                     "An eligible dock at app launch starts immediately")
        launchDelay.cancel()
        precondition(launchDelay.remaining(shouldListen: true, now: 20) == 120,
                     "A subsequent connection must not inherit the launch exception")
        var changedBeforeReady = DockListeningDelay(alreadyDockedAtStartup: true)
        changedBeforeReady.invalidateStartup()
        precondition(changedBeforeReady.remaining(shouldListen: true, now: 30) == 120,
                     "A dock change while playback is being checked uses the connection delay")
        var disabledAtStartup = DockListeningDelay()
        precondition(disabledAtStartup.remaining(shouldListen: false, now: 40) == nil)
        precondition(disabledAtStartup.remaining(shouldListen: true, now: 50) == 120,
                     "Enabling automatic listening later does not invent an already-docked launch")

        // Virtual time tests the real two-minute policy without using the mic,
        // playing speech or shortening the installed app's delay.
        var delay = DockListeningDelay()
        precondition(delay.remaining(shouldListen: false, now: 0) == nil)
        precondition(delay.remaining(shouldListen: true, now: 10) == 120)
        precondition(delay.remaining(shouldListen: true, now: 80) == 50,
                     "Repeated notifications must not postpone an existing deadline")
        precondition(delay.remaining(shouldListen: true, now: 129.9)! > 0)
        precondition(delay.remaining(shouldListen: true, now: 130) == 0)
        precondition(delay.remaining(shouldListen: true, now: 150) == 0)
        precondition(delay.remaining(shouldListen: false, now: 151) == nil)
        precondition(delay.remaining(shouldListen: true, now: 160) == 120,
                     "Reconnect must require a fresh uninterrupted delay")
        delay.cancel()
        precondition(delay.deadline == nil, "Manual start/stop and shutdown cancel pending auto-start")
        var dockPolicy = ListeningPolicy()
        func update(power: Bool, display: Bool, automatic: Bool = true, at time: Double) -> Double? {
            delay.remaining(shouldListen: dockPolicy.shouldListen(automatic: automatic,
                onPower: power, externalDisplay: display), now: time)
        }
        precondition(update(power: true, display: false, at: 200) == nil)
        precondition(update(power: true, display: true, at: 210) == 120)
        precondition(update(power: false, display: true, at: 329) == nil)
        precondition(update(power: true, display: true, at: 330) == 120)
        precondition(update(power: true, display: false, at: 449) == nil)
        precondition(update(power: true, display: true, at: 450) == 120)
        precondition(update(power: true, display: true, automatic: false, at: 460) == nil)
        precondition(update(power: true, display: true, at: 470) == 120)
        dockPolicy.pause()
        precondition(update(power: true, display: true, at: 600) == nil,
                     "A paused policy cannot start after its old deadline")
        precondition(update(power: false, display: true, at: 610) == nil)
        precondition(update(power: true, display: true, at: 620) == 120)
        precondition(update(power: true, display: true, at: 740) == 0)

        // Pinned-device capture chunking with synthetic rendered audio only:
        // no audio unit, microphone or route change.
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false,
                                   channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 2)!)
        var pending: AVAudioPCMBuffer?
        var chunks: [AVAudioPCMBuffer] = []
        var nextSample: Float = 0
        for _ in 0..<5 {
            let rendered = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1_500)!
            rendered.frameLength = 1_500
            for frame in 0..<1_500 {
                rendered.floatChannelData![0][frame] = nextSample
                rendered.floatChannelData![1][frame] = -1 - nextSample
                nextSample += 1
            }
            MicrophoneCapture.append(rendered, to: &pending, capacity: 4_096) { chunks.append($0) }
            rendered.floatChannelData![0][0] = .nan // reused render memory must not alias chunks
        }
        precondition(chunks.count == 1 && chunks[0].frameLength == 4_096, "Completed chunks have the requested size")
        precondition(pending?.frameLength == 7_500 - 4_096 && pending !== chunks[0], "Remainder starts a new owned chunk")
        for frame in 0..<4_096 {
            precondition(chunks[0].floatChannelData![0][frame] == Float(frame), "Channel 1 stays first and continuous across renders")
            precondition(chunks[0].floatChannelData![1][frame] == -1 - Float(frame), "Other channels keep their order")
        }
        for frame in 0..<Int(pending!.frameLength) { precondition(pending!.floatChannelData![0][frame] == Float(4_096 + frame)) }
        let inputs = MicrophoneInputs()
        print("Input routing and dock policy checks passed; available inputs: \(inputs.devices.map(\.name).joined(separator: ", "))")
        let dock = DockMonitor()
        print("Live status: \(dock.powerText); \(dock.externalDisplays) external displays")
        var resource = ResourceUsage(); print(resource.sample())
    }
}
