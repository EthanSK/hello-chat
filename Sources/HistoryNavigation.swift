// Standard auxiliary mouse Back/Forward buttons, matching Agentic Mouse's
// ForwardNavigationActionExecutor. No caret keys, focus change or app importer. — GPT-6.1 Sol
import AppKit
import ApplicationServices
import CoreGraphics

struct HistoryNavigation {
    enum Direction: String, CaseIterable, Hashable {
        case back, forward
        var button: UInt32 { self == .back ? 3 : 4 }
        var slot: PhraseSlot { self == .back ? .backPhrase : .forwardPhrase }
    }
    var session: () -> DesktopSessionState = { .current }
    var trusted: () -> Bool = { AXIsProcessTrusted() }
    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var makeEvents: (Direction) -> [CGEvent]? = Self.events
    var post: ([CGEvent], pid_t) -> Void = { events, pid in events.forEach { $0.postToPid(pid) } }

    func perform(_ direction: Direction, expectedPID: pid_t) -> Bool {
        guard expectedPID > 0, session() == .interactive, trusted(), frontmost() == expectedPID,
              let events = makeEvents(direction), events.count == 2, frontmost() == expectedPID else { return false }
        post(events, expectedPID)
        return true // Submitted only: the receiving app owns its navigation behavior.
    }
    static func events(_ direction: Direction) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let button = CGMouseButton(rawValue: direction.button),
              let location = CGEvent(source: source)?.location,
              let down = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown,
                  mouseCursorPosition: location, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp,
                  mouseCursorPosition: location, mouseButton: button) else { return nil }
        return [down, up]
    }
}
