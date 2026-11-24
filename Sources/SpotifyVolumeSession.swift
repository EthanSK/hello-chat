// Own one reversible Spotify volume change. Tests inject storage and playback
// access; this state machine never starts playback or changes system volume.
import Foundation

enum SpotifyControlError: Error {
    case permissionRequired, unavailable, invalidReply, volumeChanged, appleEvent(Int32)
}

struct SpotifyVolumeOperationFailure: Error {
    let underlying: Error
    let beforeDispatch: Bool
}

enum VoiceCallPresence: String { case active, inactive, unknown }

enum SpotifyVolumePolicy {
    // Factory fallback only; a user's saved Maximum volume takes precedence.
    static let maximumVolume = 50
    static let preferenceKey = "spotifyVoiceVolumeLimit"
    static func limit(in defaults: UserDefaults = .standard) -> Int {
        min(100, max(0, defaults.object(forKey: preferenceKey) as? Int ?? maximumVolume))
    }
}

struct VoiceCallObservation: Equatable {
    let presence: VoiceCallPresence
    let callIdentifier: String?
    var verifiedCallIdentifier: String? = nil
    // Metadata-only explanation for diagnostics. Never a call or thread identifier.
    var evidence: String? = nil
    // Monotonic start time of the native observation; UI must not apply a read
    // begun before its own newer Start/End confirmation. Other consumers ignore it.
    var observedAt: TimeInterval? = nil
}

// Saved boundaries read after the current Codex process launched. `ended`
// holds sessions with their own session-ended record, even if restarted.
struct VoiceLedgerSessions: Equatable {
    var startedAtMilliseconds: [String: Int64]
    var ended: Set<String> = []
    var active: Set<String> { Set(startedAtMilliseconds.keys) }
}

// Saved final End events outrank stale AX buttons. Session identity also
// catches End/Start pairs whose short inactive interval was never observed.
struct SavedCallBoundaries {
    struct Outcome: Equatable {
        var endPrevious = false
        var suppressControls = false
        // The known session left the active set without its own End record.
        var vanished = false
    }
    private(set) var activeSessions: Set<String>?
    private var suppressUntilControlsClear = false
    var hasActiveCall: Bool { activeSessions.map { !$0.isEmpty } ?? false }
    var callIdentifier: String? { activeSessions?.count == 1 ? activeSessions?.first : nil }

    // Only the known session's own End record proves the call closed. A session
    // that merely disappears (another launch cutoff, pruned or unresolved rows)
    // is indeterminate. The ledger stops vouching for it and fresh native
    // controls decide; keeping the stale set would block a real restore.
    mutating func observe(_ current: VoiceLedgerSessions?, controlsPresent: Bool,
                          controlsComplete: Bool) -> Outcome {
        var outcome = Outcome()
        if let current {
            if let previous = activeSessions, !previous.isEmpty, previous.isDisjoint(with: current.active) {
                if previous.isSubset(of: current.ended) {
                    outcome.endPrevious = true
                    suppressUntilControlsClear = current.active.isEmpty
                } else { outcome.vanished = true }
            }
            if !current.active.isEmpty { suppressUntilControlsClear = false }
            activeSessions = current.active
        }
        outcome.suppressControls = suppressUntilControlsClear
        if controlsComplete && !controlsPresent { suppressUntilControlsClear = false }
        return outcome
    }
}

// One fresh native read. `ledger` is nil when the verified Codex process or its
// launch time is unresolved, or the private schema/read is unavailable.
struct VoiceCallRead {
    var controlsPresent: Bool
    var controlsComplete: Bool
    var applicationAbsent: Bool
    var process: pid_t?
    var ledger: VoiceLedgerSessions?
    var ledgerResolved = true
    var accessibilityAllowed = true
}

// Combine native controls with saved boundaries for the same Codex process.
// Pure state, so replayed reads exercise the live observer's transitions.
struct VoiceCallTracker {
    private var boundaries = SavedCallBoundaries()
    private var decision = VoiceCallDecision()
    private var process: pid_t?
    var presence: VoiceCallPresence { decision.presence }
    var activeSessions: Set<String>? { boundaries.activeSessions }

