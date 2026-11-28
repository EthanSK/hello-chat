// Block the actual shared native writer and prove Quit drains it without allowing
// a queued second change. All hardware functions are injected. — GPT-6.1 Sol
import CoreAudio
import Foundation

@main enum SystemOutputVolumeDrainTests {
    @MainActor static func main() async throws {
        final class Hardware {
            let device = SystemOutputVolume.Device(id: 10, uid: "fixture", name: "Fixture")
            var level: Float = 0.7
            var writes: [Float] = []
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            func control() -> SystemOutputVolume {
                .init(hardware: .init(current: { self.device }, controls: { _ in
                    [.init(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: self.level)]
                }, muted: { _ in false }, write: { _, _, value in
                    self.writes.append(value); self.entered.signal(); self.release.wait(); self.level = value
                }))
            }
        }
        func received(_ semaphore: DispatchSemaphore) async {
            await withCheckedContinuation { continuation in DispatchQueue.global().async { semaphore.wait(); continuation.resume() } }
        }
        let f = Hardware(), owner = SystemOutputVolumeCommands(control: f.control())
        let first = Task { try await owner.set(30, on: f.device) }
        await received(f.entered)
        let queued = Task { try await owner.set(70, on: f.device) }
        owner.stopAccepting()
        var finished = false
        let quittingStarted = DispatchSemaphore(value: 0)
        let quit = Task { quittingStarted.signal(); await owner.finish(); finished = true }
        await received(quittingStarted)
        precondition(!finished, "Quit must not finish while an owned write is blocked")
        f.release.signal()
        let actual = try await first.value
        await quit.value
        precondition(finished && actual.percent == 30 && f.writes.count == 1)
        do { _ = try await queued.value; preconditionFailure("Queued work must refuse on Quit") }
        catch let error as SystemOutputVolume.OperationFailure { precondition(error.beforeDispatch) }
        do { _ = try await owner.set(50, on: f.device); preconditionFailure("Closed writer must refuse") }
        catch let error as SystemOutputVolume.OperationFailure { precondition(error.beforeDispatch) }
        print("Passed actual shared output writer drain/in-flight/queued-refusal checks; no hardware writes")
    }
}
