// Extraction of AppUpdater's existing pending-install handling, with new
// coalesced rechecks and reversible preparation after an installer abort.
// Polling exists only while a downloaded update is waiting, never at idle.
import Foundation

@MainActor final class UpdateInstallation {
    private let mayInstall: () async -> Bool
    private let prepare: () async -> Bool
    private let restore: () async -> Void
    private let wait: () async throws -> Void
    private let waitingChanged: (Bool) -> Void
    private var handler: (() -> Void)?
    private var checkTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var abortTask: Task<Void, Never>?
    private var checkAgain = false
    private var prepared = false
    private var generation = 0

    init(mayInstall: @escaping () async -> Bool, prepare: @escaping () async -> Bool,
         restore: @escaping () async -> Void, waitingChanged: @escaping (Bool) -> Void,
         wait: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }) {
        self.mayInstall = mayInstall; self.prepare = prepare; self.restore = restore
        self.waitingChanged = waitingChanged; self.wait = wait
    }

    func offer(_ handler: @escaping () -> Void) {
        generation += 1
        let token = generation, previousAbort = abortTask
        Task { @MainActor in
            await previousAbort?.value
            guard generation == token else { return }
            self.handler = handler; prepared = false
            waitingChanged(true)
            requestCheck()
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await self?.wait() } catch { return }
                    guard let self, self.handler != nil else { return }
                    self.requestCheck()
                }
            }
        }
    }

    func requestCheck() {
        guard handler != nil else { return }
        checkAgain = true
        guard checkTask == nil else { return }
        checkTask = Task { @MainActor in
            defer { checkTask = nil }
            while handler != nil, checkAgain, !Task.isCancelled {
                checkAgain = false
                let allowed = await mayInstall()
                guard !Task.isCancelled, handler != nil else { return }
                guard allowed else { continue }
                prepared = await prepare()
                guard !Task.isCancelled, prepared, let install = handler else { continue }
                // Preparation can await cancelled Voice work. A recording or
                // call may begin meanwhile, so the earlier read is not enough.
                let stillAllowed = await mayInstall()
                guard !Task.isCancelled, handler != nil else { return }
                guard stillAllowed else {
                    await restore()
                    prepared = false
                    continue
                }
                handler = nil; pollTask?.cancel(); pollTask = nil
                waitingChanged(false)
                install()
            }
        }
    }

    func abort() async {
        generation += 1
        handler = nil; checkAgain = false
        pollTask?.cancel(); pollTask = nil
        if let abortTask { await abortTask.value; return }
        let pending = checkTask
        pending?.cancel()
        waitingChanged(false)
        let recovery = Task { @MainActor in
            // A cancellation cannot interrupt arbitrary cleanup code. Wait for
            // that preparation before restoring, so it cannot undo the restore.
            await pending?.value
            if prepared { await restore(); prepared = false }
        }
        abortTask = recovery
        await recovery.value
        abortTask = nil
    }
}
