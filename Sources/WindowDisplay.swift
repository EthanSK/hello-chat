import AppKit
import SwiftUI

enum WindowDisplay {
    static let preferenceKey = "preferredDisplayUUID"

    static func identifier(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // Ethan's "top-right monitor" is a saved local display choice, never a
    // personal monitor ID baked into the app. Keep it when unplugged so it
    // works again after reconnecting; use an available screen in the meantime.
    static var preferredScreen: NSScreen? {
        let saved = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
        return NSScreen.screens.first(where: { !saved.isEmpty && identifier($0) == saved })
            ?? NSScreen.main ?? NSScreen.screens.first
    }
}

struct WindowDisplaySettings: View {
    @AppStorage(WindowDisplay.preferenceKey) private var preferred = ""
    @State private var screens = NSScreen.screens

    var body: some View {
        Picker("Open windows on", selection: $preferred) {
            Text("Default display").tag("")
            ForEach(screens, id: \.self) { screen in
                Text(screen.localizedName).tag(WindowDisplay.identifier(screen))
            }
            if !preferred.isEmpty, !screens.contains(where: { WindowDisplay.identifier($0) == preferred }) {
                Text("Saved display (disconnected)").tag(preferred)
            }
        }
        .accessibilityIdentifier("preferredDisplay")
        Text("Applies to new windows and after restarting. Uses an available display if your choice is disconnected.")
            .foregroundStyle(.secondary)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
    }
}
