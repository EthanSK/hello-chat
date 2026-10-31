// Previously HeyChatApp.swift / Hey Chat. Product name: HelloChat; spoken wake phrase: Hello Chat.
import AppKit
import Combine
import SwiftUI
import CoreML
import FluidAudio
import AVFoundation
import CoreAudio

@main enum Main {
    static func main() {
        ModelHub.offlineMode = true
        if CommandLine.arguments.contains("--preview-phrase-highlights") || Bundle.main.object(forInfoDictionaryKey: "HelloChatPhrasePreview") as? Bool == true {
            // Shared view only: no GateModel, capture, archive, Voice or sound.
            PhraseHighlightPreviewApp.main(); return
        }
        if CommandLine.arguments.contains("--check-phrase-variants") {
            // Actual compiled matcher, text only. Never dispatch Voice, capture
            // a microphone, save a transcript or play a command sample.
            var off = PhraseMatcher(), on = PhraseMatcher()
            let wakes = off.consume("as well chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake
            let safeEnd = on.consume("as well chat", wake: "", sleep: "Bye Chat", similar: true) == nil
            var context = StandaloneWake()
            context.audio(level: 0.2, seconds: 0.1)
            context.update("I said hello chat", at: 1)
            context.audio(level: 0, seconds: 0.8)
            let mentionIgnored = !context.poll(at: 2, phrase: "Hello Chat", similar: true)
            let ordinarySpeechIgnored = PhraseMatcher.matches(in: PhraseMatcher.words("it's too high at low speed"),
                phrase: "Hello Chat", similar: true).isEmpty
            let variants = PhraseMatcher.defaultVariantCounts
            let report: [String: Any] = ["wakeSpellings": variants.wake, "endSpellings": variants.end,
                "weakWakeSpellings": variants.weakWake, "screenshotWakes": wakes,
                "screenshotCannotEnd": safeEnd, "mentionIgnored": mentionIgnored,
                "ordinarySpeechIgnored": ordinarySpeechIgnored]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(wakes && safeEnd && mentionIgnored && ordinarySpeechIgnored ? 0 : 1)
        }
        let selectedModel: SpeechModel
        if let index = CommandLine.arguments.firstIndex(of: "--model") {
            guard index + 1 < CommandLine.arguments.count,
                  let model = SpeechModel(rawValue: CommandLine.arguments[index + 1]) else {
                fputs("Unknown speech model.\n", stderr); exit(2)
            }
            selectedModel = model
        } else { selectedModel = .defaultModel }
        if let index = CommandLine.arguments.firstIndex(of: "--check-recording") ?? CommandLine.arguments.firstIndex(of: "--check-standalone-recording") {
            guard index + 1 < CommandLine.arguments.count else { exit(2) }
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                let result = await SpeechCheck().run(url: url, model: selectedModel, standalone: CommandLine.arguments.contains("--check-standalone-recording"))
                let report: [String: Any] = ["model": selectedModel.rawValue, "text": result.text, "segments": result.segments, "detections": result.detections,
                    "gaps": result.gaps, "resets": result.resets, "utteranceEnds": result.utteranceEnds,
                    "cpuSeconds": result.cpuSeconds, "audioSeconds": result.audioSeconds,
                    "memoryMB": ResourceUsage.footprintMB(), "anePlanShare": selectedModel.neuralPlacementKnown ? result.neuralShare as Any : NSNull()]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                exit(result.commands.isEmpty ? 1 : 0)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--check-capture-lifecycle") {
            // Real selected-input capture only: no transcript, archive, Voice,
            // playback, global input-device changes or keyboard events.
            Task { @MainActor in
                var listener: SpeechListener? = SpeechListener(diagnostics: nil)
                weak var released = listener
                let inputs = MicrophoneInputs()
                listener?.model = selectedModel
                listener?.inputDevice = {
                    guard let input = inputs.selected else { throw BridgeError.message("Selected microphone is unavailable.") }
                    return input.id
                }
                var passed = true
                for iteration in 1...6 {
                    do {
                        try await listener!.start()
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        let seconds = listener!.resultAudioSeconds
                        listener!.stop(); await listener!.waitUntilStopped()
                        let ok = seconds >= 0.5
                        passed = passed && ok
                        let row: [String: Any] = ["iteration": iteration, "passed": ok, "audioSeconds": seconds,
                            "memoryMB": ResourceUsage.footprintMB(), "neuralMemoryMB": ResourceUsage.neuralFootprintMB()]
                        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
                    } catch {
                        listener!.stop(); await listener!.waitUntilStopped()
                        let failure = error as NSError
                        print("capture_failed domain=\(failure.domain) code=\(failure.code)")
                        passed = false; break
                    }
                }
                listener = nil
                await Task.yield()
                let deallocated = released == nil
                print("listener_deallocated=\(deallocated)")
                exit(passed && deallocated ? 0 : 1)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--stress-speech") {
            Task { @MainActor in
                let args = CommandLine.arguments
                let count = args.firstIndex(of: "--iterations").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 10
                guard (1...100).contains(count),
                      let positive = Bundle.main.url(forResource: "SpeechCheck", withExtension: "wav"),
                      let negative = Bundle.main.url(forResource: "SpeechNegative", withExtension: "wav") else { exit(2) }
                var passed = true
                for iteration in 1...count {
                    let good = await SpeechCheck().run(url: positive, recoverBeforeAudio: iteration % 3 == 0, model: selectedModel)
                    let other = await SpeechCheck().run(url: negative, model: selectedModel)
                    let ok = good.commands == [.wake, .sleep] && other.commands.isEmpty && PhraseMatcher.words(other.text).contains("weather")
                        && good.gaps == 0 && other.gaps == 0 && good.detections.allSatisfy { $0["after_flush"] as? Bool == false }
                    passed = passed && ok
                    let report: [String: Any] = ["model": selectedModel.rawValue, "iteration": iteration, "passed": ok, "detections": good.detections,
                        "negativeCommands": other.commands.count, "memoryMB": ResourceUsage.footprintMB(), "neuralMemoryMB": ResourceUsage.neuralFootprintMB(),
                        "gaps": good.gaps + other.gaps, "resets": good.resets + other.resets,
                        "cpuSeconds": good.cpuSeconds + other.cpuSeconds, "audioSeconds": good.audioSeconds + other.audioSeconds,
                        "anePlanShare": selectedModel.neuralPlacementKnown ? good.neuralShare as Any : NSNull(), "pipeline": "production SpeechListener file input; no microphone, playback or Voice call"]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
                }
                exit(passed ? 0 : 1)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--check-speech") || CommandLine.arguments.contains("--check-audio-recovery") {
            Task { @MainActor in
                guard let positiveURL = Bundle.main.url(forResource: "SpeechCheck", withExtension: "wav"),
                      let negativeURL = Bundle.main.url(forResource: "SpeechNegative", withExtension: "wav") else { exit(2) }
                let recovery = CommandLine.arguments.contains("--check-audio-recovery")
                let positive = await SpeechCheck().run(url: positiveURL, recoverBeforeAudio: recovery, model: selectedModel)
                let negative = await SpeechCheck().run(url: negativeURL, recoverBeforeAudio: recovery, model: selectedModel)
                let passed = positive.commands == [.wake, .sleep] && negative.commands.isEmpty && PhraseMatcher.words(negative.text).contains("weather")
                let report: [String: Any] = ["model": selectedModel.rawValue, "passed": passed, "positive": positive.text, "negative": negative.text,
                    "wakeDetected": positive.commands.contains(.wake), "endDetected": positive.commands.contains(.sleep),
                    "negativeCommands": negative.commands.count, "estimatedEncoderANEShare": selectedModel.neuralPlacementKnown ? positive.neuralShare as Any : NSNull(),
                    "recognitionProcessCPUSeconds": positive.cpuSeconds + negative.cpuSeconds,
                    "audioSeconds": positive.audioSeconds + negative.audioSeconds, "audioGapRecoveryChecked": recovery]
                if let json = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: json, as: UTF8.self)) }
                exit(passed ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--check-meter-isolation") {
            Task { @MainActor in
                let model = GateModel()
                var wholeWindowUpdates = 0
                let observation = model.objectWillChange.sink { wholeWindowUpdates += 1 }
                for index in 0..<100 { model.meter.level = Double(index) / 100 }
                withExtendedLifetime(observation) {}
                print("100 meter updates; \(wholeWindowUpdates) whole-window updates")
                exit(wholeWindowUpdates == 0 ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--check-agent-flow") {
            Task { @MainActor in
                let monitor = AgentFlowRecordingMonitor()
                print("{\"phrasesPaused\":\(monitor.suppressesPhrases)}")
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--check-voice-controls") || CommandLine.arguments.contains("--check-end-controls") {
            // Read-only diagnostic: never activates Codex or sends a shortcut.
            for depth in [32, 96] {
                let state = VoiceBridge.snapshot(maximumDepth: depth, requireEnd: CommandLine.arguments.contains("--check-end-controls"))
                var info = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any] ?? [:]
                info["maximumDepth"] = depth
                if let json = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys) { print(String(decoding: json, as: UTF8.self)) }
            }
            return
        }
        if CommandLine.arguments.contains("--status") {
            let state = VoiceBridge.snapshot(readMicrophone: false)
            var info = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any] ?? [:]
            let savedModel = SpeechModel.saved()
            info["recognition"] = savedModel.title
            info["neuralEngineAvailable"] = MLComputeDevice.allComputeDevices.contains { if case .neuralEngine = $0 { return true }; return false }
            info["microphonePermission"] = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
            if let json = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys) { print(String(decoding: json, as: UTF8.self)) }
            return
        }
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Hey Chat/instance.lock")
            let instance = try AppInstanceLock(url: url)
            guard instance.acquired else { return }
            try AppPaths.migrateLegacyData()
            withExtendedLifetime(instance) { HelloChatApp.main() }
        } catch {
            fputs("Could not acquire HelloChat instance lock: \(error)\n", stderr)
        }
    }
}

