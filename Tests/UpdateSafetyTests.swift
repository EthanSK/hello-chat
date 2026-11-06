// Verify only the helper's own active work blocks updates; external app state
// is intentionally absent from the policy and calls are preserved by detach.
import Foundation

@main enum UpdateSafetyTests {
    static func main() {
        precondition(UpdateSafety.canRelaunch(busy: false, checkingSpeech: false))
        for busy in [false, true] {
            for checkingSpeech in [false, true] {
                for capturingStartupSpeech in [false, true] {
                    precondition(UpdateSafety.canRelaunch(busy: busy, checkingSpeech: checkingSpeech,
                        capturingStartupSpeech: capturingStartupSpeech) == !(busy || checkingSpeech || capturingStartupSpeech))
                }
            }
        }
        print("Update relaunch safety: idle allowed; helper action, speech-check and startup capture protected")
    }
}
