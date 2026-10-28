import Foundation

// Loading is expensive. A cancelled start must finish releasing its worker
// before a newer start loads another copy of the same models.
actor SpeechPreparationGate {
    static let shared = SpeechPreparationGate()
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func withPermit<T>(_ operation: () async throws -> T) async throws -> T {
        if occupied { await withCheckedContinuation { waiting.append($0) } }
        else { occupied = true }
        defer {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

struct SpeechRollover {
    private var seconds = 0.0
    private var quietSeconds = 0.0
    var shouldReset: Bool { seconds >= 120 || (seconds >= 45 && quietSeconds >= 0.8) }
    mutating func consumed(seconds duration: Double, quiet: Bool) {
        seconds += duration
        quietSeconds = quiet ? quietSeconds + duration : 0
    }
}

struct SpeechOnset {
    private var quietSeconds = 0.0
    mutating func consumed(seconds: Double, quiet: Bool) -> Bool {
        let beginsAfterPause = !quiet && quietSeconds >= 2
        quietSeconds = quiet ? quietSeconds + seconds : 0
        return beginsAfterPause
    }
}
