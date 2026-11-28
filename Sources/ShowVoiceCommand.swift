// "Show voice" opens the current local Voice chat, or the last one after a call.
import AppKit
import Foundation

enum ShowVoiceCommand {
    enum Outcome: String {
        case opened, openedPrevious, inactive, unknown, failed
        var didOpen: Bool { self == .opened || self == .openedPrevious }
        var message: String {
            switch self {
            case .opened: return "Opened the current Voice chat."
            case .openedPrevious: return "Opened the last Voice chat."
            case .inactive: return "No previous Voice chat found."
            case .unknown: return "Couldn’t identify the Voice chat."
            case .failed: return "Couldn’t open the Voice chat."
            }
        }
    }

    @MainActor static func perform(
        resolve: () async -> VoicePeerReceipt = { await Task.detached { VoicePeerControl.localStatus() }.value },
        recent: () async -> VoiceTimeline.RecentChat = {
            await Task.detached { VoiceTimeline.mostRecentChat(database: VoiceTimeline.databaseURL()) }.value
        },
        open: (Int32?, URL) async -> Bool = openThread,
        valid: () -> Bool = { true }
    ) async -> Outcome {
        var current = await resolve()
        var previous: VoiceTimeline.RecentChat = .none
        if current.status == .inactive {
            previous = await recent()
            // A call may have started while the saved history was being read.
            current = await resolve()
        }
        guard !Task.isCancelled else { return .unknown }
        let thread: UUID
        let pid: Int32?
        let outcome: Outcome
        if current.status == .active, let call = current.call {
            thread = call.thread
            pid = call.pid
            outcome = .opened
        } else if current.status == .inactive {
            switch previous {
            case .thread(let id): thread = id
            case .none: return .inactive
            case .unknown: return .unknown
            }
            pid = nil
            outcome = .openedPrevious
        } else { return .unknown }
        guard valid(), !Task.isCancelled, let link = URL(string: "codex://threads/" + thread.uuidString.lowercased()) else { return .unknown }
        return await open(pid, link) ? outcome : .failed
    }

    @MainActor private static func openThread(_ pid: Int32?, _ link: URL) async -> Bool {
        await VoiceBridge.openChat(pid, link)
    }
}
