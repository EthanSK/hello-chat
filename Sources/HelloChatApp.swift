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
        if arguments == ["--agent-control-v1"] { exit(HControlMailbox.command()) }
        if arguments == ["--preview-notification-replies"] || Bundle.main.object(forInfoDictionaryKey: "HChatNotificationReplyPreview") as? Bool == true {
            MainActor.assumeIsolated { NotificationReplyPreview.run() }; return
        }
        if arguments.count == 2, arguments[0] == "--check-spotify-volume-phrase" {
            let aliases = PhraseList.decode(UserDefaults.standard.object(forKey: PhraseList.defaultsKey))
            let configuration = PhraseConfiguration(rows: Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map {
                ($0, [$0.savedValue()] + (aliases[$0] ?? []))
            }))
            let dictionaries = PhraseDictionaries(savedByTrigger: UserDefaults.standard.object(forKey: "phraseDictionaries") as? [String: [String]] ?? [:], active: configuration)
            let prefixes = configuration.phrases(for: .spotifyVolumePhrase).map {
                PhrasePattern(slot: .spotifyVolumePhrase, text: $0, similar: UserDefaults.standard.object(forKey: "similarPhrases") as? Bool ?? true, dictionaries: dictionaries)
            }
            // The installed parser and saved settings only: no model, capture,
            // Apple Event, receipt, cue or playback action. — GPT-6.1 Sol
            var detector = SpotifyVolumePhrase()
            detector.audio(level: 0.2, seconds: 0.1, at: 0)
            detector.update(arguments[1], at: 1, timings: nil); detector.endUtterance()
            let commands = detector.poll(at: 1, prefixes: prefixes)
            let report: [String: Any] = ["volumes": commands.map(\.volume),
                "repeatEnabled": CommandRepetition.enabled(PhraseSlot.spotifyVolumePhrase.rawValue),
                "title": PhraseSlot.spotifyVolumePhrase.settingsTitle]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
            return
        }
        if arguments.first == "--codex-chat-speed" {
            guard arguments.count == 3, let thread = UUID(uuidString: arguments[1]),
                  arguments[2] == "check" || CodexChatSpeed.Speed.allCases.contains(where: { $0.rawValue.lowercased() == arguments[2] })
            else { print("invalid"); exit(2) }
            let speed = CodexChatSpeed.Speed.allCases.first { $0.rawValue.lowercased() == arguments[2] }
            let result = CodexChatSpeed.perform(thread: thread, speed: speed)
            print(String(decoding: try! JSONEncoder().encode(result), as: UTF8.self))
            exit(["observed", "unchanged", "confirmed"].contains(result.status) ? 0 : 1)
        }
        if arguments.first == "--voice-command-receipt" {
            // The skill supplies the real session and input frame time. Only a live local call can
            // grant an exclusive fallback. A read-only check can still explain an already-ended call.
            guard arguments.count == 9, let thread = UUID(uuidString: arguments[1]),
                  let session = UUID(uuidString: arguments[2]), let frame = UUID(uuidString: arguments[3]),
                  let from = Double(arguments[4]), let through = Double(arguments[5]),
                  ["check", "claim"].contains(arguments[8]) else { print("invalid"); exit(2) }
            let action = arguments[6], supplied = arguments[7]
            let supported = Set(PhraseSlot.allCases.map(\.rawValue) + VoiceAudioAction.allCases.map(\.rawValue) + ["app", "speakerOutput"])
            guard supported.contains(action), supplied.count <= 160,
                  (action == "app" || action == "speakerOutput" || action == PhraseSlot.spotifyVolumePhrase.rawValue) == !supplied.isEmpty else { print("invalid"); exit(2) }
            let target: String
            switch action {
            case "app": target = AppNameSpellings(saved: UserDefaults.standard.object(forKey: AppNameSpellings.defaultsKey)).commandTarget(supplied)
            case "speakerOutput":
                guard let output = SpeakerOutputSettings.load().receiptTarget(supplied) else { print("unknownSpeaker"); return }
                target = output
            case PhraseSlot.spotifyVolumePhrase.rawValue:
                guard let volume = Int(supplied), (0...100).contains(volume) else { print("invalid"); exit(2) }
                target = String(volume)
            default: target = ""
            }
            let callKey = thread.uuidString.lowercased() + ":" + session.uuidString.lowercased()
            let claim = arguments[8] == "claim"
            if claim {
                let current = VoicePeerControl.localStatus()
                guard current.status == .active, current.call?.thread == thread, current.call?.session == session
                else { print("inactiveOrUnknown"); return }
            }
            do {
                print(try SpokenCommandJournal.shared.decide(action: action, target: target, session: callKey,
                    frame: frame, from: from, through: through, allowFallback: claim))
            } catch { print("journalUnavailable"); exit(1) }
            return
        }
        if arguments == ["--browser-rewind-status"] || arguments == ["--browser-custom-rewind-status"] {
            Task { @MainActor in
                let bridge = VideoBridge()
                bridge.probeRewind(custom: arguments == ["--browser-custom-rewind-status"]) { supported in
                    withExtendedLifetime(bridge) { print(supported ? "supported" : "unavailable") }
                    exit(supported ? 0 : 1)
                }
            }
            RunLoop.main.run()
            return
        }
        if arguments.count == 2, arguments[0] == "--browser-video", let requested = VideoCommand(rawValue: arguments[1]) {
            let command = requested.resolved(rewindSeconds: VideoCommand.rewindSeconds())
            Task { @MainActor in
                let bridge = VideoBridge()
                bridge.sendIfAvailable(command) { outcome in
                    withExtendedLifetime(bridge) { print(outcome.diagnostic) }
                    exit(outcome.confirms(command) ? 0 : 1)
                }
            }
            RunLoop.main.run()
            return
        }
        if arguments == ["--show-current-voice"] {
            Task { @MainActor in
                let result = await ShowVoiceCommand.perform()
                print(result.message)
                exit(result.didOpen ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if let receipt = VoicePeerMailbox.command(arguments) {
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
    @StateObject private var zoom: InterfaceZoom
    @StateObject private var updater: AppUpdater
    private let agentControl: HAgentControl
    init() {
        let model = GateModel()
        let zoom = InterfaceZoom()
        let updater = AppUpdater()
        _model = StateObject(wrappedValue: model)
        _zoom = StateObject(wrappedValue: zoom)
        _updater = StateObject(wrappedValue: updater)
        agentControl = HAgentControl(model, zoom: zoom, updater: updater)
        agentControl.start()
        HChatShortcutActions.handler = { [weak model] action in
            guard let model else { throw HChatShortcutError.unavailable }
            return try await model.performShortcut(action)
        }
    }
    var body: some Scene {
        Window("Hello Chat · \(AppVersion.display)", id: "main") {
            MainView(model: model, zoom: zoom, updater: updater)
                .modifier(HControlWindow(control: agentControl))
                .background(InitialWindowPlacement(windowFound: model.phraseWindow.attach))
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
                .modifier(HControlWindow(control: agentControl))
                .background(InitialWindowPlacement())
        }
        .defaultSize(width: 560, height: 660)
        .windowResizability(.contentMinSize)
        MenuBarExtra("Hello Chat", systemImage: model.enabled ? "waveform.circle.fill" : "waveform.circle") {
            MenuView(model: model).modifier(HControlWindow(control: agentControl))
        }
    }
}

private struct HControlWindow: ViewModifier {
    @Environment(\.openWindow) var openWindow
    let control: HAgentControl

    func body(content: Content) -> some View {
        content.onAppear {
            control.openWindow = { id in
                openWindow(id: id); NSApp.activate(ignoringOtherApps: true)
            }
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
                    // One place for command outcomes. The model words each result; this row shows it
                    // as written, with any reason from the command, and links to the history.
                    LastCommandRow(message: model.lastCommandMessage, detail: model.lastCommandDetail) { model.openCommandHistory() }
                } header: {
                    HStack {
                        Text("Live transcription").accessibilityIdentifier("liveTranscriptionTitle")
                        CommandInfoButton(title: "Live transcription", detail: "Shows what H Chat heard on this Mac. Green marks an exact phrase and orange an alternate spelling. A highlight means the phrase was heard. Last command shows what happened next.")
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
                Section("Commands") {
                    Toggle(isOn: Binding(get: { model.listeningToggleOn }, set: { _ in model.toggle() })) {
                        HStack(spacing: 6) {
                            Text("Listening enabled")
                            CommandInfoButton(title: "Listening enabled", detail: "When on, H Chat listens for the phrases below with the command microphone. Speech is recognized on this Mac.")
                        }
                    }.disabled(model.busy && !preparing && !model.enabled)
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
                    // Permission problems stop listening or commands, so they stay beside the toggle.
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
                    // Ethan wants to change the microphone from the home page.
                    // Home owns the only microphone editor; Settings keeps advanced options.
                    MicrophoneSettings(inputs: model.inputs)
                    NativeMeter(meter: model.meter, active: model.detectionRunning)
                    Picker(selection: $model.speechModel) {
                        ForEach(SpeechModel.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Speech model")
                            CommandInfoButton(title: "Speech model", detail: "Turns command microphone audio into text on this Mac. \(model.speechModel.detail)")
                        }
                    }
                    .disabled(model.busy || model.checkingSpeech || model.changingModel)
                    .accessibilityIdentifier("speechModelPicker")
                    // Rows take value snapshots, so live transcript updates don't rebuild every command row.
                    PhraseFields(model: model, configuration: model.phraseConfiguration).equatable()
                    PhraseFields(model: model, configuration: model.phraseConfiguration, slots: PhraseSlot.dotSlots).equatable()
                    VideoControls(model: model, bridge: model.videoBridge, configuration: model.phraseConfiguration,
                                  rewindSeconds: model.rewindVideoSeconds).equatable()
                    PhraseFields(model: model, configuration: model.phraseConfiguration, slots: PhraseSlot.musicSlots).equatable()
                    PhraseFields(model: model, configuration: model.phraseConfiguration, slots: PhraseSlot.desktopSlots).equatable()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Switch speakers")
                                CommandInfoButton(title: "Switch speakers", detail: "Switches Mac audio to a speaker you’ve added. Say a phrase followed by its name. This keeps your microphone and alert output in place.")
                            }
                            let names = model.speakerOutputSettings.destinations.compactMap { SpeakerOutputSettings.lines($0.names).first }
                            Text(names.isEmpty ? "No speakers added" : names.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CommandSettingsButton(title: "Switch speakers") { showingSpeakerOutput = true }
                            .accessibilityIdentifier("speakerOutputSettings")
                    }
                        .sheet(isPresented: $showingSpeakerOutput) {
                            SpeakerOutputEditor(initial: model.speakerOutputSettings, otherPatterns: model.speakerOutputConflictingPhrases, preview: model.previewSound, save: model.saveSpeakerOutputSettings)
                        }
                    // A configuration error, not a command outcome, so it stays beside its command.
                    if let phrase = model.speakerOutputConflict {
                        Label("Switch speakers is off because another command already uses “\(phrase)”.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).accessibilityIdentifier("speakerOutputConflict")
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

// The most recent command outcome, directly under what was heard. The text is shown as the
// model words it; the history opens as a text file with recent outcomes in order.
private struct LastCommandRow: View {
    let message: String?
    let detail: String?
    let openHistory: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last command").font(.caption).foregroundStyle(.secondary)
                Text(message ?? "None yet")
                    .foregroundStyle(message == nil ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("lastCommandMessage")
                if let detail, detail != message {
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("lastCommandDetail")
                }
            }
            Spacer(minLength: 8)
            Button(action: openHistory) { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show command history")
                .help("Opens a list of recent commands and what happened to each")
                .accessibilityIdentifier("commandHistoryButton")
        }
    }
}

// Real loads only. Quick results never flash a spinner; slow ones show it after a short delay.
private struct DelayedProgress: View {
    let label: String
    var showsLabel = false
    @State private var visible = false
    var body: some View {
        Group {
            if showsLabel { ProgressView(label) } else { ProgressView().controlSize(.small) }
        }
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .accessibilityLabel(label)
        .task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            visible = true
        }
    }
}


struct PhraseHighlightPreviewApp: App {
    var body: some Scene {
        Window("Hello Chat · \(AppVersion.display)", id: "phrase-preview") {
            Form {
                Section("Live transcription") {
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
    @State private var soundDraft = "default"
    // Saved with the speakers by Done, like the sound; Cancel leaves the stored choice alone.
    @State private var repeatDraft: Bool
    @State private var spellingPrefix: String?
    @AppStorage("similarPhrases") private var alternateSpellings = true
    @AppStorage(FeedbackSounds.preferenceKey("speakerOutput")) private var savedSound = "default"
    let otherPatterns: [PhrasePattern]
    let save: (SpeakerOutputSettings) -> Bool
    let preview: ((FeedbackSounds.Cue) -> Void)?
    // Validation expands every phrase, spelling and name, so it runs once per draft change rather
    // than on every render. Done stays off until the draft is valid; Cancel always discards it.
    private struct Validation {
        let problem: String?
        let spellings: [String: [String]]
    }
    @State private var validation: Validation
    private var problem: String? { validation.problem }
    @State private var loadingDevices = true
    @State private var hasOutputHelper = true
    init(initial: SpeakerOutputSettings, otherPatterns: [PhrasePattern], preview: ((FeedbackSounds.Cue) -> Void)? = nil, save: @escaping (SpeakerOutputSettings) -> Bool) {
        _draft = State(initialValue: initial); self.otherPatterns = otherPatterns; self.preview = preview; self.save = save
        _validation = State(initialValue: Self.validate(initial, avoiding: otherPatterns))
        _repeatDraft = State(initialValue: CommandRepetition.enabled(RepeatCountToggle.speakerOutput))
    }
    private static func validate(_ settings: SpeakerOutputSettings, avoiding otherPatterns: [PhrasePattern]) -> Validation {
        // The same steps as GateModel.saveSpeakerOutputSettings, so Done is never on for a draft it rejects.
        let effective = settings.cleaned().omittingConflictingBuiltIns(avoiding: otherPatterns)
        let issue = effective.issue ?? effective.conflictingPhrase(with: otherPatterns).map { "Another command already uses “\($0)”." }
        return Validation(problem: issue, spellings: effective.prefixSpellings ?? [:])
    }
    // A speaker still being added isn't a conflict. Show the next step in grey and keep red for real problems.
    private var incomplete: Bool {
        draft.destinations.contains {
            $0.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SpeakerOutputSettings.lines($0.names).isEmpty
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Switch speakers").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Done") { finish() }
                        .disabled(problem != nil)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("speakerOutputSave")
                }
                Text("Say a phrase, then a speaker name, such as “Switch speakers to Kitchen”.")
                    .foregroundStyle(.secondary)
                RepeatCountToggle(command: RepeatCountToggle.speakerOutput, example: "Switch speakers to Kitchen", draft: $repeatDraft)
                if !alternateSpellings { AlternateSpellingsOffNote() }
                if !loadingDevices && !hasOutputHelper {
                    Label("The speaker switching helper is missing.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .accessibilityIdentifier("speakerOutputIssue")
                } else if incomplete {
                    Text("Choose an output and enter a name for each speaker.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("speakerOutputIssue")
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        .accessibilityIdentifier("speakerOutputIssue")
                }
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 4)
            // One scroll container. A Form inside a ScrollView clipped the last speaker and
            // showed field titles as a label column.
            Form {
                Section("Phrases") {
                    SpeakerPhraseRows(text: $draft.prefixes, field: "Phrase", add: "Add phrase") { prefix in
                        let key = PhraseList.key(prefix)
                        if !key.isEmpty {
                            let listed = draft.prefixSpellings?[key] ?? SpeakerOutputSettings.builtInSpellings(for: prefix)
                            let unused = max(0, listed.count - (validation.spellings[key] ?? listed).count)
                            SpellingCountButton(count: listed.count, unused: alternateSpellings ? unused : 0) {
                                spellingPrefix = prefix
                            }
                        }
                    }
                    if SpeakerOutputSettings.lines(draft.prefixes).isEmpty {
                        Text("Add a phrase to use this command.").foregroundStyle(.secondary)
                    } else if draft.cleaned().prefixes != SpeakerOutputSettings.defaultPrefixes {
                        Button("Restore default phrases") { draft.prefixes = SpeakerOutputSettings.defaultPrefixes }
                    }
                }
                ForEach($draft.destinations) { $destination in
                    Section {
                        Picker("Output", selection: $destination.output) {
                            // The list loads in the background. A saved output isn't called
                            // unavailable until loading has finished.
                            Text(loadingDevices ? "Finding outputs…" : devices.isEmpty ? "No outputs found" : "Choose output…").tag("")
                            ForEach(devices, id: \.self) { name in Text(name).tag(name) }
                            if !destination.output.isEmpty && !devices.contains(destination.output) {
                                Text(loadingDevices ? destination.output : destination.output + " (not available)").tag(destination.output)
                            }
                        }.accessibilityLabel("Output device")
                        SpeakerPhraseRows(text: $destination.names, field: "Speaker name", add: "Add name") { _ in
                            EmptyView()
                        }
                    } header: {
                        HStack {
                            Text(SpeakerOutputSettings.lines(destination.names).first ?? "New speaker")
                            Spacer()
                            Button("Remove speaker") { draft.destinations.removeAll { $0.id == destination.id } }
                        }.textCase(nil)
                    }
                }
                Section {
                    if draft.destinations.isEmpty {
                        Text("Add a speaker to use this command.").foregroundStyle(.secondary)
                    }
                    Button("Add speaker") { draft.destinations.append(SpeakerDestination(names: "", output: "")) }
                        .accessibilityIdentifier("speakerOutputAdd")
                } footer: {
                    Text("Lists connected outputs and saved Bluetooth speakers. Choosing one here doesn't switch to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preview {
                    Section {
                        CommandSoundPicker(control: "speakerOutput", title: "Sound", defaultCue: nil, draft: $soundDraft, preview: preview)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 440, idealHeight: 580)
        .onAppear { soundDraft = savedSound }
        .onChange(of: draft) { _, settings in
            validation = Self.validate(settings, avoiding: otherPatterns)
            saveError = nil
        }
        .task {
            let inventory = await Task.detached { (SpeakerOutput.helperInstalled, SpeakerOutput.available()) }.value
            hasOutputHelper = inventory.0
            devices = inventory.1
            loadingDevices = false
        }
        .sheet(isPresented: Binding(get: { spellingPrefix != nil }, set: { if !$0 { spellingPrefix = nil } })) {
            if let prefix = spellingPrefix {
                let key = PhraseList.key(prefix)
                PhraseDictionaryEditor(slot: nil, phrase: prefix, dictionary: Binding(
                    get: { draft.prefixSpellings?[key] }, set: { entries in
                        var spellings = draft.prefixSpellings ?? [:]
                        spellings[key] = entries
                        draft.prefixSpellings = spellings
                    }), builtIn: SpeakerOutputSettings.builtInSpellings(for: prefix), similar: alternateSpellings,
                    validate: { [draft, otherPatterns] entries in
                        var proposed = draft
                        var spellings = proposed.prefixSpellings ?? [:]
                        spellings[key] = entries
                        proposed.prefixSpellings = spellings
                        return Self.validate(proposed, avoiding: otherPatterns).problem
                    })
            }
        }
    }
    private func finish() {
        if save(draft) {
            savedSound = soundDraft
            if repeatDraft != CommandRepetition.enabled(RepeatCountToggle.speakerOutput) {
                CommandRepetition.setEnabled(repeatDraft, command: RepeatCountToggle.speakerOutput)
            }
            dismiss()
        } else {
            // The model rechecks against the current commands, which can change while this is open.
            saveError = "Another command changed while this was open. Cancel, then open Switch speakers again."
        }
    }
}

// The speaker editor keeps its saved newline format. A trailing blank can stay
// in the editor while the user adds a row; only nonempty phrases are recognized.
private struct SpeakerPhraseRows<Accessory: View>: View {
    @Binding var text: String
    let field: String
    let add: String
    @ViewBuilder var accessory: (String) -> Accessory
    @FocusState private var focusedRow: Int?

    var body: some View {
        let rows = text.components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Hidden labels: a grouped Form otherwise repeats the field title beside every row.
                        TextField(field, text: Binding(get: {
                            text.components(separatedBy: .newlines)[safe: index] ?? ""
                        }, set: { value in
                            var lines = text.components(separatedBy: .newlines)
                            guard lines.indices.contains(index) else { return }
                            lines[index] = value
                            text = lines.joined(separator: "\n")
                        }), prompt: Text(field))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .accessibilityLabel(field)
                            .focused($focusedRow, equals: index)
                        Button {
                            var lines = text.components(separatedBy: .newlines)
                            guard lines.indices.contains(index) else { return }
                            lines.remove(at: index)
                            text = lines.joined(separator: "\n")
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove " + field.lowercased())
                    }
                    accessory(rows[index])
                }
            }
            Button(add) {
                text += "\n"
                DispatchQueue.main.async { focusedRow = rows.count }
            }
        }
    }
}

// Refactor of PhraseFields/PhraseField: Ethan’s “one settings panel per command” groups
// every trigger and its spellings while retaining the existing saved rows. — GPT-6.1 Sol
private enum PhraseFocus: Hashable { case main(PhraseSlot), row(UUID) }

private struct CommandInfoButton: View {
    let title: String
    let detail: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("About " + title)
            .accessibilityLabel("About " + title)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }.padding().frame(width: 270, alignment: .leading)
            }
    }
}

private extension PhraseSlot {
    var commandHelp: String {
        switch self {
        case .wakePhrase: return "Starts Codex Voice. If a call is already open, it brings its microphone back on."
        case .sleepPhrase: return "Ends the current Codex Voice call."
        case .mutePhrase: return "Mutes the microphone in the current Codex Voice call."
        case .unmutePhrase: return "Turns the microphone back on in the current Codex Voice call."
        case .silentPhrase, .silencePhrase: return "Mutes the sound coming from the current Codex Voice call. Other Mac audio isn’t changed."
        case .unsilencePhrase: return "Turns sound back on in the current Codex Voice call."
        case .pauseVideoPhrase: return "Pauses the browser video through Agent Flow."
        case .playVideoPhrase: return "Resumes the browser video through Agent Flow."
        case .rewindVideoPhrase, .rewindFivePhrase, .rewindTenPhrase: return "Jumps back in the browser video through Agent Flow. Choose how far in the gear."
        case .pauseMusicPhrase: return "Presses the Mac’s Play/Pause key. If the current media is already paused, it can resume."
        case .playMusicPhrase: return "Presses the Mac’s Play/Pause key. If the current media is already playing, it can pause."
        case .switchAppPhrase, .openAppPhrase: return "Say a phrase followed by an app name. H Chat opens it or brings it forward."
        case .zoomInPhrase: return "Sends Zoom In to the app you’re using."
        case .zoomOutPhrase: return "Sends Zoom Out to the app you’re using."
        case .showVoicePhrase: return "Opens the current Voice chat in Codex, or your last Voice chat if the call has ended."
        case .callDotPhrase: return "Opens Your dot in ChatGPT and starts a call. It won’t start while Codex Voice is active or its status is unknown. A Dot call that’s already active or opening is left alone."
        case .hangUpDotPhrase: return "Ends the Dot call shown in ChatGPT. If Dot call controls aren’t available, it does nothing."
        case .spotifyVolumePhrase: return "Sets Spotify’s volume to the number you say, from 0 to 100. Spotify must already be running. Without a number, it does nothing. Your Maximum volume setting, system volume and playback aren’t changed."
        }
    }
}

private struct CommandSettingsButton: View {
    let title: String
    let open: () -> Void
    var body: some View {
        Button(action: open) { Image(systemName: "gearshape").frame(width: 22, height: 22) }
            .help("Configure " + title).accessibilityLabel("Configure " + title)
    }
}

// Ethan's repeat count for every command, on by default. The key is the pane's first slot (or
// speakerOutput), matching GateModel's repeat lookup. Phrase panes save at once like their rows;
// Switch speakers passes a draft that only its Done saves. One original for the in-app wording;
// README's How It Works repeat row uses the same sentences, and the website derives from README.
private struct RepeatCountToggle: View {
    static let speakerOutput = "speakerOutput"
    static let settingsHelp = "Say how many times after a command, such as “Zoom in three times”. Turn off Repeat count in a command’s gear on Home."
    static let guide: String = {
        guard let url = Bundle.main.url(forResource: "CommandRepetitionHelp", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode([String: String].self, from: data),
              let body = content["body"], let examples = content["examples"] else { return settingsHelp }
        return examples + "\n\n" + body
    }()
    let command: String
    let example: String
    let draft: Binding<Bool>?
    @State private var saved: Bool
    init(command: String, example: String, draft: Binding<Bool>? = nil) {
        self.command = command; self.example = example; self.draft = draft
        _saved = State(initialValue: CommandRepetition.enabled(command))
    }
    // Rewind numbers can be a distance, and every music run is another Play/Pause press.
    private var tooltip: String {
        let first = "Say how many times after the command, such as “\(example) three times”. Up to 100."
        switch command {
        case PhraseSlot.rewindVideoPhrase.rawValue:
            return first + " Always include “times”, since a number alone can be a distance."
        case PhraseSlot.spotifyVolumePhrase.rawValue:
            return first + " Always include “times”, since a number alone is the volume."
        case PhraseSlot.pauseMusicPhrase.rawValue, PhraseSlot.playMusicPhrase.rawValue:
            return first + " Without a number, it runs once. Each run is another Play/Pause press, so an even number can leave playback as it was."
        default:
            return first + " Without a number, it runs once."
        }
    }
    var body: some View {
        Toggle("Repeat count", isOn: draft ?? $saved)
            .toggleStyle(.checkbox)
            .help(tooltip)
            .accessibilityIdentifier(command + "RepeatCount")
            .onChange(of: saved) { _, value in CommandRepetition.setEnabled(value, command: command) }
    }
}

private struct CommandSoundPicker: View {
    let control: String
    let title: String
    let defaultCue: FeedbackSounds.Cue?
    let preview: (FeedbackSounds.Cue) -> Void
    @AppStorage private var choice: String
    let draft: Binding<String>?
    init(control: String, title: String, defaultCue: FeedbackSounds.Cue?, draft: Binding<String>? = nil, preview: @escaping (FeedbackSounds.Cue) -> Void) {
        self.control = control; self.title = title; self.defaultCue = defaultCue; self.preview = preview; self.draft = draft
        _choice = AppStorage(wrappedValue: "default", FeedbackSounds.preferenceKey(control))
    }
    @AppStorage("soundEffects") private var enabled = true
    private var selected: FeedbackSounds.Cue? { FeedbackSounds.selected(draft?.wrappedValue ?? choice, default: defaultCue) }
    var body: some View {
        HStack {
            Picker(title, selection: draft ?? $choice) {
                Text(defaultCue == nil ? "None (default)" : "Default").tag("default")
                if defaultCue != nil { Text("None").tag("off") }
                ForEach(PhraseSlot.allCases) { slot in Text(slot.soundTitle).tag(slot.cue.rawValue) }
                Text("Microphone command heard").tag(FeedbackSounds.Cue.microphoneDetected.rawValue)
            }.accessibilityIdentifier(control + "SoundPicker")
            Button {
                if let selected { preview(selected) }
            } label: { Image(systemName: "play.fill") }
                .disabled(!enabled || selected == nil)
                .accessibilityLabel("Preview " + title).help("Preview sound")
        }
    }
}

// Home rows read value snapshots instead of observing the model. Live transcript updates still
// re-render MainView, but these rows only re-render when their phrases or the rewind amount change.
// Each gear sheet observes the model itself.
private struct PhraseFields: View, Equatable {
    let model: GateModel
    let configuration: PhraseConfiguration
    let slots: [PhraseSlot]
    let rewindSeconds: Int
    @State private var selected: PhraseSlot? = nil
    init(model: GateModel, configuration: PhraseConfiguration, slots: [PhraseSlot] = PhraseSlot.voiceSlots, rewindSeconds: Int = 10) {
        self.model = model; self.configuration = configuration; self.slots = slots; self.rewindSeconds = rewindSeconds
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.slots == rhs.slots && lhs.rewindSeconds == rhs.rewindSeconds
    }
    // The rewind amount appears once, in this explanation, rather than as a second caption line.
    private func help(for slot: PhraseSlot) -> String {
        guard slot.isRewind else { return slot.commandHelp }
        let amount = rewindSeconds == 1 ? "1 second" : "\(rewindSeconds) seconds"
        return "Jumps back \(amount) in the browser video through Agent Flow. Change the amount in the gear. Phrases that say 5 or 10 seconds always use that amount."
    }
    var body: some View {
        ForEach(PhraseSlot.settingsGroups(slots), id: \.first) { group in
            if let slot = group.first {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(slot.settingsTitle)
                            CommandInfoButton(title: slot.settingsTitle, detail: help(for: slot))
                        }
                        let phrases = (slot.isRewind ? [.rewindVideoPhrase] : group).flatMap { configuration.phrases(for: $0) }
                        let actionTitle = slot.settingsTitle.components(separatedBy: " (").first ?? slot.settingsTitle
                        if phrases.count != 1 || PhraseList.key(phrases[0]) != PhraseList.key(actionTitle) {
                            Text(phrases.isEmpty ? "No phrases" : phrases.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    CommandSettingsButton(title: slot.settingsTitle) { selected = slot }
                        .accessibilityIdentifier(slot.identifier + "Settings")
                }
            }
        }
        .sheet(item: $selected) { slot in
            CommandPhrasesView(model: model, slots: PhraseSlot.settingsGroups(slots).first { $0.first == slot } ?? [slot])
        }
    }
}

// Refactor of the existing phrase-row editor. All changes still use GateModel’s
// main keys, extra rows, validation and slash-entry commit path. — GPT-6.1 Sol
private struct CommandPhrasesView: View {
    @ObservedObject var model: GateModel
    let slots: [PhraseSlot]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: PhraseFocus?
    @State private var showingAppSpellings = false
    @State private var showingSound = false
    @State private var addedRow: UUID?
    @State private var showingExplicitRewinds = false
    // Rewind is one configurable action. The existing 5- and 10-second phrases stay editable
    // below it with their own sounds, but they aren't a second way to choose an amount.
    private var listedSlots: [PhraseSlot] { slots.filter { !$0.isRewind || $0 == .rewindVideoPhrase } }
    private var explicitRewinds: [PhraseSlot] { slots.filter { $0 == .rewindFivePhrase || $0 == .rewindTenPhrase } }
    // The app cue follows the phrase's first word; new rows with any other verb join Open.
    private func soundTitle(_ slot: PhraseSlot) -> String {
        switch slot {
        case .switchAppPhrase: return "Switch phrases"
        case .openAppPhrase: return "Open, Show and other phrases"
        default: return slot.soundTitle
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(slots.first?.settingsTitle ?? "Phrases").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                // Rows save as you type, so Done only closes. Escape does the same.
                Button("Done") { commitFocused(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                if let first = slots.first, !first.isRewind {
                    // Switch and Open rows form one list. New rows join Open, whose short form
                    // and fallback suit any verb, such as “Launch app”.
                    Button("Add phrase") { add(to: first == .switchAppPhrase ? .openAppPhrase : first) }
                        .accessibilityIdentifier(first.identifier + "Add")
                }
                if slots.contains(.switchAppPhrase) {
                    Button("App spellings…") { showingAppSpellings = true }
                        .accessibilityIdentifier("appSpellingsButton")
                }
                Button("Sound…") { showingSound = true }
                    .accessibilityIdentifier("configureCommandSound")
                    .popover(isPresented: $showingSound) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(listedSlots) { slot in
                                CommandSoundPicker(control: slot.cue.rawValue, title: listedSlots.count == 1 ? "Sound" : soundTitle(slot),
                                                   defaultCue: slot.cue, preview: model.previewSound)
                            }
                            if slots.contains(.mutePhrase) || slots.contains(.unmutePhrase) {
                                CommandSoundPicker(control: FeedbackSounds.Cue.microphoneDetected.rawValue, title: "Microphone command heard",
                                                   defaultCue: .microphoneDetected, preview: model.previewSound)
                            }
                        }.padding().frame(minWidth: 300)
                    }
            }
            if let first = slots.first {
                RepeatCountToggle(command: first.rawValue, example: repeatExample(first))
            }
            if !model.similarPhrases { AlternateSpellingsOffNote() }
            if slots.contains(.rewindVideoPhrase) {
                RewindAmountField(seconds: $model.rewindVideoSeconds)
            }
            if let slot = slots.first(where: { $0 == .switchAppPhrase || $0 == .spotifyVolumePhrase }), let example = slot.example {
                Text(example).font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(listedSlots) { phraseRows(for: $0) }
                        if !explicitRewinds.isEmpty {
                            let count = explicitRewinds.reduce(0) { $0 + model.phraseConfiguration.phrases(for: $1).count }
                            DisclosureGroup("Phrases that say how far (\(count))", isExpanded: $showingExplicitRewinds) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(explicitRewinds) { slot in
                                        HStack {
                                            Text(slot == .rewindFivePhrase ? "5 seconds" : "10 seconds").font(.headline)
                                            Spacer()
                                            CommandSoundPicker(control: slot.cue.rawValue, title: "Sound", defaultCue: slot.cue,
                                                               preview: model.previewSound)
                                                .fixedSize()
                                        }
                                        phraseRows(for: slot)
                                    }
                                }.padding(.top, 8)
                            }.accessibilityIdentifier("explicitRewindPhrases")
                        }
                    }.padding(2)
                }.onChange(of: addedRow) { _, id in
                    if let id {
                        reader.scrollTo(id, anchor: .center)
                        focus = .row(id)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 440, idealWidth: 570, maxWidth: 640, minHeight: 360, idealHeight: 560, maxHeight: 640)
        .sheet(isPresented: $showingAppSpellings) { AppSpellingsView(model: model) }
    }
    private func phraseRows(for slot: PhraseSlot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            editor(slot, id: nil, number: 1, current: model[keyPath: model.phraseKeyPath(for: slot)],
                   text: Binding(get: { model[keyPath: model.phraseKeyPath(for: slot)] },
                                 set: { model.renamePhrase(slot, id: nil, old: model[keyPath: model.phraseKeyPath(for: slot)], new: $0) }))
            ForEach(Array((model.phraseAliases[slot] ?? []).enumerated()), id: \.element.id) { index, row in
                editor(slot, id: row.id, number: index + 2, current: row.text,
                       text: Binding(get: { model.phraseAliases[slot]?.first { $0.id == row.id }?.text ?? "" },
                                     set: { model.renamePhrase(slot, id: row.id, old: model.phraseAliases[slot]?.first { $0.id == row.id }?.text ?? "", new: $0) }))
                    .id(row.id)
            }
        }
    }
    // Each row receives value snapshots, so a transcript update while this sheet is open
    // doesn't recompute every row's spellings.
    private func editor(_ slot: PhraseSlot, id: UUID?, number: Int, current: String, text: Binding<String>) -> some View {
        let field: PhraseFocus = id.map { PhraseFocus.row($0) } ?? .main(slot)
        return TriggerPhraseEditor(model: model, slot: slot, value: current, text: text,
                                   commit: PhraseCommit(field: field, focus: $focus, commit: commit),
                                   id: id, number: number, issue: model.phraseIssue(slot, id: id),
                                   saved: model.phraseDictionaries[slot.spellingKey(for: current)],
                                   similar: model.similarPhrases, dictionaries: model.matchingDictionaries)
            .equatable()
    }
    // The tooltip's example uses the current main phrase; Switch app needs an app name after it.
    private func repeatExample(_ slot: PhraseSlot) -> String {
        let phrase = model[keyPath: model.phraseKeyPath(for: slot)].trimmingCharacters(in: .whitespacesAndNewlines)
        let main = phrase.isEmpty ? slot.defaultText : phrase
        if slot == .switchAppPhrase { return main + " Chrome" }
        if slot == .spotifyVolumePhrase { return main + " forty percent" }
        return main
    }
    private func add(to slot: PhraseSlot) {
        commitFocused()
        addedRow = model.addPhraseRow(slot)
    }
    private func commitFocused() { if let field = focus { commit(field) } }
    private func commit(_ field: PhraseFocus) {
        switch field {
        case .main(let slot): model.commitPhraseRow(slot, id: nil)
        case .row(let id): if let slot = model.phraseSlot(containing: id) { model.commitPhraseRow(slot, id: id) }
        }
    }
}

// The one rewind amount. Type a duration or step one second at a time. Values are kept
// within the range Agent Flow accepts.
private struct RewindAmountField: View {
    @Binding var seconds: Int
    var body: some View {
        let range = VideoCommand.durationRange
        let value = $seconds.changes(in: range)
        HStack(spacing: 6) {
            Text("Rewind by")
            TextField("Seconds", value: value, format: .number)
                .labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: 64)
                .accessibilityLabel("Rewind seconds").accessibilityIdentifier("rewindVideoSeconds")
            Stepper("Rewind seconds", value: value, in: range)
                .labelsHidden()
            Text(seconds == 1 ? "second" : "seconds")
        }
    }
}

// One editor within App prefixes. The native app catalog supplies choices; GateModel owns the
// saved configuration shared by Switch and Open. Editing never opens an app. — GPT-6.1 Sol
private struct AppSpellingsView: View {
    // Reads only the app spellings, so the long app list isn't rebuilt on every transcript update.
    let model: GateModel
    @State private var names: AppNameSpellings
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [AppCandidate] = []
    @State private var loaded = false
    @State private var selectedID: String? = nil
    @State private var search = ""
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    init(model: GateModel) {
        self.model = model
        _names = State(initialValue: model.appNameSpellings)
    }
    private var selected: AppCandidate? { apps.first { $0.id == selectedID } }
    private var filtered: [AppCandidate] {
        let key = AppResolver.key(search)
        return key.isEmpty ? apps : apps.filter { $0.names.contains { AppResolver.key($0).contains(key) } }
    }
    private var validation: String? {
        do {
            let values = try AppNameSpellings.parse(draft)
            guard let selected else { return nil }
            let conflicts = names.conflicts(values, for: selected.id, among: apps)
            return conflicts.isEmpty ? nil : "Already used by \(conflicts.joined(separator: ", "))."
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App spellings").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.disabled(editing)
                    .accessibilityIdentifier("appSpellingsClose")
            }
            Text("Other names H Chat accepts for each app, for every app phrase. App names always work.")
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
                        if !loaded { DelayedProgress(label: "Loading apps…", showsLabel: true) }
                        else { Text(filtered.isEmpty ? "No apps found" : "Select an app").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(16).frame(minWidth: 570, idealWidth: 600, minHeight: 440, idealHeight: 480)
            .interactiveDismissDisabled(editing)
            .onExitCommand { if editing { editing = false } else { dismiss() } }
            .onReceive(model.$appNameSpellings) { names = $0 }
            .task {
                apps = await model.appSpellingChoices()
                selectedID = apps.first { !names.spellings(for: $0.id).isEmpty }?.id ?? apps.first?.id
                loaded = true
            }
    }
    @ViewBuilder private func spellingDetail(_ app: AppCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.displayName).font(.headline).accessibilityIdentifier("appSpellingSelection")
            if editing {
                Text("One per line. Leave empty to use app names only.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body.monospaced()).border(.separator)
                    .accessibilityLabel("App spellings").accessibilityIdentifier("appSpellingEditor")
                    .focused($editorFocused)
                if let validation { Text(validation).font(.caption).foregroundStyle(.red).accessibilityIdentifier("appSpellingError") }
                // An edit inside the sheet uses Save; Done closes the sheet.
                HStack {
                    Button("Cancel") { editing = false }.accessibilityIdentifier("appSpellingCancel")
                    Spacer()
                    Button("Save") {
                        guard let values = try? AppNameSpellings.parse(draft), validation == nil else { return }
                        model.appNameSpellings.overrides[app.id] = values
                        editing = false
                    }.disabled(validation != nil).accessibilityIdentifier("appSpellingSave")
                }
            } else {
                let values = names.spellings(for: app.id)
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
                    if names.overrides[app.id] != nil {
                        Button("Restore built-in spellings") { model.appNameSpellings.overrides[app.id] = nil }
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

// Editing phrases is always available. Video commands need a live Agent Flow connection, so
// the connection notice appears only while it's missing. Outcomes go to Last command.
private struct VideoControls: View, Equatable {
    let model: GateModel
    @ObservedObject var bridge: VideoBridge
    let configuration: PhraseConfiguration
    let rewindSeconds: Int
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration && lhs.rewindSeconds == rhs.rewindSeconds
    }
    private var available: Bool { bridge.availability.isAvailable }
    var body: some View {
        PhraseFields(model: model, configuration: configuration, slots: PhraseSlot.videoSlots, rewindSeconds: rewindSeconds).equatable()
        if !available {
            HStack(spacing: 5) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Link(bridge.availability == .unavailable(.incompatible) ? "Update Agent Flow for video commands" : "Connect Agent Flow for video commands",
                     destination: VideoBridge.installURL)
                    .help(bridge.availability.detail)
                    .accessibilityIdentifier("installAgentFlowBridgeLink")
                Spacer(minLength: 8)
                if bridge.availability == .checking {
                    DelayedProgress(label: "Checking Agent Flow")
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

struct SpellingCountButton: View {
    let count: Int
    let unused: Int
    var identifier: String? = nil
    let edit: () -> Void

    private var title: String {
        switch count {
        case 0: return "Add alternate spellings…"
        case 1: return "1 alternate spelling…"
        default: return "\(count) alternate spellings…"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(title, action: edit)
                .help("Edit alternate spellings for this phrase")
                .accessibilityIdentifier(identifier ?? "speakerPrefixSpellings")
            if unused > 0 {
                Text("\(unused) not used").foregroundStyle(.secondary)
                    .help("These spellings aren’t used by this phrase.")
            }
        }.font(.caption)
    }
}

private struct AlternateSpellingsOffNote: View {
    var body: some View {
        Text("Alternate spellings are off in Settings.").font(.caption).foregroundStyle(.secondary)
    }
}

// One phrase and its alternate spellings. The count and the editor use one list: this trigger's
// saved spellings, or its built-in ones when none are saved. The list opens in the editor, so the
// row doesn't repeat it. Entries recognition can't use right now are counted as unused.
private struct TriggerPhraseEditor: View, Equatable {
    let model: GateModel
    let slot: PhraseSlot
    let value: String // Snapshot of the text, for comparison; a Binding reads the live value.
    @Binding var text: String
    let commit: PhraseCommit
    let id: UUID?
    let number: Int
    let issue: PhraseConfiguration.Issue?
    let saved: [String]?
    let similar: Bool
    let dictionaries: PhraseDictionaries
    @State private var showingDictionary = false
    init(model: GateModel, slot: PhraseSlot, value: String, text: Binding<String>, commit: PhraseCommit, id: UUID?, number: Int,
         issue: PhraseConfiguration.Issue?, saved: [String]?, similar: Bool, dictionaries: PhraseDictionaries) {
        self.model = model; self.slot = slot; self.value = value; _text = text; self.commit = commit; self.id = id
        self.number = number; self.issue = issue; self.saved = saved; self.similar = similar; self.dictionaries = dictionaries
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.slot == rhs.slot && lhs.value == rhs.value && lhs.id == rhs.id && lhs.number == rhs.number && lhs.issue == rhs.issue
            && lhs.saved == rhs.saved && lhs.similar == rhs.similar && lhs.dictionaries == rhs.dictionaries
    }
    private var builtIn: [String] { slot.stockSpellings(for: value) }
    private var identifier: String { slot.identifier + (id == nil ? "" : String(number)) }
    private var listed: [String] { saved ?? builtIn }
    private var unused: Int {
        guard similar, !listed.isEmpty else { return 0 }
        let pattern = PhrasePattern(slot: slot, text: value, similar: similar, dictionaries: dictionaries)
        let recognized = Set(PhraseMatcher.knownSpellings(for: value, similar: pattern.similar, ending: slot.ending,
                                                         dictionaries: pattern.dictionaries).dropFirst().map(PhraseList.key))
        return listed.filter { !recognized.contains(PhraseList.key($0)) }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Phrase", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(slot.label) \(number)").accessibilityIdentifier(identifier)
                    .modifier(commit)
                if let id {
                    Button("Remove") { model.removePhraseRow(slot, id: id) }
                        .accessibilityIdentifier(identifier + "Remove")
                } else if !slot.isDefault(value) {
                    Button("Restore default") { text = slot.defaultText }
                        .accessibilityIdentifier(identifier + "Reset")
                }
            }
            PhraseIssueText(issue: issue, identifier: identifier + "Issue")
            if !PhraseMatcher.words(value).isEmpty {
                SpellingCountButton(count: listed.count, unused: unused, identifier: identifier + "EditSpellings") {
                    showingDictionary = true
                }
            }
        }
        .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showingDictionary) {
            PhraseDictionaryEditor(slot: slot, phrase: value, dictionary: Binding(
                get: { model.phraseDictionaries[slot.spellingKey(for: value)] },
                set: { model.phraseDictionaries[slot.spellingKey(for: value)] = $0 }),
                builtIn: builtIn, similar: similar,
                validate: { model.spellingConflict($0, for: slot, phrase: value) })
        }
    }
}

// Refactor of PhraseSpellings’ existing dictionary editor. The owning command panel
// now displays the recognized forms; this sheet only edits that trigger’s dictionary. — GPT-6.1 Sol
struct PhraseDictionaryEditor: View {
    let slot: PhraseSlot?
    let phrase: String
    @Binding var dictionary: [String]?
    let builtIn: [String]
    let similar: Bool
    let validate: ([String]) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error: String?
    @State private var importing = false
    // Same finish as the other draft editors: Cancel discards, Done saves a valid list and closes.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alternate spellings").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("For “\(phrase)”").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { finish() }.accessibilityIdentifier("phraseDictionarySave")
            }
            Text("One per line. Leave empty to use only the phrase.")
                .font(.caption).foregroundStyle(.secondary)
            if !similar {
                Label("Recognize alternate spellings is off in Settings, so these aren't used.", systemImage: "info.circle")
                    .font(.caption)
            }
            TextEditor(text: $draft).font(.body.monospaced()).border(.separator)
                .accessibilityLabel("Alternate spellings").accessibilityIdentifier("phraseDictionaryEditor")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            HStack {
                Button("Import text file…") { importing = true }.accessibilityIdentifier("phraseDictionaryImport")
                if dictionary != nil && !builtIn.isEmpty {
                    Button("Restore built-in spellings") { dictionary = nil; dismiss() }
                        .accessibilityIdentifier("phraseDictionaryRestore")
                }
                Spacer()
            }
        }
        .padding(20).frame(minWidth: 520, idealWidth: 540, minHeight: 420, idealHeight: 460).interactiveDismissDisabled()
        .onAppear { draft = (dictionary ?? builtIn).joined(separator: "\n") }
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
    private func finish() {
        do {
            let entries = try PhraseDictionary.parse(draft, for: slot)
            if let issue = validate(entries) { error = issue; return }
            let keys = entries.map(PhraseList.key)
            // Store nothing when the list matches the built-in one, so later built-in updates
            // still apply. An empty list with no built-ins also needs no saved entry.
            if keys == builtIn.map(PhraseList.key) || (entries.isEmpty && builtIn.isEmpty) {
                if dictionary != nil { dictionary = nil }
            } else {
                dictionary = entries
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @AppStorage(CodexVoiceSpeed.preferenceKey) private var ultrafastForNewVoiceChats = true
    @ObservedObject var model: GateModel
    @ObservedObject var zoom: InterfaceZoom
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    // This button's own progress and result. model.busy also covers other actions, and the
    // model's error otherwise shows only on Home.
    @State private var settingUltrafast = false
    @State private var ultrafastResult: (message: String, failed: Bool)?
    @State private var showRepeatHelp = false
    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppVersion.display).accessibilityIdentifier("appVersion")
            }
            Section("Voice chats") {
                Button(settingUltrafast ? "Setting Ultrafast…" : "Set Voice to Ultrafast") { setUltrafast() }
                    .disabled(model.busy || settingUltrafast).accessibilityIdentifier("setVoiceUltrafast")
                if let ultrafastResult {
                    Text(ultrafastResult.message).foregroundStyle(ultrafastResult.failed ? Color.red : Color.secondary)
                        .textSelection(.enabled).accessibilityIdentifier("setVoiceUltrafastResult")
                }
                Toggle("Prepare GPT-6.2 Sol, High and Ultrafast", isOn: $ultrafastForNewVoiceChats)
                    .accessibilityIdentifier("ultrafastForNewVoiceChats")
                Text("H Chat restores your previous defaults after Voice opens. If Codex is already running, it can use the choices saved in its window.")
                    .foregroundStyle(.secondary)
            }
            NotificationReplySettingsSection(settings: model.notificationReplies.settings,
                replySpellings: Binding(get: { model.phraseDictionaries[NotificationReplyCore.Commands.replySpellingKey] },
                    set: { model.phraseDictionaries[NotificationReplyCore.Commands.replySpellingKey] = $0 }),
                endReplySpellings: Binding(get: { model.phraseDictionaries[NotificationReplyCore.Commands.endReplySpellingKey] },
                    set: { model.phraseDictionaries[NotificationReplyCore.Commands.endReplySpellingKey] = $0 }),
                similar: model.similarPhrases, readiness: { model.notificationReplies.readiness })
            Section("Automatic Listening") {
                Toggle("Listen automatically when docked", isOn: $model.automaticListening)
                    .accessibilityIdentifier("automaticListening")
                Text("Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. You can turn listening on yourself at any time.")
                    .foregroundStyle(.secondary)
                DockStatus(dock: model.dock)
            }
            // Home owns phrases, spellings, the microphone and each command's sound. Settings keeps
            // only app-wide choices, with one way back to Home.
            Section("Recognition") {
                Toggle("Recognize alternate spellings", isOn: $model.similarPhrases)
                    .accessibilityIdentifier("similarPhrases")
                Text(model.similarPhrases ? "Also matches each phrase’s alternate spellings." : "Phrases must match exactly. Capitalization, spaces and punctuation can differ.")
                    .foregroundStyle(.secondary)
                if !model.hasPhrase(.wakePhrase) || !model.hasPhrase(.sleepPhrase) {
                    Label("Add a wake phrase and an end phrase on Home.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                HStack(alignment: .top) {
                    Text(RepeatCountToggle.settingsHelp).foregroundStyle(.secondary)
                    Button { showRepeatHelp = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("About Repeat count")
                        .popover(isPresented: $showRepeatHelp) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Repeat count").font(.headline)
                                Text(RepeatCountToggle.guide).textSelection(.enabled)
                            }.padding().frame(width: 350)
                        }
                }.accessibilityIdentifier("repeatCountHelp")
                Button("Edit phrases on Home") { openWindow(id: "main") }
                    .accessibilityIdentifier("phraseSettingsHome")
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
                Text("Choose each command’s sound from its gear on Home.").foregroundStyle(.secondary)
            }
            Section("Spotify") {
                let limit = $model.spotifyVolumeLimit.changes(in: 0...100)
                Toggle("Lower volume during chat", isOn: $model.lowerSpotifyDuringChat)
                    .accessibilityIdentifier("lowerSpotifyDuringChat")
                HStack {
                    Text("Maximum volume")
                    Spacer()
                    TextField("Percent", value: limit, format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 48)
                        .accessibilityLabel("Spotify maximum volume percent").accessibilityIdentifier("spotifyVolumeLimit")
                    Text("%")
                    Stepper("Maximum volume", value: limit, in: 0...100).labelsHidden()
                }
                Text("Keeps Spotify at or below this volume during Voice. Restores the previous volume afterwards unless you changed the volume.")
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
                Toggle("Bring Home forward when a phrase is heard", isOn: $model.bringHomeForward)
                    .accessibilityIdentifier("bringHomeForward")
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
    // Same action as the menu and Shortcuts; only the shown result differs. Result messages come
    // from GateModel and CodexChatSpeed, so Settings adds no second wording for them.
    private func setUltrafast() {
        settingUltrafast = true
        ultrafastResult = nil
        Task { @MainActor in
            defer { settingUltrafast = false }
            do {
                let message = try await model.performShortcut(.ultrafast)
                ultrafastResult = (message, false)
            } catch is CancellationError {
            } catch {
                ultrafastResult = (error.localizedDescription, true)
            }
        }
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
    @State private var showingRecent = false
    var body: some View {
        Text("Timing and error logs exclude recognized words. Saved transcripts are in Transcript Archive. Audio isn't saved.").foregroundStyle(.secondary)
        Button("Show logs in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.directory.appendingPathComponent("events.jsonl")])
        }.accessibilityIdentifier("showDiagnosticLogs")
        DisclosureGroup("Recent events", isExpanded: $showingRecent) {
            Text(recent.isEmpty ? "No events yet" : recent).fontDesign(.monospaced).textSelection(.enabled)
                .accessibilityIdentifier("diagnosticEvents")
        }
        // Read the log only while it's shown.
        .task(id: showingRecent) {
            while showingRecent, !Task.isCancelled {
                recent = Diagnostics.shared.tail()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

// The resolved device is shown in the menu itself, so there's no separate “Using” line.
struct MicrophoneSettings: View {
    @ObservedObject var inputs: MicrophoneInputs
    var body: some View {
        let systemName = inputs.devices.first { $0.id == inputs.systemDefault }?.name
        Picker(selection: $inputs.selectedUID) {
            Text(systemName.map { "System default (\($0))" } ?? "System default").tag("")
            ForEach(inputs.devices) { input in Text(input.name).tag(input.uid) }
            if !inputs.selectedUID.isEmpty && inputs.selected == nil {
                Text("Selected microphone isn't connected").tag(inputs.selectedUID)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Command microphone")
                CommandInfoButton(title: "Command microphone", detail: "Choose the microphone H Chat uses to hear phrases. Choose the call microphone in Codex Voice.")
            }
        }
        .accessibilityIdentifier("microphonePicker")
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
        Button("Set Voice to Ultrafast") { Task { _ = try? await model.performShortcut(.ultrafast) } }
            .disabled(model.busy)
        Divider()
        Button("Hello Chat") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        // The history opens in the default text editor, so H Chat doesn't take focus back.
        Button("Show Command History") { model.openCommandHistory() }
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Hello Chat") { model.quit() }
    }
}

// Initial placement only. Native resizing, window zoom and user placement are
// left to macOS; scrolling handles content larger than the chosen window.
struct InitialWindowPlacement: NSViewRepresentable {
    var windowFound: ((NSWindow) -> Void)? = nil
    final class Host: NSView {
        var windowFound: ((NSWindow) -> Void)?
        private var placed = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { windowFound?(window) }
            guard let window, !placed, let screen = WindowDisplay.preferredScreen else { return }
            placed = true
            DispatchQueue.main.async {
                let bounds = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.1, dy: screen.visibleFrame.height * 0.1)
                let size = NSSize(width: min(window.frame.width, bounds.width), height: min(window.frame.height, bounds.height))
                window.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
        }
    }
    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.windowFound = windowFound
        return host
    }
    func updateNSView(_ nsView: Host, context: Context) {
        nsView.windowFound = windowFound
        if let window = nsView.window { windowFound?(window) }
    }
}
