// Connect the reversible volume lease to native Spotify Apple Events and the
// read-only call observer. All application events run away from the UI thread.
import AppKit
import ApplicationServices
import Carbon
import Combine
import Foundation

enum SpotifyVolumeControl {
    private static let volumeProperty: OSType = 0x70566f6c // Spotify's own pVol, never system output.

    static func application() -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
            .filter { !$0.isTerminated }
        return apps.count == 1 ? apps[0] : nil
    }

    static func authorize(ask: Bool) throws {
        guard let app = application() else { throw SpotifyControlError.unavailable }
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), typeWildCard, ask)
        if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            throw SpotifyControlError.permissionRequired
        }
        guard status == noErr else { throw SpotifyControlError.appleEvent(status) }
    }

    static func read() throws -> Int? {
        guard application() != nil else { return nil }
        try authorize(ask: false)
        let reply = try send(eventID: AEEventID(kAEGetData))
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            throw SpotifyControlError.invalidReply
        }
        let volume = Int(value.int32Value)
        guard (0...100).contains(volume) else { throw SpotifyControlError.invalidReply }
        return volume
    }

    static func write(_ volume: Int, expected: Int, exact: Bool) throws -> Int {
        guard (0...100).contains(volume) else { throw SpotifyControlError.invalidReply }
        guard let app = application() else { throw SpotifyControlError.unavailable }
        // The user can move the slider, or Spotify can restart, after the
        // original snapshot. Do not overwrite that intervening change.
        return try SpotifyVolumeWrite.perform(volume, expected: expected, read: {
            guard application()?.processIdentifier == app.processIdentifier else { throw SpotifyControlError.volumeChanged }
            return try read()
        }, exact: exact, set: { requested in
            _ = try send(eventID: AEEventID(kAESetData), volume: requested, processIdentifier: app.processIdentifier)
        })
    }

    private static func send(eventID: AEEventID, volume: Int? = nil, processIdentifier: pid_t? = nil) throws -> NSAppleEventDescriptor {
        // Address the existing process, so a quit race cannot launch Spotify.
        guard let app = application() else { throw SpotifyControlError.unavailable }
        guard processIdentifier == nil || processIdentifier == app.processIdentifier else { throw SpotifyControlError.volumeChanged }
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        property.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        property.setDescriptor(NSAppleEventDescriptor(typeCode: volumeProperty), forKeyword: AEKeyword(keyAEKeyData))
        property.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let object = property.coerce(toDescriptorType: OSType(typeObjectSpecifier)) else {
            throw SpotifyControlError.invalidReply
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        if let volume { event.setParam(NSAppleEventDescriptor(int32: Int32(volume)), forKeyword: AEKeyword(keyAEData)) }
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw SpotifyControlError.appleEvent(error.int32Value)
        }
        return reply
    }
}

@MainActor final class SpotifyVoiceVolume: ObservableObject {
    @Published private(set) var permissionRequired = false
    @Published private(set) var message = ""
    private let monitor: VoiceCallMonitor
    private let queue = DispatchQueue(label: "HelloChat.spotify-volume", qos: .utility)
    private let session: SpotifyVolumeSession
    private var enabled = false
    private var presence: VoiceCallPresence = .unknown
    private var callIdentifier: String?
    private var microphoneMuted: Bool?
    // Why the observer last changed presence: metadata only, for diagnostics.
    private var evidence: String?
    private(set) var callEpoch = 0
    private var generation = 0
    private var spotifyLaunchObserver: NSObjectProtocol?

    init(monitor: VoiceCallMonitor, receiptURL: URL = AppPaths.support.appendingPathComponent("SpotifyVolume/restore.json")) {
        self.monitor = monitor
        let receipt = SpotifyVolumeReceipt(url: receiptURL)
        session = SpotifyVolumeSession(access: .init(read: SpotifyVolumeControl.read, write: SpotifyVolumeControl.write,
            load: receipt.load, save: receipt.save))
    }

    func observe(_ state: VoiceCallObservation) {
        guard enabled else { return }
        let nextIdentifier = state.presence == .inactive ? nil : state.callIdentifier ?? callIdentifier
        guard state.presence != presence || nextIdentifier != callIdentifier else { return }
        if state.presence == .inactive || (callIdentifier != nil && nextIdentifier != callIdentifier) {
            microphoneMuted = nil
            callEpoch += 1
        }
        presence = state.presence
        callIdentifier = nextIdentifier
        evidence = state.evidence
        reconcile()
    }

    // Only H Chat's confirmed microphone commands control this override.
    // Agent Flow recording and speaker silence can change native audio state
    // independently, so generic accessibility reads never set it.
    func confirmMicrophoneMute(_ muted: Bool, in epoch: Int) {
        guard enabled, epoch == callEpoch else { return }
        microphoneMuted = muted
        if presence == .active { reconcile() }
        else { monitor.refresh() }
    }

