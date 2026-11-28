// Rebind native Voice notifications off the UI/recognition thread. This changes no
// call evidence, polling interval or control action. — GPT-6.1 Sol
import ApplicationServices
import Foundation

struct VoiceObserverRegistration {
    typealias Entry = (AXUIElement, CFString)
    var windows: (AXUIElement) -> [AXUIElement] = { root in
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
    var remove: (AXObserver, AXUIElement, CFString) -> Void = { observer, element, name in
        AXObserverRemoveNotification(observer, element, name)
    }
    var add: (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer) -> Bool = { observer, element, name, context in
        AXObserverAddNotification(observer, element, name, context) == .success
    }

    func retire(observer: AXObserver, entries: [Entry]) async {
        await Task.detached(priority: .utility) {
            for (element, name) in entries { remove(observer, element, name) }
        }.value
    }

    // Found and fixed by GPT-6.1 Sol: even reading AXWindows or adding observer
    // notifications can block on a busy Codex process; never perform these on MainActor. — GPT-6.1 Sol
    func replace(observer: AXObserver, pid: pid_t, previous: [Entry], call: [AXUIElement],
                 audio: [AXUIElement], readAudio: Bool, context: UnsafeMutableRawPointer) async -> [Entry] {
        await Task.detached(priority: .utility) {
            for (element, name) in previous { remove(observer, element, name) }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.04)
            let elements = [root] + windows(root) + call
            let notifications = [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                kAXFocusedWindowChangedNotification, kAXLayoutChangedNotification, "AXChildrenChanged", "AXLoadComplete", "AXLayoutComplete"]
            var result: [Entry] = []
            for element in elements {
                AXUIElementSetMessagingTimeout(element, 0.04)
                let names = notifications + (readAudio && audio.contains(where: { CFEqual($0, element) })
                    ? [kAXValueChangedNotification, kAXTitleChangedNotification] : [])
                for name in names where add(observer, element, name as CFString, context) {
                    result.append((element, name as CFString))
                }
            }
            return result
        }.value
    }
}
