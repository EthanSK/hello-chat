// Verify native saved-frame restoration without showing a window or changing real preferences. — GPT-6.1 Sol
// Check native Home frame restoration and independent Settings placement offscreen. — GPT-6.1 Sol
import AppKit
import XCTest
@testable import HelloChat

@MainActor final class WindowTests: XCTestCase {
    func testSavedFrameWins() async throws {
        guard let home = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).path else { throw XCTSkip("Use the fixture") }
        guard WindowDisplay.preferredScreen != nil else { throw XCTSkip("No screen") }
        let key = "NSWindow Frame main"
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        let window = NSWindow(contentRect: NSRect(x: 123, y: 234, width: 400, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let desired = window.frame
        defer { window.close() }
        window.saveFrame(usingName: "main")
        window.setFrame(NSRect(x: 0, y: 0, width: 400, height: 400), display: false)
        let host = InitialWindowPlacement.Host()
        host.savedFrameName = "main"
        window.contentView = host
        let done = expectation(description: "settled")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(window.frame, desired)
        XCTAssertFalse(window.isVisible)
    }

    func testLaunchSnapshotSurvivesNativeAutosaveOverwrite() async throws {
        guard let home = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).path else { throw XCTSkip("Use the fixture") }
        guard WindowDisplay.preferredScreen != nil else { throw XCTSkip("No screen") }
        let key = "NSWindow Frame main", old = UserDefaults.standard.object(forKey: "NSWindow Frame main")
        defer { UserDefaults.standard.set(old, forKey: key) }
        let window = NSWindow(contentRect: NSRect(x: 123, y: 234, width: 400, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let desired = window.frame
        window.saveFrame(usingName: "main")
        let snapshot = try XCTUnwrap(UserDefaults.standard.string(forKey: key))
        window.setFrame(NSRect(x: 0, y: 0, width: 400, height: 400), display: false)
        window.saveFrame(usingName: "main")
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: key), snapshot)
        let host = InitialWindowPlacement.Host()
        host.savedFrameName = "main"; host.initialSavedFrame = snapshot
        window.contentView = host
        let done = expectation(description: "native placement finished")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(window.frame, desired)
        XCTAssertFalse(window.isVisible)
    }

    func testUnnamedSettingsPlacementDoesNotUseHomeFrame() async throws {
        guard let home = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).path else { throw XCTSkip("Use the fixture") }
        guard WindowDisplay.preferredScreen != nil else { throw XCTSkip("No screen") }
        let key = "NSWindow Frame main", old = UserDefaults.standard.object(forKey: "NSWindow Frame main")
        defer { UserDefaults.standard.set(old, forKey: key) }
        let window = NSWindow(contentRect: NSRect(x: 123, y: 234, width: 400, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let saved = window.frame
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.saveFrame(usingName: "main")
        window.contentView = InitialWindowPlacement.Host()
        let done = expectation(description: "settled")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNotEqual(window.frame, saved, "An unnamed Settings/preview window keeps its own existing placement")
        XCTAssertFalse(window.isVisible)
    }
}