    // Keep Ethan's phrase-to-Spotify behavior without making its native key wait
    // for Voice buttons. This is the requested phrase direction, not mute readback. — GPT-6.1 Sol
    func microphonePhraseSent(_ requestedMuted: Bool, in epoch: Int) {
        guard enabled, epoch == callEpoch, presence == .active else { return }
        microphoneMuted = requestedMuted
        reconcile()
    }

    func setEnabled(_ value: Bool) {
        observeSpotifyLaunch()
        enabled = value; generation += 1; callEpoch += 1
        presence = value ? .unknown : .inactive
        callIdentifier = nil
        microphoneMuted = nil
        evidence = nil
        if !value { reconcile() }
    }

    func requestPermission() {
        let generation = self.generation
        queue.async { [weak self] in
            let granted: Bool
            do { try SpotifyVolumeControl.authorize(ask: true); granted = true }
            catch { granted = false; Diagnostics.shared.failure("spotify.permission.failed", error) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if granted { self.permissionRequired = false }
                self.reconcile(); self.monitor.refresh()
            }
        }
    }

    private func observeSpotifyLaunch() {
        guard spotifyLaunchObserver == nil else { return }
        spotifyLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.spotify.client" else { return }
                // Even after the setting is disabled, a receipt can be waiting
                // for Spotify to reopen. Restore it without restarting H Chat.
                Task { @MainActor [weak self] in self?.reconcile() }
            }
    }

    func volumeLimitChanged() {
        if enabled, presence == .active { reconcile(limitEdited: true) }
    }

    func setVolume(to volume: Int, beforeWrite: (() throws -> Void)? = nil) async throws -> Int {
        generation += 1 // Older automatic checks cannot replace this command's permission result.
        let generation = self.generation
        let session = self.session
        let preserve = enabled && presence != .inactive
        let identifier = callIdentifier
        do {
            let actual: Int = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try session.setVolume(volume, preservingForCall: preserve, callIdentifier: identifier, beforeWrite: beforeWrite)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            if self.generation == generation { permissionRequired = false; message = "" }
            return actual
        } catch {
            let cause = (error as? SpotifyVolumeOperationFailure)?.underlying ?? error
            if self.generation == generation, case SpotifyControlError.permissionRequired = cause {
                permissionRequired = true
                message = "Allow Spotify control to set its volume."
            }
            throw error
        }
    }

    private func reconcile(limitEdited: Bool = false) {
        let limit = SpotifyVolumePolicy.limit()
        let state = enabled ? presence : .inactive
        let callIdentifier = self.callIdentifier
        let microphoneMuted = self.microphoneMuted
        let evidence = enabled ? self.evidence ?? "none" : "disabled"
        generation += 1
        let generation = self.generation
        let session = self.session
        queue.async { [weak self] in
            do {
                let result = try session.reconcile(state, callIdentifier: callIdentifier, microphoneMuted: microphoneMuted, limit: limit, limitEdited: limitEdited)
                Diagnostics.shared.record("spotify.volume.reconciled", info: [
                    "result": result.rawValue, "call": state.rawValue,
                    "microphone_volume_request": microphoneMuted.map { $0 ? "mute" : "unmute" } ?? "none",
                    "evidence": evidence
                ])
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if [.lowered, .restored, .manualChange, .unchanged].contains(result) { self.permissionRequired = false }
                    switch result {
                    case .lowered: self.message = "Spotify chat volume limit is \(limit)%."
                    case .restored: self.message = "Spotify volume restored."
                    case .manualChange: self.message = "Spotify volume changed manually."
                    case .spotifyClosed: self.message = "Spotify is closed."
                    case .uncertain: self.message = "Checking chat status…"
                    case .idle, .unchanged: self.message = ""
                    }
                }
            } catch {
                Diagnostics.shared.failure("spotify.volume.failed", error)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    if case SpotifyControlError.permissionRequired = error {
                        self.permissionRequired = true
                        self.message = "Allow Spotify control to lower its volume."
                    } else { self.message = "Could not change Spotify volume." }
                }
            }
        }
    }

    func shutdown(preservingVolume: Bool) async {
        generation += 1; callEpoch += 1
        if let spotifyLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(spotifyLaunchObserver) }
        spotifyLaunchObserver = nil
        let session = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                // A normal Quit restores promptly and leaves Codex Voice alone.
                // An updater transfers the saved lease to the replacement app.
                if !preservingVolume {
                    do { _ = try session.reconcile(.inactive, preservingManualOverride: true) }
                    catch { Diagnostics.shared.failure("spotify.restore_on_quit.failed", error) }
                }
                continuation.resume()
            }
        }
    }
}