    // Returns observations in publication order, and whether to read again now.
    mutating func observe(_ read: VoiceCallRead) -> (observations: [VoiceCallObservation], readAgain: Bool) {
        var observations: [VoiceCallObservation] = []
        var replaced = false
        if let next = read.process, let owner = process, owner != next {
            // A replacement Codex process cannot continue the old process's
            // call, even if its exit was never observed between two reads.
            replaced = boundaries.hasActiveCall || decision.presence == .active
            boundaries = SavedCallBoundaries(); decision = VoiceCallDecision()
        }
        if let next = read.process { process = next }
        let boundary = boundaries.observe(read.ledger, controlsPresent: read.controlsPresent,
                                          controlsComplete: read.controlsComplete)
        let evidence = Self.evidence(read, boundary, replaced: replaced)
        // An End followed by Start can happen between two reads. The active
        // boolean stays true, but the previous call still ends.
        if replaced || boundary.endPrevious {
            observations.append(.init(presence: .inactive, callIdentifier: nil, evidence: evidence))
        }
        let readAgain = decision.observe(controlsPresent: read.controlsPresent,
            controlsComplete: read.controlsComplete, persistedCallActive: boundaries.hasActiveCall,
            applicationAbsent: read.applicationAbsent, savedCallEnded: boundary.suppressControls)
        // Spotify tolerates ledger-only presence and incomplete AX reads. Peer
        // End requires fresh evidence from both sources.
        let active = read.ledger?.active
        let verified = read.controlsPresent && read.accessibilityAllowed && read.process != nil
            && active?.count == 1 ? active?.first : nil
        observations.append(.init(presence: decision.presence, callIdentifier: boundaries.callIdentifier,
                                  verifiedCallIdentifier: verified, evidence: evidence))
        return (observations, readAgain)
    }

    private static func evidence(_ read: VoiceCallRead, _ boundary: SavedCallBoundaries.Outcome,
                                 replaced: Bool) -> String {
        let controls = read.controlsPresent ? "present" : read.controlsComplete ? "absent" : "incomplete"
        let saved: String
        if replaced { saved = "process_replaced" }
        else if boundary.endPrevious { saved = "ended" }
        else if boundary.vanished { saved = "vanished" }
        else if let ledger = read.ledger { saved = ledger.active.isEmpty ? "none" : "active" }
        else { saved = read.ledgerResolved ? "unreadable" : "unresolved" }
        return "controls=\(controls) saved=\(saved)" + (read.applicationAbsent ? " app=absent" : "")
    }
}

struct SpotifyVolumeLease: Codable, Equatable {
    enum MutePhase: String, Codable { case restoring, restored, manualOverride }

    let version: Int
    let original: Int
    let applied: Int
    var confirmed: Bool
    var callIdentifier: String?
    let cap: Int?
    var previousApplied: Int? // Original expected slider position during an in-call cap edit.
    // Optional for receipts written before the spoken microphone controls
    // affected Spotify. A call can have a restore receipt even while muted.
    var mutePhase: MutePhase?

    init(original: Int, applied: Int, confirmed: Bool = false, callIdentifier: String? = nil,
         cap: Int = SpotifyVolumePolicy.maximumVolume) {
        version = 2; self.original = original; self.applied = applied; self.confirmed = confirmed
        self.callIdentifier = callIdentifier
        self.cap = cap
    }
    // Version-one receipts used the old 30% cap. Retain their exact ownership
    // during an active-call upgrade instead of treating recovery as corrupt.
    var appliedCap: Int { version == 1 ? 30 : cap ?? -1 }
    var valid: Bool {
        (version == 1 || version == 2) && (0...100).contains(original) &&
            (0...100).contains(appliedCap) &&
            (applied == min(original, appliedCap) || (original > appliedCap && applied == appliedCap - 1))
    }
    // Spotify can truncate its internal floating-point slider one point below
    // the requested integer. A crash before saving the readback still owns
    // that value, but only while the receipt is unconfirmed.
    func owns(_ value: Int) -> Bool {
        value == applied || (!confirmed && value == previousApplied) || (!confirmed && original > appliedCap && applied == appliedCap && value == appliedCap - 1)
    }
}

enum SpotifyVolumeWrite {
    // Native Spotify can report one point below the requested integer. Exact
    // writes compensate once; legacy caps can retain their lower readback.
    static func perform(_ target: Int, expected: Int, read: () throws -> Int?,
                        exact: Bool, set: (Int) throws -> Void) throws -> Int {
        guard try read() == expected else { throw SpotifyControlError.volumeChanged }
        try set(target)
        let actual = try read()
        if actual == target { return target }
        guard target < 100, actual == target - 1 else { throw SpotifyControlError.invalidReply }
        if !exact { return target - 1 }
        guard try read() == actual else { throw SpotifyControlError.volumeChanged }
        try set(target + 1)
        guard try read() == target else { throw SpotifyControlError.invalidReply }
        return target
    }
}

