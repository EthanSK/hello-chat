// Display-only fixture for the shared Settings/HUD. No GateModel, recognizer, microphone, cue, media or delivery. — GPT-6.1 Sol
import AppKit
import SwiftUI

@MainActor enum NotificationReplyPreview {
    static func run() {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == "Built-in Retina Display" }) else { return }
        let name = "HelloChat.NotificationReplyPreview." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { return }
        let settings = NotificationReplySettings(defaults: defaults); settings.enabled = true
        let hud = NotificationReplyHUD(isPreview: true, defaults: defaults)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A bounded one-display pointer check cannot leave a full Settings window or all-display fixture behind. — GPT-6.1 Sol
        if Bundle.main.object(forInfoDictionaryKey: "HChatNotificationReplySmoke") as? Bool == true {
            UserDefaults.standard.removeObject(forKey: "HChatSmokeHeaderReceivedMouseDown")
            let began = ProcessInfo.processInfo.systemUptime, front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            var initial = [Double]()
            func record(_ reason: String) {
                UserDefaults.standard.set(["reason": reason, "elapsed": ProcessInfo.processInfo.systemUptime - began,
                    "initialTopLeft": initial, "positions": defaults.dictionary(forKey: "notificationReplyHUDPositions") ?? [:],
                    "frontBefore": front, "frontAfter": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                    "headerReceivedMouseDown": UserDefaults.standard.bool(forKey: "HChatSmokeHeaderReceivedMouseDown"),
                    "appActive": app.isActive], forKey: "HChatNotificationReplySmokeResult")
                UserDefaults.standard.synchronize()
            }
            hud.onDismiss = { _ in record("dismissed"); defaults.removePersistentDomain(forName: name); app.terminate(nil) }
            let expiry = Timer(timeInterval: 30, repeats: false) { _ in
                Task { @MainActor in record("expired"); hud.show(nil); defaults.removePersistentDomain(forName: name); app.terminate(nil) }
            }
            RunLoop.main.add(expiry, forMode: .common)
            let text = Bundle.main.object(forInfoDictionaryKey: "HChatNotificationReplySmokeText") as? String
                ?? "Display-only pointer check. No microphone, sound or message is running. Drag the header or close this panel."
            hud.show(.init(event: UUID(), phase: .composing, reason: "", spokenText: String(text.prefix(2048))))
            if let frame = hud.panels.values.first?.frame { initial = [frame.minX, frame.maxY] }
            withExtendedLifetime((hud, settings, expiry)) { app.run() }
            hud.show(nil); defaults.removePersistentDomain(forName: name)
            return
        }
        let area = screen.visibleFrame
        let width = min(480, area.width * 2 / 3), height = min(400, area.height * 2 / 3)
        let window = NSWindow(contentRect: NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
        let closeHandler = CloseHandler(hud: hud)
        window.delegate = closeHandler
        window.title = "Notification Reply Preview — Display Only"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Controls(settings: settings, hud: hud))
        window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - (height + 28) / 2, width: width, height: height + 28), display: false)
        window.orderFront(nil)
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: .main) { _ in
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        // A finite preview cannot become another background session. — GPT-6.1 Sol
        let expiry = Timer(timeInterval: 120, repeats: false) { _ in
            Task { @MainActor in hud.show(nil); UserDefaults(suiteName: name)?.removePersistentDomain(forName: name); window.close(); app.terminate(nil) }
        }
        RunLoop.main.add(expiry, forMode: .common)
        withExtendedLifetime((window, hud, settings, expiry, closeHandler)) { app.run() }
        hud.show(nil); defaults.removePersistentDomain(forName: name)
    }
    private final class CloseHandler: NSObject, NSWindowDelegate {
        let hud: NotificationReplyHUD
        init(hud: NotificationReplyHUD) { self.hud = hud }
        func windowWillClose(_ notification: Notification) {
            hud.show(nil); NSApplication.shared.terminate(nil)
        }
    }
    private struct Controls: View {
        @ObservedObject var settings: NotificationReplySettings
        let hud: NotificationReplyHUD
        private let event = UUID()
        private let text = "This is a preview notification. No microphone, sound or message is running in this preview."
        var body: some View {
            Form {
                NotificationReplySettingsSection(settings: settings, readiness: { settings.enabled ? .ready : .disabled })
                Section("Display Preview") {
                    Text("Display only. No microphone, sound or message.").foregroundStyle(.secondary)
                    ForEach([NotificationReplyCore.Phase.preparing, .announcing, .waiting, .composing, .unavailable], id: \.rawValue) { phase in
                        Button(phase.rawValue.capitalized) { hud.show(.init(event: event, phase: phase, reason: phase == .unavailable ? "voiceActive" : "", spokenText: text)) }
                    }
                    Button("Long notification") {
                        hud.show(.init(event: event, phase: .composing, reason: "", spokenText: String(repeating: "The original notification stays visible while you speak. ", count: 36)))
                    }
                    Button("Hide") { hud.show(nil) }
                    Button("Close preview") { hud.show(nil); NSApplication.shared.terminate(nil) }
                }
            }.formStyle(.grouped)
        }
    }
}
