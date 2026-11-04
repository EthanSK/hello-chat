// Verify update relaunch boundaries with snapshots, never real calls or installs.
import Foundation

@main enum UpdateSafetyTests {
    static func main() {
        let off = VoiceSnapshot(pid: 123, inputRunning: false, recorderRunning: false,
                                microphone: nil, accessibilityAllowed: true)
        precondition(UpdateSafety.canRelaunch(busy: false, recording: false, voice: off))
        for busy in [false, true] {
            for recording in [false, true] where busy || recording {
                precondition(!UpdateSafety.canRelaunch(busy: busy, recording: recording, voice: off))
            }
        }
        for mic in [MicrophoneState.listening, .muted] {
            var active = off; active.microphone = mic
            precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: active))
        }
        var endOnly = off; endOnly.endControlAvailable = true
        precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: endOnly))
        var unknown = off; unknown.controlsComplete = false
        precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: unknown))
        unknown = off; unknown.accessibilityAllowed = false
        precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: unknown))
        var absent = unknown; absent.pid = nil
        precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: absent))
        absent.applicationAbsent = true
        precondition(UpdateSafety.canRelaunch(busy: false, recording: false, voice: absent))
        var recording = off; recording.inputRunning = true
        precondition(!UpdateSafety.canRelaunch(busy: false, recording: false, voice: recording))
        print("Update relaunch safety: active, muted, End-only, recording, busy, unknown and absent states passed")
    }
}
