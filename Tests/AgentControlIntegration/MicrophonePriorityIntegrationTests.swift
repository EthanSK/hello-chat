// Exercise the real microphone settings API and paint its views in an isolated profile,
// without opening capture, showing windows or changing system audio. — GPT-6.1 Sol
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import HelloChat

@MainActor final class MicrophonePriorityIntegrationTests: XCTestCase {
    // A new priority edit invalidates the existing agent revision. An explicit single choice
    // then takes over through the same owner. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol.
    func testExplicitSelectionAndPriorityRevision() async throws {
        try requireIsolatedHome()
        let keys = [MicrophonePriority.defaultsKey, "inputDeviceUID"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let model = GateModel(enableSpotifyControl: false)
        XCTAssertFalse(model.enabled, "The isolated profile must not open microphone capture")
        let control = HAgentControl(model, zoom: InterfaceZoom(), updater: AppUpdater())
        func perform(_ name: String, _ arguments: [String: Any] = [:]) async throws -> HControlOutcome {
            try await control.handle(HControlRequest(JSONSerialization.data(withJSONObject: [
                "version": 1, "id": UUID().uuidString, "expiresAt": Date().timeIntervalSince1970 + 20,
                "operation": name, "arguments": arguments])))
        }
        func snapshot() async throws -> [String: Any] {
            let outcome = try await perform("settings.read")
            return try XCTUnwrap(outcome.result as? [String: Any])
        }
        let initial = try await snapshot()
        model.inputs.addToPriority(.init(id: 999999, uid: "fixture-disconnected", name: "Disconnected fixture"))
        let edited = try await snapshot()
        XCTAssertNotEqual(initial["revision"] as? String, edited["revision"] as? String)
        let oldRevision = try XCTUnwrap(edited["revision"] as? String)
        model.inputs.setPriorityEnabled(true)
        do {
            _ = try await perform("settings.microphone", ["uid": "", "revision": oldRevision])
            XCTFail("A newer priority-mode edit must reject a stale write")
        } catch HControlFailure.conflict { }
        XCTAssertTrue(model.inputs.priority.enabled)
        let current = try await snapshot()
        let settings = try XCTUnwrap(current["settings"] as? [String: Any])
        let priority = try XCTUnwrap(settings["microphonePriority"] as? [String: Any])
        XCTAssertEqual(priority["enabled"] as? Bool, true)
        let revision = try XCTUnwrap(current["revision"] as? String)
        do {
            _ = try await perform("settings.microphone", ["uid": "fixture-invalid", "revision": revision])
            XCTFail("An unavailable requested microphone must not disable priority mode")
        } catch HControlFailure.unavailable { }
        XCTAssertTrue(model.inputs.priority.enabled)
        _ = try await perform("settings.microphone", ["uid": "", "revision": revision])
        XCTAssertFalse(model.inputs.priority.enabled)
        XCTAssertEqual(model.inputs.selectedUID, "")
        XCTAssertEqual(model.inputs.priority.entries.map(\.uid), ["fixture-disconnected"])
        let final = try await snapshot()
        XCTAssertNotEqual(current["revision"] as? String, final["revision"] as? String)
        XCTAssertFalse(model.enabled)
        await model.notificationReplies.shutdown()
    }

    // The same production views paint empty, selected, disconnected and fallback states at the
    // narrow Home width and larger text, with fake devices and no visible window. — GPT-6.1 Sol
    func testMicrophoneViewsRenderOffscreen() throws {
        try requireIsolatedHome()
        guard let output = ProcessInfo.processInfo.environment["HCHAT_MICROPHONE_RENDER_DIR"] else {
            throw XCTSkip("Supply the task-owned render destination")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = oldAppearance }
        final class Inventory { var devices: [MicrophoneInput] = [] }
        let hardware = Inventory()
        let builtIn = MicrophoneInput(id: 1, uid: "fixture-built-in", name: "MacBook Pro Microphone")
        let usb = MicrophoneInput(id: 2, uid: "fixture-usb", name: "Studio USB microphone with a long descriptive name")
        let suite = "HelloChat.MicrophoneRenders." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        hardware.devices = [builtIn, usb]
        let inputs = MicrophoneInputs(defaults: defaults, hardware: .init(devices: { hardware.devices }, systemDefault: { builtIn.id }))
        func paint<V: View>(_ root: V, name: String, width: CGFloat, height: CGFloat) throws {
            let frame = NSRect(x: -20000, y: -20000, width: width, height: height)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: root.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: frame.size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
            XCTAssertFalse(window.isVisible)
            XCTAssertGreaterThan(data.count, 1000)
        }
        try paint(Form { MicrophoneSettings(inputs: inputs) { } }.formStyle(.grouped),
                  name: "home-single-narrow", width: 380, height: 130)
        try paint(Form { MicrophoneSettings(inputs: inputs) { } }.formStyle(.grouped),
                  name: "home-single-normal", width: 480, height: 130)
        try paint(MicrophonePriorityEditor(inputs: inputs), name: "priority-empty", width: 440, height: 420)
        inputs.addToPriority(usb)
        inputs.addToPriority(.init(id: 3, uid: "fixture-headset", name: "Travel Headset"))
        inputs.setPriorityEnabled(true)
        try paint(MicrophonePriorityEditor(inputs: inputs), name: "priority-connected", width: 520, height: 420)
        try paint(MicrophonePriorityEditor(inputs: inputs).font(.system(size: 16.9)).controlSize(.large),
                  name: "priority-large-text-narrow", width: 440, height: 480)
        try paint(Form { MicrophoneSettings(inputs: inputs) { } }.formStyle(.grouped),
                  name: "home-priority-narrow", width: 380, height: 130)
        hardware.devices = [builtIn]; inputs.refresh()
        try paint(MicrophonePriorityEditor(inputs: inputs), name: "priority-fallback", width: 520, height: 420)
        XCTAssertEqual(inputs.selected?.uid, builtIn.uid)
    }

    private func requireIsolatedHome() throws {
        guard let home = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: home).appendingPathComponent("control-fixture-owner").path)
        else { throw XCTSkip("Use the isolated control fixture") }
    }
}
