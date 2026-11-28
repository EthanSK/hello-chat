// Native app-audio playback for short command cues. Keep system alert volume and device routing
// under macOS/user control; each cue has its own gain and a real completion receipt.
import AVFoundation
import Foundation

enum FeedbackVolume {
    static let defaultsKey = "soundEffectsVolume"
    static let defaultLevel: Float = 0.7 // The existing audible Wake level, now shared by all cues.
    static func level(_ saved: Any?) -> Float {
        guard let value = saved as? Double, value.isFinite else { return defaultLevel }
        return Float(min(1, max(0, value)))
    }
}

// Reuse the existing, verified native-call observer. Unknown reads and initial inactivity are not
// End events. A detection cue and a later confirmed End share one call epoch, without a timer.
struct VoiceEndFeedback {
    private var active = false
    private var identity: String?
    private var epoch = 0
    private var acknowledged: Int?
    private var endedEpoch: Int?
    var activeEpoch: Int? { active ? epoch : nil }
    mutating func observe(_ presence: VoiceCallPresence, callIdentifier: String?) -> Bool {
        switch presence {
        case .active:
            if !active || (identity != nil && callIdentifier != nil && identity != callIdentifier) {
                epoch += 1; acknowledged = nil
            }
            active = true
            if let callIdentifier { identity = callIdentifier }
            return false
        case .unknown: return false
        case .inactive:
            guard active else { return false }
            active = false; identity = nil; endedEpoch = epoch
            return claimConfirmedEnd(for: epoch)
        }
    }
    mutating func detectedEnd() { if active { acknowledged = epoch } }
    mutating func claimConfirmedEnd(for expected: Int?) -> Bool {
        // An asynchronous End for an older call must not acknowledge a newer call's eventual End.
        guard let expected else { return true }
        guard expected == epoch else { return false }
        guard let target = active ? epoch : endedEpoch else { return true }
        guard acknowledged != target else { return false }
        acknowledged = target
        return true
    }
}

@MainActor final class FeedbackSounds: NSObject, AVAudioPlayerDelegate {
    // One short, non-speech file per cue in Resources/Sounds (scripts/make-feedback-sounds.py).
    enum Cue: String, CaseIterable {
        case wake = "Wake", ended = "Ended"
        case microphoneDetected = "MicrophoneDetected", microphoneMuted = "MicrophoneMuted", microphoneUnmuted = "MicrophoneUnmuted"
        case speakersMuted = "SpeakersMuted", speakersUnmuted = "SpeakersUnmuted"
        case silent = "Silent"
        case notificationReplyAccepted = "NotificationReplyAccepted"
        case videoPaused = "VideoPaused", videoPlayed = "VideoPlayed", rewind = "Rewind", rewindFive = "RewindFive", rewindTen = "RewindTen"
        case musicPause = "MusicPause", musicPlay = "MusicPlay"
        case spotifyVolume = "SpotifyVolume"
        case outputVolume = "OutputVolume", youtubeVolume = "YouTubeVolume"
        case nextTrack = "NextTrack", back = "Back", forward = "Forward"
        case setSpeed = "SetSpeed"
        case callDot = "CallDot", hangUpDot = "HangUpDot"
        case switchApp = "SwitchApp", openApp = "OpenApp", zoomIn = "ZoomIn", zoomOut = "ZoomOut", showVoice = "ShowVoice"
    }
    private var sounds: [Cue: AVAudioPlayer] = [:]
    var loadedCues: Set<Cue> { Set(sounds.keys) }
    init(locate: (Cue) -> URL? = { Bundle.main.url(forResource: $0.rawValue, withExtension: "wav", subdirectory: "Sounds") }) {
        super.init()
        for cue in Cue.allCases {
            if let url = locate(cue), let sound = try? AVAudioPlayer(contentsOf: url) {
                sound.delegate = self; sounds[cue] = sound
            }
        }
    }
    nonisolated static func preferenceKey(_ control: String) -> String { "commandSound." + control }
    nonisolated static func selected(_ value: String?, default cue: Cue?) -> Cue? {
        if value == "off" { return nil }
        return value.flatMap(Cue.init(rawValue:)) ?? cue
    }
    func play(_ cue: Cue) { play(control: cue.rawValue, default: cue) }
    func play(control: String, default cue: Cue?) {
        let selection = UserDefaults.standard.string(forKey: Self.preferenceKey(control))
        guard let selected = Self.selected(selection, default: cue) else { return }
        sample(selected)
    }
    func sample(_ cue: Cue) {
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
        sound.volume = FeedbackVolume.level(UserDefaults.standard.object(forKey: FeedbackVolume.defaultsKey))
        let played = sound.play()
        Diagnostics.shared.record("feedback.play", numbers: [
            "play_call_ms": (Diagnostics.now - requestedAt) * 1000,
            "volume": Double(sound.volume), "duration_s": sound.duration
        ], info: ["cue": cue.rawValue, "started": String(played), "player": "AVAudioPlayer"])
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let cue = sounds.first(where: { $0.value === player })?.key else { return }
        Diagnostics.shared.record("feedback.finished", numbers: ["duration_s": player.duration],
            info: ["cue": cue.rawValue, "completed": String(flag), "player": "AVAudioPlayer"])
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
        case .rewindVideoPhrase: return .rewind
        case .rewindFivePhrase: return .rewindFive
        case .rewindTenPhrase: return .rewindTen
        case .pauseMusicPhrase: return .musicPause
        case .playMusicPhrase: return .musicPlay
        case .spotifyVolumePhrase: return .spotifyVolume
        case .outputVolumePhrase: return .outputVolume
        case .youtubeVolumePhrase: return .youtubeVolume
        case .nextTrackPhrase: return .nextTrack
        case .backPhrase: return .back
        case .forwardPhrase: return .forward
        case .setSpeedPhrase: return .setSpeed
        case .callDotPhrase: return .callDot
        case .hangUpDotPhrase: return .hangUpDot
        case .switchAppPhrase: return .switchApp
        case .openAppPhrase: return .openApp
        case .zoomInPhrase: return .zoomIn
        case .zoomOutPhrase: return .zoomOut
        case .showVoicePhrase: return .showVoice
        }
    }
    var soundTitle: String {
        // The phrase editor groups these together; keep their existing sound choices distinct.
        switch self {
        case .mutePhrase, .unmutePhrase, .unsilencePhrase: return action.settingsTitle
        case .silentPhrase: return "Silent (Codex Voice speakers)"
        case .silencePhrase: return "Silence (Codex Voice speakers)"
        default: break
        }
        if self == .switchAppPhrase { return "Switch app" }
        if self == .openAppPhrase { return "Open app" }
        for suffix in [" phrase", " prefix"] where label.hasSuffix(suffix) { return String(label.dropLast(suffix.count)) }
        return label
    }
}
