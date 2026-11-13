import Combine
import Foundation

// Browser video control through Agent Flow Bridge. Ethan asked for "pause the video" and
// "play video" to work with any browser video. This file never touches Codex Voice: a reply
// can only update availability or report one command's outcome.
enum VideoCommand: String, CaseIterable, Hashable {
    case pause, play
    var slot: PhraseSlot { self == .pause ? .pauseVideoPhrase : .playVideoPhrase }
}

enum VideoBridgeUnavailableReason: Equatable {
    case notConnected, noReply, incompatible
}

// Only a reply from a connected extension speaking this protocol counts as available.
enum VideoBridgeAvailability: Equatable {
    case checking
    case available
    case unavailable(VideoBridgeUnavailableReason)
    var isAvailable: Bool { self == .available }
    var detail: String {
        switch self {
        case .checking: return "Checking Agent Flow Bridge…"
        case .available: return "Agent Flow Bridge is connected to Chrome."
        case .unavailable(.notConnected): return "Agent Flow Bridge isn't connected to Chrome."
        case .unavailable(.noReply): return "Agent Flow Bridge didn't reply."
        case .unavailable(.incompatible): return "Update Agent Flow Bridge to control videos."
        }
    }
}

enum VideoCommandOutcome: Equatable {
    case changed
    case unchanged(String) // The extension's reason, such as already-paused or no-video.
    case unavailable
    case rejected          // Too old or malformed; nothing ran in Chrome.
    case unconfirmed       // No reply in time. Never retried.
    func summary(for command: VideoCommand) -> String {
        switch self {
        case .changed: return command == .pause ? "Paused the browser video" : "Playing the browser video"
        case .unchanged("already-paused"): return "Browser video is already paused"
        case .unchanged("already-playing"): return "Browser video is already playing"
        case .unchanged("play-blocked"): return "Chrome blocked video playback"
        case .unchanged("video-ended"): return "The browser video has ended"
        case .unchanged("no-video"): return "No browser video found"
        case .unchanged: return "Couldn't confirm the browser video changed"
        case .unavailable: return "Agent Flow Bridge isn't available"
        case .rejected: return "Video command arrived too late, so it was ignored"
        case .unconfirmed: return "No reply from Agent Flow Bridge"
        }
    }
    var diagnostic: String {
        switch self {
        case .changed: return "changed"
        case .unchanged(let reason): return "unchanged:\(reason)"
        case .unavailable: return "unavailable"
        case .rejected: return "rejected"
        case .unconfirmed: return "unconfirmed"
        }
    }
}

struct VideoBridgeReply: Equatable {
    var requestId: String
    var action: String
    var state: String
    var changed: Bool?
    var reason: String?
    var protocolVersion: Int?
}

protocol VideoBridgeTransport: AnyObject {
    var onReply: (@MainActor (VideoBridgeReply) -> Void)? { get set }
    func post(requestId: String, action: String, issuedAt: Int)
}

// Must match HelloChatVideoNotification in Agent Flow Bridge's AgentFlowBridgeShared.swift.
final class DistributedVideoBridgeTransport: NSObject, VideoBridgeTransport {
    static let request = Notification.Name("com.ethansk.hellochat.video.request")
    static let reply = Notification.Name("com.ethansk.hellochat.video.reply")
    var onReply: (@MainActor (VideoBridgeReply) -> Void)?
    override init() {
        super.init()
        // AppKit suspends distributed delivery while H Chat is inactive, which is the usual case
        // while Ethan watches a video. Replies must still arrive immediately.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)),
            name: Self.reply, object: nil, suspensionBehavior: .deliverImmediately)
    }
    deinit { DistributedNotificationCenter.default().removeObserver(self) }
    func post(requestId: String, action: String, issuedAt: Int) {
        DistributedNotificationCenter.default().postNotificationName(Self.request, object: nil,
            userInfo: ["requestId": requestId, "action": action, "issuedAt": issuedAt], deliverImmediately: true)
    }
    @objc private func received(_ notification: Notification) {
        guard let info = notification.userInfo, let requestId = info["requestId"] as? String,
              let action = info["action"] as? String, let state = info["state"] as? String else { return }
        let reply = VideoBridgeReply(requestId: requestId, action: action, state: state,
            changed: (info["changed"] as? NSNumber)?.boolValue, reason: info["reason"] as? String,
            protocolVersion: (info["protocolVersion"] as? NSNumber)?.intValue)
        Task { @MainActor [weak self] in self?.onReply?(reply) }
    }
}

@MainActor final class VideoBridge: ObservableObject {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    static let protocolVersion = 1
    // The bridge README's setup heading is "## Install"; there is no "Install and load the extension" heading.
    static let installURL = URL(string: "https://github.com/EthanSK/AgentFlow/tree/main/companions/youtube-bridge#install")!
    static let statusTimeout: TimeInterval = 1.5
    static let commandTimeout: TimeInterval = 5
    @Published private(set) var availability: VideoBridgeAvailability = .checking
    private let transport: VideoBridgeTransport
    private let now: () -> Int
    private let schedule: Scheduler
    private let makeID: () -> String
    private struct Pending {
        let action: String
        let sequence: Int
        let completion: (@MainActor (VideoCommandOutcome) -> Void)?
        var cancelTimer: () -> Void = {}
    }
    private var pending: [String: Pending] = [:]
    private var sequence = 0
    private var appliedSequence = 0
    var pendingCount: Int { pending.count }