@MainActor final class InterfaceZoom: ObservableObject {
    @Published private(set) var scale: Double = min(1.8, max(0.8, UserDefaults.standard.object(forKey: "interfaceZoom") as? Double ?? 1)) {
        didSet { UserDefaults.standard.set(scale, forKey: "interfaceZoom") }
    }
    var canIncrease: Bool { scale < 1.8 }
    var canDecrease: Bool { scale > 0.8 }
    func increase() { scale = min(1.8, (scale * 10 + 1).rounded() / 10) }
    func decrease() { scale = max(0.8, (scale * 10 - 1).rounded() / 10) }
    func reset() { scale = 1 }
}

// One bundle-backed version for the header and Settings; no separate UI value.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))"
    }
}

struct HelloChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = GateModel()
    @StateObject private var zoom = InterfaceZoom()
    var body: some Scene {
        Window("HelloChat · \(AppVersion.display)", id: "main") {
            MainView(model: model, zoom: zoom)
                .background(InitialWindowPlacement())
                .onAppear { delegate.model = model; delegate.refreshPlayback() }
        }
        .defaultSize(width: 474, height: 630)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton().keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit HelloChat") { model.quit() }.keyboardShortcut("q")
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In") { zoom.increase() }
                    .keyboardShortcut("+", modifiers: .command).disabled(!zoom.canIncrease)
                Button("Zoom Out") { zoom.decrease() }
                    .keyboardShortcut("-", modifiers: .command).disabled(!zoom.canDecrease)
                Button("Actual Size") { zoom.reset() }.keyboardShortcut("0", modifiers: .command)
            }
        }
        Window("HelloChat Settings", id: "settings") {
            SettingsView(model: model, zoom: zoom)
                .background(InitialWindowPlacement())
        }
        .defaultSize(width: 560, height: 660)
        .windowResizability(.contentMinSize)
        MenuBarExtra("HelloChat", systemImage: model.enabled ? "waveform.circle.fill" : "waveform.circle") {
            MenuView(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: GateModel?
    private var terminating = false
    private var readyToTerminate = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var playbackMonitoringReady = false
    func refreshPlayback() {
        guard playbackMonitoringReady else { return }
        model?.playbackChanged(allowed: outputListener != nil && BosePlayback.isSelected == false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.refreshPlayback() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            outputListener = listener
        }
        playbackMonitoringReady = true
        refreshPlayback() // Keep the app alive even when route observation fails.
    }
    deinit {
        if let outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let ready = await model.prepareToQuit()
            if ready {
                readyToTerminate = true
                // Return from the current Swift actor job before asking AppKit
                // again. terminateLater's nested event loop can otherwise hold
                // that actor job while the cleanup Task waits for its executor.
                DispatchQueue.main.async { sender.terminate(nil) }
            } else { terminating = false }
        }
        return .terminateCancel
    }
}

