// Exercise the real update coordinator with injected state and no app installs.
import Foundation

@main enum UpdateInstallationTests {
    @MainActor static func until(_ ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { await Task.yield() }
        precondition(ready(), "Expected asynchronous update transition")
    }

    @MainActor static func main() async {
        var allowed = false, checks = 0, installs = 0
        let polling = UpdateInstallation(mayInstall: { checks += 1; return allowed },
            prepare: { true }, restore: {}, waitingChanged: { _ in },
            wait: { try await Task.sleep(nanoseconds: 1_000_000) })
        polling.offer { installs += 1 }
        await until { checks > 0 }
        allowed = true // No focus, model-busy or recording event accompanies this change.
        await until { installs == 1 }
        let finishedChecks = checks
        try? await Task.sleep(nanoseconds: 5_000_000)
        precondition(checks == finishedChecks, "No polling survives installation")

        var reading: CheckedContinuation<Void, Never>?
        var coalescedChecks = 0, coalescedInstalls = 0
        let coalescing = UpdateInstallation(mayInstall: {
            coalescedChecks += 1
            if coalescedChecks == 1 { await withCheckedContinuation { reading = $0 }; return false }
            return true
        }, prepare: { true }, restore: {}, waitingChanged: { _ in })
        coalescing.offer { coalescedInstalls += 1 }
        await until { reading != nil }
        coalescing.requestCheck() // The last event arrives during the old async snapshot.
        reading?.resume()
        await until { coalescedInstalls == 1 }
        precondition(coalescedChecks == 3, "A concurrent event gets a fresh read, then preparation is rechecked")

        var preparation: CheckedContinuation<Void, Never>?
        var recording = false, safetyChecks = 0, safetyRestores = 0, safeInstalls = 0
        let lateRecording = UpdateInstallation(mayInstall: {
            safetyChecks += 1
            return !recording
        }, prepare: {
            if preparation == nil { await withCheckedContinuation { preparation = $0 } }
            return true
        }, restore: { safetyRestores += 1 }, waitingChanged: { _ in })
        lateRecording.offer { safeInstalls += 1 }
        await until { preparation != nil }
        recording = true
        lateRecording.requestCheck()
        preparation?.resume()
        await until { safetyRestores == 1 }
        precondition(safeInstalls == 0 && safetyChecks >= 2,
                     "Recording that begins during preparation postpones installation and restores the app")
        recording = false
        lateRecording.requestCheck()
        await until { safeInstalls == 1 }
        precondition(safetyRestores == 1, "The pending offer survives until it is safe to install")

        var disabled = false, restores = 0, attempts = 0
        let reversible = UpdateInstallation(mayInstall: { true }, prepare: { disabled = true; return true },
            restore: { disabled = false; restores += 1 }, waitingChanged: { _ in })
        reversible.offer { attempts += 1 }
        await until { attempts == 1 }
        precondition(disabled)
        await reversible.abort()
        precondition(!disabled && restores == 1, "An installer abort restores the prepared runtime")
        reversible.offer { attempts += 1 }
        await until { attempts == 2 }
        await reversible.abort()
        precondition(!disabled && restores == 2, "A later update remains usable after an abort")

        var preparing: CheckedContinuation<Void, Never>?
        var stopped = false, recovered = false, lateInstalls = 0
        let cancellation = UpdateInstallation(mayInstall: { true }, prepare: {
            stopped = true
            await withCheckedContinuation { preparing = $0 }
            return true
        }, restore: { stopped = false; recovered = true }, waitingChanged: { _ in })
        cancellation.offer { lateInstalls += 1 }
        await until { preparing != nil }
        let abort = Task { await cancellation.abort() }
        await Task.yield()
        preparing?.resume()
        await abort.value
        precondition(recovered && !stopped && lateInstalls == 0,
                     "Abort waits for in-flight preparation before restoring, and never installs late")
        print("Update coordination: no-focus resume, event coalescing, abort recovery and cancellation ordering passed")
    }
}
