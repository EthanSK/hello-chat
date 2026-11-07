// Exercise volume ownership and crash recovery with injected Spotify/storage.
// These tests never send Apple Events or touch real playback and call controls.
import Foundation

@main enum SpotifyVolumeTests {
    static func check(_ condition: Bool) { precondition(condition) }
    final class Fixture {
        var volume: Int? = 80
        var receipt: SpotifyVolumeLease?
        var writes: [Int] = []
        var events: [String] = []
        var failSave = false
        var failConfirmedSave = false
        var failWrite = false
        var changeBeforeWrite: Int?
        var truncateCap = false
        func session() -> SpotifyVolumeSession {
            SpotifyVolumeSession(access: .init(read: { self.volume }, write: { value, expected, exact in
                self.events.append("write:\(value)")
                if let changed = self.changeBeforeWrite { self.volume = changed; self.changeBeforeWrite = nil }
                guard self.volume == expected else { throw CocoaError(.fileWriteUnknown) }
                if self.failWrite { throw CocoaError(.fileWriteUnknown) }
                let actual = self.truncateCap && !exact ? value - 1 : value
                self.volume = actual; self.writes.append(value)
                return actual
            }, load: { self.receipt }, save: { value in
                self.events.append("save:\(value?.original.description ?? "nil")")
                if self.failSave || (self.failConfirmedSave && value?.confirmed == true) { throw CocoaError(.fileWriteUnknown) }
                self.receipt = value
            }))
        }
    }

    static func main() throws {
        let f = Fixture(), s = f.session()
        check(try s.reconcile(.active) == .lowered)
        precondition(f.volume == 30 && f.receipt?.original == 80)
        precondition(Array(f.events.prefix(2)) == ["save:80", "write:30"], "Save original before mutation")
        _ = try s.reconcile(.active); _ = try s.reconcile(.active)
        precondition(f.writes == [30], "Duplicate/overlapping call signals never overwrite the original")
        _ = try s.reconcile(.unknown)
        precondition(f.volume == 30 && f.receipt != nil, "Unknown and reconnect do not restore")
        check(try s.reconcile(.inactive) == .restored)
        precondition(f.volume == 80 && f.receipt == nil && f.writes == [30, 80])
        _ = try s.reconcile(.inactive)
        precondition(f.writes.count == 2, "Duplicate End does nothing")

        let quiet = Fixture(); quiet.volume = 15
        let quietSession = quiet.session()
        _ = try quietSession.reconcile(.active); _ = try quietSession.reconcile(.inactive)
        precondition(quiet.volume == 15 && quiet.writes.isEmpty, "Never raise a quieter slider")

        let manual = Fixture(), manualSession = manual.session()
        _ = try manualSession.reconcile(.active); manual.volume = 55
        check(try manualSession.reconcile(.inactive) == .manualChange)
        precondition(manual.volume == 55 && manual.receipt == nil && manual.writes == [30])

        let closed = Fixture(); closed.volume = nil
        let closedSession = closed.session()
        check(try closedSession.reconcile(.active) == .spotifyClosed)
        precondition(closed.receipt == nil && closed.writes.isEmpty)
        closed.volume = 90; _ = try closedSession.reconcile(.active)
        closed.volume = nil; _ = try closedSession.reconcile(.inactive)
        precondition(closed.receipt?.original == 90, "Closed Spotify is not launched; retain pending restore")
        closed.volume = 30; _ = try closedSession.reconcile(.inactive)
        precondition(closed.volume == 90 && closed.receipt == nil)

        let crash = Fixture(); crash.failConfirmedSave = true
        do { _ = try crash.session().reconcile(.active); fatalError("Save failure not surfaced") } catch { }
        precondition(crash.volume == 30 && crash.receipt?.original == 80 && crash.receipt?.confirmed == false)
        crash.failConfirmedSave = false
        _ = try crash.session().reconcile(.inactive)
        precondition(crash.volume == 80, "A crash after mutation preserves the original")

        let restarted = Fixture(); _ = try restarted.session().reconcile(.active)
        let replacement = restarted.session()
        _ = try replacement.reconcile(.active)
        precondition(restarted.writes == [30] && restarted.receipt?.original == 80)
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
        roundedCrash.receipt = SpotifyVolumeLease(original: 57, applied: 30)
        _ = try roundedCrash.session().reconcile(.inactive)
        precondition(roundedCrash.volume == 57 && roundedCrash.receipt == nil,
                     "Interrupted rounding correction preserves restoration")
        let roundedSessionFixture = Fixture(); roundedSessionFixture.truncateCap = true
        let roundedSession = roundedSessionFixture.session()
        _ = try roundedSession.reconcile(.active)
        precondition(roundedSessionFixture.volume == 29 && roundedSessionFixture.receipt?.applied == 29 &&
                     roundedSessionFixture.receipt?.confirmed == true)
        _ = try roundedSessionFixture.session().reconcile(.inactive)
        precondition(roundedSessionFixture.volume == 80 && roundedSessionFixture.receipt == nil,
                     "Confirmed native readback survives restart and restores")
        let manualRestart = Fixture(), beforeQuit = manualRestart.session()
        _ = try beforeQuit.reconcile(.active); manualRestart.volume = 50
        _ = try beforeQuit.reconcile(.inactive, preservingManualOverride: true)
        precondition(manualRestart.receipt?.original == 80 && manualRestart.volume == 50)
        let afterRestart = manualRestart.session()
        _ = try afterRestart.reconcile(.active)
        precondition(manualRestart.volume == 50 && manualRestart.writes == [30])
        _ = try afterRestart.reconcile(.inactive)
        precondition(manualRestart.receipt == nil && manualRestart.volume == 50)

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
        _ = call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: true, applicationAbsent: true)
        _ = call.observe(controlsPresent: false, controlsComplete: true, persistedCallActive: true, applicationAbsent: true)
        precondition(call.presence == .inactive, "Actual process exit ends even stale persisted sessions")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let receipt = SpotifyVolumeReceipt(url: directory.appendingPathComponent("lease/restore.json"))
        try receipt.save(SpotifyVolumeLease(original: 77, applied: 30))
        check(try receipt.load()?.original == 77)
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.url.path)[.posixPermissions] as? Int
        precondition(permissions == 0o600)
        try receipt.save(nil); check(try receipt.load() == nil)
        print("Spotify volume ownership, recovery and call-decision checks passed")
    }
}
