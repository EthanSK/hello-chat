// Keep update relaunches outside live chat actions and Agent Flow recordings.
import Foundation

enum UpdateSafety {
    static func canRelaunch(busy: Bool, recording: Bool, voice: VoiceSnapshot) -> Bool {
        guard !busy, !recording, !voice.recorderRunning else { return false }
        if voice.pid == nil { return voice.applicationAbsent }
        return voice.accessibilityAllowed && voice.controlsComplete
            && !voice.inputRunning && voice.microphone == nil && !voice.endControlAvailable
    }
}
