import Darwin
import Foundation

// Ethan's “check that H Chat hasn't done the action already”. Both callers take the same
// lock before acting. The journal records commands and destinations, never conversation text.
struct SpokenCommandJournal {
    enum Phase: String, Codable { case attempted, confirmed, submitted, failedBeforeDispatch, unknown, fallback, superseded }
    struct Entry: Codable {
        let id: UUID
        let action: String
        var target: String
        let session: String?
        let at: Double
        var phase: Phase
        var frame: UUID?
        var from: Double?
        var through: Double?
        var requestedCount: Int?
        var completedCount: Int?
        var updatedAt: Double?
    }
    enum Permission { case run(UUID), covered }
    let directory: URL
    var now: () -> Double = { Date().timeIntervalSince1970 }
    static let shared = SpokenCommandJournal(directory: AppPaths.support.appendingPathComponent("CommandReceipts"))
    private func transaction<T>(_ body: (inout [Entry]) -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        let file = directory.appendingPathComponent("recent.json")
        var entries: [Entry] = []
        if FileManager.default.fileExists(atPath: file.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        }
        entries.removeAll { max($0.at, $0.updatedAt ?? $0.at) < now() - 180 }
        let result = body(&entries)
        try JSONEncoder().encode(entries.suffix(256)).write(to: file, options: .atomic)
        return result
    }
    // "at" is the time of the spoken words when word timings are available, not the
    // time a slow route selection or foreground check finished.
    private static let playbackActions: Set<String> = ["pauseMusicPhrase", "playMusicPhrase", "pauseVideoPhrase", "playVideoPhrase"]
    private static let rewindActions: Set<String> = ["rewindVideoPhrase", "rewindFivePhrase", "rewindTenPhrase"]
    private static func mayDescribeSameSpeech(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || (playbackActions.contains(lhs) && playbackActions.contains(rhs)) ||
            (rewindActions.contains(lhs) && rewindActions.contains(rhs))
    }
    func begin(_ action: String, target: String, session: String?, at: Double) throws -> Permission {
        try transaction { entries in
            if entries.contains(where: { $0.phase == .fallback && Self.mayDescribeSameSpeech($0.action, action) &&
                $0.target == target && (session == nil || $0.session == session) && ($0.from ?? .infinity) <= at && at <= ($0.through ?? 0) }) {
                return .covered
            }
            let id = UUID()
            entries.append(.init(id: id, action: action, target: target, session: session, at: at, phase: .attempted))
            return .run(id)
        }
    }
    @discardableResult func finish(_ id: UUID?, _ phase: Phase) -> Entry? {
        guard let id else { return nil }
        return try? transaction { entries in
            guard let i = entries.firstIndex(where: { $0.id == id && $0.phase == .attempted }) else { return nil }
            entries[i].phase = phase
            return entries[i]
        }
    }
    // One utterance retains one fallback claim even when it requests several native runs.
    // A partial dispatch is unknown, never permission to replay the whole relative action. — GPT-6.1 Sol
    @discardableResult func progress(_ id: UUID, requested: Int, completed: Int, phase: Phase) -> Entry? {
        guard (1...100).contains(requested), completed >= 0, completed <= 100 else { return nil }
        return try? transaction { entries in
            guard let index = entries.firstIndex(where: { $0.id == id && $0.phase != .fallback }) else { return nil }
            entries[index].updatedAt = now()
            entries[index].requestedCount = requested
            entries[index].completedCount = completed
            entries[index].phase = completed > 0 && phase == .failedBeforeDispatch ? .unknown : phase
            return entries[index]
        }
    }
    @discardableResult func retarget(_ id: UUID, to target: String, revisingValue: Bool = false) -> Bool {
        (try? transaction { entries in
            guard let i = entries.firstIndex(where: { $0.id == id && ($0.phase == .attempted ||
                (revisingValue && ($0.phase == .confirmed || $0.phase == .submitted))) }) else { return false }
            entries[i].target = target
            if revisingValue { entries[i].phase = .attempted }
            entries[i].updatedAt = now()
            return true
        }) ?? false
    }
    // Intersect with the real user speech frames on either side. Two plausible actions,
    // an unidentified call or a previous claim from another utterance are never a match.
    func decide(action: String, target: String, session: String, frame: UUID, from: Double, through: Double,
                allowFallback: Bool) throws -> String {
        guard from.isFinite, through.isFinite, from <= through, through - from <= 7,
              from >= now() - 45, through <= now() + 3 else { return "stale" }
        return try transaction { entries in
            let matches = entries.indices.filter { i in
                let e = entries[i]
                return Self.mayDescribeSameSpeech(e.action, action) && (e.session == session || e.session == nil) &&
                    (e.frame == frame || (e.at >= from && e.at <= through))
            }
            if matches.contains(where: { entries[$0].action != action || entries[$0].target != target || entries[$0].session == nil ||
                (entries[$0].frame != nil && entries[$0].frame != frame) }) { return "ambiguous" }
            guard matches.count <= 1 else { return "ambiguous" }
            if let i = matches.first {
                if entries[i].phase == .fallback { return "alreadyClaimed" }
                entries[i].frame = frame
                if entries[i].phase != .failedBeforeDispatch || !allowFallback { return entries[i].phase.rawValue }
                entries[i].phase = .fallback
                entries[i].from = from
                entries[i].through = through
                return "fallbackGranted"
            }
            guard allowFallback else { return "missing" }
            entries.append(.init(id: UUID(), action: action, target: target, session: session,
                                 at: min(now(), through), phase: .fallback, frame: frame, from: from, through: through))
            return "fallbackGranted"
        }
    }
}
