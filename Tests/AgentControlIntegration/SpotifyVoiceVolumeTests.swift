// Actual controller and serial volume owner, with inert Spotify access and an unstarted monitor. — GPT-6.1 Sol
import Foundation
import XCTest
@testable import HelloChat

@MainActor final class SpotifyVoiceVolumeTests: XCTestCase {
    final class Player: @unchecked Sendable {
        var volume = 49
        var writes: [Int] = []
        var receipt: SpotifyVolumeLease?
        var access: SpotifyVolumeSession.Access {
            .init(read: { self.volume }, write: { value, expected, _ in
                guard self.volume == expected else { throw SpotifyControlError.volumeChanged }
                self.volume = value; self.writes.append(value); return value
            }, load: { self.receipt }, save: { self.receipt = $0 })
        }
    }
    private func isolatedHome() throws {
        guard let expected = ProcessInfo.processInfo.environment["HCHAT_CONTROL_FIXTURE_HOME"],
              expected == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: expected).appendingPathComponent("control-fixture-owner").path)
        else { throw XCTSkip("Run with the isolated control-fixture home.") }
    }
    func testNativeControlsAndPhrasesShareOneBaseline() async throws {
        try isolatedHome()
        let saved = UserDefaults.standard.object(forKey: SpotifyVolumePolicy.preferenceKey)
        defer { UserDefaults.standard.set(saved, forKey: SpotifyVolumePolicy.preferenceKey) }
        UserDefaults.standard.set(40, forKey: SpotifyVolumePolicy.preferenceKey)
        let player = Player(), monitor = VoiceCallMonitor()
        let controller = SpotifyVoiceVolume(monitor: monitor, access: player.access)
        controller.setEnabled(true)
        XCTAssertTrue(monitor.observesAudioState)
        func native(_ mic: Bool?, _ output: Bool?, call: String = "call", at: Double = Diagnostics.now) async {
            controller.observe(.init(presence: .active, callIdentifier: call, verifiedCallIdentifier: call,
                                     observedAt: at, microphoneMuted: mic, outputSilenced: output))
            await controller.waitForPendingChanges()
        }
        await native(false, false)
        XCTAssertEqual(player.volume, 40)
        await native(false, true) // Native speaker control without any H Chat command.
        XCTAssertEqual(player.volume, 49)
        await native(true, true)
        await native(false, true)
        await native(nil, nil) // An unreadable control cannot clear the remaining reason.
        XCTAssertEqual(player.writes, [40, 49])
        await native(false, false)
        XCTAssertEqual(player.writes, [40, 49, 40])
        let oldRead = Diagnostics.now - 1
        let epoch = controller.callEpoch
        controller.outputPhraseSent(true, in: epoch)
        await controller.waitForPendingChanges()
        XCTAssertEqual(player.volume, 49)
        await native(false, false, at: oldRead)
        XCTAssertEqual(player.volume, 49, "A pre-command native read must not undo the admitted direction")
        controller.microphonePhraseSent(true, in: epoch)
        controller.outputPhraseSent(false, in: epoch)
        await controller.waitForPendingChanges()
        XCTAssertEqual(player.volume, 49, "Un-silencing output leaves the microphone reason active")
        controller.microphonePhraseSent(false, in: epoch)
        await controller.waitForPendingChanges()
        XCTAssertEqual(player.volume, 40)
        await native(true, false)
        XCTAssertEqual(player.volume, 49, "The native microphone control restores too")
        await native(false, false, call: "next", at: oldRead)
        XCTAssertEqual(player.volume, 40, "A new exact call must not inherit the old call's intent clocks")
        controller.outputPhraseSent(true, in: epoch)
        await controller.waitForPendingChanges()
        XCTAssertEqual(player.volume, 40, "An old call's delayed command cannot affect this call")
        _ = try await controller.setVolume(to: 49)
        await native(true, true, call: "next")
        await native(false, false, call: "next")
        XCTAssertEqual(player.volume, 49, "Preserve an explicit manual choice")
        controller.setEnabled(false)
        await controller.waitForPendingChanges()
        XCTAssertFalse(monitor.observesAudioState)
        let writes = player.writes
        await native(true, true, call: "next")
        XCTAssertEqual(player.writes, writes)
        await controller.shutdown(preservingVolume: false)
    }
}
