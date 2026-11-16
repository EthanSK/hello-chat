// Coalesce the existing call observer's confirmed End into a passive UI-cache update.
// Unknown/initial absence is not End, and a newer local action supersedes older reads.
import Foundation

struct VoiceStatusRefresh {
    private var wasActive = false
    private var latestRead: TimeInterval = 0
    private var localConfirmation: TimeInterval = 0
    private(set) var pending = false

    mutating func observe(_ presence: VoiceCallPresence, at time: TimeInterval?) {
        guard let time, time.isFinite, time >= latestRead, time >= localConfirmation else { return }
        latestRead = time
        switch presence {
        case .active: wasActive = true; pending = false
        case .inactive:
            if wasActive { pending = true }
            wasActive = false
        case .unknown: break
        }
    }
    mutating func confirmedLocalState(active: Bool, at time: TimeInterval) {
        localConfirmation = time
        wasActive = active
        pending = false
    }
    mutating func takeIfIdle(_ idle: Bool) -> Bool {
        guard pending, idle else { return false }
        pending = false
        return true
    }
}
