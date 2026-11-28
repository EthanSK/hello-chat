// Hold an injected remote operation and prove the actual rebinder leaves MainActor free.
// No observer notification is registered with another application. — GPT-6.1 Sol
import AppKit
import ApplicationServices
import Foundation

@main enum VoiceObserverRegistrationTests {
    @MainActor static func main() async {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var observer: AXObserver?
        precondition(AXObserverCreate(getpid(), { _, _, _, _ in }, &observer) == .success)
        let actual = observer!
        let token = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { token.deallocate() }
        let work = VoiceObserverRegistration(windows: { _ in
            precondition(!Thread.isMainThread); entered.signal(); release.wait(); return []
        }, remove: { _, _, _ in precondition(!Thread.isMainThread) }, add: { _, _, _, _ in
            precondition(!Thread.isMainThread); return true
        })
        let task = Task { await work.replace(observer: actual, pid: getpid(), previous: [], call: [], audio: [], readAudio: false, context: token) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        // This line executes on MainActor while the remote operation is still blocked.
        MainActor.preconditionIsolated()
        let mainStillResponsive = true
        release.signal()
        let entries = await task.value
        precondition(mainStillResponsive && entries.count == 7)
        await work.retire(observer: actual, entries: entries)
        print("Passed actual observer rebinding off-main/blocked-remote check; zero native registrations")
    }
}
