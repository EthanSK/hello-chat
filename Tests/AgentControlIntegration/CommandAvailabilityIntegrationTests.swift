// Actual model/store/editor ownership, with no recognition capture or native actions. — GPT-6.1 Sol
import AppKit
import Foundation
import XCTest
import SwiftUI
@testable import HelloChat

@MainActor final class CommandAvailabilityIntegrationTests: XCTestCase {
    private func isolatedHome() throws {
        guard let expected = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              expected == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: expected + "/control-fixture-owner")
        else { throw XCTSkip("Run scripts/test-control-integration.sh with its isolated home.") }
    }
    func testAllCommandsStopMatchingAndKeepTheirSavedSettings() async throws {
        try isolatedHome()
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: CommandAvailability.preferenceKey)
        defer { defaults.set(original, forKey: CommandAvailability.preferenceKey) }
        defaults.removeObject(forKey: CommandAvailability.preferenceKey)
        let model = GateModel(enableSpotifyControl: false)
        let configuration = model.phraseConfiguration
        let dictionaries = model.phraseDictionaries
        let speaker = model.speakerOutputSettings
        let initialPatterns = Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map { ($0, model.patterns(for: $0).map(\.text)) })
        let otherSettings = defaults.dictionaryRepresentation().filter { $0.key != CommandAvailability.preferenceKey }
        for command in HomeCommand.all {
            model.setCommandEnabled(false, command: command)
            XCTAssertTrue(model.disabledCommands.contains(command))
            XCTAssertFalse(model.isCommandListed(command, on: .home))
            for slot in command.slots {
                XCTAssertTrue(model.patterns(for: slot).isEmpty, slot.rawValue)
                XCTAssertNil(model.reserveSpeech(slot.rawValue, range: 0..<1, repeatAction: { _ in XCTFail("Disabled commands cannot dispatch") }))
            }
        }
        XCTAssertTrue(model.phrasePatterns.isEmpty)
        XCTAssertTrue(model.controlPhrases.isEmpty)
        XCTAssertNil(model.reserveSpeech("speakerOutput", range: 0..<1, repeatAction: { _ in XCTFail() }))
        XCTAssertEqual(model.phraseConfiguration, configuration, "Disabled commands retain phrase ownership and conflict validation")
        XCTAssertEqual(model.phraseDictionaries, dictionaries)
        XCTAssertEqual(model.speakerOutputSettings, speaker)
        let restarted = GateModel(enableSpotifyControl: false)
        XCTAssertEqual(restarted.disabledCommands, HomeCommand.all)
        for command in HomeCommand.all { model.setCommandEnabled(true, command: command) }
        XCTAssertTrue(model.disabledCommands.isEmpty)
        for slot in PhraseSlot.allCases { XCTAssertEqual(model.patterns(for: slot).map(\.text), initialPatterns[slot]) }
        XCTAssertEqual(defaults.dictionaryRepresentation().filter { $0.key != CommandAvailability.preferenceKey } as NSDictionary, otherSettings as NSDictionary,
            "Switches do not rewrite phrases, spellings, repeat settings, cues, values, model or microphone")
        await model.notificationReplies.shutdown(); await restarted.notificationReplies.shutdown()
    }
    func testOneEditorKeepsItsRowUntilDoneAndSettingsUsesSameGroup() async throws {
        try isolatedHome()
        let original = UserDefaults.standard.object(forKey: CommandAvailability.preferenceKey)
        defer { UserDefaults.standard.set(original, forKey: CommandAvailability.preferenceKey) }
        UserDefaults.standard.removeObject(forKey: CommandAvailability.preferenceKey)
        let model = GateModel(enableSpotifyControl: false)
        let command = try XCTUnwrap(HomeCommand.containing(.zoomInPhrase))
        model.openCommandSettings(command, from: .home)
        model.setCommandEnabled(false, command: command)
        XCTAssertTrue(model.isCommandListed(command, on: .home), "Hiding a row cannot destroy its sheet")
        XCTAssertFalse(model.disabledCommands.contains(command))
        model.openCommandSettings(.speakerOutput, from: .settings)
        XCTAssertEqual(model.commandEditor?.command, command, "The other window cannot open a concurrent editor")
        model.closeCommandSettings(from: .settings)
        XCTAssertEqual(model.commandEditor?.origin, .home)
        model.closeCommandSettings(from: .home)
        XCTAssertFalse(model.isCommandListed(command, on: .home)); XCTAssertTrue(model.disabledCommands.contains(command))
        model.openCommandSettings(command, from: .settings)
        model.setCommandEnabled(true, command: command)
        XCTAssertTrue(model.disabledCommands.contains(command), "Re-enabling also keeps the open editor stable")
        model.closeCommandSettings(from: .settings)
        XCTAssertTrue(model.isCommandListed(command, on: .home)); XCTAssertTrue(model.disabledCommands.isEmpty)
        await model.notificationReplies.shutdown()
    }
    func testReadbackAndRevisionUseTheSameAvailabilityStore() async throws {
        try isolatedHome()
        let original = UserDefaults.standard.object(forKey: CommandAvailability.preferenceKey)
        defer { UserDefaults.standard.set(original, forKey: CommandAvailability.preferenceKey) }
        UserDefaults.standard.removeObject(forKey: CommandAvailability.preferenceKey)
        let model = GateModel(enableSpotifyControl: false)
        let control = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater())
        func request(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let outcome = try await control.handle(HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
                "expiresAt": Date().timeIntervalSince1970 + 20, "operation": operation, "arguments": arguments])))
            XCTAssertEqual(outcome.state, .confirmed)
            return try XCTUnwrap(outcome.result as? [String: Any])
        }
        let before = try await request("settings.read"), revision = try XCTUnwrap(before["revision"] as? String)
        _ = try await request("settings.commandEnabled", ["command": "speakerOutput", "enabled": false, "revision": revision])
        XCTAssertFalse(model.commandAvailability.isEnabled(.speakerOutput))
        let after = try await request("settings.read")
        let settings = try XCTUnwrap(after["settings"] as? [String: Any])
        XCTAssertEqual((settings["commands"] as? [String: Bool])?["speakerOutput"], false)
        XCTAssertNotEqual(after["revision"] as? String, revision)
        do { _ = try await request("settings.commandEnabled", ["command": "speakerOutput", "enabled": true, "revision": revision]); XCTFail("Stale revision accepted") }
        catch HControlFailure.conflict {}
        await model.notificationReplies.shutdown()
    }
    func testDisabledCommandsKeepOwnershipOfSavedSpeakerPhrases() async throws {
        try isolatedHome()
        let defaults = UserDefaults.standard
        let keys = [CommandAvailability.preferenceKey, SpeakerOutputSettings.defaultsKey]
        let originals = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, originals) { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: CommandAvailability.preferenceKey)
        let model = GateModel(enableSpotifyControl: false)
        var speaker = SpeakerOutputSettings()
        speaker.prefixes = "Route speaker"
        speaker.destinations = [.init(names: "Fixture", output: "Fixture output")]
        XCTAssertTrue(model.saveSpeakerOutputSettings(speaker))
        model.setCommandEnabled(false, command: .speakerOutput)
        XCTAssertNotNil(model.spellingConflict(["Route speaker Fixture"], for: .zoomInPhrase, phrase: "Zoom in"), "A hidden speaker command keeps its phrases for re-enabling")
        let wake = try XCTUnwrap(HomeCommand.containing(.wakePhrase))
        let phrase = try XCTUnwrap(model.phraseConfiguration.phrases(for: .wakePhrase).first)
        model.setCommandEnabled(false, command: wake)
        XCTAssertTrue(model.speakerOutputConflictingPhrases.contains { $0.kind(for: phrase) != nil }, "Speaker editing cannot take a disabled command's phrase")
        XCTAssertTrue(model.patterns(for: .wakePhrase).isEmpty)
        XCTAssertFalse(model.phrasePatterns.contains { $0.text == "Route speaker Fixture" })
        model.setCommandEnabled(true, command: .speakerOutput)
        XCTAssertTrue(model.phrasePatterns.contains { $0.text == "Route speaker Fixture" })
        await model.notificationReplies.shutdown()
    }
    func testEveryCommandEditorAndDisabledListRenderWithoutShowingWindows() async throws {
        try isolatedHome()
        _ = NSApplication.shared
        let priorAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = priorAppearance }
        let original = UserDefaults.standard.object(forKey: CommandAvailability.preferenceKey)
        defer { UserDefaults.standard.set(original, forKey: CommandAvailability.preferenceKey) }
        UserDefaults.standard.removeObject(forKey: CommandAvailability.preferenceKey)
        let model = GateModel(enableSpotifyControl: false)
        func capture<V: View>(_ root: V, name: String, width: CGFloat = 600, height: CGFloat = 660) throws {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: root.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view; view.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible)
            if let directory = ProcessInfo.processInfo.environment["HCHAT_COMMAND_SETTINGS_CAPTURE_DIR"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent(name + ".png"))
            }
            XCTAssertFalse(window.isVisible, "No Settings preview may cover a working display")
        }
        try capture(Form { DisabledCommandsSection(model: model) }.formStyle(.grouped), name: "disabled-empty", height: 180)
        for command in HomeCommand.all {
            if command == .speakerOutput {
                try capture(SpeakerOutputEditor(initial: model.speakerOutputSettings, otherPatterns: [],
                    initialEnabled: true, saveEnabled: { _ in XCTFail("Rendering cannot save Enabled") },
                    save: { _ in XCTFail("Rendering cannot save speakers"); return false }), name: "editor-" + command.id)
            } else {
                try capture(CommandPhrasesView(model: model, slots: command.slots), name: "editor-" + command.id)
            }
        }
        for command in HomeCommand.all { model.setCommandEnabled(false, command: command) }
        XCTAssertEqual(model.disabledCommands.count, 20)
        try capture(Form { DisabledCommandsSection(model: model) }.formStyle(.grouped), name: "disabled-all", height: 900)
        let zoom = try XCTUnwrap(HomeCommand.containing(.zoomInPhrase))
        try capture(CommandPhrasesView(model: model, slots: zoom.slots), name: "editor-disabled-zoom", width: 520, height: 600)
        await model.notificationReplies.shutdown()
    }
}
