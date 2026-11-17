// Previously HeyChatApp.swift / Hey Chat. Product name: Hello Chat; spoken wake phrase: Hello Chat.
import AppKit
import ApplicationServices
import Combine
import SwiftUI
import CoreML
import FluidAudio
import AVFoundation
import Darwin

@main enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--voice-peer-status", "--voice-peer-end", "--voice-peer-confirm-end"].contains(arguments.first ?? "") {
            let receipt: VoicePeerReceipt
            let expires = Date().timeIntervalSince1970 + 4
            if VoicePeerConfiguration.installed == nil {
                receipt = .init(status: .disabled)
            } else if arguments == ["--voice-peer-status"] {
                receipt = VoicePeerMailbox.submit(.init(action: .status, call: nil, expires: expires))
            } else if arguments.count == 2, arguments[0] == "--voice-peer-confirm-end",
                      let call = VoicePeerCall(token: arguments[1]) {
                receipt = VoicePeerMailbox.submit(.init(action: .confirmEnd, call: call, expires: expires))
            } else if arguments.count == 3, arguments[0] == "--voice-peer-end",
                      let call = VoicePeerCall(token: arguments[1]), let deadline = TimeInterval(arguments[2]) {
                receipt = VoicePeerMailbox.submit(.init(action: .end, call: call, expires: deadline))
            } else {
                receipt = .init(status: .unknown)
            }
            let data = try! JSONEncoder().encode(receipt)
            print(VoicePeerReceipt.wirePrefix + String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.contains("--consume-startup-speech") {
            // The Voice skill's file handoff must exit before app startup,
            // instance ownership, microphone capture or native Voice control.
            let arguments = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            guard let seconds = value("--voice-created-at").flatMap(Double.init), seconds.isFinite, seconds > 0,
                  let threadID = value("--voice-thread-id").flatMap(UUID.init(uuidString:)) else {
                print("{\"status\":\"invalid_arguments\"}"); exit(2)
            }
            do {
                let result = try StartupSpeechFile(onEvent: {
                    Diagnostics.shared.record($0.name, numbers: $0.numbers, info: $0.info)
                }).consume(voiceCreatedAt: Date(timeIntervalSince1970: seconds), threadID: threadID)
                Diagnostics.shared.flush()
                print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); exit(0)
            } catch {
                Diagnostics.shared.failure("voice.startup_speech.consume_failed", error)
                Diagnostics.shared.flush()
                let failure = error as NSError
                let status = failure.domain == NSPOSIXErrorDomain && failure.code == Int(EWOULDBLOCK) ? "busy" : "unavailable"
                print("{\"status\":\"\(status)\"}"); exit(1)
            }
        }
        if CommandLine.arguments.contains("--preview-speaker-settings") {
            SpeakerOutputPreviewApp.main(); return // Isolated editor: no listening, routing or saved preferences.
        }
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
            let safeNamesIgnored = ["B Chat", "be chat", "bee chat", "H Chat", "UI Chat", "U I C H A T"].allSatisfy { text in
                var matcher = PhraseMatcher()
                return matcher.consume(text, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil
            }
            var endContext = StandaloneWake()
            endContext.audio(level: 0.2, seconds: 0.1)
            endContext.update("I said bye chat", at: 1)
            let endMentionIgnored = !endContext.pollEnd(at: 1, phrase: "Bye Chat", similar: true)
            endContext.resetContext()
            endContext.update("Bye Chat", at: 2)
            endContext.audio(level: 0, seconds: StandaloneWake.commandPauseSeconds)
            let directEndAccepted = endContext.pollEnd(at: 2, phrase: "Bye Chat", similar: true)
            let variants = PhraseMatcher.defaultVariantCounts
            let report: [String: Any] = ["wakeSpellings": variants.wake, "endSpellings": variants.end,
                "weakWakeSpellings": variants.weakWake, "screenshotWakes": wakes,
                "screenshotCannotEnd": safeEnd, "mentionIgnored": mentionIgnored,
                "ordinarySpeechIgnored": ordinarySpeechIgnored, "safeNamesIgnored": safeNamesIgnored,
                "endMentionIgnored": endMentionIgnored, "directEndAccepted": directEndAccepted]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            exit(wakes && safeEnd && mentionIgnored && ordinarySpeechIgnored && safeNamesIgnored && endMentionIgnored && directEndAccepted ? 0 : 1)
        }
        let selectedModel: SpeechModel
        if let index = CommandLine.arguments.firstIndex(of: "--model") {
            guard index + 1 < CommandLine.arguments.count,
                  let model = SpeechModel(rawValue: CommandLine.arguments[index + 1]) else {
                fputs("Unknown speech model.\n", stderr); exit(2)
            }
            selectedModel = model
        } else { selectedModel = .defaultModel }
        if let index = CommandLine.arguments.firstIndex(of: "--check-recording") ?? CommandLine.arguments.firstIndex(of: "--check-standalone-recording") ?? CommandLine.arguments.firstIndex(of: "--check-startup-recording") {
            guard index + 1 < CommandLine.arguments.count else { exit(2) }
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                let startup = CommandLine.arguments.contains("--check-startup-recording")
                let result = await SpeechCheck().run(url: url, model: selectedModel, standalone: CommandLine.arguments.contains("--check-standalone-recording"), captureStartup: startup)
                let report: [String: Any] = ["model": selectedModel.rawValue, "text": result.text, "segments": result.segments, "detections": result.detections,
                    "gaps": result.gaps, "resets": result.resets, "utteranceEnds": result.utteranceEnds,
                    "startupSpeech": result.startupSpeech, "startupReady": result.startupReady, "startupAtVoiceOpen": result.startupAtVoiceOpen,
                    "startupBoundary": result.startupBoundary,
                    "cpuSeconds": result.cpuSeconds, "audioSeconds": result.audioSeconds,
                    "memoryMB": ResourceUsage.footprintMB(), "anePlanShare": selectedModel.neuralPlacementKnown ? result.neuralShare as Any : NSNull()]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
                exit(startup ? (result.startupReady && !result.startupSpeech.isEmpty ? 0 : 1) : (result.commands.isEmpty ? 1 : 0))
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
                let model = GateModel(enableSpotifyControl: false)
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
                print("{\"phrasesPaused\":false,\"recordingOrUnknown\":\(monitor.recordingOrUnknown)}")
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--check-voice-controls") || CommandLine.arguments.contains("--check-end-controls") || CommandLine.arguments.contains("--check-output-controls") {
            // Read-only diagnostic: never activates Codex or sends a shortcut.
            for depth in [32, 96] {
                let state = VoiceBridge.snapshot(maximumDepth: depth, requireEnd: CommandLine.arguments.contains("--check-end-controls"), readOutput: CommandLine.arguments.contains("--check-output-controls"))
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
            info["postEventAllowed"] = CGPreflightPostEventAccess()
            if let json = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys) { print(String(decoding: json, as: UTF8.self)) }
            return
        }
        if CommandLine.arguments.contains("--check-spotify-volume") {
            // Metadata-only diagnostic, before ordinary startup. No volume,
            // playback, microphone, shortcut or permission-prompt side effects.
            do {
                let volume = try SpotifyVolumeControl.read()
                let report: [String: Any] = ["running": volume != nil, "volume": volume as Any? ?? NSNull()]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
            } catch SpotifyControlError.permissionRequired { print("{\"permissionRequired\":true}") }
            catch { print("{\"unavailable\":true}") }
            return
        }
        if StartupOwnership.handoffIfNeeded() { return }
        do {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Hey Chat/instance.lock")
            let instance = try AppInstanceLock(url: url)
            guard instance.acquired else { return }
            try AppPaths.migrateLegacyData()
            AppPaths.removeRetiredPreferences()
            // App startup owns this integration, including after an update.
            // A user-managed collision must not prevent listening or change it.
            do {
                let result = try StartupSpeechSkillInstaller.installBundled()
                Diagnostics.shared.record("voice.startup_skill.install", info: ["result": result.rawValue])
            } catch { Diagnostics.shared.failure("voice.startup_skill.install_failed", error) }
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
    @StateObject private var model: GateModel
    @StateObject private var zoom = InterfaceZoom()
    @StateObject private var updater = AppUpdater()
    init() {
        let model = GateModel()
        _model = StateObject(wrappedValue: model)
        HChatShortcutActions.handler = { [weak model] action in
            guard let model else { throw HChatShortcutError.unavailable }
            return try await model.performShortcut(action)
        }
    }
    var body: some Scene {
        Window("Hello Chat · \(AppVersion.display)", id: "main") {
            MainView(model: model, zoom: zoom, updater: updater)
                .background(InitialWindowPlacement())
                .onAppear {
                    delegate.model = model
                    model.initializeListening()
                    updater.start(model: model, prepareToQuit: { await delegate.prepareForUpdate() },
                                  restoreAfterAbort: { await delegate.restoreAfterFailedUpdate() })
                }
        }
        .defaultSize(width: 474, height: 630)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton().keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Hello Chat") { model.quit() }.keyboardShortcut("q")
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In") { zoom.increase() }
                    .keyboardShortcut("+", modifiers: .command).disabled(!zoom.canIncrease)
                Button("Zoom Out") { zoom.decrease() }
                    .keyboardShortcut("-", modifiers: .command).disabled(!zoom.canDecrease)
                Button("Actual Size") { zoom.reset() }.keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("Hello Chat Help", destination: URL(string: "https://ethansk.github.io/hello-chat/#setup")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/EthanSK/hello-chat/issues")!)
            }
        }
        Window("Hello Chat Settings", id: "settings") {
            SettingsView(model: model, zoom: zoom, updater: updater)
                .background(InitialWindowPlacement())
        }
        .defaultSize(width: 560, height: 660)
        .windowResizability(.contentMinSize)
        MenuBarExtra("Hello Chat", systemImage: model.enabled ? "waveform.circle.fill" : "waveform.circle") {
            MenuView(model: model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: GateModel?
    private var terminating = false
    private var readyToTerminate = false
    // Sparkle's first termination request must be accepted. Finish the same
    // call-preserving cleanup used by Quit before invoking its install handler.
    func prepareForUpdate() async -> Bool {
        if readyToTerminate { return true }
        guard !terminating else { return false }
        terminating = true
        let ready = await model?.prepareToQuit(preservingSpotify: true) ?? true
        readyToTerminate = ready
        if !ready { terminating = false }
        return ready
    }
    func restoreAfterFailedUpdate() async {
        readyToTerminate = false; terminating = false
        await model?.restoreAfterFailedUpdate()
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
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    private var preparing: Bool { (model.busy && model.status == "Starting") || model.changingModel }
    private var connecting: Bool { model.status == "Connecting" }
    @State private var showingSpeakerOutput = false
    var body: some View {
        GeometryReader { viewport in
            Form {
                Section {
                    TranscriptPane(segments: model.transcript.isEmpty ? [] : [model.transcript], phrase: model.wakePhrase, endPhrase: model.sleepPhrase,
                                   similar: model.similarPhrases, enabled: model.enabled,
                                   viewportHeight: viewport.size.height, scale: zoom.scale,
                                   controlPhrases: model.controlPhrases, patterns: model.phrasePatterns)
                        .id(model.transcriptBatchID) // A new recognition batch releases held text and selection from the previous batch.
                } header: {
                    HStack {
                        Text("Heard (local model)")
                        Spacer()
                        Button(model.chatActionTitle) { model.toggleChat() }
                            .buttonStyle(.bordered)
                            .disabled(model.busy && !connecting)
                            .accessibilityIdentifier("voiceButton")
                        Button { model.refreshVoice() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).help("Refresh chat status")
                        .disabled(model.busy).accessibilityIdentifier("voiceRefreshButton")
                    }
                    .textCase(nil)
                }
                if updater.waitingToInstall {
                    Section {
                        Text("Update ready.")
                        Button("Restart to update") { updater.resumeIfIdle() }
                            .disabled(model.busy || model.checkingSpeech)
                    }
                }
                if let notice = model.shortcutNotice {
                    Section {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                            .accessibilityIdentifier("shortcutNotice")
                    }
                }
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
                    // Preserve Ethan's removal of redundant always-visible status/instruction rows.
                    // Explain only preparation, dock waiting or interrupted capture on Home.
                    if preparing || model.status.hasPrefix("Waiting") || model.status == "Needs attention"
                        || (model.enabled && !model.detectionRunning) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.status).accessibilityIdentifier("listeningStatus")
                            Text(model.detail).foregroundStyle(.secondary)
                                .accessibilityIdentifier("listeningDetail")
                        }
                    }
                    PhraseFields(model: model)
                    VideoControls(model: model, bridge: model.videoBridge)
                    PhraseFields(model: model, slots: PhraseSlot.musicSlots)
                    PhraseFields(model: model, slots: PhraseSlot.desktopSlots)
                    Button("Switch speakers…") { showingSpeakerOutput = true }
                        .accessibilityIdentifier("speakerOutputSettings")
                        .sheet(isPresented: $showingSpeakerOutput) {
                            SpeakerOutputEditor(initial: model.speakerOutputSettings, otherPatterns: model.speakerOutputConflictingPhrases, save: model.saveSpeakerOutputSettings)
                        }
                    if let status = model.speakerOutputStatus {
                        Text(status).foregroundStyle(.secondary).accessibilityIdentifier("speakerOutputStatus")
                    }
                    if let phrase = model.speakerOutputConflict {
                        Text("Speaker phrases are off. Already used by another command: \(phrase)")
                            .foregroundStyle(.red).accessibilityIdentifier("speakerOutputConflict")
                    }
                    if let status = model.desktopCommandStatus {
                        Text(status).foregroundStyle(.secondary).accessibilityIdentifier("desktopCommandStatus")
                    }
                    // Ethan wants to change the microphone from the home page.
                    // Home owns the only microphone editor; Settings keeps advanced options.
                    MicrophoneSettings(inputs: model.inputs)
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
                        if model.micPermissionDenied {
                            Link("Microphone settings…", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                .accessibilityIdentifier("microphoneSettingsLink")
                        } else {
                            Button("Allow Microphone") { model.requestAudioPermissions() }
                        }
                    }
                    if !model.accessibilityAllowed {
                        Button("Accessibility settings…") { model.requestAccessibilityPermission() }
                            .accessibilityIdentifier("accessibilitySettingsLink")
                        Text("Allow Hello Chat to send shortcuts and read Codex Voice controls.").foregroundStyle(.secondary)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions(); model.refreshVideoBridge() // A status check only; no playback change.
        }
    }
}


struct PhraseHighlightPreviewApp: App {
    var body: some Scene {
        Window("Hello Chat · \(AppVersion.display)", id: "phrase-preview") {
            Form {
                Section("Heard (local model)") {
                    HeardTranscript(text: "Hello chat. Mute chat. Silent chat. Silence chat. Bye chat. By chat. Hello chance.",
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

private struct SpeakerOutputPreviewApp: App {
    @State private var settings = SpeakerOutputSettings(destinations: [SpeakerDestination(names: "Studio", output: "Example output")])
    var body: some Scene {
        Window("Speaker settings preview", id: "speaker-preview") {
            SpeakerOutputEditor(initial: settings, otherPatterns: []) { settings = $0; return true }
        }
    }
}

// One saved editor for speaker command prefixes and destination names. Editing the draft does
// not reset live recognition until Save, and choosing a device never changes the current route.
private struct SpeakerOutputEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpeakerOutputSettings
    @State private var devices: [String] = []
    @State private var saveError: String?
    let otherPatterns: [PhrasePattern]
    let save: (SpeakerOutputSettings) -> Bool
    private var issue: String? {
        draft.issue ?? draft.conflictingPhrase(with: otherPatterns).map { "Already used by another command: \($0)" }
    }
    init(initial: SpeakerOutputSettings, otherPatterns: [PhrasePattern], save: @escaping (SpeakerOutputSettings) -> Bool) {
        _draft = State(initialValue: initial); self.otherPatterns = otherPatterns; self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Switch speakers").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if save(draft) { dismiss() }
                    else { saveError = "Phrases changed elsewhere. Close and try again." }
                }.disabled(issue != nil)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("speakerOutputSave")
            }
            Text("Say a prefix followed by a speaker name, such as ‘Switch speakers to Kitchen’.")
                .foregroundStyle(.secondary)
            ScrollView {
              Form {
                Section("Prefixes") {
                    TextField("One prefix per line", text: $draft.prefixes, axis: .vertical)
                        .lineLimit(2...5).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("speakerOutputPrefixes")
                }
                Section("Speakers") {
                    ForEach($draft.destinations) { $destination in
                        LabeledContent("Names, one per line") {
                            HStack(alignment: .top) {
                                TextField("Speaker names", text: $destination.names, axis: .vertical)
                                    .labelsHidden().lineLimit(1...4).accessibilityLabel("Speaker names")
                                Button { draft.destinations.removeAll { $0.id == destination.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.plain).accessibilityLabel("Remove speaker")
                            }
                        }.accessibilityElement(children: .contain)
                        LabeledContent("Output") {
                            HStack {
                                Menu(destination.output.isEmpty ? "Choose output…" : destination.output) {
                                    ForEach(devices, id: \.self) { name in Button(name) { destination.output = name } }
                                    if devices.isEmpty { Text("No configured outputs found") }
                                }.accessibilityLabel("Output device")
                                    .accessibilityValue(destination.output.isEmpty ? "No output selected" : destination.output)
                                Image(systemName: "minus.circle").hidden().accessibilityHidden(true)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                    Button("Add speaker") { draft.destinations.append(SpeakerDestination(names: "", output: "")) }
                        .accessibilityIdentifier("speakerOutputAdd")
                }
                if let issue = issue ?? saveError { Text(issue).foregroundStyle(.red).accessibilityIdentifier("speakerOutputIssue") }
              }.fixedSize(horizontal: false, vertical: true).padding(.trailing, 12)
            }
            Text("Choose an output configured in the audio switch helper. Disconnected speakers stay listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 600, height: 500)
        .task { devices = await Task.detached { SpeakerOutput.available() }.value }
    }
}

// Both windows edit the same saved phrases, using the existing native form fields. Extra phrases
// sit directly below their section's main phrase (Ethan, 14 November 2026); + adds one.
private enum PhraseFocus: Hashable { case main(PhraseSlot), row(UUID) }

private struct PhraseFields: View {
    @ObservedObject var model: GateModel
    var slots: [PhraseSlot] = PhraseSlot.voiceSlots
    @FocusState private var focus: PhraseFocus?
    @State private var showingAppSpellings = false
    var body: some View {
        ForEach(PhraseSlot.fieldGroups(slots), id: \.first) { group in
          VStack(alignment: .leading, spacing: 8) {
           ForEach(group) { slot in
            PhraseField(slot: slot, text: Binding(get: { model[keyPath: model.phraseKeyPath(for: slot)] },
                set: { model[keyPath: model.phraseKeyPath(for: slot)] = $0 }), similar: model.similarPhrases,
                dictionary: Binding(get: { model.phraseDictionaries[slot.rawValue] },
                    set: { model.phraseDictionaries[slot.rawValue] = $0 }),
                commit: PhraseCommit(field: .main(slot), focus: $focus, commit: commit),
                showsLabel: slot == group.first, showsAdd: slot == group.first,
                add: { add(group.first ?? slot) })
            PhraseIssueText(issue: model.phraseIssue(slot, id: nil), identifier: slot.identifier + "Issue")
            ForEach(Array((model.phraseAliases[slot] ?? []).enumerated()), id: \.element.id) { index, row in
                ExtraPhraseField(slot: slot, number: index + 2,
                    text: Binding(get: { model.phraseAliases[slot]?.first { $0.id == row.id }?.text ?? "" },
                        set: { model.setPhraseRow(slot, id: row.id, text: $0) }),
                    commit: PhraseCommit(field: .row(row.id), focus: $focus, commit: commit),
                    remove: { model.removePhraseRow(slot, id: row.id) })
                PhraseIssueText(issue: model.phraseIssue(slot, id: row.id), identifier: "\(slot.identifier)\(index + 2)Issue")
            }
           }
           if let slot = group.first, let example = slot.example {
               Text(example).foregroundStyle(.secondary).accessibilityIdentifier("\(slot.rawValue)Example")
           }
           if group.first == .switchAppPhrase {
               Button("App spellings…") { showingAppSpellings = true }
                   .accessibilityIdentifier("appSpellingsButton")
           }
          }
        }
        .sheet(isPresented: $showingAppSpellings) { AppSpellingsView(model: model) }
    }
    private func commit(_ field: PhraseFocus) {
        switch field {
        case .main(let slot): model.commitPhraseRow(slot, id: nil)
        case .row(let id): if let slot = model.phraseSlot(containing: id) { model.commitPhraseRow(slot, id: id) }
        }
    }
    private func add(_ slot: PhraseSlot) {
        let id = model.addPhraseRow(slot)
        Task { @MainActor in focus = .row(id) } // The new field exists only after this update.
    }
}

// One editor beside App prefix. The native app catalog supplies choices; GateModel owns the one
// saved spelling configuration used by both Switch and Open. Editing never opens the chosen app.
private struct AppSpellingsView: View {
    @ObservedObject var model: GateModel
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppCandidate] = []
    @State private var loaded = false
    @State private var selectedID: String?
    @State private var search = ""
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    private var selected: AppCandidate? { apps.first { $0.id == selectedID } }
    private var filtered: [AppCandidate] {
        let key = AppResolver.key(search)
        return key.isEmpty ? apps : apps.filter { $0.names.contains { AppResolver.key($0).contains(key) } }
    }
    private var validation: String? {
        do {
            let values = try AppNameSpellings.parse(draft)
            guard let selected else { return nil }
            let conflicts = model.appNameSpellings.conflicts(values, for: selected.id, among: apps)
            return conflicts.isEmpty ? nil : "Already used by \(conflicts.joined(separator: ", "))."
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App spellings").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.disabled(editing)
                    .accessibilityIdentifier("appSpellingsClose")
            }
            Text("Add names the local model hears for each app. Switch and Open use the same spellings.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Find an app", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("appSpellingSearch")
                    List(filtered, id: \.id, selection: $selectedID) { app in
                        Text(app.displayName).tag(app.id)
                    }.accessibilityIdentifier("appSpellingApps")
                }.frame(width: 180).disabled(editing)
                if let selected {
                    spellingDetail(selected)
                } else {
                    Group {
                        if !loaded { ProgressView("Loading apps…") }
                        else { Text(filtered.isEmpty ? "No apps found" : "Select an app").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(16).frame(width: 570, height: 440)
            .interactiveDismissDisabled(editing)
            .onExitCommand { if editing { editing = false } else { dismiss() } }
            .task {
                apps = await model.appSpellingChoices()
                selectedID = apps.first { !model.appNameSpellings.spellings(for: $0.id).isEmpty }?.id ?? apps.first?.id
                loaded = true
            }
    }
    @ViewBuilder private func spellingDetail(_ app: AppCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.displayName).font(.headline).accessibilityIdentifier("appSpellingSelection")
            Text("App names always work. Spaces, punctuation and capitalization may differ.")
                .font(.caption).foregroundStyle(.secondary)
            if editing {
                Text("One spelling per line. Leave blank to use app names only.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body.monospaced()).border(.separator)
                    .accessibilityLabel("App spellings").accessibilityIdentifier("appSpellingEditor")
                    .focused($editorFocused)
                if let validation { Text(validation).font(.caption).foregroundStyle(.red).accessibilityIdentifier("appSpellingError") }
                HStack {
                    Button("Cancel") { editing = false }.accessibilityIdentifier("appSpellingCancel")
                    Spacer()
                    Button(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Use app names only" : "Save") {
                        guard let values = try? AppNameSpellings.parse(draft), validation == nil else { return }
                        model.appNameSpellings.overrides[app.id] = values
                        editing = false
                    }.disabled(validation != nil).accessibilityIdentifier("appSpellingSave")
                }
            } else {
                Text(model.appNameSpellings.overrides[app.id] == nil ? "Built-in spellings" : "Custom spellings")
                    .font(.caption).foregroundStyle(.secondary)
                let values = model.appNameSpellings.spellings(for: app.id)
                if values.isEmpty {
                    Text("App names only").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(values, id: \.self) { Text($0).textSelection(.enabled) }
                        .accessibilityIdentifier("appSpellingList")
                }
                HStack {
                    Button("Edit spellings…") {
                        draft = values.joined(separator: "\n"); editing = true; editorFocused = true
                    }.accessibilityIdentifier("appSpellingEdit")
                    Spacer()
                    if model.appNameSpellings.overrides[app.id] != nil {
                        Button("Restore built-in") { model.appNameSpellings.overrides[app.id] = nil }
                            .accessibilityIdentifier("appSpellingRestore")
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Slash entry such as "Open app / Switch app" becomes rows only on Return, leaving the field or
// leaving the window, never while typing. Each field commits only itself.
private struct PhraseCommit: ViewModifier {
    let field: PhraseFocus
    var focus: FocusState<PhraseFocus?>.Binding
    let commit: (PhraseFocus) -> Void
    @Environment(\.controlActiveState) private var activeState
    func body(content: Content) -> some View {
        content
            .focused(focus, equals: field)
            .onSubmit { commit(field) }
            .onChange(of: focus.wrappedValue == field) { focused, now in if focused, !now { commit(field) } }
            .onChange(of: activeState) { _, state in if state == .inactive, focus.wrappedValue == field { commit(field) } }
            .onDisappear { if focus.wrappedValue == field { commit(field) } }
    }
}

// A repeat for the same action is redundant (grey); a phrase another action already owns is
// ignored for this one (red, with the existing warning icon).
private struct PhraseIssueText: View {
    let issue: PhraseConfiguration.Issue?
    let identifier: String
    var body: some View {
        switch issue {
        case .conflict(let owner):
            Label(Self.text(owner), systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier(identifier)
        case .duplicate(let owner):
            Text(Self.text(owner)).foregroundStyle(.secondary).accessibilityIdentifier(identifier)
        case nil:
            EmptyView()
        }
    }
    // Every section label is a phrase or prefix name, such as "Already an end phrase".
    static func text(_ owner: PhraseSlot) -> String {
        let name = owner.label.lowercased()
        return "Already \("aeiou".contains(name.first ?? " ") ? "an" : "a") \(name)"
    }
}

private struct ExtraPhraseField: View {
    let slot: PhraseSlot
    let number: Int
    @Binding var text: String
    let commit: PhraseCommit
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            // The main row's label space, so the fields line up under it.
            Group {
                Text(slot.label).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "info.circle")
            }
            .hidden().accessibilityHidden(true)
            Spacer(minLength: 8)
            TextField(slot.label, text: $text).labelsHidden()
                .multilineTextAlignment(.trailing).accessibilityLabel("\(slot.label) \(number)")
                .accessibilityIdentifier("\(slot.identifier)\(number)")
                .modifier(commit)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).help("Remove phrase")
                .accessibilityLabel("Remove \(slot.label.lowercased()) \(number)")
                .accessibilityIdentifier("\(slot.identifier)\(number)Remove")
        }.accessibilityElement(children: .contain)
    }
}

// Browser video control needs a connected Agent Flow Bridge. Its phrases and buttons stay visible
// but greyed out until then; the install link below them stays active.
private struct VideoControls: View {
    @ObservedObject var model: GateModel
    @ObservedObject var bridge: VideoBridge
    private var available: Bool { bridge.availability.isAvailable }
    var body: some View {
        PhraseFields(model: model, slots: PhraseSlot.videoSlots)
            .disabled(!available)
        HStack(spacing: 8) {
            Text("Browser video")
            Spacer(minLength: 8)
            Button { model.requestVideo(.pause) } label: { Label("Pause", systemImage: "pause.fill") }
                .accessibilityLabel("Pause browser video").accessibilityIdentifier("pauseVideoButton")
            Button { model.requestVideo(.play) } label: { Label("Play", systemImage: "play.fill") }
                .accessibilityLabel("Play browser video").accessibilityIdentifier("playVideoButton")
        }
        .disabled(!available)
        .help(bridge.availability.detail)
        if let result = model.videoCommandStatus {
            Text(result).foregroundStyle(.secondary).accessibilityIdentifier("videoCommandStatus")
        }
        if !available {
            HStack(spacing: 5) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Link("Install Agent Flow Bridge to use", destination: VideoBridge.installURL)
                    .help(bridge.availability.detail)
                    .accessibilityIdentifier("installAgentFlowBridgeLink")
                Spacer(minLength: 8)
                if bridge.availability == .checking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking Agent Flow Bridge")
                } else {
                    Button { model.refreshVideoBridge() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Check Agent Flow Bridge again")
                        .accessibilityLabel("Check Agent Flow Bridge again")
                        .accessibilityIdentifier("videoBridgeRefreshButton")
                }
            }
        }
    }
}

private struct PhraseField: View {
    let slot: PhraseSlot
    @Binding var text: String
    let similar: Bool
    @Binding var dictionary: [String]?
    let commit: PhraseCommit
    var showsLabel = true
    var showsAdd = true
    let add: () -> Void
    @State private var showingSpellings = false
    private var available: Bool { slot.isDefault(text) }
    var body: some View {
        HStack(spacing: 5) { // Keep the button separate so Accessibility does not merge it into the field label.
            Text(showsLabel ? slot.label : "or").fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(showsLabel ? .primary : .secondary).accessibilityHidden(!showsLabel)
            Button { showingSpellings = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(!available)
                .help(available ? "Recognized spellings" : "Spellings are only available for “\(slot.defaultText)”. Custom phrases match exactly.")
                .accessibilityLabel("\(slot.label) spellings").accessibilityIdentifier(slot.identifier + "Info")
                .popover(isPresented: $showingSpellings) {
                    PhraseSpellings(slot: slot, phrase: text, similar: similar, dictionary: $dictionary)
                }
            Spacer(minLength: 8)
            TextField(slot.label, text: $text).labelsHidden()
                .multilineTextAlignment(.trailing).accessibilityLabel(slot.label).accessibilityIdentifier(slot.identifier)
                .modifier(commit)
            if !available {
                Button { text = slot.defaultText } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).help("Restore default phrase")
                    .accessibilityLabel("Restore default \(slot.label.lowercased())")
                    .accessibilityIdentifier(slot.identifier + "Reset")
            }
            if showsAdd { Button(action: add) { Image(systemName: "plus.circle") }
                .buttonStyle(.plain).help("Add phrase")
                .accessibilityLabel("Add \(slot.label.lowercased())")
                .accessibilityIdentifier(slot.identifier + "Add")
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct PhraseSpellings: View {
    let slot: PhraseSlot
    let phrase: String
    let similar: Bool
    @Binding var dictionary: [String]?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var spellings: [String] = []
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var importing = false
    @State private var loaded = false
    private enum Focus: Hashable { case search, editor }
    @FocusState private var focus: Focus?
    private struct Configuration: Equatable {
        let phrase: String
        let similar: Bool
        let dictionary: [String]?
    }
    private var dictionaries: PhraseDictionaries {
        PhraseDictionaries(dictionary.map { [PhraseMatcher.words(slot.defaultText).joined(): $0] } ?? [:])
    }
    private var matching: [String] {
        let query = PhraseMatcher.words(search).joined()
        return query.isEmpty ? spellings : spellings.filter { PhraseMatcher.words($0).joined().contains(query) }
    }
    var body: some View {
        let visible = matching
        let emptyDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(editing ? "Edit Dictionary" : "Recognized Spellings").font(.headline)
                Spacer()
                if !editing { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            Text(phrase).font(.subheadline)
            Text("Spaces, punctuation and capitalization may differ.").font(.caption).foregroundStyle(.secondary)
            if !similar {
                Text("Alternate spellings are off in Settings. Only the saved phrase is recognized.").font(.callout)
            }
            if editing {
                Text("One full spelling per line. Saving replaces the built-in alternatives. The default phrase always works; leave this blank to use only that phrase.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body.monospaced()).disabled(!similar || !slot.isDefault(phrase))
                    .border(.separator).accessibilityLabel("Custom dictionary")
                    .accessibilityIdentifier("phraseDictionaryEditor").focused($focus, equals: .editor)
                if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Import text file…") { importing = true }
                        .disabled(!similar || !slot.isDefault(phrase)).accessibilityIdentifier("phraseDictionaryImport")
                    Spacer()
                    Button("Cancel") { editing = false; error = nil }.keyboardShortcut(.cancelAction)
                    Button(emptyDraft ? "Use phrase only" : "Save") {
                        do { dictionary = try PhraseDictionary.parse(draft, for: slot); editing = false; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!similar || !slot.isDefault(phrase)).accessibilityIdentifier("phraseDictionarySave")
                }
            } else {
                Text(similar ? (dictionary == nil ? "Built-in dictionary" : "Custom dictionary") : (dictionary == nil ? "Built-in dictionary (off)" : "Saved custom dictionary (off)"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Find a spelling", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("phraseSpellingSearch").focused($focus, equals: .search)
                if !loaded {
                    ProgressView("Loading spellings…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    Text("No spellings found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visible, id: \.self) { Text($0).textSelection(.enabled) }
                        .accessibilityIdentifier("phraseSpellingList")
                }
                Text(loaded ? (visible.count == 1 ? "1 spelling" : "\(visible.count) spellings") : "").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Edit dictionary…") { draft = (dictionary ?? []).joined(separator: "\n"); editing = true; error = nil }
                        .disabled(!similar || !slot.isDefault(phrase)).accessibilityIdentifier("phraseDictionaryEdit")
                    Spacer()
                    if dictionary != nil {
                        Button("Restore built-in") { dictionary = nil; search = "" }
                            .disabled(!similar || !slot.isDefault(phrase)).accessibilityIdentifier("phraseDictionaryRestore")
                    }
                }
            }
        }.padding().frame(width: 420, height: 470)
            .interactiveDismissDisabled(editing)
            .onExitCommand {
                if editing { editing = false; error = nil }
                else { dismiss() }
            }
            .task(id: Configuration(phrase: phrase, similar: similar, dictionary: dictionary)) { // nil means built-in; an empty dictionary means exact-only, so they must have different identities.
                spellings = PhraseMatcher.knownSpellings(for: phrase, similar: similar, ending: slot.ending, dictionaries: dictionaries)
                loaded = true
            }
            .task(id: editing) { focus = editing ? .editor : .search }
            .onChange(of: draft) { error = nil }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
                switch result {
                case .success(let url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { draft = try PhraseDictionary.read(url, for: slot).joined(separator: "\n"); error = nil }
                    catch { self.error = error.localizedDescription }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
    }
}

struct SettingsView: View {
    @ObservedObject var model: GateModel
    @ObservedObject var zoom: InterfaceZoom
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppVersion.display).accessibilityIdentifier("appVersion")
            }
            Section("Automatic Listening") {
                Toggle("Listen automatically when docked", isOn: $model.automaticListening)
                    .accessibilityIdentifier("automaticListening")
                Text("Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. You can turn listening on yourself at any time.")
                    .foregroundStyle(.secondary)
                DockStatus(dock: model.dock)
            }
            Section("Recognition") {
                Button("Phrases and microphone on Home") { openWindow(id: "main") }
                    .accessibilityIdentifier("phraseSettingsHome")
                Toggle("Alternate spellings for default phrases", isOn: $model.similarPhrases)
                    .accessibilityIdentifier("similarPhrases")
                Text(model.similarPhrases ? "Custom phrases match exactly. Use each default phrase’s info button to view or replace its dictionary. Green is exact; orange is an alternate spelling." : "Alternate spellings are off. Saved phrases match exactly, ignoring capitalization, spacing and punctuation.")
                    .foregroundStyle(.secondary)
                if !model.hasPhrase(.wakePhrase) || !model.hasPhrase(.sleepPhrase) {
                    Text("Enter wake and end phrases on Home.").foregroundStyle(.red)
                }
                Button(model.checkingSpeech ? "Checking speech…" : "Check speech recognition") { model.checkSpeech() }
                    .disabled(model.speechCheckUnavailableReason != nil)
                    .accessibilityIdentifier("speechCheck")
                Text(model.speechCheckUnavailableReason ?? "Checks bundled recordings locally. Pauses H Chat listening during the check.")
                    .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: $model.soundEffectsVolume, in: 0...1)
                            .accessibilityLabel("Sound effects volume").accessibilityIdentifier("soundEffectsVolume")
                        Text("\(Int((model.soundEffectsVolume * 100).rounded()))%").monospacedDigit().frame(minWidth: 38)
                    }
                }.disabled(!model.soundEffects)
                // Every phrase has its own sound; preview them to learn which is which.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180 * zoom.scale), alignment: .leading)], alignment: .leading) {
                    ForEach(PhraseSlot.allCases) { slot in
                        Button { model.previewSound(slot.cue) } label: {
                            Text("\(slot.soundTitle) sound")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                            .accessibilityIdentifier("previewSound\(slot.cue.rawValue)")
                    }
                }.disabled(!model.soundEffects)
            }
            Section("Spotify") {
                Toggle("Lower volume during chat", isOn: $model.lowerSpotifyDuringChat)
                    .accessibilityIdentifier("lowerSpotifyDuringChat")
                Text("Lowers Spotify to \(SpotifyVolumePolicy.maximumVolume)% or below, then restores its volume unless changed manually.")
                    .foregroundStyle(.secondary)
                SpotifyVolumeStatus(volume: model.spotifyVolume)
            }
            Section("Transcript Archive") {
                Toggle("Save transcripts", isOn: $model.saveTranscripts).accessibilityIdentifier("saveTranscripts")
                Text("Saves local recognition as JSON with rough phrase timestamps. May include background speech. Audio isn't saved.").foregroundStyle(.secondary)
                Text(TranscriptArchive.directory.path).textSelection(.enabled).accessibilityIdentifier("transcriptArchivePath")
                Text(TranscriptBackupConfiguration.message).foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcriptBackupStatus")
                if let error = model.archiveError { Text(error).foregroundStyle(.red).accessibilityIdentifier("transcriptArchiveError") }
            }
            Section("Updates") {
                if !updater.configured { Text("Updates aren't available in this build.").foregroundStyle(.secondary) }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticChecks }, set: { updater.automaticChecks = $0 }))
                    .disabled(!updater.configured)
                Toggle("Download updates automatically", isOn: Binding(
                    get: { updater.automaticDownloads }, set: { updater.automaticDownloads = $0 }))
                    .disabled(!updater.configured || !updater.automaticChecks)
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

private struct SpotifyVolumeStatus: View {
    @ObservedObject var volume: SpotifyVoiceVolume
    var body: some View {
        if !volume.message.isEmpty { Text(volume.message).foregroundStyle(.secondary) }
        if volume.permissionRequired {
            Button("Allow Spotify control") { volume.requestPermission() }
                .accessibilityIdentifier("allowSpotifyControl")
        }
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
        Button(model.chatActionTitle) { model.toggleChat() }
        .disabled(model.busy && model.status != "Connecting")
        Button("Refresh chat status") { model.refreshVoice() }
            .disabled(model.busy)
        Divider()
        Button("Hello Chat") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Hello Chat") { model.quit() }
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
