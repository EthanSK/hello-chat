// Exercise volume ownership and crash recovery with injected Spotify/storage.
// These tests never send Apple Events or touch real playback and call controls.
import Foundation

@main enum SpotifyVolumeTests {
    static func check(_ condition: Bool) { precondition(condition) }
    final class Fixture {
        var volume: Int? = 80
        var receipt: SpotifyVolumeLease?
        var writes: [Int] = []
        var exactWrites: [Bool] = []
        var events: [String] = []
        var failSave = false
        var failConfirmedSave = false
        var failRestoredSave = false
        var failWrite = false
        var changeBeforeWrite: Int?
        func session() -> SpotifyVolumeSession {
            SpotifyVolumeSession(access: .init(read: { self.volume }, write: { value, expected, exact in
                self.events.append("write:\(value)")
                if let changed = self.changeBeforeWrite { self.volume = changed; self.changeBeforeWrite = nil }
                guard self.volume == expected else { throw CocoaError(.fileWriteUnknown) }
                if self.failWrite { throw CocoaError(.fileWriteUnknown) }
                self.volume = value; self.writes.append(value)
                self.exactWrites.append(exact)
                return value
            }, load: { self.receipt }, save: { value in
                self.events.append("save:\(value?.original.description ?? "nil")")
                if self.failSave || (self.failConfirmedSave && value?.confirmed == true) ||
                    (self.failRestoredSave && value?.mutePhase == .restored) {
                    throw CocoaError(.fileWriteUnknown)
                }
                self.receipt = value
            }))
        }
    }

