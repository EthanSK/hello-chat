// Isolated native Sparkle fixture: compile with AppUpdater, UpdateSafety and
// GateCore. It has no audio or Codex access; only the updater is production code.
import AppKit
import Combine

@MainActor final class GateModel: ObservableObject {
    @Published var busy = false
    @Published var phrasesPausedForAgentFlow = false
}

enum VoiceBridge {
    static func snapshot() -> VoiceSnapshot {
        var result = VoiceSnapshot(pid: nil, inputRunning: false, recorderRunning: false,
                                   microphone: nil, accessibilityAllowed: true)
        result.applicationAbsent = true
        if let root = Bundle.main.object(forInfoDictionaryKey: "TestResultDirectory") as? String,
           FileManager.default.fileExists(atPath: root + "/call-active") {
            result.pid = 123; result.applicationAbsent = false
            result.inputRunning = true; result.microphone = .listening
        }
        return result
    }
}

final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    func record(_ event: String) {
        guard let directory = Bundle.main.object(forInfoDictionaryKey: "TestResultDirectory") as? String else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("lifecycle.log")
        let line = "\(event) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")\n"
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let output = try? FileHandle(forWritingTo: file) else { return }
        defer { try? output.close() }
        try? output.seekToEnd(); try? output.write(contentsOf: Data(line.utf8))
    }
    func failure(_ event: String, _ error: Error) { record(event + ": " + error.localizedDescription) }
}

@MainActor final class UpdateFixtureDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    let model = GateModel()
    var window: NSWindow?
    var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let root = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root); NSApp.mainMenu = menu
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "Window")
        let status = NSMenuItem(title: "Show update status", action: #selector(showUpdate), keyEquivalent: "")
        status.target = self; windows.addItem(status)
        windowItem.submenu = windows; menu.addItem(windowItem); NSApp.windowsMenu = windows
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 420, height: 180),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "H Chat Update Test"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let label = NSTextField(labelWithString: "Isolated update test · build \(version)")
        let button = NSButton(title: "Check for Updates…", target: self, action: #selector(check))
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        updater.start(model: model, prepareToQuit: { Diagnostics.shared.record("prepared"); return true },
                      restoreAfterAbort: { Diagnostics.shared.record("restored") })
        updater.$canCheck.sink { button.isEnabled = $0 }.store(in: &subscriptions)
        updater.$waitingToInstall.sink { Diagnostics.shared.record("waiting=\($0)") }.store(in: &subscriptions)
        Diagnostics.shared.record("launched")
    }
    @objc func check() { updater.checkForUpdates() }
    @objc func showUpdate() {
        NSApp.windows.first { $0.title.hasPrefix("Updating ") }?.makeKeyAndOrderFront(nil)
    }
}

@main @MainActor enum UpdateFixture {
    static func main() {
        if let label = Bundle.main.object(forInfoDictionaryKey: "TestStartupLabel") as? String,
           StartupOwnership.handoffIfNeeded(label: label) { return }
        let app = NSApplication.shared
        let delegate = UpdateFixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
