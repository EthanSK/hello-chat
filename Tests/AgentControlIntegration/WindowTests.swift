// Verify native saved-frame restoration without showing a window or changing real preferences. — GPT-6.1 Sol
// Check native Home frame restoration and independent Settings placement offscreen. — GPT-6.1 Sol
import AppKit
import XCTest
@testable import HelloChat

@MainActor final class WindowTests: XCTestCase {
    // Opt-in cross-process ordering on the built-in display. No foreign window, app activation,
    // media control or ordinary user preference is changed. — GPT-6.1 Sol
    func testHomeYieldsToExistingForegroundWindow() async throws {
        guard ProcessInfo.processInfo.environment["HCHAT_LIVE_WINDOW_ORDER_FIXTURE"] == "1",
              let home = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).path else { throw XCTSkip("Use the opt-in isolated native fixture") }
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.localizedName == "Built-in Retina Display" })
        let application = NSApplication.shared, oldPolicy = NSApplication.shared.activationPolicy()
        guard application.setActivationPolicy(.accessory) else { throw XCTSkip("Native fixture cannot present its window") }
        defer { application.setActivationPolicy(oldPolicy) }
        let front = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        guard front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              front.activationPolicy == .regular else { throw XCTSkip("No independent foreground app") }
        let target = AppCandidate(id: try XCTUnwrap(front.bundleIdentifier), names: ["Native fixture target"], url: front.bundleURL, pid: front.processIdentifier)
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 150, y: screen.visibleFrame.midY - 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "H Chat window-order check"
        defer { window.close() }
        let presentation = PhraseWindowPresentation()
        presentation.attach(window)
        XCTAssertTrue(presentation.show())
        let displayed = expectation(description: "native window ordering processed")
        DispatchQueue.main.async { displayed.fulfill() }
        await fulfillment(of: [displayed], timeout: 2)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front.processIdentifier)
        let before = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownIndex = try XCTUnwrap(before.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber })
        let targetIndex = try XCTUnwrap(before.firstIndex { ($0[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 })
        XCTAssertLessThan(ownIndex, targetIndex, "Reproduce the focused app below newly raised Home")
        let frame = window.frame
        let firstResult = presentation.yield(to: target)
        let ordered = expectation(description: "WindowServer processed native order")
        DispatchQueue.main.async { ordered.fulfill() }
        await fulfillment(of: [ordered], timeout: 2)
        let after = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let afterOwn = try XCTUnwrap(after.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber })
        let afterTarget = try XCTUnwrap(after.firstIndex { ($0[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 })
        print("WINDOW_ORDER first=\(firstResult) before=\(ownIndex),\(targetIndex) after=\(afterOwn),\(afterTarget)")
        XCTAssertGreaterThan(afterOwn, afterTarget, "Native ordering must reveal the requested app above Home")
        XCTAssertTrue(presentation.yield(to: target), "Repeated commands yield to an already-active app")
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front.processIdentifier)
    }

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
