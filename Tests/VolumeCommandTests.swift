// Real parsers and reversible Spotify policy; all effects are injected, never live audio. — GPT-6.1 Sol
import Foundation

@main enum VolumeCommandTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let config = PhraseConfiguration(rows: [.outputVolumePhrase: ["Set volume"], .spotifyVolumePhrase: ["Spotify volume"],
            .unsilencePhrase: ["Unshush"], .silentPhrase: ["Shush"], .playVideoPhrase: ["Play video"]])
        let dictionaries = PhraseDictionaries(savedByTrigger: [:], active: config)
        let output = PhrasePattern(slot: .outputVolumePhrase, text: "Set volume", similar: true, dictionaries: dictionaries)
        let spotify = PhrasePattern(slot: .spotifyVolumePhrase, text: "Spotify volume", similar: true, dictionaries: dictionaries)
        func numeric(_ text: String) -> [Int] {
            var parser = SpotifyVolumePhrase(); parser.audio(level: 0.2, seconds: 0.1, at: 0)
            parser.update(text, at: 1, timings: nil)
            return parser.poll(at: 1, prefixes: [output]).map(\.volume)
        }
        func choice(_ text: String) -> [SpotifyVolumeChoice] {
            var parser = SpotifyCommandVolumePhrase(); parser.audio(level: 0.2, seconds: 0.1, at: 0)
            parser.update(text, at: 1, timings: nil)
            return parser.poll(at: 1, prefixes: [spotify]).map(\.value)
        }
        for number in 0...100 {
            for prefix in ["Set volume", "Set volume to", "Set the volume", "Computer volume"] {
                check(numeric("\(prefix) \(number) percent") == [number], "Absolute current-output value")
            }
            check(choice("Spotify volume \(number)") == [.percent(number)], "Spotify numeric path remains")
        }
        for (spoken, number) in [("thirty", 30), ("seventy", 70), ("one hundred", 100), ("zero", 0)] {
            check(numeric("Set volume " + spoken) == [number], "Spoken numbers use the existing decoder")
        }
        for text in ["Set Spotify volume thirty", "Spotify volume thirty", "Set volume normal", "Set volume -1",
            "Set volume one hundred five", "Set volume 101", "Set volume thirty point five", "Set volume thirty tomorrow",
            "Don't set volume thirty", "I said set volume thirty", "Add set volume thirty", "Set volume thirty decibels"] {
            check(numeric(text).isEmpty, "No Spotify theft, invalid values or mentioned/planned control: " + text)
        }
        for prefix in ["Spotify volume", "Set Spotify volume", "Set Spotify volume to"] {
            for (name, expected) in [("normal", SpotifyVolumePreset.normal), ("lower", .lowered), ("lowered", .lowered)] {
                check(choice(prefix + " " + name) == [.preset(expected)], "Explicit Spotify preset")
            }
        }
        for text in ["Spotify volume normal tomorrow", "Don't Spotify volume lower", "I said Spotify volume normal",
            "Spotify volume normal is the setting", "Spotify volume normally", "Spotify volume lowest", "Set volume lower"] {
            check(choice(text).isEmpty, "Preset context/word boundaries")
        }
        var revised = SpotifyCommandVolumePhrase(); revised.audio(level: 0.2, seconds: 0.1, at: 0)
        revised.update("Spotify volume thirty", at: 1, timings: nil)
        let a = revised.poll(at: 1, prefixes: [spotify])
        revised.update("Spotify volume normal", at: 2, timings: nil)
        let b = revised.poll(at: 2, prefixes: [spotify])
        check(a.first?.id == b.first?.id && b.first?.revised == true && b.first?.value == .preset(.normal), "Numeric/preset revision shares one receipt")
        check(revised.poll(at: 3, prefixes: [spotify]).isEmpty, "No replay of unchanged value")
        for text in ["Spotify volume normal tomorrow", "Don't Spotify volume lower", "I said Spotify volume normal", "Spotify volume lowered when I leave"] {
            check(choice(text).isEmpty, "Named presets retain direct-address/future guards: " + text)
        }
        let hush = PhrasePattern(slot: .silentPhrase, text: "Shush", similar: true, dictionaries: dictionaries)
        for text in ["Shut up", "Please shut up", "Shut up now"] {
            var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1, at: 0); detector.update(text, at: 1)
            check(detector.poll(at: 1, phrase: hush.text, similar: true, rejectNegated: true, patterns: [hush], directOnly: true), "One immediate Voice-silence spelling: " + text)
            check(!detector.poll(at: 2, phrase: hush.text, similar: true, rejectNegated: true, patterns: [hush], directOnly: true), "No duplicate silence dispatch")
        }
        for text in ["Don't shut up", "I said shut up", "The words shut up", "Shut up is a spelling", "Unshut up", "Add shut up as a spelling"] {
            var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1, at: 0); detector.update(text, at: 1)
            check(!detector.poll(at: 1, phrase: hush.text, similar: true, rejectNegated: true, patterns: [hush], directOnly: true), "Do not execute mentioned or negated silence: " + text)
        }
        let restore = PhrasePattern(slot: .unsilencePhrase, text: "Unshush", similar: true, dictionaries: dictionaries)
        for spelling in ["Unshush"] + PhraseSlot.unsilencePhrase.stockSpellings(for: "Unshush") {
            var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1, at: 0); detector.update(spelling, at: 1)
            check(detector.poll(at: 1, phrase: restore.text, similar: true, rejectNegated: true, patterns: [restore], directOnly: true), "Unshush is immediate: " + spelling)
            check(hush.kind(for: spelling) == nil, "Restore never becomes silence")
            check(!detector.poll(at: 2, phrase: restore.text, similar: true, rejectNegated: true, patterns: [restore], directOnly: true), "One restore occurrence")
        }
        for text in ["Don't unshush", "I said unshush", "The word unshush", "Unshushable", "Unshush is a command"] {
            var detector = StandaloneWake(); detector.audio(level: 0.2, seconds: 0.1, at: 0); detector.update(text, at: 1)
            check(!detector.poll(at: 1, phrase: restore.text, similar: true, rejectNegated: true, patterns: [restore], directOnly: true), "No quoted/negated/ordinary restore")
        }
        let play = PhrasePattern(slot: .playVideoPhrase, text: "Play video", similar: true, dictionaries: dictionaries)
        check(play.kind(for: "Play a video") == .dictionary, "Play a video is shipped from the shared dictionary")
        check(HomeCommand.all.first?.slots == [.silentPhrase, .silencePhrase], "Shush remains first")

        final class Fixture {
            var volume: Int? = 49
            var saved: SpotifyVolumeLease?
            var writes: [Int] = []
            var failSave = false
            func session() -> SpotifyVolumeSession { .init(access: .init(read: { self.volume }, write: { value, expected, _ in
                precondition(self.volume == expected); self.writes.append(value); self.volume = value; return value
            }, load: { self.saved }, save: { if self.failSave { throw CocoaError(.fileWriteUnknown) }; self.saved = $0 })) }
        }
        let f = Fixture(); let session = f.session()
        _ = try session.reconcile(.active, callIdentifier: "call", limit: 30)
        for _ in 0..<3 {
            check(try session.setPreset(.normal, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30) == 49, "Normal restores actual saved49")
            _ = try session.reconcile(.active, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
            check(f.volume == 49 && f.saved?.original == 49 && f.saved?.valid == true, "Normal survives duplicate active observation/restart receipt")
            check(try session.setPreset(.lowered, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30) == 30, "Lowered uses configured level")
        }
        // Use a fresh owner after recovery; this matches the production serial lease owner.
        let recovered = f.session()
        _ = try recovered.reconcile(.active, callIdentifier: "call", microphoneMuted: true, outputSilenced: true, limit: 30)
        check(f.volume == 49, "Either mute reason restores baseline")
        _ = try recovered.reconcile(.active, callIdentifier: "call", microphoneMuted: false, outputSilenced: true, limit: 30)
        check(f.volume == 49, "Overlap cannot lower early")
        _ = try recovered.reconcile(.active, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
        check(f.volume == 30, "Last reason clears to lowered level")
        _ = try recovered.reconcile(.active, callIdentifier: "call", microphoneMuted: true, outputSilenced: true, limit: 30)
        check(try recovered.setPreset(.lowered, callIdentifier: "call", microphoneMuted: nil, outputSilenced: nil, limit: 30) == 49, "Unknown new audio fields retain known overlapping mute reasons")
        _ = try recovered.reconcile(.inactive)
        check(f.volume == 49 && f.saved == nil, "Call End keeps original restoration")
        let q = Fixture(); q.volume = 20; let quiet = q.session()
        _ = try quiet.reconcile(.active, callIdentifier: "call", limit: 30)
        _ = try quiet.setPreset(.lowered, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
        check(q.volume == 20 && q.writes.isEmpty, "Already quieter never becomes louder")
        let manual = Fixture(); let ms = manual.session()
        _ = try ms.reconcile(.active, callIdentifier: "call", limit: 30)
        _ = try ms.setPreset(.normal, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
        _ = try ms.setVolume(70, preservingForCall: true, callIdentifier: "call")
        _ = try ms.reconcile(.inactive)
        check(manual.volume == 70 && manual.saved == nil, "An explicit percentage remains a manual choice")
        let unsafe = Fixture(); unsafe.failSave = true
        do { _ = try unsafe.session().setPreset(.lowered, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30); preconditionFailure() }
        catch let e as SpotifyVolumeOperationFailure { check(e.beforeDispatch && unsafe.writes.isEmpty, "Persist baseline before dispatch") }
        let persisted = Fixture(), persistent = persisted.session()
        _ = try persistent.reconcile(.active, callIdentifier: "call", limit: 30)
        _ = try persistent.setPreset(.normal, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
        check(persisted.saved?.version == 3, "Old app recovery must refuse an unknown preset lease")
        let encoded = try JSONEncoder().encode(persisted.saved!)
        persisted.saved = try JSONDecoder().decode(SpotifyVolumeLease.self, from: encoded)
        _ = try persisted.session().reconcile(.active, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30)
        check(persisted.volume == 49 && persisted.saved?.preset == .normal, "Normal survives actual encoded receipt recovery")
        let failed = Fixture(), failSession = failed.session()
        _ = try failSession.reconcile(.active, callIdentifier: "call", limit: 30)
        failed.failSave = true; let beforeWrites = failed.writes
        do { _ = try failSession.setPreset(.normal, callIdentifier: "call", microphoneMuted: false, outputSilenced: false, limit: 30); preconditionFailure() }
        catch let e as SpotifyVolumeOperationFailure { check(e.beforeDispatch && failed.writes == beforeWrites, "Durable baseline/preset precedes a write") }
        print("Passed \(checks) volume, Unshush and default-dictionary checks; no live action")
    }
}
