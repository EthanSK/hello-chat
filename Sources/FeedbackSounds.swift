import AppKit

@MainActor final class FeedbackSounds {
    enum Cue: String { case wake = "Wake", ended = "Ended" }
    private var sounds: [Cue: NSSound] = [:]
    init() {
        for cue in [Cue.wake, .ended] {
            if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds"),
               let sound = NSSound(contentsOf: url, byReference: false) {
                sound.volume = cue == .wake ? 0.7 : 0.35; sounds[cue] = sound
            }
        }
    }
    func play(_ cue: Cue) {
        guard UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true else {
            Diagnostics.shared.record("feedback.skipped", info: ["cue": cue.rawValue, "reason": "disabled"])
            return
        }
        guard let sound = sounds[cue] else {
            Diagnostics.shared.record("feedback.skipped", info: ["cue": cue.rawValue, "reason": "missing_resource"])
            return
        }
        let requestedAt = Diagnostics.now
        Diagnostics.shared.record("feedback.requested", numbers: ["uptime": requestedAt], info: ["cue": cue.rawValue])
        sounds.values.forEach { $0.stop() }
        // Every cue starts at its first sample, including a replay after a
        // previous cue was interrupted. No system volume or route is changed.
        sound.currentTime = 0
        let played = sound.play()
        Diagnostics.shared.record("feedback.play", numbers: [
            "play_call_ms": (Diagnostics.now - requestedAt) * 1000,
            "volume": Double(sound.volume), "duration_s": sound.duration
        ], info: ["cue": cue.rawValue, "started": String(played)])
    }
}