struct MainView: View {
    @ObservedObject var model: GateModel
    @ObservedObject var zoom: InterfaceZoom
    @Environment(\.openWindow) private var openWindow
    private var preparing: Bool { (model.busy && model.status == "Starting") || model.changingModel }
    private var voiceOn: Bool { model.voice.connected }
    private var connecting: Bool { model.status == "Connecting" }
    var body: some View {
        GeometryReader { viewport in
            Form {
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("errorMessage")
                    }
                }
                Section("Listening (say it twice if detection is wonky)") {
                    Toggle("Listen for wake phrase", isOn: Binding(get: { model.listeningToggleOn }, set: { _ in model.toggle() }))
                        .disabled(model.busy && !preparing && !model.enabled)
                        .accessibilityIdentifier("listeningToggle")
                    TextField("Wake phrase", text: $model.wakePhrase)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("wakePhraseLabel")
                    TextField("End phrase", text: $model.sleepPhrase)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("endPhraseLabel")
                    LabeledContent("Status", value: preparing ? "Preparing local model…" : model.status)
                        .accessibilityIdentifier("listeningStatus")
                    Text(model.phrasesPausedForAgentFlow ? "Phrases paused for Agent Flow." : model.detail)
                        .foregroundStyle(.secondary)
                    Picker("Speech model", selection: $model.speechModel) {
                        ForEach(SpeechModel.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .disabled(model.busy || model.checkingSpeech || model.changingModel)
                    .accessibilityIdentifier("speechModelPicker")
                    NativeMeter(meter: model.meter, active: model.detectionRunning)
                    Text(model.speechModel.detail).foregroundStyle(.secondary)
                    if !model.micAllowed {
                        Button("Allow Microphone") { model.requestAudioPermissions() }
                    }
                }
                Section("Heard (local model)") {
                    TranscriptPane(text: model.transcript, phrase: model.wakePhrase, endPhrase: model.sleepPhrase,
                                   similar: model.similarPhrases, enabled: model.enabled,
                                   viewportHeight: viewport.size.height, scale: zoom.scale)
                }
                Section("Codex Voice") {
                    LabeledContent("Status", value: connecting ? "Opening…" : (voiceOn ? "On" : "Off"))
                        .accessibilityIdentifier("voiceStatus")
                    Text(voiceOn ? "Say \(model.sleepPhrase) to end Voice." : "Say \(model.wakePhrase) to start Voice. No need to turn it on first.")
                        .foregroundStyle(.secondary)
                    Button(connecting ? "Cancel" : (voiceOn ? "End Voice in Codex" : "Start Voice in Codex")) {
                        if voiceOn || connecting { model.manualMute() } else { model.manualTalk() }
                    }
                    .disabled(model.busy && !connecting)
                    .accessibilityIdentifier("voiceButton")
                    if !model.lastEvent.isEmpty {
                        Text(model.lastEvent).foregroundStyle(.secondary).accessibilityIdentifier("lastEvent")
                    }
                }
            }
            .formStyle(.grouped)
            .font(.system(size: 13 * zoom.scale))
            .controlSize(zoom.scale >= 1.3 ? .large : .regular)
            .coordinateSpace(name: TranscriptPane.coordinateSpace)
        }
        .frame(minWidth: 380, minHeight: 380)
        .toolbar {
            ToolbarItemGroup {
                Button { openWindow(id: "settings") } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}


struct PhraseHighlightPreviewApp: App {
    var body: some Scene {
        Window("HelloChat · \(AppVersion.display)", id: "phrase-preview") {
            Form {
                Section("Heard (local model)") {
                    HeardTranscript(text: "Hello, this is a test. What's going on? Hello chat. Bye chat by chat why does the end voice end phrase not highlight",
                                    phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true, enabled: true)
                    HeardTranscript(text: "Start Lantern. End Lantern. Hello Chat and Bye Chat stay unchanged with custom phrases.",
                                    phrase: "Start Lantern", endPhrase: "End Lantern", similar: true, enabled: true)
                }
            }
            .formStyle(.grouped).textSelection(.enabled)
            .frame(minWidth: 380, minHeight: 220)
            .background(InitialWindowPlacement())
        }
        .defaultSize(width: 560, height: 400)
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: GateModel
    @ObservedObject var zoom: InterfaceZoom
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppVersion.display).accessibilityIdentifier("appVersion")
            }
            Section("Microphone") {
                MicrophoneSettings(inputs: model.inputs)
            }
            Section("Automatic Listening") {
                Toggle("Listen automatically when docked", isOn: $model.automaticListening)
                    .accessibilityIdentifier("automaticListening")
                Text("Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. You can turn listening on yourself at any time.")
                    .foregroundStyle(.secondary)
                DockStatus(dock: model.dock)
            }
            Section("Phrases") {
                TextField("Wake phrase", text: $model.wakePhrase).accessibilityIdentifier("wakePhrase")
                TextField("End phrase", text: $model.sleepPhrase).accessibilityIdentifier("endPhrase")
                Text("Say the wake phrase, then finish speaking to talk to Chat. Clear mentions of the phrase are ignored. The end phrase acts immediately, including while Voice is connecting.")
                    .foregroundStyle(.secondary)
                Toggle("Allow small spelling differences", isOn: $model.similarPhrases)
                    .accessibilityIdentifier("similarPhrases")
                Text(model.similarPhrases ? "Matches joined words and small changes such as Hello Chatt for Hello Chat. Requires the full wake phrase." : "Matches saved phrases exactly. Spaces and punctuation may differ.")
                    .foregroundStyle(.secondary)
                if PhraseMatcher.words(model.wakePhrase).isEmpty || PhraseMatcher.words(model.sleepPhrase).isEmpty {
                    Text("Enter both phrases").foregroundStyle(.red)
                }
                Picker("End Voice after silence", selection: $model.timeout) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                Button(model.checkingSpeech ? "Checking speech…" : "Check speech recognition") { model.checkSpeech() }
                    .disabled(model.busy || model.voice.connected)
                    .accessibilityIdentifier("speechCheck")
                if !model.speechCheckText.isEmpty {
                    Text(model.speechCheckText).textSelection(.enabled)
                        .accessibilityIdentifier("speechCheckResult")
                }
            }
            Section("Resources") {
                ResourceStatus()
                Text(model.computeText)
                Text(model.computeDetail).foregroundStyle(.secondary)
                Text("CPU includes audio capture, conversion, decoding and app controls. Neural Engine utilization is not measured.")
                    .foregroundStyle(.secondary)
            }
            Section("Sounds") {
                Toggle("Sound effects", isOn: $model.soundEffects).accessibilityIdentifier("soundEffects")
                HStack {
                    Button("Wake sound") { model.previewSound(.wake) }
                    Button("End sound") { model.previewSound(.ended) }
                }.disabled(!model.soundEffects)
            }
            Section("Transcript Archive") {
                Toggle("Save transcripts", isOn: $model.saveTranscripts).accessibilityIdentifier("saveTranscripts")
                Text("Saves local recognition as JSON with rough phrase timestamps. May include background speech. Audio isn't saved.").foregroundStyle(.secondary)
                Text(TranscriptArchive.directory.path).textSelection(.enabled).accessibilityIdentifier("transcriptArchivePath")
                Text("Google Drive backup runs daily while plugged in. Existing backups remain when saving is off.").foregroundStyle(.secondary)
                if let error = model.archiveError { Text(error).foregroundStyle(.red).accessibilityIdentifier("transcriptArchiveError") }
            }
            Section("Diagnostics") { DiagnosticsView() }
            Section("Appearance") {
                WindowDisplaySettings()
                LabeledContent("Zoom") {
                    HStack {
                        Button("−") { zoom.decrease() }.disabled(!zoom.canDecrease).accessibilityLabel("Zoom Out")
                        Text("\(Int((zoom.scale * 100).rounded()))%").monospacedDigit()
                            .accessibilityIdentifier("zoomValue")
                        Button("+") { zoom.increase() }.disabled(!zoom.canIncrease).accessibilityLabel("Zoom In")
                        Button("Actual Size") { zoom.reset() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 13 * zoom.scale))
        .controlSize(zoom.scale >= 1.3 ? .large : .regular)
        .frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity,
               minHeight: 420, idealHeight: 660, maxHeight: .infinity)
    }
}

struct DiagnosticsView: View {
    @State private var recent = ""
    var body: some View {
        Text("Timing and error logs exclude recognized words. Saved transcripts are in Transcript Archive. Audio isn't saved.").foregroundStyle(.secondary)
        Text(Diagnostics.shared.directory.path).textSelection(.enabled)
        DisclosureGroup("Recent events") {
            Text(recent.isEmpty ? "No events yet" : recent).fontDesign(.monospaced).textSelection(.enabled)
                .accessibilityIdentifier("diagnosticEvents")
        }
        .task {
            while !Task.isCancelled {
                recent = Diagnostics.shared.tail()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

struct MicrophoneSettings: View {
    @ObservedObject var inputs: MicrophoneInputs
    var body: some View {
        Picker("Microphone", selection: $inputs.selectedUID) {
            Text("System default").tag("")
            ForEach(inputs.devices) { input in Text(input.name).tag(input.uid) }
            if !inputs.selectedUID.isEmpty && inputs.selected == nil {
                Text("Selected microphone unavailable").tag(inputs.selectedUID)
            }
        }
        .accessibilityIdentifier("microphonePicker")
        Text("Using: \(inputs.selectedName)").foregroundStyle(.secondary)
            .accessibilityIdentifier("microphoneRoute")
        Text("For local listening. Codex Voice uses its own input setting.").foregroundStyle(.secondary)
    }
}

struct DockStatus: View {
    @ObservedObject var dock: DockMonitor
    var body: some View {
        Text("\(dock.powerText) · \(dock.externalDisplays) external display\(dock.externalDisplays == 1 ? "" : "s")")
            .foregroundStyle(.secondary).accessibilityIdentifier("dockStatus")
    }
}

struct ResourceStatus: View {
    @State private var usage = ResourceUsage()
    @State private var text = "Measuring…"
    var body: some View {
        Text(text).monospacedDigit()
            .accessibilityIdentifier("resourceUsage")
            .task {
                while !Task.isCancelled {
                    text = usage.sample()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
}

struct NativeMeter: View {
    @ObservedObject var meter: AudioMeter
    let active: Bool
    var body: some View {
        ProgressView(value: active ? meter.level : 0)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(active ? "\(Int(meter.level * 100)) percent" : "Off")
    }
}

struct MenuView: View {
    @ObservedObject var model: GateModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Button(model.listeningToggleOn ? "Stop listening" : "Start listening") { model.toggle() }
            .disabled(model.busy && !model.enabled)
        Button(model.status == "Connecting" ? "Cancel" : (model.microphone == .listening ? "End Voice in Codex" : "Start Voice in Codex")) {
            if model.microphone == .listening || model.status == "Connecting" { model.manualMute() } else { model.manualTalk() }
        }
        .disabled(model.busy && model.status != "Connecting")
        Divider()
        Button("HelloChat") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit HelloChat") { model.quit() }
    }
}

// Initial placement only. Native resizing, window zoom and user placement are
// left to macOS; scrolling handles content larger than the chosen window.
struct InitialWindowPlacement: NSViewRepresentable {
    final class Host: NSView {
        private var placed = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !placed, let screen = WindowDisplay.preferredScreen else { return }
            placed = true
            DispatchQueue.main.async {
                let bounds = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.1, dy: screen.visibleFrame.height * 0.1)
                let size = NSSize(width: min(window.frame.width, bounds.width), height: min(window.frame.height, bounds.height))
                window.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
        }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) {}
}
