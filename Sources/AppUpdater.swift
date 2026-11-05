// Sparkle owns update discovery, signatures and installation. The app only
// postpones a relaunch during this helper's own operations and prepares a normal
// detach before releasing Sparkle's install callback. External calls continue.
import AppKit
import Combine
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var waitingToInstall = false
    @Published private(set) var configured = false
    private weak var model: GateModel?
    private var prepareToQuit: (() async -> Bool)?
    private var restoreAfterAbort: (() async -> Void)?
    private var observations = Set<AnyCancellable>()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: nil)
    private lazy var installation = UpdateInstallation(mayInstall: { [weak self] in
        guard let model = self?.model else { return false }
        return UpdateSafety.canRelaunch(busy: model.busy, checkingSpeech: model.checkingSpeech)
    }, prepare: { [weak self] in
        guard let prepare = self?.prepareToQuit else { return false }
        return await prepare()
    }, restore: { [weak self] in await self?.restoreAfterAbort?() },
    waitingChanged: { [weak self] in self?.waitingToInstall = $0 })

    var automaticChecks: Bool {
        get { configured && controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var automaticDownloads: Bool {
        get { configured && controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    func start(model: GateModel, prepareToQuit: @escaping () async -> Bool,
               restoreAfterAbort: @escaping () async -> Void) {
        guard self.model == nil else { return }
        self.model = model
        self.prepareToQuit = prepareToQuit
        self.restoreAfterAbort = restoreAfterAbort
        // Unconfigured development builds never pretend to offer a working
        // updater. Release packaging requires the real, matching public key.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        configured = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        model.$busy.combineLatest(model.$checkingSpeech)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Published sends before its value changes; yield to read
                    // the resulting state, without adding a timed delay.
                    await Task.yield()
                    self?.resumeIfIdle()
                }
            }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.resumeIfIdle() }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] _ in self?.resumeIfIdle() }.store(in: &observations)
        controller.startUpdater()
    }

    func checkForUpdates() { if canCheck { controller.checkForUpdates(nil) } }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installation.offer {
            Diagnostics.shared.record("update.relaunch.ready")
            installHandler()
        }
        return true
    }

    func resumeIfIdle() {
        installation.requestCheck()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { await installation.abort() }
        Diagnostics.shared.failure("update.aborted", error)
    }
}
