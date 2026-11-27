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
        for power in [false, true] {
            for display in [false, true] {
                precondition(existingPolicy.shouldListen(automatic: true, onPower: power,
                    externalDisplay: display, manualEnabled: existing.manualEnabled),
                    "A remembered manual On works with automatic docking enabled, including after restart")
            }
        }
        existingPolicy.pause()
        precondition(existingPolicy.shouldListen(automatic: true, onPower: false,
            externalDisplay: false, manualEnabled: true), "Dock events and pauses cannot override manual On")
        precondition(!existingPolicy.shouldListen(automatic: true, onPower: false,
            externalDisplay: false, manualEnabled: false), "Manual Off stops an undocked manual override")
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

        var resumedActive = DockListeningDelay()
        resumedActive.resumeActiveSession()
        precondition(resumedActive.remaining(shouldListen: true, now: 100) == 0,
                     "An active listener resumes immediately after an aborted update")
        var interruptedWait = DockListeningDelay()
        precondition(interruptedWait.remaining(shouldListen: true, now: 100) == 120)
        var restoredWait = interruptedWait
        precondition(restoredWait.remaining(shouldListen: true, now: 140) == 80,
                     "Restoring an interrupted update preserves the existing dock deadline")
        precondition(restoredWait.remaining(shouldListen: false, now: 150) == nil,
                     "Current Off or ineligible policy still prevents listening after restoration")
        resumedActive.cancel()
        precondition(resumedActive.remaining(shouldListen: true, now: 160) == 120,
                     "A real environment change still starts a new dock delay")

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
        try microphonePriorityChecks()
        let inputs = MicrophoneInputs()
        print("Input routing and dock policy checks passed; available inputs: \(inputs.devices.map(\.name).joined(separator: ", "))")
        let dock = DockMonitor()
        print("Live status: \(dock.powerText); \(dock.externalDisplays) external displays")
        var resource = ResourceUsage(); print(resource.sample())
    }

    /// Command microphone priority order through the real MicrophoneInputs rules, with injected
    /// device lists and a private preferences domain: no CoreAudio listener, capture or system route.
    /// `refresh()` is what the device-list and default-input listeners call. — Claude Opus 5.5
    @MainActor static func microphonePriorityChecks() throws {
        final class FakeHardware { var devices: [MicrophoneInput] = []; var systemDefault: AudioDeviceID = 0 }
        let builtIn = MicrophoneInput(id: 1, uid: "builtin", name: "MacBook Pro Microphone")
        let usb = MicrophoneInput(id: 2, uid: "usb", name: "USB")
        let headset = MicrophoneInput(id: 3, uid: "headset", name: "Headset")
        let webcam = MicrophoneInput(id: 4, uid: "webcam", name: "Webcam")
        precondition(MicrophoneRoute.resolve(priority: [], devices: [builtIn, usb], systemDefault: 2) == usb,
                     "An empty order follows the system default")
        precondition(MicrophoneRoute.resolve(priority: [.init(uid: "usb", name: "USB")], devices: [], systemDefault: 0) == nil)
        let fake = FakeHardware(); fake.devices = [builtIn, usb]; fake.systemDefault = builtIn.id
        let hardware = MicrophoneInputs.Hardware(devices: { fake.devices }, systemDefault: { fake.systemDefault })
        let suite = "HelloChat.MicrophonePriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var routeChanges = 0
        func load(_ defaults: UserDefaults) -> MicrophoneInputs {
            let inputs = MicrophoneInputs(defaults: defaults, hardware: hardware)
            inputs.onRouteChange = { routeChanges += 1 }
            return inputs
        }
        func expectChanges(_ expected: Int, _ message: String, _ change: () -> Void) {
            let before = routeChanges
            change()
            precondition(routeChanges - before == expected, message)
        }

        // An existing single choice: the upgrade neither enables priority order nor writes anything.
        defaults.set("usb", forKey: "inputDeviceUID")
        let upgraded = defaults.persistentDomain(forName: suite) as NSDictionary?
        let inputs = load(defaults)
        precondition(!inputs.priority.enabled && inputs.priority.entries.isEmpty, "Priority order starts off and empty")
        precondition(inputs.selected == usb && inputs.routeRule == .chosen, "The existing single choice keeps its route")
        precondition(defaults.persistentDomain(forName: suite) as NSDictionary? == upgraded, "Loading writes no migration")
        expectChanges(0, "Building the order while it's off keeps the single choice in use") {
            inputs.addToPriority(builtIn); inputs.addToPriority(usb); inputs.addToPriority(usb)
        }
        precondition(inputs.priority.entries.map(\.uid) == ["builtin", "usb"], "Each microphone is listed once, in the order added")
        precondition(inputs.selected == usb && inputs.activePriorityUID == nil, "Nothing is Active while priority order is off")

        expectChanges(1, "Turning priority order on applies its first connected microphone") { inputs.setPriorityEnabled(true) }
        precondition(inputs.selected == builtIn && inputs.activePriorityUID == "builtin" && inputs.routeRule == .priorityOrder)
        precondition(defaults.string(forKey: "inputDeviceUID") == "usb", "The single choice stays saved")
        expectChanges(1, "Moving a connected microphone to the top switches to it") { inputs.movePriority(uid: "usb", by: -1) }
        precondition(inputs.selected == usb)
        expectChanges(0, "Moving past either end changes nothing") {
            inputs.movePriority(uid: "usb", by: -1); inputs.movePriority(uid: "builtin", by: 1)
        }
        fake.devices = [builtIn, usb, headset]
        expectChanges(0, "A newly connected microphone doesn't take over until it's listed above") {
            inputs.refresh(); inputs.addToPriority(headset)
        }
        expectChanges(0, "Reordering rows below the chosen microphone keeps audio running") { inputs.movePriority(uid: "headset", by: -1) }
        precondition(inputs.priority.entries.map(\.uid) == ["usb", "headset", "builtin"])
        fake.devices = [builtIn, usb]
        expectChanges(0, "Unplugging an unused listed microphone keeps audio running") { inputs.refresh() }
        precondition(inputs.priority.entries.map(\.uid) == ["usb", "headset", "builtin"] && inputs.priority.entries[1].name == "Headset",
                     "A disconnected row keeps its UID and name")

        // USB disconnect and reconnect, including a new CoreAudio device ID for the same UID.
        fake.devices = [builtIn]
        expectChanges(1, "Unplugging the chosen USB microphone moves to the next connected one") { inputs.refresh() }
        precondition(inputs.selected == builtIn && inputs.activePriorityUID == "builtin")
        let replugged = MicrophoneInput(id: 9, uid: "usb", name: "USB")
        fake.devices = [builtIn, replugged]
        expectChanges(1, "Reconnecting a higher microphone switches back to it") { inputs.refresh() }
        precondition(inputs.selected == replugged)
        expectChanges(0, "An unchanged device list doesn't restart") { inputs.refresh() }
        fake.devices = [builtIn, MicrophoneInput(id: 9, uid: "usb", name: "USB Studio")]
        expectChanges(0, "A renamed microphone updates its saved name without restarting") { inputs.refresh() }
        precondition(inputs.priority.entries[0].name == "USB Studio"
            && MicrophonePriority(saved: defaults.object(forKey: MicrophonePriority.defaultsKey)).entries[0].name == "USB Studio")
        expectChanges(0, "Changing the single choice while priority order is on keeps its route") { inputs.selectedUID = "builtin" }
        precondition(defaults.string(forKey: "inputDeviceUID") == "builtin")

        // Nothing listed connected: H Chat's normal system default.
        expectChanges(0, "Removing an unused row keeps audio running") { inputs.removeFromPriority(uid: "builtin") }
        fake.devices = [builtIn, webcam]
        expectChanges(1, "With nothing listed connected, priority order follows the system default") { inputs.refresh() }
        precondition(inputs.selected == builtIn && inputs.routeRule == .priorityFallback && inputs.activePriorityUID == nil,
                     "No listed row is Active during the fallback")
        fake.systemDefault = webcam.id
        expectChanges(1, "The fallback follows a changed system default") { inputs.refresh() }
        precondition(inputs.selected == webcam)
        fake.devices = [builtIn, webcam, headset]
        expectChanges(1, "A listed microphone returning ends the fallback") { inputs.refresh() }
        precondition(inputs.selected == headset && inputs.routeRule == .priorityOrder)
        fake.systemDefault = builtIn.id
        expectChanges(0, "A system default change is ignored while a listed microphone is connected") { inputs.refresh() }
        expectChanges(1, "Removing the chosen microphone moves on") { inputs.removeFromPriority(uid: "headset") }
        precondition(inputs.selected == builtIn && inputs.routeRule == .priorityFallback)

        let reloaded = load(defaults)
        precondition(reloaded.priority == inputs.priority && reloaded.priority.enabled && reloaded.priority.entries.map(\.uid) == ["usb"],
                     "Priority order and its rows survive a restart")
        precondition(reloaded.selectedUID == "builtin" && reloaded.selected == builtIn)
        expectChanges(0, "Turning priority order off keeps a route that resolves to the same microphone") { inputs.setPriorityEnabled(false) }
        precondition(inputs.routeRule == .chosen && inputs.selected == builtIn && inputs.activePriorityUID == nil)
        expectChanges(1, "The single menu restarts on a change, as before") { inputs.selectedUID = "usb" }
        precondition(inputs.selected == nil, "A missing explicit microphone stays unavailable with priority order off")
        expectChanges(1, "Turning priority order on uses its fallback") { inputs.setPriorityEnabled(true) }
        expectChanges(1, "Turning it off returns to the missing single choice") { inputs.setPriorityEnabled(false) }
        precondition(inputs.selected == nil && inputs.priority.entries.map(\.uid) == ["usb"], "Turning it off keeps the rows")

        // A different permanent UID still needs a restart when CoreAudio reuses its numeric ID.
        // Found and fixed by GPT-6.1 Sol.
        fake.devices = [builtIn]; fake.systemDefault = builtIn.id
        inputs.setPriorityEnabled(true)
        let replacement = MicrophoneInput(id: builtIn.id, uid: "replacement", name: "Replacement")
        fake.devices = [replacement]
        expectChanges(1, "A replacement UID with a reused device number must restart") { inputs.refresh() }
        precondition(inputs.selected == replacement)
        expectChanges(0, "An unchanged replacement device remains idempotent") { inputs.refresh() }

        // The existing agent microphone command is an explicit single choice, rather than an
        // unused backup value. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol.
        fake.devices = [builtIn, usb]; inputs.refresh(); inputs.addToPriority(builtIn)
        precondition(inputs.selected == usb)
        expectChanges(1, "An explicit single choice must take over from priority order once") {
            inputs.selectSingle(uid: "builtin")
        }
        precondition(!inputs.priority.enabled && inputs.selected == builtIn && inputs.priority.entries.map(\.uid) == ["usb", "builtin"])
        expectChanges(0, "Repeating an explicit unchanged microphone does not restart") { inputs.selectSingle(uid: "builtin") }

        // Malformed and repeated saved rows. Sanitizing happens in memory; loading still writes nothing.
        fake.devices = [builtIn]
        let malformedSuite = "HelloChat.MicrophonePriorityTests.Malformed.\(UUID().uuidString)"
        let malformed = UserDefaults(suiteName: malformedSuite)!
        defer { malformed.removePersistentDomain(forName: malformedSuite) }
        let rows: [Any] = [["uid": "usb", "name": "USB"], ["uid": "usb", "name": "Duplicate"], ["uid": " ", "name": "Blank"],
                           ["name": "No UID"], "row", ["uid": 7], ["uid": "headset"]]
        malformed.set(["enabled": true, "devices": rows] as [String: Any], forKey: MicrophonePriority.defaultsKey)
        let malformedSaved = malformed.persistentDomain(forName: malformedSuite) as NSDictionary?
        let cleaned = load(malformed)
        precondition(cleaned.priority.enabled && cleaned.priority.entries == [.init(uid: "usb", name: "USB"), .init(uid: "headset", name: "")],
                     "Malformed rows are skipped and a repeated UID keeps its first place")
        precondition(cleaned.selected == builtIn && cleaned.routeRule == .priorityFallback)
        precondition(malformed.persistentDomain(forName: malformedSuite) as NSDictionary? == malformedSaved)
        for value: Any in ["on", ["enabled": "yes", "devices": "usb"], ["devices": [["uid": "usb", "name": "USB"]]]] {
            malformed.set(value, forKey: MicrophonePriority.defaultsKey)
            let reread = load(malformed)
            precondition(!reread.priority.enabled && reread.routeRule == .systemDefault && reread.selected == builtIn,
                         "A malformed or missing mode stays off")
        }

        // Selection only pins H Chat's own input unit. Its device reads are read-only by type; this
        // also guards the real CoreAudio code against a future global default-device write.
        let owner = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MicrophoneInputs.swift")
        let ownerSource = try String(contentsOf: owner, encoding: .utf8)
        precondition(!ownerSource.contains("AudioObjectSetPropertyData"), "Microphone selection never writes the macOS default input or output")
        print("Microphone priority order checks passed")
    }
}
