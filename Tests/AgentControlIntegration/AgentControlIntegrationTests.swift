// Run using scripts/test-control-integration.sh, which gives H Chat a fresh private home before any settings are loaded.
import Foundation
import XCTest
@testable import HelloChat

final class AgentControlIntegrationTests: XCTestCase {
    @MainActor func testNotificationSettingsUseRevisionGuardedSharedStore() async throws {
        try requireIsolatedHome()
        let model = GateModel(enableSpotifyControl: false)
        let controller = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater())
        func perform(_ operation: String, _ arguments: [String: Any] = [:]) async throws -> HControlOutcome {
            try await controller.handle(HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
                "expiresAt": Date().timeIntervalSince1970 + 20, "operation": operation, "arguments": arguments])))
        }
        let initial = try await perform("settings.read")
        var revision = try XCTUnwrap((initial.result as? [String: Any])?["revision"] as? String)
        let enabled = !model.notificationReplies.settings.enabled
        let idle = model.notificationReplies.settings.idleSeconds == 30 ? 31 : 30
        let seconds = model.notificationReplies.settings.replySeconds == 180 ? 179 : 180
        for (name, value) in [("notificationRepliesEnabled", enabled as Any), ("notificationReplyIdleSeconds", idle as Any), ("notificationReplySeconds", seconds as Any)] {
            let previous = revision
            let changed = try await perform("settings." + name, ["value": value, "revision": revision])
            XCTAssertEqual(changed.state, .confirmed)
            revision = try XCTUnwrap((changed.result as? [String: Any])?["revision"] as? String)
            XCTAssertNotEqual(revision, previous)
            do { _ = try await perform("settings." + name, ["value": value, "revision": previous]); XCTFail("A stale edit overwrote the shared setting") }
            catch HControlFailure.conflict {}
        }
        XCTAssertEqual(model.notificationReplies.settings.enabled, enabled)
        XCTAssertEqual(model.notificationReplies.settings.idleSeconds, idle)
        XCTAssertEqual(model.notificationReplies.settings.replySeconds, seconds)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: NotificationReplySettings.enabledKey), enabled)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "notificationReplySeconds"), seconds)
        do { _ = try await perform("settings.notificationReplySeconds", ["value": 181, "revision": revision]); XCTFail("An out-of-range setting was accepted") }
        catch HControlFailure.invalid {}
        await model.notificationReplies.shutdown()
    }
    private func requireIsolatedHome() throws {
        guard let expected = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              expected == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: expected).appendingPathComponent("control-fixture-owner").path)
        else { throw XCTSkip("Run scripts/test-control-integration.sh to supply an isolated home.") }
    }
    @MainActor func testOwnedStartCancellation() async throws {
        try requireIsolatedHome()
        UserDefaults.standard.set(false, forKey: "soundEffects")
        enum Boundary: CaseIterable { case scanning, sending, reusing }
        for boundary in Boundary.allCases {
            var waiting: CheckedContinuation<Void, Never>?
            var sent = [String]()
            var ends = 0
            var callExists = boundary == .reusing
            let transport = NativeVoice.Transport(snapshot: {
                if boundary == .scanning {
                    await withCheckedContinuation { waiting = $0 }
                    callExists = true // An unrelated call appears while the original scan is suspended.
                }
                return VoiceSnapshot(pid: boundary == .scanning ? 456 : 123, inputRunning: callExists,
                                     recorderRunning: false, microphone: callExists ? .listening : nil, accessibilityAllowed: true)
            }, send: { command, pid in
                sent.append(command)
                XCTAssertEqual(pid, 123)
                if boundary == .sending {
                    await withCheckedContinuation { waiting = $0 }
                    callExists = true
                }
            }, activate: { _ in XCTFail("Unexpected activation") },
            requestEnd: { ends += 1; return nil }, unmute: { _ in XCTFail("Unexpected unmute") },
            finishLaunchDefaults: { _, _ in
                if boundary == .reusing { await withCheckedContinuation { waiting = $0 } }
            })
            let model = GateModel(enableSpotifyControl: false, voice: NativeVoice(transport: transport))
            let controller = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater())
            let startID = UUID()
            func perform(_ name: String, id: UUID = UUID(), _ args: [String: Any] = [:]) async throws -> HControlOutcome {
                let request = try HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": id.uuidString,
                    "expiresAt": Date().timeIntervalSince1970 + 20, "operation": name, "arguments": args]))
                return try await controller.handle(request)
            }
            let start = Task { try await perform("shortcut.start", id: startID) }
            let deadline = ContinuousClock.now + .seconds(8)
            while waiting == nil && ContinuousClock.now < deadline { await Task.yield() }
            let pending = try XCTUnwrap(waiting, "Fixture did not reach \(boundary)")
            do { _ = try await perform("voice.cancelStart", ["startRequestId": UUID().uuidString]); XCTFail("A different Start was cancelled") }
            catch HControlFailure.conflict {}
            do { _ = try await perform("shortcut.start"); XCTFail("The first Start lost its reservation") }
            catch HControlFailure.unavailable {}
            if boundary == .scanning {
                let cancelled = try await perform("voice.cancelStart", ["startRequestId": startID.uuidString])
                XCTAssertEqual(cancelled.state, .confirmed)
            } else {
                do { _ = try await perform("voice.cancelStart", ["startRequestId": startID.uuidString]); XCTFail("Native operation accepted a blind cancellation") }
                catch HControlFailure.unavailable {}
            }
            pending.resume()
            if boundary == .scanning {
                do { _ = try await start.value; XCTFail("Withdrawn Start reported success") }
                catch HControlFailure.unavailable {}
            } else {
                let outcome = try await start.value
                XCTAssertEqual(outcome.state, .confirmed)
            }
            XCTAssertEqual(sent, boundary == .sending ? [VoiceBridge.startCommand] : [])
            XCTAssertEqual(ends, 0)
            XCTAssertFalse(model.busy)
            do { _ = try await perform("voice.cancelStart", ["startRequestId": startID.uuidString]); XCTFail("Stale Start was cancelled") }
            catch HControlFailure.conflict {}
        }
    }

    @MainActor func testCatalogueAndLiveSettingsConflict() async throws {
        try requireIsolatedHome()
        let model = GateModel(enableSpotifyControl: false)
        let controller = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater(), openWindow: { _ in XCTFail("Unexpected window action") })
        func perform(_ name: String, _ args: [String: Any] = [:]) async throws -> HControlOutcome {
            let request = try HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString,
                "expiresAt": Date().timeIntervalSince1970 + 20, "operation": name, "arguments": args]))
            return try await controller.handle(request)
        }
        let discovery = try await perform("capabilities")
        let catalog = try XCTUnwrap((discovery.result as? [String: Any])?["operations"] as? [String: [String: Any]])
        XCTAssertEqual(Set(catalog.keys), Set(controller.operations.keys))
        XCTAssertEqual(HChatShortcutAction.allCases.filter { catalog["shortcut." + $0.rawValue] != nil }.count, HChatShortcutAction.allCases.count)
        for (name, description) in catalog {
            let arguments = try XCTUnwrap(description["arguments"] as? [String: Any], name)
            XCTAssertEqual(arguments["additionalProperties"] as? Bool, false)
            XCTAssertNotNil(arguments["properties"], name)
            XCTAssertTrue(["available","conditional","unavailable"].contains(description["availability"] as? String ?? ""), name)
            if description["availability"] as? String != "available" { XCTAssertNotNil(description["reason"], name) }
        }
        if let catalogueOutput = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_CATALOGUE"] {
            try discovery.receipt(for: UUID()).write(to: URL(fileURLWithPath: catalogueOutput), options: .atomic)
        }
        let read = try await perform("settings.read")
        let original = try XCTUnwrap((read.result as? [String: Any])?["revision"] as? String)
        for _ in 0..<8 {
            let repeated = try await perform("settings.read")
            XCTAssertEqual((repeated.result as? [String: Any])?["revision"] as? String, original,
                           "Equivalent spelling display forms cannot invalidate an unchanged settings revision")
        }
        let newSeconds = model.rewindVideoSeconds == 37 ? 38 : 37
        let stored = try await perform("settings.rewindVideoSeconds", ["value": newSeconds, "revision": original])
        XCTAssertEqual(stored.state, .confirmed)
        XCTAssertEqual(model.rewindVideoSeconds, newSeconds)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: VideoCommand.rewindSecondsPreference), newSeconds)
        let revision = try XCTUnwrap((stored.result as? [String: Any])?["revision"] as? String)
        XCTAssertNotEqual(revision, original)
        do { _ = try await perform("settings.rewindVideoSeconds", ["value": 4,"revision": original]); XCTFail("Stale settings applied") }
        catch HControlFailure.conflict {}
        do { _ = try await perform("settings.rewindVideoSeconds", ["value": true,"revision": revision]); XCTFail("Boolean accepted as seconds") }
        catch HControlFailure.invalid {}
        do { _ = try await perform("settings.rewindVideoSeconds", ["value": 4, "revision": revision, "extra": 1]); XCTFail("Unknown argument accepted") }
        catch HControlFailure.invalid {}
        do { _ = try await perform("unknown.command"); XCTFail("Unknown operation accepted") }
        catch HControlFailure.unavailable {}
        XCTAssertEqual(model.rewindVideoSeconds, newSeconds)
        let row = try await perform("settings.phrase.write", ["slot": PhraseSlot.rewindVideoPhrase.rawValue, "row": "new", "text": "the offline sample","revision": revision])
        XCTAssertEqual(row.state, .confirmed)
        let id = try XCTUnwrap(model.phraseAliases[.rewindVideoPhrase]?.last?.id)
        let next = try XCTUnwrap((row.result as? [String: Any])?["revision"] as? String)
        let removed = try await perform("settings.phrase.remove", ["slot": PhraseSlot.rewindVideoPhrase.rawValue, "row": id.uuidString,"revision": next])
        XCTAssertEqual(removed.state, .confirmed)
        XCTAssertFalse(model.phraseAliases[.rewindVideoPhrase]?.contains(where: { $0.id == id }) ?? false)
        func restore(_ name: String, _ fields: [String: Any]) async throws {
            let current = try await perform("settings.read")
            var arguments = fields
            arguments["revision"] = try XCTUnwrap((current.result as? [String: Any])?["revision"])
            let result = try await perform(name, arguments)
            XCTAssertEqual(result.state, .confirmed)
        }
        let app = "com.google.Chrome"
        let stockAppSpellings = AppNameSpellings().spellings(for: app)
        model.appNameSpellings.overrides[app] = ["offline fixture alias"]
        XCTAssertNotEqual(model.appNameSpellings.spellings(for: app), stockAppSpellings)
        try await restore("settings.appSpellings.restore", ["bundleId": app])
        XCTAssertNil(model.appNameSpellings.overrides[app])
        XCTAssertEqual(model.appNameSpellings.spellings(for: app), stockAppSpellings)

        let slot = PhraseSlot.rewindVideoPhrase
        model.renamePhrase(slot, id: nil, old: model.rewindVideoPhrase, new: "a different offline phrase")
        try await restore("settings.phrase.restore", ["slot": slot.rawValue])
        XCTAssertEqual(model.rewindVideoPhrase, slot.defaultText)
        let phrase = slot.defaultText, key = slot.spellingKey(for: phrase)
        model.phraseDictionaries[key] = ["different offline spelling"]
        try await restore("settings.spellings.restore", ["slot": slot.rawValue,"row": "main"])
        XCTAssertNil(model.phraseDictionaries[key])
        let restoredSnapshot = try await perform("settings.read")
        let settings = try XCTUnwrap((restoredSnapshot.result as? [String: Any])?["settings"] as? [String: Any])
        let phrases = try XCTUnwrap(settings["phrases"] as? [String: [[String: Any]]])
        XCTAssertEqual(phrases[slot.rawValue]?.first?["spellings"] as? [String], slot.stockSpellings(for: phrase))

        var speaker = model.speakerOutputSettings
        speaker.prefixes = "select my fixture output"
        XCTAssertTrue(model.saveSpeakerOutputSettings(speaker))
        try await restore("settings.speakerPrefixes.restore", [:])
        XCTAssertEqual(model.speakerOutputSettings.prefixes, SpeakerOutputSettings.defaultPrefixes)
        let prefix = try XCTUnwrap(SpeakerOutputSettings.lines(SpeakerOutputSettings.defaultPrefixes).first)
        let prefixKey = PhraseList.key(prefix)
        speaker = model.speakerOutputSettings
        speaker.prefixSpellings = [prefixKey: ["fixture speaker spelling"]]
        XCTAssertTrue(model.saveSpeakerOutputSettings(speaker))
        try await restore("settings.speakerPrefixSpellings.restore", ["prefix": prefix])
        XCTAssertNil(model.speakerOutputSettings.prefixSpellings?[prefixKey])
        let finalSnapshot = try await perform("settings.read")
        let finalSettings = try XCTUnwrap((finalSnapshot.result as? [String: Any])?["settings"] as? [String: Any])
        XCTAssertEqual((finalSettings["effectiveSpeakerPrefixSpellings"] as? [String: [String]])?[prefixKey], SpeakerOutputSettings.builtInSpellings(for: prefix))
        XCTAssertFalse(model.enabled)
    }
}
