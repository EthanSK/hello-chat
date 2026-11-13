import AppKit

@MainActor final class FeedbackSounds {
    // One short, non-speech file per cue in Resources/Sounds (scripts/make-feedback-sounds.py).
    enum Cue: String, CaseIterable {
        case wake = "Wake", ended = "Ended"
        case microphoneDetected = "MicrophoneDetected", microphoneMuted = "MicrophoneMuted", microphoneUnmuted = "MicrophoneUnmuted"
        case speakersMuted = "SpeakersMuted", speakersUnmuted = "SpeakersUnmuted"
        case silent = "Silent"
        case videoPaused = "VideoPaused", videoPlayed = "VideoPlayed"
        case switchApp = "SwitchApp", openApp = "OpenApp", zoomIn = "ZoomIn", zoomOut = "ZoomOut"
    }
    private var sounds: [Cue: NSSound] = [:]
    var loadedCues: Set<Cue> { Set(sounds.keys) }
    init(locate: (Cue) -> URL? = { Bundle.main.url(forResource: $0.rawValue, withExtension: "wav", subdirectory: "Sounds") }) {
        for cue in Cue.allCases {
            if let url = locate(cue), let sound = NSSound(contentsOf: url, byReference: false) {
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

// Every phrase has its own sound so Ethan can learn commands by ear. Deliberately exhaustive: a new
// phrase slot doesn't compile until it picks a cue, and FeedbackSoundTests checks its asset. The cue
// belongs to the slot, so edited phrase text and spoken app names never change it.
extension PhraseSlot {
    var cue: FeedbackSounds.Cue {
        switch self {
        case .wakePhrase: return .wake
        case .sleepPhrase: return .ended
        case .mutePhrase: return .microphoneMuted
        case .unmutePhrase: return .microphoneUnmuted
        case .silentPhrase: return .silent
        case .silencePhrase: return .speakersMuted
        case .unsilencePhrase: return .speakersUnmuted
        case .pauseVideoPhrase: return .videoPaused
        case .playVideoPhrase: return .videoPlayed
        case .switchAppPhrase: return .switchApp
        case .openAppPhrase: return .openApp
        case .zoomInPhrase: return .zoomIn
        case .zoomOutPhrase: return .zoomOut
        }
    }
    var soundTitle: String {
        for suffix in [" phrase", " prefix"] where label.hasSuffix(suffix) { return String(label.dropLast(suffix.count)) }
        return label
    }
}
