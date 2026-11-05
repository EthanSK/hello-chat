// Finish H Chat's own in-flight operations before updating. A Codex Voice call
// or Agent Flow recording belongs to that app, so neither blocks our restart.
import Foundation

enum UpdateSafety {
    static func canRelaunch(busy: Bool, checkingSpeech: Bool) -> Bool {
        !busy && !checkingSpeech
    }
}