    init(transport: VideoBridgeTransport = DistributedVideoBridgeTransport(),
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
         schedule: @escaping Scheduler = VideoBridge.mainScheduler,
         makeID: @escaping () -> String = { UUID().uuidString }) {
        self.transport = transport; self.now = now; self.schedule = schedule; self.makeID = makeID
        transport.onReply = { [weak self] reply in self?.receive(reply) }
    }

    nonisolated static func mainScheduler(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    // Status is a version check only; it never asks Chrome to touch a tab.
    func refresh() {
        guard !pending.values.contains(where: { $0.action == "status" }) else { return }
        start(action: "status", completion: nil, timeout: Self.statusTimeout)
    }

    // One request, one reply. A timeout reports unconfirmed and checks status; it never resends.
    func send(_ command: VideoCommand, completion: @escaping @MainActor (VideoCommandOutcome) -> Void = { _ in }) {
        start(action: command.rawValue, completion: completion, timeout: Self.commandTimeout)
    }

    func stop() {
        for entry in pending.values { entry.cancelTimer() }
        pending.removeAll()
    }

    func receive(_ reply: VideoBridgeReply) {
        // Unknown, expired or repeated ids are ignored, so a late reply can't replay anything.
        guard let entry = pending[reply.requestId], entry.action == reply.action else { return }
        pending[reply.requestId] = nil
        entry.cancelTimer()
        let compatible = reply.protocolVersion == Self.protocolVersion
        switch (reply.state, entry.action == "status") {
        case ("available", true):
            apply(compatible ? .available : .unavailable(.incompatible), sequence: entry.sequence)
        case ("done", false) where compatible:
            apply(.available, sequence: entry.sequence)
            entry.completion?(reply.changed == true ? .changed : .unchanged(reply.reason ?? "no-video"))
        case ("unavailable", _):
            apply(.unavailable(.notConnected), sequence: entry.sequence)
            entry.completion?(.unavailable)
        case ("rejected", true):
            apply(.unavailable(.noReply), sequence: entry.sequence)
        case ("rejected", false):
            entry.completion?(.rejected)
        default:
            apply(.unavailable(.incompatible), sequence: entry.sequence)
            entry.completion?(.unavailable)
        }
    }

    private func start(action: String, completion: (@MainActor (VideoCommandOutcome) -> Void)?, timeout: TimeInterval) {
        let id = makeID()
        sequence += 1
        pending[id] = Pending(action: action, sequence: sequence, completion: completion)
        let cancel = schedule(timeout) { [weak self] in self?.expire(id) }
        if pending[id] != nil { pending[id]?.cancelTimer = cancel } else { cancel() }
        transport.post(requestId: id, action: action, issuedAt: now())
    }

    private func expire(_ id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if entry.action == "status" {
            apply(.unavailable(.noReply), sequence: entry.sequence)
        } else {
            entry.completion?(.unconfirmed)
            refresh()
        }
    }

    private func apply(_ value: VideoBridgeAvailability, sequence: Int) {
        guard sequence >= appliedSequence else { return } // An older request's late answer never overwrites a newer one.
        appliedSequence = sequence
        if availability != value { availability = value }
    }
}

// Spoken video commands share H Chat's phrase, mention, negation and occurrence rules. Matching
// and consumption never depend on bridge availability, and nothing here can open Voice.
struct VideoPhraseDetectors {
    private var detectors = Dictionary(uniqueKeysWithValues: VideoCommand.allCases.map { ($0, StandaloneWake()) })
    mutating func reset() { for command in VideoCommand.allCases { detectors[command] = StandaloneWake() } }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        for command in VideoCommand.allCases { detectors[command, default: StandaloneWake()].audio(level: level, seconds: seconds, at: time) }
    }
    mutating func update(_ text: String, at time: Double, timings: [(word: String, start: Double, end: Double)]? = nil) {
        for command in VideoCommand.allCases { detectors[command, default: StandaloneWake()].update(text, at: time, timings: timings) }
    }
    // End wins over video commands in the same transcript, as it does over audio commands.
    mutating func cancelPending(patterns: [VideoCommand: PhrasePattern], endPattern: PhrasePattern) {
        for (command, pattern) in patterns where !PhraseMatcher.words(pattern.text).isEmpty {
            detectors[command, default: StandaloneWake()].cancelPending(patterns: [pattern], endPattern: endPattern)
        }
    }
    // Accepted commands in spoken order. Each occurrence is consumed once.
    mutating func poll(at time: Double, patterns: [VideoCommand: PhrasePattern]) -> [(command: VideoCommand, range: Range<Int>)] {
        VideoCommand.allCases.compactMap { command -> (command: VideoCommand, range: Range<Int>)? in
            guard let pattern = patterns[command], !PhraseMatcher.words(pattern.text).isEmpty,
                  detectors[command, default: StandaloneWake()].poll(at: time, phrase: pattern.text, similar: pattern.similar,
                      rejectNegated: true, ending: pattern.ending, patterns: [pattern]),
                  let range = detectors[command]?.acceptedRange else { return nil }
            return (command, range)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    // Directional commands are idempotent, so the last one spoken decides the final state.
    static func admitted(_ accepted: [(command: VideoCommand, range: Range<Int>)]) -> VideoCommand? { accepted.last?.command }
}
