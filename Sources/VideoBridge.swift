import Combine
import Foundation

// Browser video control through Agent Flow Bridge. Ethan asked for "pause the video" and
// "play video" to work with any browser video. This file never touches Codex Voice: a reply
// can only update availability or report one command's outcome.
enum VideoCommand: String, CaseIterable, Hashable {
    case pause, play, rewindFive, rewindTen, rewind
    static let rewindSecondsPreference = "rewindVideoSeconds"
    static func rewindSeconds(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: rewindSecondsPreference)
        return durationRange.contains(value) ? value : 10
    }
    static let durationRange = 1...3600
    func resolved(rewindSeconds: Int) -> Self {
        guard self == .rewind else { return self }
        switch rewindSeconds {
        case 5: return .rewindFive
        case 10: return .rewindTen
        default: return .rewind
        }
    }
    var setsPlaybackState: Bool { self == .pause || self == .play }
    static func isSuperseded(_ command: VideoCommand, at position: Int, lastPlayback: Int?) -> Bool {
        command.setsPlaybackState && position != lastPlayback
    }

    var slot: PhraseSlot {
        switch self {
        case .pause: return .pauseVideoPhrase
        case .play: return .playVideoPhrase
        case .rewind: return .rewindVideoPhrase
        case .rewindFive: return .rewindFivePhrase
        case .rewindTen: return .rewindTenPhrase
        }
    }
    var unchangedReason: String {
        switch self {
        case .pause: return "already-paused"
        case .play: return "already-playing"
        case .rewind, .rewindFive, .rewindTen: return "at-start"
        }
    }
    var successMessage: String {
        switch self {
        case .pause: return "Paused the browser video"
        case .play: return "Playing the browser video"
        case .rewind, .rewindFive, .rewindTen: return "Rewound the browser video"
        }
    }
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
    case volume(Int)
    case changed
    case rewound(Double)
    case unchanged(String) // The extension's reason, such as already-paused or no-video.
    case unavailable
    case rejected          // Too old or malformed; nothing ran in Chrome.
    case unconfirmed       // No reply in time. Never retried.
    // A paused/playing cue states a confirmed result, including an idempotent repeat. A timeout,
    // missing video or rejected play must not sound like success.
    func confirms(_ command: VideoCommand) -> Bool {
        switch self {
        case .changed, .rewound: return true
        case .unchanged(let reason): return reason == command.unchangedReason
        case .volume, .unavailable, .rejected, .unconfirmed: return false
        }
    }
    func summary(for command: VideoCommand) -> String {
        switch self {
        case .volume(let value): return "YouTube volume · \(value)%"
        case .rewound(let seconds): return "Rewound the video by \(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds"
        case .changed: return command.successMessage
        case .unchanged("at-start"): return "The video is already at the start"
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
        case .volume(let value): return "volume:\(value)"
        case .rewound(let seconds): return "rewound:\(seconds)"
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
    var movedSeconds: Double? = nil
    var capabilities: [String]? = nil
    var volumePercent: Int? = nil
    var playing: Bool? = nil
    var paused: Bool? = nil
    var muted: Bool? = nil
    var confirmed: Bool? = nil
}

protocol VideoBridgeTransport: AnyObject {
    var onReply: (@MainActor (VideoBridgeReply) -> Void)? { get set }
    func post(requestId: String, action: String, issuedAt: Int, seconds: Int?, volumePercent: Int?)
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
    func post(requestId: String, action: String, issuedAt: Int, seconds: Int?, volumePercent: Int?) {
        var fields: [String: Any] = ["requestId": requestId, "action": action, "issuedAt": issuedAt]
        if let seconds { fields["seekSeconds"] = -seconds }
        if let volumePercent { fields["volumePercent"] = volumePercent }
        DistributedNotificationCenter.default().postNotificationName(Self.request, object: nil,
            userInfo: fields, deliverImmediately: true)
    }
    @objc private func received(_ notification: Notification) {
        guard let info = notification.userInfo, let requestId = info["requestId"] as? String,
              let action = info["action"] as? String, let state = info["state"] as? String else { return }
        let reply = VideoBridgeReply(requestId: requestId, action: action, state: state,
            changed: (info["changed"] as? NSNumber)?.boolValue, reason: info["reason"] as? String,
            protocolVersion: (info["protocolVersion"] as? NSNumber)?.intValue,
            movedSeconds: (info["movedSeconds"] as? NSNumber)?.doubleValue,
            capabilities: info["capabilities"] as? [String],
            volumePercent: HControlNumber.integer(info["volumePercent"]),
            playing: HControlNumber.boolean(info["playing"]), paused: HControlNumber.boolean(info["paused"]),
            muted: HControlNumber.boolean(info["muted"]), confirmed: HControlNumber.boolean(info["confirmed"]))
        Task { @MainActor [weak self] in self?.onReply?(reply) }
    }
}

private enum HControlNumber {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (0...100).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
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
        let volumePercent: Int?
        let completion: (@MainActor (VideoCommandOutcome) -> Void)?
        var cancelTimer: () -> Void = {}
    }
    private var pending: [String: Pending] = [:]
    private var sequence = 0
    private var appliedSequence = 0
    private var supportsYouTubeVolume = false
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

    // Status checks the live extension without operating a tab.
    func refresh() {
        guard !pending.values.contains(where: { $0.action == "status" }) else { return }
        start(action: "status", completion: nil, timeout: Self.statusTimeout)
    }

    // One request, one reply. A timeout reports unconfirmed and checks status; it never resends.
    func send(_ command: VideoCommand, completion: @escaping @MainActor (VideoCommandOutcome) -> Void = { _ in }) {
        start(action: command.rawValue, completion: completion, timeout: Self.commandTimeout)
    }

    // Check the live extension immediately before sending an action. A disconnected
    // extension can never receive an old command after it reconnects.
    func sendIfAvailable(_ command: VideoCommand, seconds: Int = VideoCommand.rewindSeconds(), shouldSend: @escaping @MainActor () -> Bool = { true }, completion: @escaping @MainActor (VideoCommandOutcome) -> Void) {
        if command == .rewind {
            guard VideoCommand.durationRange.contains(seconds) else { completion(.rejected); return }
            probeRewind(custom: true) { [weak self] ready in
                guard ready, let self else { completion(.unavailable); return }
                guard shouldSend() else { completion(.rejected); return }
                self.start(action: command.rawValue, seconds: seconds, completion: completion, timeout: Self.commandTimeout)
            }
        } else if command.slot.isRewind {
            probeRewind { [weak self] ready in
                guard ready, let self else { completion(.unavailable); return }
                guard shouldSend() else { completion(.rejected); return }
                self.send(command, completion: completion)
            }
        } else {
            start(action: "status", completion: { [weak self] status in
                guard status == .unchanged("connected"), let self else { completion(.unavailable); return }
                guard shouldSend() else { completion(.rejected); return }
                self.send(command, completion: completion)
            }, timeout: Self.statusTimeout)
        }
    }

    // Capability is read from this exact fresh status reply; older bridge versions
    // never receive an absolute-volume action. No fallback to a relative volume key. — GPT-6.1 Sol
    func setYouTubeVolume(_ percent: Int, shouldSend: @escaping @MainActor () -> Bool = { true },
                          completion: @escaping @MainActor (VideoCommandOutcome) -> Void) {
        guard (0...100).contains(percent) else { completion(.rejected); return }
        start(action: "status", completion: { [weak self] status in
            guard let self, status == .unchanged("connected"), self.supportsYouTubeVolume else { completion(.unavailable); return }
            guard shouldSend() else { completion(.rejected); return }
            self.start(action: "setVolume", volumePercent: percent, completion: completion, timeout: Self.commandTimeout)
        }, timeout: Self.statusTimeout)
    }

    func probeRewind(custom: Bool = false, completion: @escaping @MainActor (Bool) -> Void) {
        start(action: custom ? "seekStatus" : "rewindStatus", completion: { outcome in
            completion(outcome == .unchanged(custom ? "custom-seek-supported" : "rewind-supported"))
        }, timeout: Self.statusTimeout)
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
            supportsYouTubeVolume = compatible && reply.capabilities?.contains("youtubeAbsoluteVolume") == true
            entry.completion?(compatible ? .unchanged("connected") : .unavailable)
        case ("done", false) where compatible:
            apply(.available, sequence: entry.sequence)
            if entry.action == "setVolume" {
                guard let expected = entry.volumePercent, reply.confirmed == true, reply.volumePercent == expected,
                      reply.playing != nil, reply.paused != nil, reply.muted != nil,
                      !(reply.playing == true && reply.paused == true) else { entry.completion?(.unconfirmed); return }
                entry.completion?(.volume(expected))
            } else if reply.changed == true, let seconds = reply.movedSeconds, seconds.isFinite, seconds > 0 {
                entry.completion?(.rewound(seconds))
            } else {
                entry.completion?(reply.changed == true ? .changed : .unchanged(reply.reason ?? "no-video"))
            }
        case ("unavailable", _):
            apply(.unavailable(.notConnected), sequence: entry.sequence)
            entry.completion?(.unavailable)
        case ("rejected", true):
            apply(.unavailable(.noReply), sequence: entry.sequence)
            entry.completion?(.unavailable)
        case ("rejected", false):
            entry.completion?(.rejected)
        default:
            apply(.unavailable(.incompatible), sequence: entry.sequence)
            entry.completion?(.unavailable)
        }
    }

    private func start(action: String, seconds: Int? = nil, volumePercent: Int? = nil, completion: (@MainActor (VideoCommandOutcome) -> Void)?, timeout: TimeInterval) {
        let id = makeID()
        sequence += 1
        pending[id] = Pending(action: action, sequence: sequence, volumePercent: volumePercent, completion: completion)
        let cancel = schedule(timeout) { [weak self] in self?.expire(id) }
        if pending[id] != nil { pending[id]?.cancelTimer = cancel } else { cancel() }
        transport.post(requestId: id, action: action, issuedAt: now(), seconds: seconds, volumePercent: volumePercent)
    }

    private func expire(_ id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if entry.action == "status" {
            apply(.unavailable(.noReply), sequence: entry.sequence)
            entry.completion?(.unavailable)
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

// Consume the occurrence first. Dispatch checks the current extension connection,
// so a later reconnection cannot replay an ignored phrase.
typealias VideoPhraseDetectors = CommandPhraseDetectors<VideoCommand>