// Runtime access is confined to SpotifyVoiceVolume's one serial worker queue;
// tests use synchronous injected access. No mutable state crosses that owner.
final class SpotifyVolumeSession: @unchecked Sendable {
    struct Access {
        var read: () throws -> Int?
        var write: (_ volume: Int, _ expected: Int, _ exact: Bool) throws -> Int
        var load: () throws -> SpotifyVolumeLease?
        var save: (SpotifyVolumeLease?) throws -> Void
    }
    enum Result: String { case idle, lowered, unchanged, restored, manualChange, spotifyClosed, uncertain }
    private let access: Access
    private var lease: SpotifyVolumeLease?
    private var loaded = false

    init(access: Access) { self.access = access }

    // A spoken absolute volume is a deliberate manual choice, including when it
    // equals our current cap. Persist that override before sending so End/Quit
    // cannot restore the pre-call value over it. — GPT-6.1 Sol
    func setVolume(_ volume: Int, preservingForCall: Bool, callIdentifier: String?) throws -> Int {
        var dispatched = false
        do {
            guard (0...100).contains(volume) else { throw SpotifyControlError.invalidReply }
            try load()
            guard let current = try access.read() else { throw SpotifyControlError.unavailable }
            guard (0...100).contains(current) else { throw SpotifyControlError.invalidReply }
            if var saved = lease ?? (preservingForCall
                ? SpotifyVolumeLease(original: current, applied: current, confirmed: true, callIdentifier: callIdentifier, cap: 100) : nil) {
                saved.mutePhase = .manualOverride
                if preservingForCall { saved.callIdentifier = callIdentifier }
                try keep(saved)
            }
            if current == volume { return current }
            dispatched = true
            return try access.write(volume, current, true)
        } catch {
            throw SpotifyVolumeOperationFailure(underlying: error, beforeDispatch: !dispatched)
        }
    }

    private func load() throws {
        guard !loaded else { return }
        let saved = try access.load()
        if let saved, !saved.valid { throw CocoaError(.fileReadCorruptFile) }
        lease = saved; loaded = true
    }

    // Save BEFORE sending the volume change. A crash between the event and its
    // reply must not lose the original value or save the cap as the next original.
    func reconcile(_ call: VoiceCallPresence, preservingManualOverride: Bool = false,
                   callIdentifier: String? = nil, microphoneMuted: Bool? = nil,
                   limit: Int = SpotifyVolumePolicy.maximumVolume, limitEdited: Bool = false) throws -> Result {
        try load()
        guard call != .unknown else { return .uncertain }
        if call == .active, let currentID = callIdentifier, let previousID = lease?.callIdentifier,
           previousID != currentID {
            // Recovery after the helper was absent for End/Start must not carry
            // an old call's manual override into this new call.
            _ = try reconcile(.inactive)
        }
        if call == .inactive, lease == nil { return .idle }
        guard let current = try access.read() else { return .spotifyClosed }
        guard (0...100).contains(current) else { throw CocoaError(.coderInvalidValue) }

        if call == .active {
            if var saved = lease {
                if saved.callIdentifier == nil, let callIdentifier {
                    saved.callIdentifier = callIdentifier
                    try keep(saved)
                }
                if saved.mutePhase == .manualOverride { return .manualChange }
                if microphoneMuted ?? (saved.mutePhase != nil) {
                    return try restoreWhileMuted(saved, current: current)
                }
                if limitEdited, saved.confirmed, saved.owns(current), saved.mutePhase == nil, saved.appliedCap != limit {
                    var updated = SpotifyVolumeLease(original: saved.original, applied: min(saved.original, limit),
                                                    callIdentifier: saved.callIdentifier, cap: limit)
                    updated.previousApplied = current
                    try keep(updated)
                    return try apply(updated)
                }
                return try lowerWhileListening(saved, current: current, limit: limit)
            }
            let saved = SpotifyVolumeLease(original: current, applied: min(current, limit),
                                           callIdentifier: callIdentifier, cap: limit)
            if microphoneMuted == true {
                var restored = saved
                restored.mutePhase = .restored
                try keep(restored)
                return .unchanged
            }
            try keep(saved)
            return try apply(saved)
        }

        guard let saved = lease else { return .idle }
        let ownsCap = saved.mutePhase != .restored && saved.mutePhase != .manualOverride && saved.owns(current)
        // Quit can leave the call running. Keep the receipt if the call was
        // explicitly muted or the user changed the slider.
        if preservingManualOverride {
            if saved.mutePhase == .restoring || saved.mutePhase == .restored {
                return try restoreWhileMuted(saved, current: current)
            }
            if !ownsCap { return .manualChange }
        }
        let restore = ownsCap && saved.original != current
        if restore { _ = try access.write(saved.original, current, true) }
        // Keep the receipt if restoration failed, or Spotify is closed. A later
        // launch can retry without launching Spotify or losing crash recovery.
        try keep(nil)
        if restore { return .restored }
        return ownsCap || (saved.mutePhase == .restored && current == saved.original) ? .unchanged : .manualChange
    }