    static func main() throws {
        let f = Fixture(), s = f.session()
        check(try s.reconcile(.active) == .lowered)
        precondition(f.volume == 50 && f.receipt?.original == 80 && f.receipt?.cap == 50)
        precondition(f.exactWrites == [true], "New 50% writes require exact native readback")
        precondition(Array(f.events.prefix(2)) == ["save:80", "write:50"], "Save original before mutation")
        _ = try s.reconcile(.active); _ = try s.reconcile(.active)
        precondition(f.writes == [50], "Duplicate/overlapping call signals never overwrite the original")
        _ = try s.reconcile(.unknown)
        precondition(f.volume == 50 && f.receipt != nil, "Unknown and reconnect do not restore")
        check(try s.reconcile(.inactive) == .restored)
        precondition(f.volume == 80 && f.receipt == nil && f.writes == [50, 80])
        _ = try s.reconcile(.inactive)
        precondition(f.writes.count == 2, "Duplicate End does nothing")
        try microphonePhraseVolume()

        let quiet = Fixture(); quiet.volume = 45
        let quietSession = quiet.session()
        _ = try quietSession.reconcile(.active); _ = try quietSession.reconcile(.inactive)
        precondition(quiet.volume == 45 && quiet.writes.isEmpty, "Never raise a quieter slider")
        let atCap = Fixture(); atCap.volume = 50
        let atCapSession = atCap.session()
        _ = try atCapSession.reconcile(.active); _ = try atCapSession.reconcile(.inactive)
        precondition(atCap.volume == 50 && atCap.writes.isEmpty, "An existing 50% stays untouched")

        let manual = Fixture(), manualSession = manual.session()
        _ = try manualSession.reconcile(.active); manual.volume = 55
        check(try manualSession.reconcile(.inactive) == .manualChange)
        precondition(manual.volume == 55 && manual.receipt == nil && manual.writes == [50])

        let closed = Fixture(); closed.volume = nil
        let closedSession = closed.session()
        check(try closedSession.reconcile(.active) == .spotifyClosed)
        precondition(closed.receipt == nil && closed.writes.isEmpty)
        closed.volume = 90; _ = try closedSession.reconcile(.active)
        closed.volume = nil; _ = try closedSession.reconcile(.inactive)
        precondition(closed.receipt?.original == 90, "Closed Spotify is not launched; retain pending restore")
        closed.volume = 50; _ = try closedSession.reconcile(.inactive)
        precondition(closed.volume == 90 && closed.receipt == nil)

        let crash = Fixture(); crash.failConfirmedSave = true
        do { _ = try crash.session().reconcile(.active); fatalError("Save failure not surfaced") } catch { }
        precondition(crash.volume == 50 && crash.receipt?.original == 80 && crash.receipt?.confirmed == false)
        crash.failConfirmedSave = false
        _ = try crash.session().reconcile(.inactive)
        precondition(crash.volume == 80, "A crash after mutation preserves the original")

        let restarted = Fixture(); _ = try restarted.session().reconcile(.active)
        let replacement = restarted.session()
        _ = try replacement.reconcile(.active)
        precondition(restarted.writes == [50] && restarted.receipt?.original == 80)
        _ = try replacement.reconcile(.inactive)
        precondition(restarted.volume == 80)

        let failed = Fixture(); failed.failSave = true
        do { _ = try failed.session().reconcile(.active); fatalError("Storage failure accepted") } catch { }
        precondition(failed.volume == 80 && failed.writes.isEmpty, "No change without a saved original")

        let moved = Fixture(); moved.changeBeforeWrite = 55
        let movedSession = moved.session()
        do { _ = try movedSession.reconcile(.active); fatalError("Intervening adjustment overwritten") } catch { }
        precondition(moved.volume == 55 && moved.writes.isEmpty)
        _ = try movedSession.reconcile(.inactive)
        precondition(moved.volume == 55 && moved.receipt == nil)

        let restoreFailure = Fixture(), restoreSession = restoreFailure.session()
        _ = try restoreSession.reconcile(.active); restoreFailure.failWrite = true
        do { _ = try restoreSession.reconcile(.inactive); fatalError("Restore failure accepted") } catch { }
        precondition(restoreFailure.receipt?.original == 80)
        restoreFailure.failWrite = false; _ = try restoreSession.reconcile(.inactive)
        precondition(restoreFailure.volume == 80 && restoreFailure.receipt == nil)

        // Real Spotify returned 29 for a 30 request. Exercise the native write
        // algorithm independently, including a user adjustment between writes.
        var roundedVolume = 57, roundedWrites: [Int] = []
        let applied = try SpotifyVolumeWrite.perform(30, expected: 57, read: { roundedVolume }, exact: false, set: { value in
            roundedWrites.append(value); roundedVolume = value - 1
        })
        precondition(roundedVolume == 29 && applied == 29 && roundedWrites == [30])
        _ = try SpotifyVolumeWrite.perform(57, expected: 29, read: { roundedVolume }, exact: true, set: { value in
            roundedWrites.append(value); roundedVolume = value - 1
        })
        precondition(roundedVolume == 57 && roundedWrites.suffix(2) == [57, 58])
        roundedVolume = 80; roundedWrites = []
        let exactCap = try SpotifyVolumeWrite.perform(50, expected: 80, read: { roundedVolume }, exact: true, set: { value in
            roundedWrites.append(value); roundedVolume = value - 1
        })
        precondition(exactCap == 50 && roundedVolume == 50 && roundedWrites == [50, 51],
                     "The new preference matches the requested native 50 readback")
        roundedVolume = 57
        var reads = 0
        do {
            _ = try SpotifyVolumeWrite.perform(30, expected: 57, read: {
                reads += 1
                if reads == 3 { roundedVolume = 50 }
                return roundedVolume
            }, exact: true, set: { roundedVolume = $0 - 1 })
            fatalError("Manual change between compensation writes overwritten")
        } catch { }
        precondition(roundedVolume == 50)
        let roundedCrash = Fixture(); roundedCrash.volume = 29
        let legacy = Data(#"{"version":1,"original":57,"applied":30,"confirmed":false}"#.utf8)
        roundedCrash.receipt = try JSONDecoder().decode(SpotifyVolumeLease.self, from: legacy)
        _ = try roundedCrash.session().reconcile(.inactive)
        precondition(roundedCrash.volume == 57 && roundedCrash.receipt == nil,
                     "Interrupted rounding correction preserves restoration")
        let roundedSessionFixture = Fixture(); roundedSessionFixture.volume = 49
        roundedSessionFixture.receipt = SpotifyVolumeLease(original: 80, applied: 50)
        _ = try roundedSessionFixture.session().reconcile(.inactive)
        precondition(roundedSessionFixture.volume == 80 && roundedSessionFixture.receipt == nil,
                     "Confirmed native readback survives restart and restores")
        let manualRestart = Fixture(), beforeQuit = manualRestart.session()
        _ = try beforeQuit.reconcile(.active); manualRestart.volume = 65
        _ = try beforeQuit.reconcile(.inactive, preservingManualOverride: true)
        precondition(manualRestart.receipt?.original == 80 && manualRestart.volume == 65)
        let afterRestart = manualRestart.session()
        _ = try afterRestart.reconcile(.active)
        precondition(manualRestart.volume == 65 && manualRestart.writes == [50])
        _ = try afterRestart.reconcile(.inactive)
        precondition(manualRestart.receipt == nil && manualRestart.volume == 65)

        let replaced = Fixture(), replacedSession = replaced.session()
        _ = try replacedSession.reconcile(.active, callIdentifier: "call-A")
        replaced.volume = 65
        // There need not be an inactive callback between saved call identities.
        _ = try replaced.session().reconcile(.active, callIdentifier: "call-B")
        precondition(replaced.volume == 50 && replaced.receipt?.original == 65 &&
                     replaced.receipt?.callIdentifier == "call-B")
        _ = try replaced.session().reconcile(.inactive)
        precondition(replaced.volume == 65 && replaced.receipt == nil)

        let legacyOverride = Fixture(); legacyOverride.volume = 50
        legacyOverride.receipt = try JSONDecoder().decode(SpotifyVolumeLease.self,
            from: Data(#"{"version":1,"original":50,"applied":29,"confirmed":true,"callIdentifier":"current"}"#.utf8))
        let upgradedSession = legacyOverride.session()
        _ = try upgradedSession.reconcile(.active, callIdentifier: "current")
        precondition(legacyOverride.volume == 50 && legacyOverride.writes.isEmpty,
                     "Installing the 50% policy preserves this call's old manual override")
        _ = try upgradedSession.reconcile(.inactive)
        precondition(legacyOverride.volume == 50 && legacyOverride.receipt == nil)
        let legacyPending = Fixture()
        legacyPending.receipt = try JSONDecoder().decode(SpotifyVolumeLease.self,
            from: Data(#"{"version":1,"original":80,"applied":30,"confirmed":false}"#.utf8))
        _ = try legacyPending.session().reconcile(.active)
        precondition(legacyPending.volume == 30 && legacyPending.exactWrites == [false] &&
                     legacyPending.receipt?.appliedCap == 30,
                     "A pending legacy receipt keeps its old ownership until the call ends")
        _ = try legacyPending.session().reconcile(.inactive)
        precondition(legacyPending.volume == 80 && legacyPending.receipt == nil)

        var boundaries = SavedCallBoundaries()
        _ = boundaries.observe(ledger(["A"]), controlsPresent: true, controlsComplete: true)
        let replacementBoundary = boundaries.observe(ledger(["B"], ended: ["A"]), controlsPresent: true, controlsComplete: true)
        precondition(replacementBoundary.endPrevious && !replacementBoundary.suppressControls,
                     "Active-to-active replacement still closes the old call")
        let knownEnd = boundaries.observe(ledger([], ended: ["A", "B"]), controlsPresent: true, controlsComplete: true)
        precondition(knownEnd.endPrevious && knownEnd.suppressControls,
                     "Final saved End outranks stale buttons")
        precondition(boundaries.observe(ledger([], ended: ["A", "B"]), controlsPresent: true, controlsComplete: true).suppressControls)
        _ = boundaries.observe(ledger([], ended: ["A", "B"]), controlsPresent: false, controlsComplete: true)
        precondition(!boundaries.observe(ledger([], ended: ["A", "B"]), controlsPresent: true, controlsComplete: true).suppressControls,
                     "A later temporary call can use fresh controls")
        _ = boundaries.observe(ledger(["C"], ended: ["A", "B"]), controlsPresent: true, controlsComplete: true)
        precondition(!boundaries.observe(nil, controlsPresent: false, controlsComplete: false).endPrevious &&
                     boundaries.hasActiveCall, "Unavailable metadata retains the known call")
        precondition(!boundaries.observe(ledger(["C", "D"]), controlsPresent: true, controlsComplete: true).endPrevious)
        precondition(!boundaries.observe(ledger(["D"], ended: ["C"]), controlsPresent: true, controlsComplete: true).endPrevious,
                     "An overlapping remaining call keeps the shared volume lease")
        // A read bounded by the wrong launch time drops every row. Missing is
        // not ended: no saved End, no stale-button override, no stale vouching.
        let missing = boundaries.observe(ledger([]), controlsPresent: true, controlsComplete: true)
        precondition(!missing.endPrevious && !missing.suppressControls && missing.vanished && !boundaries.hasActiveCall,
                     "A session that disappears without its own End record is indeterminate")
        _ = boundaries.observe(ledger(["E"]), controlsPresent: true, controlsComplete: true)
        let changed = boundaries.observe(ledger(["F"]), controlsPresent: true, controlsComplete: true)
        precondition(!changed.endPrevious && changed.vanished && boundaries.callIdentifier == "F",
                     "Without an End record, the changed identity closes the old lease downstream")
        try callPresenceReplays()

        var call = VoiceCallDecision()
        precondition(!call.observe(controlsPresent: true, controlsComplete: true, persistedCallActive: false, applicationAbsent: false))
        precondition(call.presence == .active, "Temporary call uses actual controls, with no disk record")
        _ = call.observe(controlsPresent: false, controlsComplete: false, persistedCallActive: false, applicationAbsent: false)
        precondition(call.presence == .unknown, "Incomplete scans cannot establish End")
        precondition(call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: false, applicationAbsent: false))
        _ = call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: false, applicationAbsent: false)
        precondition(call.presence == .inactive, "Two completed negative reads confirm a manual End")
        _ = call.observe(controlsPresent: true, controlsComplete: true, persistedCallActive: true, applicationAbsent: false)
        _ = call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: true, applicationAbsent: false)
        precondition(call.presence == .active, "Persisted active session protects transport reconnect")
        precondition(call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: true, applicationAbsent: true)
                     && call.presence == .unknown, "Process exit asks for one immediate confirming read")
        _ = call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: true, applicationAbsent: true)
        precondition(call.presence == .inactive, "Actual process exit ends even stale persisted sessions")
        _ = call.observe(controlsPresent: true, controlsComplete: true, persistedCallActive: false,
                         applicationAbsent: false, savedCallEnded: true)
        precondition(call.presence == .inactive, "Final saved End defeats stale positive controls")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let receipt = SpotifyVolumeReceipt(url: directory.appendingPathComponent("lease/restore.json"))
        try receipt.save(SpotifyVolumeLease(original: 77, applied: 50))
        check(try receipt.load()?.original == 77)
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.url.path)[.posixPermissions] as? Int
        precondition(permissions == 0o600)
        try receipt.save(nil); check(try receipt.load() == nil)
        print("Spotify volume ownership, recovery and call-decision checks passed")
    }

    static func ledger(_ active: Set<String>, ended: Set<String> = []) -> VoiceLedgerSessions {
        VoiceLedgerSessions(active: active, ended: ended)
    }

    static func read(_ controls: String, _ saved: VoiceLedgerSessions?, process: pid_t? = 3735,
                     absent: Bool = false, resolved: Bool = true) -> VoiceCallRead {
        VoiceCallRead(controlsPresent: controls == "present", controlsComplete: controls != "incomplete",
                      applicationAbsent: absent, process: process, ledger: saved, ledgerResolved: resolved)
    }

    // Mirrors SpotifyVoiceVolume.observe: duplicate presence/identity is ignored
    // and only changes reconcile the injected Spotify fixture.
    final class Replay {
        let fixture = Fixture()
        lazy var session = fixture.session()
        var tracker = VoiceCallTracker()
        var presence: VoiceCallPresence = .unknown
        var identifier: String?
        var published: [VoiceCallPresence] = []
        var evidence: [String] = []

        @discardableResult func step(_ read: VoiceCallRead) throws -> Bool {
            let result = tracker.observe(read)
            for observation in result.observations {
                let next = observation.presence == .inactive ? nil : observation.callIdentifier ?? identifier
                guard observation.presence != presence || next != identifier else { continue }
                presence = observation.presence; identifier = next
                published.append(presence); evidence.append(observation.evidence ?? "")
                _ = try session.reconcile(presence, callIdentifier: identifier)
            }
            return result.readAgain
        }
    }

    static func callPresenceReplays() throws {
        // Observed 22:07/22:17 shape: the saved session never ended, but one read
        // could not bind the ledger to the verified Codex launch.
        let glitch = Replay()
        try glitch.step(read("present", ledger(["thread:current"])))
        precondition(glitch.fixture.volume == 50 && glitch.presence == .active)
        try glitch.step(read("incomplete", nil, process: nil, resolved: false))
        try glitch.step(read("present", nil, resolved: false))
        precondition(glitch.presence == .active && glitch.published == [.active] && glitch.fixture.writes == [50],
                     "An unresolved launch keeps the known call instead of restoring")
        precondition(glitch.tracker.observe(read("incomplete", nil, resolved: false)).observations.last?.evidence
                     == "controls=incomplete saved=unresolved")
        // The previous fallback produced an empty read from a too-late cutoff.
        try glitch.step(read("present", ledger([])))
        try glitch.step(read("incomplete", ledger([])))
        try glitch.step(read("present", ledger(["thread:current"])))
        precondition(!glitch.published.contains(.inactive) && glitch.fixture.writes == [50] && glitch.fixture.volume == 50,
                     "A session missing without its End record never restores Spotify")
        // A real End still restores on the first read, even with stale buttons.
        try glitch.step(read("present", ledger([], ended: ["thread:current"])))
        precondition(glitch.presence == .inactive && glitch.fixture.volume == 80 && glitch.fixture.writes == [50, 80])
        precondition(glitch.evidence.last == "controls=present saved=ended")
        try glitch.step(read("present", ledger([], ended: ["thread:current"])))
        precondition(glitch.presence == .inactive, "Saved End outranks stale controls until they clear")

        // Observed 22:14 shape: a temporary-thread session ended and the original
        // thread started a new session four seconds later. Both are real.
        let moved = Replay()
        try moved.step(read("present", ledger(["new:temp"])))
        try moved.step(read("absent", ledger([], ended: ["new:temp"])))
        precondition(moved.presence == .inactive && moved.fixture.writes == [50, 80], "A real End is not delayed")
        try moved.step(read("present", ledger(["original:current"], ended: ["new:temp"])))
        precondition(moved.presence == .active && moved.identifier == "original:current" && moved.fixture.writes == [50, 80, 50])

        // End and Start between two reads still restore, then lower the new call.
        let rapid = Replay()
        try rapid.step(read("present", ledger(["chat:A"])))
        try rapid.step(read("present", ledger(["chat:B"], ended: ["chat:A"])))
        precondition(rapid.published == [.active, .inactive, .active] && rapid.identifier == "chat:B" &&
                     rapid.fixture.writes == [50, 80, 50] && rapid.fixture.receipt?.callIdentifier == "chat:B")

        // Codex exit: one unknown read, then an immediate second read ends it.
        let exit = Replay()
        try exit.step(read("present", ledger(["chat:A"])))
        let confirmExit = try exit.step(read("incomplete", nil, process: nil, absent: true, resolved: false))
        precondition(confirmExit && exit.presence == .unknown && exit.fixture.volume == 50)
        let exitAgain = try exit.step(read("incomplete", nil, process: nil, absent: true, resolved: false))
        precondition(!exitAgain && exit.presence == .inactive && exit.fixture.volume == 80,
                     "Process exit restores without a timer")

        // Codex replaced between reads: its call cannot continue in a new process,
        // even when the new launch time cannot be resolved.
        let replaced = Replay()
        try replaced.step(read("present", ledger(["chat:A"]), process: 100))
        try replaced.step(read("incomplete", nil, process: 200, resolved: false))
        precondition(replaced.presence == .unknown && replaced.published.contains(.inactive) &&
                     replaced.fixture.volume == 80 && replaced.evidence.contains("controls=incomplete saved=process_replaced"))
        precondition(replaced.tracker.activeSessions == nil, "No stale saved session protects the new process")
        // A temporary call in the new process still ends from fresh controls.
        try replaced.step(read("present", nil, process: 200, resolved: false))
        precondition(replaced.presence == .active && replaced.fixture.volume == 50)
        let confirmEnd = try replaced.step(read("absent", nil, process: 200, resolved: false))
        precondition(confirmEnd)
        try replaced.step(read("absent", nil, process: 200, resolved: false))
        precondition(replaced.presence == .inactive && replaced.fixture.volume == 80)

        // Saved startup acceptance alone still cannot lower Spotify.
        let ledgerOnly = Replay()
        try ledgerOnly.step(read("absent", ledger(["chat:A"])))
        try ledgerOnly.step(read("incomplete", ledger(["chat:A"])))
        precondition(ledgerOnly.presence == .unknown && ledgerOnly.fixture.writes.isEmpty)
        // Once established, incomplete reads and a reconnect keep the call.
        try ledgerOnly.step(read("present", ledger(["chat:A"])))
        try ledgerOnly.step(read("absent", ledger(["chat:A"])))
        try ledgerOnly.step(read("incomplete", ledger(["chat:A"])))
        precondition(ledgerOnly.presence == .active && ledgerOnly.fixture.writes == [50])
    }

    static func microphonePhraseVolume() throws {
        let f = Fixture(), session = f.session()
        check(try session.reconcile(.active, callIdentifier: "A") == .lowered)
        check(try session.reconcile(.active, callIdentifier: "A", microphoneMuted: true) == .restored)
        check(try session.reconcile(.active, callIdentifier: "A", microphoneMuted: true) == .unchanged)
        check(try session.reconcile(.unknown) == .uncertain)
        check(try session.reconcile(.active, callIdentifier: "A") == .unchanged)
        precondition(f.writes == [50, 80] && f.receipt?.mutePhase == .restored)
        let restarted = f.session()
        check(try restarted.reconcile(.active, callIdentifier: "A") == .unchanged)
        check(try restarted.reconcile(.active, callIdentifier: "A", microphoneMuted: false) == .lowered)
        check(try restarted.reconcile(.active, callIdentifier: "A", microphoneMuted: false) == .unchanged)
        check(try restarted.reconcile(.active, callIdentifier: "A", microphoneMuted: true) == .restored)
        check(try restarted.reconcile(.inactive) == .unchanged)
        precondition(f.writes == [50, 80, 50, 80] && f.receipt == nil)

        let quiet = Fixture(), quietSession = quiet.session()
        quiet.volume = 35
        _ = try quietSession.reconcile(.active, microphoneMuted: true)
        _ = try quietSession.reconcile(.active, microphoneMuted: false)
        _ = try quietSession.reconcile(.inactive)
        precondition(quiet.volume == 35 && quiet.writes.isEmpty)

        let manual = Fixture(), manualSession = manual.session()
        _ = try manualSession.reconcile(.active)
        _ = try manualSession.reconcile(.active, microphoneMuted: true)
        manual.volume = 60 // A user adjustment while Spotify is at its listening level wins.
        check(try manualSession.reconcile(.active, microphoneMuted: false) == .manualChange)
        manual.volume = 50 // Returning to our old cap does not reacquire ownership.
        check(try manual.session().reconcile(.inactive) == .manualChange)
        precondition(manual.volume == 50 && manual.writes == [50, 80])

        let manualLowered = Fixture(), manualLoweredSession = manualLowered.session()
        _ = try manualLoweredSession.reconcile(.active)
        manualLowered.volume = 30
        check(try manualLoweredSession.reconcile(.active, microphoneMuted: true) == .manualChange)
        check(try manualLoweredSession.reconcile(.active, microphoneMuted: false) == .manualChange)
        precondition(manualLowered.volume == 30 && manualLowered.writes == [50])

        let replacement = Fixture(), replacementSession = replacement.session()
        _ = try replacementSession.reconcile(.active, microphoneMuted: true)
        _ = try replacementSession.reconcile(.active, callIdentifier: "A")
        check(try replacement.session().reconcile(.active, callIdentifier: "B") == .lowered)
        precondition(replacement.writes == [50] && replacement.receipt?.callIdentifier == "B")

        let failed = Fixture(), failedSession = failed.session()
        _ = try failedSession.reconcile(.active)
        failed.failWrite = true
        do {
            _ = try failedSession.reconcile(.active, microphoneMuted: true)
            fatalError("Restore failure accepted")
        } catch { }
        precondition(failed.volume == 50 && failed.receipt?.mutePhase == .restoring)
        failed.failWrite = false
        failed.failRestoredSave = true
        do {
            _ = try failedSession.reconcile(.active, microphoneMuted: true)
            fatalError("Receipt failure accepted")
        } catch { }
        precondition(failed.volume == 80 && failed.receipt?.mutePhase == .restoring)
        failed.failRestoredSave = false
        check(try failed.session().reconcile(.active) == .unchanged)
        check(try failed.session().reconcile(.active, microphoneMuted: false) == .lowered)
        precondition(failed.writes == [50, 80, 50] && failed.receipt?.mutePhase == nil)
    }
}
