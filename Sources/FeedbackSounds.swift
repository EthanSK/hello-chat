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
        guard UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true else { return }
        sounds.values.forEach { $0.stop() }
        let played = sounds[cue]?.play() ?? false
        Diagnostics.shared.record("feedback.play", info: ["cue": cue.rawValue, "started": String(played)])
    }
}