    private func restoreWhileMuted(_ saved: SpotifyVolumeLease, current: Int) throws -> Result {
        if saved.mutePhase == .restored {
            return current == saved.original ? .unchanged : try preserveManualChange(saved)
        }
        let alreadyRestored = current == saved.original && (saved.mutePhase == .restoring || !saved.confirmed)
        guard alreadyRestored || saved.owns(current) else { return try preserveManualChange(saved) }
        var updated = saved
        let restore = current != saved.original
        if restore {
            if updated.mutePhase != .restoring {
                updated.mutePhase = .restoring
                try keep(updated)
            }
            _ = try access.write(saved.original, current, true)
        }
        updated.mutePhase = .restored
        try keep(updated)
        return restore ? .restored : .unchanged
    }

    private func lowerWhileListening(_ saved: SpotifyVolumeLease, current: Int, limit: Int) throws -> Result {
        if saved.mutePhase == .restored || (saved.mutePhase == .restoring && current == saved.original) {
            guard current == saved.original else { return try preserveManualChange(saved) }
            let next = SpotifyVolumeLease(original: saved.original, applied: min(saved.original, limit),
                                          callIdentifier: saved.callIdentifier, cap: limit)
            try keep(next)
            return try apply(next)
        }
        if !saved.confirmed && current == (saved.previousApplied ?? saved.original) { return try apply(saved) }
        guard saved.owns(current) else { return try preserveManualChange(saved) }
        if !saved.confirmed || saved.mutePhase == .restoring { try confirm(saved, applied: current) }
        return .unchanged
    }

    private func preserveManualChange(_ saved: SpotifyVolumeLease) throws -> Result {
        var updated = saved
        updated.mutePhase = .manualOverride
        try keep(updated)
        return .manualChange
    }

    private func keep(_ saved: SpotifyVolumeLease?) throws {
        try access.save(saved)
        lease = saved
    }

    private func apply(_ saved: SpotifyVolumeLease) throws -> Result {
        let expected = saved.previousApplied ?? saved.original
        let actual = expected != saved.applied
            ? try access.write(saved.applied, expected, saved.version != 1)
            : saved.applied
        try confirm(saved, applied: actual)
        return saved.original == saved.applied ? .unchanged : .lowered
    }

    private func confirm(_ saved: SpotifyVolumeLease, applied: Int) throws {
        try keep(SpotifyVolumeLease(original: saved.original, applied: applied, confirmed: true,
                                    callIdentifier: saved.callIdentifier, cap: saved.appliedCap))
    }
}

// Persist slider values and an opaque call identifier, never tracks or transcripts.
struct SpotifyVolumeReceipt {
    let url: URL
    func load() throws -> SpotifyVolumeLease? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SpotifyVolumeLease.self, from: Data(contentsOf: url))
    }
    func save(_ value: SpotifyVolumeLease?) throws {
        let fm = FileManager.default
        guard let value else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// Positive controls establish a call, including temporary chats. Persisted
// active sessions protect reconnects; incomplete AX reads never establish End.
struct VoiceCallDecision {
    private(set) var presence: VoiceCallPresence = .unknown
    private var negativeReads = 0

    mutating func observe(controlsPresent: Bool, controlsComplete: Bool,
                          persistedCallActive: Bool, applicationAbsent: Bool,
                          savedCallEnded: Bool = false) -> Bool {
        if savedCallEnded {
            negativeReads = 0; presence = .inactive; return false
        }
        if controlsPresent {
            negativeReads = 0; presence = .active; return false
        }
        if persistedCallActive && !applicationAbsent {
            negativeReads = 0
            // Startup acceptance can precede real controls. It may keep an
            // established call active, but cannot lower Spotify by itself.
            if presence != .active { presence = .unknown }
            return false
        }
        guard applicationAbsent || controlsComplete else {
            negativeReads = 0; presence = .unknown; return false
        }
        negativeReads += 1
        if negativeReads >= 2 { presence = .inactive; return false }
        // Request another actual read immediately, not a settling timer.
        presence = .unknown; return true
    }
}
