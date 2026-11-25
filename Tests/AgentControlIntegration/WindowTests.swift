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
        window.contentView = InitialWindowPlacement.Host()
        let done = expectation(description: "settled")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(window.frame, desired)
        XCTAssertFalse(window.isVisible)
    }
}
