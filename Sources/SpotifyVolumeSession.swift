// Own one reversible Spotify volume change. Tests inject storage and playback
// access; this state machine never starts playback or changes system volume.
import Foundation

enum SpotifyControlError: Error {
    case permissionRequired, unavailable, invalidReply, volumeChanged, appleEvent(Int32)
}

enum VoiceCallPresence: String { case active, inactive, unknown }

enum SpotifyVolumePolicy {
    // Ethan's persistent voice-call preference is 50%, replacing 30%.
    static let maximumVolume = 50
}

struct VoiceCallObservation: Equatable {
    let presence: VoiceCallPresence
    let callIdentifier: String?
}

// Saved final End events outrank stale AX buttons. Session identity also
// catches End/Start pairs whose short inactive interval was never observed.
struct SavedCallBoundaries {
    private(set) var activeSessions: Set<String>?
    private var suppressUntilControlsClear = false
    var hasActiveCall: Bool { activeSessions.map { !$0.isEmpty } ?? false }
    var callIdentifier: String? { activeSessions?.count == 1 ? activeSessions?.first : nil }

    mutating func observe(_ current: Set<String>?, controlsPresent: Bool,
                          controlsComplete: Bool) -> (endPrevious: Bool, suppressControls: Bool) {
        var ended = false
        if let current {
            if let previous = activeSessions, !previous.isEmpty, previous.isDisjoint(with: current) {
                ended = true
                suppressUntilControlsClear = current.isEmpty
            }
            if !current.isEmpty { suppressUntilControlsClear = false }
            activeSessions = current
        }
        let suppress = suppressUntilControlsClear
        if controlsComplete && !controlsPresent { suppressUntilControlsClear = false }
        return (ended, suppress)
    }
}

struct SpotifyVolumeLease: Codable, Equatable {
    let version: Int
    let original: Int
    let applied: Int
    var confirmed: Bool
    let callIdentifier: String?
    let cap: Int?

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
        value == applied || (!confirmed && original > appliedCap && applied == appliedCap && value == appliedCap - 1)
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

    // Save BEFORE sending the volume change. A crash between the event and its
    // reply must not lose the original value or save the cap as the next original.
    func reconcile(_ call: VoiceCallPresence, preservingManualOverride: Bool = false,
                   callIdentifier: String? = nil) throws -> Result {
        if !loaded {
            let saved = try access.load()
            if let saved, !saved.valid { throw CocoaError(.fileReadCorruptFile) }
            lease = saved; loaded = true
        }
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
            if let saved = lease {
                if !saved.confirmed && current == saved.original {
                    return try apply(saved)
                }
                // A manual change wins. Do not keep forcing the slider back to
                // the cap. At End, restore only if our applied value is still there.
                return saved.owns(current) ? .unchanged : .manualChange
            }
            let saved = SpotifyVolumeLease(original: current, applied: min(current, SpotifyVolumePolicy.maximumVolume),
                                           callIdentifier: callIdentifier)
            try access.save(saved); lease = saved
            return try apply(saved)
        }

        guard let saved = lease else { return .idle }
        // Quit is not the call's End. Retain an override across a helper
        // restart so the same ongoing call cannot lower the user's slider.
        if preservingManualOverride && !saved.owns(current) { return .manualChange }
        let restore = saved.owns(current) && saved.original != saved.applied
        if restore { _ = try access.write(saved.original, current, true) }
        // Keep the receipt if restoration failed, or Spotify is closed. A later
        // launch can retry without launching Spotify or losing crash recovery.
        try access.save(nil); lease = nil
        return restore ? .restored : (current == saved.applied ? .unchanged : .manualChange)
    }

    private func apply(_ saved: SpotifyVolumeLease) throws -> Result {
        let actual = saved.original != saved.applied
            ? try access.write(saved.applied, saved.original, saved.appliedCap == SpotifyVolumePolicy.maximumVolume)
            : saved.applied
        let confirmed = SpotifyVolumeLease(original: saved.original, applied: actual, confirmed: true,
                                          callIdentifier: saved.callIdentifier, cap: saved.appliedCap)
        try access.save(confirmed); lease = confirmed
        return saved.original == saved.applied ? .unchanged : .lowered
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
