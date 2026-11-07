// Own one reversible Spotify volume change. Tests inject storage and playback
// access; this state machine never starts playback or changes system volume.
import Foundation

enum VoiceCallPresence: String { case active, inactive, unknown }

struct SpotifyVolumeLease: Codable, Equatable {
    let version: Int
    let original: Int
    let applied: Int
    var confirmed: Bool

    init(original: Int, applied: Int, confirmed: Bool = false) {
        version = 1; self.original = original; self.applied = applied; self.confirmed = confirmed
    }
    var valid: Bool { version == 1 && (0...100).contains(original) && applied == min(original, 30) }
}

// Runtime access is confined to SpotifyVoiceVolume's one serial worker queue;
// tests use synchronous injected access. No mutable state crosses that owner.
final class SpotifyVolumeSession: @unchecked Sendable {
    struct Access {
        var read: () throws -> Int?
        var write: (_ volume: Int, _ expected: Int) throws -> Void
        var load: () throws -> SpotifyVolumeLease?
        var save: (SpotifyVolumeLease?) throws -> Void
    }
    enum Result: String { case idle, lowered, unchanged, restored, manualChange, spotifyClosed, uncertain }
    private let access: Access
    private var lease: SpotifyVolumeLease?
    private var loaded = false

    init(access: Access) { self.access = access }

    // Save BEFORE sending the volume change. A crash between the event and its
    // reply must not lose the original value or save 30 as the next original.
    func reconcile(_ call: VoiceCallPresence) throws -> Result {
        if !loaded {
            let saved = try access.load()
            if let saved, !saved.valid { throw CocoaError(.fileReadCorruptFile) }
            lease = saved; loaded = true
        }
        guard call != .unknown else { return .uncertain }
        if call == .inactive, lease == nil { return .idle }
        guard let current = try access.read() else { return .spotifyClosed }
        guard (0...100).contains(current) else { throw CocoaError(.coderInvalidValue) }

        if call == .active {
            if let saved = lease {
                if !saved.confirmed && current == saved.original {
                    return try apply(saved)
                }
                // A manual change wins. Do not keep forcing the slider back to
                // 30. At End, restore only if our applied value is still there.
                return current == saved.applied ? .unchanged : .manualChange
            }
            let saved = SpotifyVolumeLease(original: current, applied: min(current, 30))
            try access.save(saved); lease = saved
            return try apply(saved)
        }

        guard let saved = lease else { return .idle }
        let restore = current == saved.applied && saved.original != saved.applied
        if restore { try access.write(saved.original, current) }
        // Keep the receipt if restoration failed, or Spotify is closed. A later
        // launch can retry without launching Spotify or losing crash recovery.
        try access.save(nil); lease = nil
        return restore ? .restored : (current == saved.applied ? .unchanged : .manualChange)
    }

    private func apply(_ saved: SpotifyVolumeLease) throws -> Result {
        if saved.original != saved.applied { try access.write(saved.applied, saved.original) }
        var confirmed = saved; confirmed.confirmed = true
        try access.save(confirmed); lease = confirmed
        return saved.original == saved.applied ? .unchanged : .lowered
    }
}

// Persist just the original/applied slider values, never tracks or transcripts.
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
                          persistedCallActive: Bool, applicationAbsent: Bool) -> Bool {
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
