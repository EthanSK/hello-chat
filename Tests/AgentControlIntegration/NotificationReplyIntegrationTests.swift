// Exercise the real app coordinator with fixture origins, a simulated clock and injected delivery; never capture or queue live speech. — GPT-6.1 Sol
import Foundation
import AppKit
import SQLite3
import XCTest
import SwiftUI
@testable import HelloChat

@MainActor final class NotificationReplyIntegrationTests: XCTestCase {
    private final class Clock { var time = 100.0; let wallBase = 1_795_500_000.0 }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock(); private var values: [[String]] = []
        func append(_ value: [String]) { lock.lock(); values.append(value); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    }
    private struct Fixture {
        let coordinator: NotificationReplyCoordinator
        let origin: NotificationReplyOrigin
        let clock: Clock
        let calls: Calls
        let root: URL
    }
    private func fixture(coordinator supplied: NotificationReplyCoordinator? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HChatNotificationIntegration-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), codex = home.appendingPathComponent(".codex")
        let sessions = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = UUID(), file = sessions.appendingPathComponent("fixture.jsonl")
        try Data().write(to: file)
        let database = codex.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?; sqlite3_open(database.path, &db)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('\(thread.uuidString.lowercased())','\(file.path)');", nil, nil, nil), SQLITE_OK)
        let origin = try NotificationReplyOrigin.capture(thread: thread, turn: nil, question: "", home: home)
        let name = "HChatNotificationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = NotificationReplySettings(defaults: defaults); settings.enabled = true
        let coordinator = supplied ?? NotificationReplyCoordinator(settings: settings, directory: root.appendingPathComponent("status"))
        coordinator.settings.enabled = true
        let clock = Clock(), calls = Calls()
        coordinator.clock = { clock.time }; coordinator.wallClock = { clock.wallBase + clock.time }
        coordinator.currentReadiness = { .ready }
        coordinator.captureOrigin = { _, _, _ in origin }
        coordinator.currentDesktop = { (URL(fileURLWithPath: "/fixture/codex"), getpid()) }
        coordinator.queueCommand = { calls.append($0); return 0 }
        coordinator.openOrigin = { _, _ in false } // Never open a real app in coordinator tests.
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        return .init(coordinator: coordinator, origin: origin, clock: clock, calls: calls, root: root)
    }
    private func prepare(_ fixture: Fixture, event: UUID) async throws -> [String: Any] {
        try await fixture.coordinator.prepare(event: event, thread: fixture.origin.thread, turn: nil, question: "", spokenText: "Fixture notification ready.")
    }
    private func finish(_ fixture: Fixture, event: UUID) throws {
        let model = fixture.coordinator, clock = fixture.clock
        let start = clock.time
        clock.time = start + 0.1
        _ = try model.audioStarted(event: event, instance: model.instance, uptime: clock.time, wall: clock.wallBase + clock.time)
        clock.time = start + 0.2
        _ = try model.audioEnded(event: event, instance: model.instance, uptime: clock.time, wall: clock.wallBase + clock.time, completed: true)
        clock.time = start + 2
        model.recognized(.init(batch: UUID(), text: "Reply yes End reply", words: [
            .init(text: "reply", start: start + 1, end: start + 1.1), .init(text: "yes", start: start + 1.2, end: start + 1.3),
            .init(text: "end", start: start + 1.5, end: start + 1.6), .init(text: "reply", start: start + 1.7, end: start + 1.8)], stableWords: 4))
    }
    private func fallback(_ f: Fixture, event: UUID, delivery: Double = 90) async throws -> [String: Any] {
        try await f.coordinator.fallbackReady(event: event, instance: f.coordinator.instance,
            deliveredUptime: delivery, deliveredWall: f.clock.wallBase + delivery,
            skipReason: "agent-flow-speech-denied", expiresAt: f.clock.wallBase + f.clock.time + 3)
    }
    func testStopSpeakingUsesNegotiatedAudioAndNeverDispatches() async throws {
        for supported in [false, true] {
            let f = try fixture(), event = UUID(), m = f.coordinator
            var finalizations: [Double] = []
            m.finalizeRecognition = { finalizations.append($0) }
            m.openOrigin = { _, _ in XCTFail("Stopping speech must not navigate"); return false }
            let initial = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
                spokenText: "Fixture notification ready.", manualFinish: true, stopSpeaking: supported)
            XCTAssertEqual(initial["stopSpeaking"] as? Bool, supported)
            f.clock.time = 100.1
            _ = try m.audioStarted(event: event, instance: m.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
            let batch = UUID(), words: [NotificationReplyCore.Word] = [
                .init(text: "shut", start: 100.5, end: 100.65), .init(text: "up", start: 100.7, end: 100.85)]
            f.clock.time = 101
            m.recognized(.init(batch: batch, text: "Shut up", words: words, stableWords: 0))
            XCTAssertEqual(try m.status(event: event, instance: m.instance)["phase"] as? String, "announcing")
            XCTAssertEqual(finalizations.isEmpty, !supported, "Partial stop requests native confirmation only after negotiation")
            m.recognized(.init(batch: batch, text: "Shut up", words: words, stableWords: 2))
            let result = try m.status(event: event, instance: m.instance)
            XCTAssertEqual(result["phase"] as? String, supported ? "cancelled" : "announcing")
            XCTAssertEqual(result["reason"] as? String, supported ? "user-stop-speaking" : "")
            if supported {
                _ = try m.mediaReleased(event: event, instance: m.instance, released: true)
                f.clock.time = 101.2
                let late = try m.audioEnded(event: event, instance: m.instance, uptime: f.clock.time,
                    wall: f.clock.wallBase + f.clock.time, completed: true)
                XCTAssertEqual(late["phase"] as? String, "cancelled", "Late audio completion cannot reopen Reply")
                XCTAssertEqual(late["reason"] as? String, "user-stop-speaking")
            }
            await m.waitForPendingDelivery()
            XCTAssertEqual(f.calls.count, 0)
            await m.shutdown()
        }
    }
    func testStopSpeakingPrepareCannotChangeNegotiationOnReplay() async throws {
        let f = try fixture(), event = UUID(), m = f.coordinator
        let first = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
            spokenText: "Original fixture.", stopSpeaking: true)
        let repeated = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
            spokenText: "Original fixture.", stopSpeaking: true)
        XCTAssertEqual(first["instance"] as? String, repeated["instance"] as? String)
        do {
            _ = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
                spokenText: "Original fixture.", stopSpeaking: false)
            XCTFail("A duplicate event must not change its stop contract")
        } catch let error as NotificationReplyCoordinator.Failure {
            XCTAssertEqual(error.rawValue, NotificationReplyCoordinator.Failure.invalidEvent.rawValue)
        }
        await m.shutdown()
    }
    func testStopHintUsesTheSameFrozenEchoGuardAsRecognition() async throws {
        for ownText in ["Ordinary fixture.", "The Shut up command is available."] {
            let f = try fixture(), event = UUID(), m = f.coordinator
            var shown: [NotificationReplyCoordinator.Presentation] = []
            m.showPresentation = { if let presentation = $0 { shown.append(presentation) } }
            _ = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
                spokenText: ownText, manualFinish: true, stopSpeaking: true)
            f.clock.time = 100.1
            _ = try m.audioStarted(event: event, instance: m.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
            XCTAssertEqual(shown.last?.canSayStopSpeaking, ownText == "Ordinary fixture.")
            XCTAssertEqual(try m.status(event: event, instance: m.instance)["stopSpeaking"] as? Bool, true,
                "Negotiated support remains distinct from this event's usable main phrase")
            await m.shutdown()
        }
    }
    func testStopSpeakingStillHonoursVoiceGuard() async throws {
        let f = try fixture(), event = UUID(), m = f.coordinator
        _ = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
            spokenText: "Original fixture.", manualFinish: true, stopSpeaking: true)
        f.clock.time = 100.1
        _ = try m.audioStarted(event: event, instance: m.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
        m.currentReadiness = { .voiceActive }
        f.clock.time = 101
        m.recognized(.init(batch: UUID(), text: "Shut up", words: [
            .init(text: "shut", start: 100.5, end: 100.65), .init(text: "up", start: 100.7, end: 100.85)], stableWords: 2))
        XCTAssertEqual(try m.status(event: event, instance: m.instance)["reason"] as? String, "voiceActive")
        XCTAssertEqual(f.calls.count, 0)
        await m.shutdown()
    }
    func testStaleOriginCannotBecomeAStopRequest() async throws {
        let f = try fixture(), event = UUID(), m = f.coordinator
        _ = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "",
            spokenText: "Original fixture.", manualFinish: true, stopSpeaking: true)
        f.clock.time = 100.1
        _ = try m.audioStarted(event: event, instance: m.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
        let changed = expectation(description: "The real origin watcher rejects newer user input")
        var observed = false
        m.outcome = { _, _, reason, _ in
            if reason == "originStale", !observed { observed = true; changed.fulfill() }
        }
        let handle = try FileHandle(forWritingTo: f.origin.rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"A newer fixture instruction\"}}\n".utf8))
        try handle.close()
        await fulfillment(of: [changed], timeout: 3)
        f.clock.time = 101
        m.recognized(.init(batch: UUID(), text: "Shut up", words: [
            .init(text: "shut", start: 100.5, end: 100.65), .init(text: "up", start: 100.7, end: 100.85)], stableWords: 2))
        XCTAssertEqual(try m.status(event: event, instance: m.instance)["reason"] as? String, "originStale")
        _ = try m.mediaReleased(event: event, instance: m.instance, released: true)
        await m.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 0)
        await m.shutdown()
    }
    func testManualCaptureRenewsPastOldLimitsAndCleansFromDecision() async throws {
        let f = try fixture(), event = UUID(), m = f.coordinator
        let first = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "", spokenText: "Original fixture.", manualFinish: true)
        XCTAssertEqual(first["manualFinish"] as? Bool, true)
        XCTAssertEqual(first["ownerLeaseSeconds"] as? Double, 10)
        XCTAssertTrue(first["ownerLeaseExpiresUptime"] is NSNull)
        _ = try await fallback(f, event: event)
        f.clock.time = 101.5
        m.recognized(.init(batch: UUID(), text: "Reply yes", words: [.init(text: "reply", start: 101, end: 101.1), .init(text: "yes", start: 101.2, end: 101.3)], stableWords: 2))
        for time in stride(from: 102.0, through: 1902.0, by: 1) {
            f.clock.time = time
            let status = try m.status(event: event, instance: m.instance)
            XCTAssertEqual(status["ownerLeaseExpiresUptime"] as? Double, time + 10)
            m.checkBounds()
        }
        XCTAssertTrue(m.isComposing, "Normal silence persists past old idle/total/initial limits")
        f.clock.time = 1903
        m.recognized(.init(batch: UUID(), text: "End reply", words: [.init(text: "end", start: 1902.1, end: 1902.2), .init(text: "reply", start: 1902.3, end: 1902.4)], stableWords: 2))
        XCTAssertEqual(try m.status(event: event, instance: m.instance)["phase"] as? String, "releasing")
        f.clock.time = 1909; m.checkBounds()
        XCTAssertTrue(m.hasOpenAttempt, "Cleanup uses the first decision, not an expired initial audio anchor")
        _ = try m.mediaReleased(event: event, instance: m.instance, released: true)
        await m.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 1)
        await m.shutdown()
    }
    func testExpiredManualOwnerAndSpokenCancelStayUnsent() async throws {
        for expired in [true, false] {
            let f = try fixture(), event = UUID(), m = f.coordinator
            _ = try await m.prepare(event: event, thread: f.origin.thread, turn: nil, question: "", spokenText: "Original fixture.", manualFinish: true)
            _ = try await fallback(f, event: event)
            f.clock.time = 101.5
            m.recognized(.init(batch: UUID(), text: "Reply yes", words: [.init(text: "reply", start: 101, end: 101.1), .init(text: "yes", start: 101.2, end: 101.3)], stableWords: 2))
            if expired { f.clock.time = 111.5 }
            else {
                f.clock.time = 102.5
                m.recognized(.init(batch: UUID(), text: "Cancel reply", words: [.init(text: "cancel", start: 102, end: 102.1), .init(text: "reply", start: 102.2, end: 102.3)], stableWords: 2))
            }
            let result = try m.status(event: event, instance: m.instance)
            XCTAssertEqual(result["reason"] as? String, expired ? "owner-lost" : "cancel-reply")
            XCTAssertTrue(result["ownerLeaseExpiresUptime"] is NSNull)
            _ = try m.mediaReleased(event: event, instance: m.instance, released: true)
            await m.waitForPendingDelivery()
            XCTAssertEqual(f.calls.count, 0)
            await m.shutdown()
        }
    }
    func testInitialNativeConfirmationKeepsReferenceAndPendingHint() async throws {
        let f = try fixture(), event = UUID(), m = f.coordinator
        var shown: [NotificationReplyCoordinator.Presentation] = [], finalizations: [Double] = []
        m.showPresentation = { if let value = $0 { shown.append(value) } }
        m.finalizeRecognition = { finalizations.append($0) }
        _ = try await prepare(f, event: event)
        _ = try await fallback(f, event: event)
        let batch = UUID()
        f.clock.time = 106.9; m.processed(through: 106)
        let words: [NotificationReplyCore.Word] = [.init(text: "reply", start: 104.9, end: 105), .init(text: "yes", start: 105.2, end: 105.3)]
        m.recognized(.init(batch: batch, text: "Reply yes", words: words, stableWords: 0))
        XCTAssertEqual(shown.last?.confirmingReply, true)
        XCTAssertEqual(finalizations.count, 1, "Initial Reply requests the actual selected provider's native finalizer")
        f.clock.time = 107.1; m.checkBounds()
        XCTAssertEqual(shown.last?.confirmingReply, true)
        m.recognized(.init(batch: batch, text: "Reply yes", words: words, stableWords: 2))
        XCTAssertEqual(shown.last?.phase, .composing)
        XCTAssertEqual(shown.last?.replyText, "yes")
        m.interrupted("recognition-audio-gap")
        XCTAssertEqual(shown.last?.phase, .cancelled)
        XCTAssertTrue(shown.allSatisfy { $0.spokenText == "Fixture notification ready." }, "Every displayed phase keeps the exact event reference")
        XCTAssertEqual(m.lifecycleCounts.textBytes, 0, "Terminal heavy state retires after the final value presentation")
        XCTAssertEqual(f.calls.count, 0)
        await m.shutdown()
    }
    func testConflictingFinishSpellingsLeaveAmbientRecognitionUntouched() async throws {
        let f = try fixture(), m = f.coordinator
        var resets = 0, origins = 0
        m.resetRecognition = { resets += 1 }
        m.captureOrigin = { _, _, _ in origins += 1; return f.origin }
        m.commandForms = { .init(endReplySpellings: ["Cancel"]) }
        let result = try await prepare(f, event: UUID())
        XCTAssertEqual(result["phase"] as? String, "unavailable")
        XCTAssertEqual(result["reason"] as? String, "command-spellings-conflict")
        XCTAssertFalse(m.interceptsSpeech)
        XCTAssertEqual(resets, 0, "Rejected admission cannot discard ambient input")
        XCTAssertEqual(origins, 0)
        XCTAssertEqual(f.calls.count, 0)
        await m.shutdown()
    }
    func testPrepareOptionalManualAndStopSchemasKeepLegacyAndStrictValidation() async throws {
        let model = GateModel(enableSpotifyControl: false)
        let f = try fixture(coordinator: model.notificationReplies)
        let control = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater())
        let operation = try XCTUnwrap(control.operations["notificationReply.prepare"])
        XCTAssertEqual(operation.optionalFields.keys.sorted(), ["manualFinish", "stopSpeaking"])
        XCTAssertNil(operation.fields["manualFinish"])
        XCTAssertNil(operation.fields["stopSpeaking"])
        func request(_ args: [String: Any]) throws -> HControlRequest {
            try HControlRequest(JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString, "expiresAt": Date().timeIntervalSince1970 + 10, "operation": "notificationReply.prepare", "arguments": args]))
        }
        for flag in [nil, false, true] as [Bool?] {
          for stopFlag in [nil, false, true] as [Bool?] {
            let event = UUID()
            var args: [String: Any] = ["eventID": event.uuidString, "threadID": f.origin.thread.uuidString, "turnID": "", "questionID": "", "spokenText": "Fixture notification ready."]
            if let flag { args["manualFinish"] = flag }
            if let stopFlag { args["stopSpeaking"] = stopFlag }
            let result = try await control.handle(request(args))
            XCTAssertEqual((result.result as? [String: Any])?["manualFinish"] as? Bool, flag ?? false)
            XCTAssertEqual((result.result as? [String: Any])?["stopSpeaking"] as? Bool, stopFlag ?? false)
            _ = try f.coordinator.cancel(event: event, instance: f.coordinator.instance, reason: "fixture")
            _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: false)
            for bad in [1, "true"] as [Any] {
                for key in ["manualFinish", "stopSpeaking"] {
                    var invalid = args; invalid[key] = bad
                    do { _ = try await control.handle(request(invalid)); XCTFail("Invalid optional Boolean accepted: \(key)") } catch HControlFailure.invalid { }
                }
            }
            args.removeValue(forKey: "manualFinish"); args["extra"] = true
            do { _ = try await control.handle(request(args)); XCTFail("Unknown prepare field accepted") } catch HControlFailure.invalid { }
          }
        }
        for (name, other) in control.operations where name != "notificationReply.prepare" {
            XCTAssertTrue(other.optionalFields.isEmpty, "Existing strict schema changed: \(name)")
        }
        await f.coordinator.shutdown()
    }
    func testAcceptedReplyOpensExactOriginOnceWithoutWaitingForArrival() async throws {
        let f = try fixture(), event = UUID()
        var opened: [(Int32, UUID)] = []
        f.coordinator.openOrigin = { opened.append(($0, $1)); return true }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        XCTAssertTrue(opened.isEmpty)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, getpid()); XCTAssertEqual(opened.first?.1, f.origin.thread)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued", "Opening does not claim saved arrival")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        XCTAssertEqual(opened.count, 1); XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testOwnExactArrivalBeforeQueueReturnsStillOpens() async throws {
        let f = try fixture(), event = UUID()
        let entered = DispatchSemaphore(value: 0), observed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var opens = 0
        f.coordinator.openOrigin = { _, thread in XCTAssertEqual(thread, f.origin.thread); opens += 1; return true }
        f.coordinator.validateSubmittedOrigin = { origin, reply in try origin.validate(reply: reply); observed.signal() }
        f.coordinator.queueCommand = { command in
            f.calls.append(command)
            let message = String(command.last!.dropFirst("--message=".count))
            let handle = try FileHandle(forWritingTo: f.origin.rollout); defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: ["type":"event_msg", "payload":["type":"user_message", "message":message, "images":[], "local_images":[]]]) + Data([10]))
            entered.signal()
            guard release.wait(timeout: .now() + 4) == .success else { return 1 }
            return 0
        }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        let queued = await Task.detached { entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(queued)
        let checked = await Task.detached { observed.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(checked, "The actual origin watcher must inspect our own arrival while the runner is still in flight")
        XCTAssertEqual(opens, 0)
        release.signal(); await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(opens, 1); XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testNavigationFailureNeverResendsOrChangesAcceptedOutcome() async throws {
        let f = try fixture(), event = UUID()
        var opens = 0
        f.coordinator.openOrigin = { _, _ in opens += 1; return false }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(opens, 1); XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        XCTAssertEqual(opens, 1); XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testCancellationNewerInputAndDesktopReplacementPreventNavigationAfterAcceptance() async throws {
        for reason in ["settings-changed", "recognition-audio-gap", "voiceActive", "new-user-input", "desktop-replaced", "desktop-pid", "submission-unknown", "user-dismissed"] {
            let f = try fixture(), event = UUID()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var opens = 0
            f.coordinator.openOrigin = { _, _ in opens += 1; return true }
            f.coordinator.queueCommand = { command in
                f.calls.append(command); entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { return 1 }
                return reason == "submission-unknown" ? 1 : 0
            }
            _ = try await prepare(f, event: event); try finish(f, event: event)
            _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
            let running = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
            XCTAssertTrue(running)
            if reason == "new-user-input" {
                let handle = try FileHandle(forWritingTo: f.origin.rollout); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"A genuinely newer instruction\"}}\n".utf8))
            } else if reason == "desktop-replaced" {
                f.coordinator.currentDesktop = { (URL(fileURLWithPath: "/other/codex"), getpid()) }
            } else if reason == "desktop-pid" {
                f.coordinator.currentDesktop = { (URL(fileURLWithPath: "/fixture/codex"), getpid() + 1) }
            } else if reason == "user-dismissed" { f.coordinator.dismiss(event: event) }
            else if reason != "submission-unknown" { f.coordinator.interrupted(reason) }
            release.signal(); await f.coordinator.waitForPendingDelivery()
            XCTAssertEqual(opens, 0, reason); XCTAssertEqual(f.calls.count, 1, reason)
            XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String,
                reason == "submission-unknown" ? "unavailable" : "queued", "Accepted sends remain accepted even if focus is cancelled")
            await f.coordinator.shutdown()
        }
    }
    func testCancellationDuringPostAcceptanceValidationSuppressesOnlyNavigation() async throws {
        let f = try fixture(), event = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var opens = 0
        f.coordinator.openOrigin = { _, _ in opens += 1; return true }
        f.coordinator.validateSubmittedOrigin = { origin, reply in
            try origin.validate(reply: reply); entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw NotificationReplyOrigin.Failure.originUnavailable }
        }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        let validating = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        XCTAssertTrue(validating)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued")
        f.coordinator.interrupted("recognition-audio-gap")
        release.signal(); await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(opens, 0); XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued")
        await f.coordinator.shutdown()
    }
    func testVisualFallbackStartsAtNewHUDAndFinalizesOnce() async throws {
        let f = try fixture(), event = UUID()
        var panels: [NotificationReplyCoordinator.Presentation] = []
        f.coordinator.showPresentation = { if let value = $0 { panels.append(value) } }
        _ = try await prepare(f, event: event)
        let first = try await fallback(f, event: event)
        XCTAssertEqual(first["opportunityKind"] as? String, "visual")
        XCTAssertEqual(first["visualDeliveredUptime"] as? Double, 90)
        XCTAssertEqual(first["opportunityUptime"] as? Double, 100, "An old delivered notice does not consume the new first HUD opportunity")
        XCTAssertEqual(panels.last?.phase, .waiting)
        XCTAssertEqual(panels.last?.commandSeconds, 5)
        f.clock.time = 104.5
        let duplicate = try await fallback(f, event: event)
        XCTAssertEqual(duplicate["opportunityUptime"] as? Double, 100)
        XCTAssertThrowsError(try f.coordinator.audioStarted(event: event, instance: f.coordinator.instance, uptime: 104.5, wall: f.clock.wallBase + 104.5))
        XCTAssertThrowsError(try f.coordinator.audioEnded(event: event, instance: f.coordinator.instance, uptime: 104.5, wall: f.clock.wallBase + 104.5, completed: true))
        f.coordinator.recognized(.init(batch: UUID(), text: "Reply yes End reply", words: [
            .init(text: "reply", start: 104.5, end: 104.6), .init(text: "yes", start: 104.7, end: 104.8),
            .init(text: "end", start: 105, end: 105.1), .init(text: "reply", start: 105.2, end: 105.3)], stableWords: 4))
        XCTAssertEqual(f.calls.count, 0, "Capture cannot submit before actual no-media/FIFO cleanup")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testVisualFallbackNeverRevivesSpeechStalenessOrLostFrames() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        _ = try f.coordinator.audioStarted(event: event, instance: f.coordinator.instance, uptime: 100, wall: f.clock.wallBase + 100)
        do { _ = try await fallback(f, event: event); XCTFail("Started audio cannot become visual fallback") } catch {}
        _ = try f.coordinator.cancel(event: event, instance: f.coordinator.instance, reason: "done")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: false)
        let stale = UUID(); _ = try await prepare(f, event: stale)
        let handle = try FileHandle(forWritingTo: f.origin.rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"<send_user_message_question_reply>Yes</send_user_message_question_reply>\"}}\n".utf8))
        try handle.close()
        let result = try await fallback(f, event: stale)
        XCTAssertEqual(result["reason"] as? String, "originStale")
        XCTAssertNotEqual(result["phase"] as? String, "waiting")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
        let fresh = try fixture(), gap = UUID()
        _ = try await prepare(fresh, event: gap); _ = try await fallback(fresh, event: gap)
        fresh.coordinator.interrupted("recognition-audio-gap")
        XCTAssertEqual(try fresh.coordinator.status(event: gap, instance: fresh.coordinator.instance)["reason"] as? String, "recognition-audio-gap")
        XCTAssertThrowsError(try fresh.coordinator.audioStarted(event: gap, instance: fresh.coordinator.instance, uptime: 100, wall: fresh.clock.wallBase + 100))
        XCTAssertEqual(fresh.calls.count, 0)
        await fresh.coordinator.shutdown()
    }
    func testVisualFallbackKeepsReadinessInstanceClockAndExpiryGuards() async throws {
        for readiness: NotificationReplyCoordinator.Readiness in [.disabled, .listeningOff, .listenerUnavailable, .voiceActive, .voiceUnknown, .desktopUnavailable] {
            let f = try fixture(), event = UUID()
            f.coordinator.currentReadiness = { readiness }
            _ = try await prepare(f, event: event)
            do { _ = try await fallback(f, event: event); XCTFail("Unavailable reply cannot fall back") } catch {}
            XCTAssertEqual(f.calls.count, 0)
            await f.coordinator.shutdown()
        }
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        do {
            _ = try await f.coordinator.fallbackReady(event: event, instance: UUID(), deliveredUptime: 90,
                deliveredWall: f.clock.wallBase + 90, skipReason: "agent-flow-speech-denied", expiresAt: .infinity)
            XCTFail("Different app instance must fail")
        } catch {}
        for (stamp, reason) in [(101.0, "agent-flow-speech-denied"), (90.0, "unknown")] {
            do {
                _ = try await f.coordinator.fallbackReady(event: event, instance: f.coordinator.instance, deliveredUptime: stamp,
                    deliveredWall: f.clock.wallBase + stamp, skipReason: reason, expiresAt: .infinity)
                XCTFail("Unknown skip or future clock must fail")
            } catch {}
        }
        let expired = try await f.coordinator.fallbackReady(event: event, instance: f.coordinator.instance, deliveredUptime: 90,
            deliveredWall: f.clock.wallBase + 90, skipReason: "agent-flow-speech-denied", expiresAt: f.clock.wallBase + 99)
        XCTAssertEqual(expired["reason"] as? String, "fallback-request-expired")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testProviderFailureFallbackAndExpiredAsyncValidation() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        let result = try await f.coordinator.fallbackReady(event: event, instance: f.coordinator.instance,
            deliveredUptime: 90, deliveredWall: f.clock.wallBase + 90,
            skipReason: "audio-unavailable-before-start", expiresAt: f.clock.wallBase + 103)
        XCTAssertEqual(result["opportunityKind"] as? String, "visual")
        f.clock.time = 105.2
        f.coordinator.recognized(.init(batch: UUID(), text: "Reply yes", words: [
            .init(text: "reply", start: 105.2, end: 105.3), .init(text: "yes", start: 105.4, end: 105.5)], stableWords: 2))
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "waiting", "Speech beyond five seconds cannot activate")
        f.coordinator.processed(through: 106); f.clock.time = 107.6; f.coordinator.checkBounds()
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "no-command")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
        let g = try fixture(), pending = UUID()
        _ = try await prepare(g, event: pending)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        g.coordinator.validateOrigin = { origin in
            try origin.validate(); entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else { throw NotificationReplyOrigin.Failure.originUnavailable }
        }
        let task = Task { try await self.fallback(g, event: pending) }
        let validating = await Task.detached { entered.wait(timeout: .now() + 2) == .success }.value
        XCTAssertTrue(validating)
        g.clock.time += 4; release.signal()
        let expired = try await task.value
        XCTAssertEqual(expired["reason"] as? String, "fallback-request-expired")
        XCTAssertTrue(expired["opportunityUptime"] is NSNull)
        XCTAssertEqual(g.calls.count, 0)
        await g.coordinator.shutdown()
    }
    func testExactReleaseAndNextPrepareAreIndependent() async throws {
        let f = try fixture(), first = UUID(), second = UUID()
        var latest: UUID?
        f.coordinator.outcome = { event, _, _, isFirst in if isFirst { latest = event } }
        let response = try await prepare(f, event: first)
        let path = URL(fileURLWithPath: try XCTUnwrap(response["statusFile"] as? String))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(text.contains("Fixture notification ready."))
        try finish(f, event: first)
        XCTAssertEqual(f.calls.count, 0)
        XCTAssertFalse(f.coordinator.interceptsSpeech)
        _ = try await prepare(f, event: second)
        _ = try f.coordinator.mediaReleased(event: first, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(try f.coordinator.status(event: first, instance: f.coordinator.instance)["phase"] as? String, "queued")
        XCTAssertEqual(try f.coordinator.status(event: second, instance: f.coordinator.instance)["phase"] as? String, "preparing")
        XCTAssertEqual(latest, second, "An older pending delivery must not take over the newest command outcome")
        _ = try f.coordinator.mediaReleased(event: first, instance: f.coordinator.instance, released: true)
        XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testLiveDraftUsesCoreWithoutWritingSpeechToMetadata() async throws {
        let f = try fixture(), event = UUID(), batch = UUID()
        var presentations: [NotificationReplyCoordinator.Presentation] = []
        f.coordinator.showPresentation = { if let value = $0 { presentations.append(value) } }
        let response = try await prepare(f, event: event)
        f.clock.time += 0.1
        _ = try f.coordinator.audioStarted(event: event, instance: f.coordinator.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
        f.clock.time += 0.1
        _ = try f.coordinator.audioEnded(event: event, instance: f.coordinator.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time, completed: true)
        f.clock.time += 1
        let first = NotificationReplyCore.Recognition(batch: batch, text: "Reply private answer", words: [
            .init(text: "reply", start: 100.5, end: 100.6), .init(text: "private", start: 100.7, end: 100.8),
            .init(text: "answer", start: 100.9, end: 101)], stableWords: 1)
        f.coordinator.recognized(first)
        XCTAssertEqual(presentations.last?.replyText, "private answer")
        let count = presentations.count
        f.coordinator.recognized(first)
        XCTAssertEqual(presentations.count, count, "No-text frames do not rebuild native panels.")
        let path = try XCTUnwrap(response["statusFile"] as? String)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertFalse(try String(contentsOfFile: path).contains("private answer"))
        XCTAssertEqual(presentations.last?.spokenText, "Fixture notification ready.")
        await f.coordinator.shutdown()
    }
    func testLastQueuedAttemptRetiresItsObserverWithoutAnotherNotification() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event); try finish(f, event: event)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.coordinator.lifecycleCounts.textBytes, 0)
        XCTAssertGreaterThan(f.coordinator.lifecycleCounts.watchers, 0)
        f.coordinator.checkBounds()
        XCTAssertTrue(f.coordinator.lifecycleCounts.checkingBounds)
        f.clock.time += 61; f.coordinator.checkBounds()
        XCTAssertEqual(f.coordinator.lifecycleCounts.watchers, 0)
        XCTAssertFalse(f.coordinator.lifecycleCounts.checkingBounds)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued")
        await f.coordinator.shutdown()
    }
    func testUnavailableAttemptLeavesAmbientRecognitionAlone() async throws {
        let f = try fixture(), event = UUID()
        f.coordinator.settings.enabled = false
        var resets = 0; f.coordinator.resetRecognition = { resets += 1 }
        let status = try await prepare(f, event: event)
        XCTAssertEqual(status["phase"] as? String, "unavailable")
        XCTAssertEqual(resets, 0)
        XCTAssertFalse(f.coordinator.interceptsSpeech)
        f.clock.time += 11; f.coordinator.checkBounds()
        XCTAssertFalse(f.coordinator.hasOpenAttempt)
        await f.coordinator.shutdown()
    }
    func testSharedSpellingEditsCancelOnlyAffectedUnsentAttempt() async throws {
        guard let expected = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              expected == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: expected).appendingPathComponent("control-fixture-owner").path)
        else { throw XCTSkip("Run scripts/test-control-integration.sh to supply an isolated home.") }
        let saved = UserDefaults.standard.object(forKey: "phraseDictionaries")
        let similar = UserDefaults.standard.object(forKey: "similarPhrases")
        defer {
            UserDefaults.standard.set(saved, forKey: "phraseDictionaries")
            UserDefaults.standard.set(similar, forKey: "similarPhrases")
        }
        let model = GateModel(enableSpotifyControl: false)
        let f = try fixture(coordinator: model.notificationReplies), first = UUID(), second = UUID()
        model.similarPhrases = true
        _ = try await prepare(f, event: first)
        model.phraseDictionaries["unrelated-fixture-key"] = ["fixture spelling"]
        XCTAssertEqual(try f.coordinator.status(event: first, instance: f.coordinator.instance)["phase"] as? String, "preparing")
        model.phraseDictionaries[NotificationReplyCore.Commands.endReplySpellingKey] = ["Finish response"]
        XCTAssertEqual(try f.coordinator.status(event: first, instance: f.coordinator.instance)["reason"] as? String, "settings-changed")
        _ = try f.coordinator.mediaReleased(event: first, instance: f.coordinator.instance, released: true)
        _ = try await prepare(f, event: second)
        model.similarPhrases = false
        XCTAssertEqual(try f.coordinator.status(event: second, instance: f.coordinator.instance)["reason"] as? String, "settings-changed")
        XCTAssertEqual(f.calls.count, 0)
        _ = try f.coordinator.mediaReleased(event: second, instance: f.coordinator.instance, released: true)
        await f.coordinator.shutdown()
    }
    func testIntentionalCaptureCutKeepsReplyHUDUntilGenuinePostCutLoss() async throws {
        let f = try fixture(), event = UUID()
        let cursor = SpeechCaptureCursor(clock: { f.clock.time })
        var boundary = SpeechContextBoundary(), continuity = SpeechContinuity()
        var phases: [NotificationReplyCore.Phase] = []
        f.coordinator.showPresentation = { if let value = $0 { phases.append(value.phase) } }
        let consumed = cursor.capture()
        XCTAssertFalse(try XCTUnwrap(continuity.admit(sequence: consumed.sequence, capturedAt: consumed.capturedAt, boundary: &boundary)).audioGap)
        let queued = [cursor.capture(), cursor.capture()]
        f.coordinator.resetRecognition = {
            let cut = cursor.boundary()
            boundary.invalidate(at: cut.capturedAt, nextSequence: cut.sequence)
        }
        _ = try await prepare(f, event: event)
        for frame in queued {
            XCTAssertNil(continuity.admit(sequence: frame.sequence, capturedAt: frame.capturedAt, boundary: &boundary))
        }
        let fresh = cursor.capture()
        let admitted = try XCTUnwrap(continuity.admit(sequence: fresh.sequence, capturedAt: fresh.capturedAt, boundary: &boundary))
        XCTAssertTrue(admitted.contextReset); XCTAssertFalse(admitted.audioGap)
        // This is the listener's actual interruption predicate, using the same
        // shared admission policy and real coordinator; no model/capture is started.
        if admitted.audioGap { f.coordinator.interrupted("recognition-audio-gap") }
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "preparing")
        f.clock.time = 100.1
        _ = try f.coordinator.audioStarted(event: event, instance: f.coordinator.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
        f.clock.time = 100.2
        _ = try f.coordinator.audioEnded(event: event, instance: f.coordinator.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time, completed: true)
        f.clock.time = 101
        f.coordinator.recognized(.init(batch: UUID(), text: "Reply yes", words: [
            .init(text: "reply", start: 100.5, end: 100.6), .init(text: "yes", start: 100.7, end: 100.8)], stableWords: 1))
        XCTAssertEqual(phases.suffix(4), [.preparing, .announcing, .waiting, .composing])
        XCTAssertTrue(f.coordinator.interceptsSpeech)
        _ = cursor.capture() // One genuinely missing post-boundary buffer.
        let afterLoss = cursor.capture()
        let lost = try XCTUnwrap(continuity.admit(sequence: afterLoss.sequence, capturedAt: afterLoss.capturedAt, boundary: &boundary))
        XCTAssertTrue(lost.audioGap)
        if lost.audioGap { f.coordinator.interrupted("recognition-audio-gap") }
        let status = try f.coordinator.status(event: event, instance: f.coordinator.instance)
        XCTAssertEqual(status["phase"] as? String, "cancelled")
        XCTAssertEqual(status["reason"] as? String, "recognition-audio-gap")
        XCTAssertFalse(f.coordinator.interceptsSpeech); XCTAssertEqual(f.calls.count, 0)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.shutdown()
    }
    func testFirstMissingPostCutBufferStillCancelsBeforeAnnouncement() async throws {
        let f = try fixture(), event = UUID()
        var boundary = SpeechContextBoundary(), continuity = SpeechContinuity()
        f.coordinator.resetRecognition = { boundary.invalidate(at: f.clock.time, nextSequence: 3) }
        _ = try await prepare(f, event: event)
        let admitted = try XCTUnwrap(continuity.admit(sequence: 5, capturedAt: f.clock.time + 0.1, boundary: &boundary))
        XCTAssertTrue(admitted.contextReset); XCTAssertTrue(admitted.audioGap)
        XCTAssertEqual(continuity.missingFrames, 2)
        if admitted.audioGap { f.coordinator.interrupted("recognition-audio-gap") }
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "recognition-audio-gap")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testReplySettingsShareSavedValuesAndCancelAnUnsentAttempt() async throws {
        let f = try fixture(), event = UUID(), settings = f.coordinator.settings
        _ = try await prepare(f, event: event)
        settings.replySeconds = 180
        XCTAssertEqual(settings.limits.replySeconds, 180)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "settings-changed")
        settings.idleSeconds = 1; XCTAssertEqual(settings.idleSeconds, 10)
        settings.replySeconds = 999; XCTAssertEqual(settings.replySeconds, 180)
        settings.enabled = false
        XCTAssertEqual(f.coordinator.readiness, .disabled)
        XCTAssertEqual(f.calls.count, 0)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: false)
        await f.coordinator.shutdown()
    }
    func testNativeHUDIsCompactKeepsPlacementAndDismissesUnsentWithoutShowingWindows() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("No native displays available for inert panel layout") }
        let f = try fixture(), event = UUID()
        let name = "HChatHUDTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let active = NSApplication.shared.isActive
        let hud = NotificationReplyHUD(defaults: defaults, showsWindows: false)
        hud.onDismiss = { f.coordinator.dismiss(event: $0) }
        f.coordinator.showPresentation = { hud.show($0) }
        _ = try await prepare(f, event: event)
        XCTAssertEqual(hud.panels.count, NSScreen.screens.count)
        let panel = try XCTUnwrap(hud.panels.values.first)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.isMovable, "The actual borderless native panel must permit a header drag")
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.host.acceptsFirstMouse(for: nil))
        let moved = panel.frame.offsetBy(dx: 12, dy: -12)
        panel.setFrame(moved, display: false)
        panel.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        hud.show(.init(event: event, phase: .composing, reason: "", spokenText: String(repeating: "Original notification stays complete. ", count: 55), replyText: String(repeating: "These are the live reply words. ", count: 30)))
        XCTAssertEqual(panel.frame.minX, moved.minX, accuracy: 0.1)
        XCTAssertEqual(panel.frame.maxY, moved.maxY, accuracy: 0.1)
        XCTAssertLessThanOrEqual(panel.frame.height, 260)
        let longHeight = panel.frame.height
        XCTAssertLessThanOrEqual(panel.host.fittingSize.height, panel.frame.height + 1, "Both scroll areas must fit without cropping the controls")
        try captureInertPanel(panel, name: "long-reply")
        hud.show(.init(event: event, phase: .composing, reason: "", spokenText: "Ready.", replyText: "Yes."))
        XCTAssertLessThan(panel.frame.height, longHeight, "Short content must fit instead of forcing the height cap")
        XCTAssertLessThanOrEqual(panel.frame.height, 208)
        XCTAssertEqual(panel.frame.maxY, moved.maxY, accuracy: 0.1)
        try captureInertPanel(panel, name: "short-reply")
        hud.show(.init(event: event, phase: .waiting, reason: "", spokenText: "Ready."))
        XCTAssertLessThanOrEqual(panel.host.fittingSize.height, panel.frame.height + 1)
        try captureInertPanel(panel, name: "waiting-five-seconds")
        for phase in [NotificationReplyCore.Phase.preparing, .announcing, .waiting, .composing, .releasing, .cancelled, .unavailable, .queued, .delivered] {
            hud.show(.init(event: event, phase: phase, reason: "", spokenText: "Exact original notification remains readable.", replyText: phase == .composing ? "Reply draft." : ""))
            XCTAssertLessThanOrEqual(panel.host.fittingSize.height, panel.frame.height + 1)
            try captureInertPanel(panel, name: "reference-" + phase.rawValue)
        }
        hud.show(.init(event: event, phase: .waiting, reason: "", spokenText: "Exact original notification remains readable.", confirmingReply: true))
        XCTAssertLessThanOrEqual(panel.host.fittingSize.height, panel.frame.height + 1)
        try captureInertPanel(panel, name: "reference-confirming")
        hud.show(.init(event: event, phase: .announcing, reason: "", spokenText: "Exact original notification remains readable.", canSayStopSpeaking: true))
        XCTAssertLessThanOrEqual(panel.host.fittingSize.height, panel.frame.height + 1)
        try captureInertPanel(panel, name: "announcing-stop-speaking")
        hud.show(.init(event: event, phase: .cancelled, reason: "user-stop-speaking", spokenText: "Exact original notification remains readable."))
        try captureInertPanel(panel, name: "stop-requested")
        XCTAssertFalse(panel.isVisible)
        hud.dismissCurrent()
        XCTAssertTrue(hud.panels.isEmpty)
        XCTAssertFalse(f.coordinator.interceptsSpeech)
        let result = try f.coordinator.status(event: event, instance: f.coordinator.instance)
        XCTAssertEqual(result["reason"] as? String, "user-dismissed")
        XCTAssertEqual(result["releaseRequested"] as? Bool, true)
        hud.show(.init(event: event, phase: .cancelled, reason: "user-dismissed", spokenText: ""))
        XCTAssertTrue(hud.panels.isEmpty, "A later update cannot reopen a dismissed event")
        XCTAssertEqual(f.calls.count, 0)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
        XCTAssertEqual(NSApplication.shared.isActive, active)
        await f.coordinator.shutdown()
    }
    func testNotificationSpellingSettingsRenderWithoutShowingWindows() throws {
        let name = "HChatSpellingSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = NotificationReplySettings(defaults: defaults); settings.enabled = true
        var reply: [String]?, end: [String]?, cancel: [String]?, stop: [String]?
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 720, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: Form {
            NotificationReplySettingsSection(settings: settings,
                replySpellings: Binding(get: { reply }, set: { reply = $0 }),
                endReplySpellings: Binding(get: { end }, set: { end = $0 }),
                cancelReplySpellings: Binding(get: { cancel }, set: { cancel = $0 }),
                stopSpeakingSpellings: Binding(get: { stop }, set: { stop = $0 }),
                similar: true, readiness: { .ready })
        }.formStyle(.grouped))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        try captureInertView(view, name: "notification-spellings-settings")
        XCTAssertFalse(window.isVisible, "Settings visual QC must not cover a working screen")
        XCTAssertNil(reply); XCTAssertNil(end); XCTAssertNil(cancel, "Rendering must not save a default over the user's spelling choice")
        XCTAssertNil(stop, "Rendering must not save a stop-control override")
    }
    private func captureInertPanel(_ panel: NotificationReplyHUD.Panel, name: String) throws {
        XCTAssertFalse(panel.isVisible)
        let view = try XCTUnwrap(panel.contentView)
        try captureInertView(view, name: name)
        XCTAssertFalse(panel.isVisible, "An offscreen visual check must never show a working-screen panel")
    }
    // The existing offscreen panel renderer also captures the actual Settings view. — GPT-6.1 Sol
    private func captureInertView(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HCHAT_NOTIFICATION_HUD_CAPTURE_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }
    func testEarlyMediaReleaseAndStaleOriginNeverSend() async throws {
        let f = try fixture(), early = UUID()
        _ = try await prepare(f, event: early)
        _ = try f.coordinator.mediaReleased(event: early, instance: f.coordinator.instance, released: true)
        XCTAssertFalse(f.coordinator.interceptsSpeech)
        XCTAssertEqual(f.calls.count, 0)
        let event = UUID(); _ = try await prepare(f, event: event); try finish(f, event: event)
        let handle = try FileHandle(forWritingTo: f.origin.rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"newer typed input\"}}\n".utf8))
        try handle.close()
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testRepeatedCancellationHasBoundedMetadataAndNoObservers() async throws {
        let f = try fixture()
        for _ in 0..<125 {
            let event = UUID(); _ = try await prepare(f, event: event)
            _ = try f.coordinator.cancel(event: event, instance: f.coordinator.instance, reason: "fixture")
            _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: false)
        }
        XCTAssertLessThanOrEqual(f.coordinator.lifecycleCounts.sessions, 97)
        XCTAssertEqual(f.coordinator.lifecycleCounts.watchers, 0)
        XCTAssertEqual(f.coordinator.lifecycleCounts.textBytes, 0)
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testSharedListenerAudioLossCancelsUnsentReply() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        f.coordinator.interrupted("recognition-audio-gap")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 0)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "recognition-audio-gap")
        XCTAssertEqual(f.coordinator.lifecycleCounts.watchers, 0)
        await f.coordinator.shutdown()
    }
    func testPriorityAfterQueueAcceptanceDoesNotClaimUnsentOrReplay() async throws {
        let f = try fixture(), event = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), calls = f.calls
        f.coordinator.queueCommand = {
            calls.append($0); entered.signal()
            return release.wait(timeout: .now() + 5) == .success ? 0 : 1
        }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        let running = await Task.detached { entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(running)
        f.coordinator.interrupted("voiceActive")
        XCTAssertNotEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "cancelled")
        release.signal()
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "queued")
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true)
        XCTAssertEqual(f.calls.count, 1)
        await f.coordinator.shutdown()
    }
    func testLostPrepareResponseExpiresWithoutOwner() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        f.clock.time += 11; f.coordinator.checkBounds()
        XCTAssertFalse(f.coordinator.hasOpenAttempt)
        XCTAssertFalse(f.coordinator.interceptsSpeech)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "announcement-not-started")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testRequestExpiresDuringOriginValidationWithoutQueuing() async throws {
        let f = try fixture(), event = UUID()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        f.coordinator.validateOrigin = { origin in
            try origin.validate(); entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw NotificationReplyOrigin.Failure.originUnavailable }
        }
        _ = try await prepare(f, event: event); try finish(f, event: event)
        let expiry = f.clock.wallBase + f.clock.time + 1
        _ = try f.coordinator.mediaReleased(event: event, instance: f.coordinator.instance, released: true, expiresAt: expiry)
        let validating = await Task.detached { entered.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(validating)
        f.clock.time += 2; release.signal()
        await f.coordinator.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 0)
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["phase"] as? String, "unavailable")
        await f.coordinator.shutdown()
    }
    func testLiveSetupRemainsFiniteAndLostOwnerExpires() async throws {
        let f = try fixture(), event = UUID()
        _ = try await prepare(f, event: event)
        for step in stride(from: 109.0, through: 279.0, by: 9) {
            f.clock.time = step
            _ = try f.coordinator.status(event: event, instance: f.coordinator.instance)
            f.coordinator.checkBounds()
        }
        f.clock.time = 281; f.coordinator.checkBounds()
        XCTAssertEqual(try f.coordinator.status(event: event, instance: f.coordinator.instance)["reason"] as? String, "announcement-setup-limit")
        let lost = UUID(); _ = try await prepare(f, event: lost)
        _ = try f.coordinator.status(event: lost, instance: f.coordinator.instance)
        f.clock.time += 11; f.coordinator.checkBounds()
        XCTAssertEqual(try f.coordinator.status(event: lost, instance: f.coordinator.instance)["reason"] as? String, "announcement-not-started")
        XCTAssertEqual(f.calls.count, 0)
        await f.coordinator.shutdown()
    }
    func testLiveOwnerAllowsDelayedSetupAndAnchorsToActualAudioExit() async throws {
        let f = try fixture(), event = UUID(), model = f.coordinator
        _ = try await prepare(f, event: event)
        for at in [104.0, 108.0, 112.0] {
            f.clock.time = at
            _ = try model.status(event: event, instance: model.instance)
            model.checkBounds()
        }
        XCTAssertEqual(try model.status(event: event, instance: model.instance)["phase"] as? String, "preparing")
        f.clock.time = 112.1
        _ = try model.audioStarted(event: event, instance: model.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time)
        f.clock.time = 115
        _ = try model.audioEnded(event: event, instance: model.instance, uptime: f.clock.time, wall: f.clock.wallBase + f.clock.time, completed: true)
        f.clock.time = 118
        model.recognized(.init(batch: UUID(), text: "Reply yes End reply", words: [
            .init(text: "reply", start: 116, end: 116.1), .init(text: "yes", start: 116.2, end: 116.3),
            .init(text: "end", start: 117, end: 117.1), .init(text: "reply", start: 117.2, end: 117.3)], stableWords: 4))
        _ = try model.mediaReleased(event: event, instance: model.instance, released: true)
        await model.waitForPendingDelivery()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertEqual(try model.status(event: event, instance: model.instance)["phase"] as? String, "queued")
        await model.shutdown()
    }
}
