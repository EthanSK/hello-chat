// Temporary Codex defaults for H Chat's native new-Voice shortcut.
import AppKit
import Darwin
import Foundation

private enum ConfigWriteError: LocalizedError {
    case versionConflict
    var errorDescription: String? { "Codex settings changed while Voice was opening." }
}

actor CodexVoiceSpeed {
    static let shared = CodexVoiceSpeed()
    static let preferenceKey = "ultrafastForNewVoiceChats"
    static let model = "gpt-6.2-sol"
    static let effort = "high"
    static let tier = "ultrafast"
    private static let requested = ["model": model, "model_reasoning_effort": effort, "service_tier": tier]
    private let receipt: URL
    private var owner: UUID?
    private var defaultsLease: Int32?
    private let openDraft: (pid_t) throws -> VoiceDraftPicker
    private let generation: (pid_t) -> Date?
    private var draft: VoiceDraftPicker?
    private var sentAt: Date?
    private var latestSessionStart: Date?
    private var expiry: Task<Void, Never>?

    init(receipt: URL = AppPaths.support.appendingPathComponent("VoiceLaunch/defaults.json"),
         openDraft: @escaping (pid_t) throws -> VoiceDraftPicker = CodexVoiceDraft.open,
         generation: @escaping (pid_t) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate }) {
        self.receipt = receipt
        self.openDraft = openDraft
        self.generation = generation
    }

    // App actions and the no-launch diagnostic CLI share this same defaults receipt.
    // A native advisory lock survives actor reentrancy and releases on process exit;
    // another process must never recover an in-flight owner's temporary choices. — GPT-6.1 Sol
    private func acquireDefaultsLease() throws {
        if defaultsLease != nil { return }
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(receipt.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError.message("Couldn’t lock Codex settings.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw BridgeError.message("Another Codex settings action is running.")
        }
        defaultsLease = fd
    }
    private func releaseDefaultsLease() {
        guard let fd = defaultsLease else { return }
        defaultsLease = nil; flock(fd, LOCK_UN); close(fd)
    }

    // Save the actual user-layer entries. A missing key must be removed on restore,
    // so inherited defaults and later unrelated edits continue to work.
    private struct Edit: Codable { let key: String; let previous: String?; let temporary: String }
    // The optional native receipt is absent on older installs and on cold starts.
    private struct Native: Codable {
        let pid: pid_t
        let launched: Date
        let previous: DraftChoices
        var attempted: [String]
        var settled: [String]?
        var pendingEfforts: [String]?
        var speedBeforeSwitch: String?
        var previousModelID: String?
        var requested: DraftChoices?
    }
    private struct Saved: Codable { let file: String; let edits: [Edit]; var native: Native? }
    private func persist(_ saved: Saved) throws {
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).write(to: receipt, options: .atomic)
    }

    private struct Layer {
        let file: String
        let version: String
        let values: [String: Any]
    }

    static func executable(pid: Int32? = nil) throws -> URL {
        let url: URL
        if let pid {
            guard let app = VoiceBridge.currentApplication(), app.processIdentifier == pid, let bundle = app.bundleURL
            else { throw BridgeError.message("Codex closed while opening Voice.") }
            url = bundle
        } else { url = try VoiceBridge.applicationURL() }
        let resources = url.appendingPathComponent("Contents/Resources")
        let paths = ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"]
        guard let exe = paths.map({ resources.appendingPathComponent($0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw BridgeError.message("Couldn't find the Codex configuration tool.") }
        return exe
    }

    private func client(_ exe: URL, _ environment: [String: String]?) throws -> CodexConfigClient {
        let c = CodexConfigClient()
        do {
            try c.start(exe, environment: environment)
            _ = try c.request("initialize", ["clientInfo": ["name": "hello_chat", "version": "1"]])
            try c.notifyInitialized()
            return c
        } catch { c.close(); throw error }
    }

    private func layer(_ client: CodexConfigClient, file: String? = nil) throws -> Layer {
        let settings = try client.request("config/read", ["includeLayers": true])
        let layers = (settings["layers"] as? [[String: Any]] ?? []).compactMap { row -> Layer? in
            guard let name = row["name"] as? [String: Any], name["type"] as? String == "user",
                  let path = name["file"] as? String, let version = row["version"] as? String,
                  let values = row["config"] as? [String: Any], row["disabledReason"] as? String == nil
            else { return nil }
            return Layer(file: path, version: version, values: values)
        }
        guard let selected = file.flatMap({ f in layers.first { $0.file == f } }) ?? (file == nil ? layers.last : nil)
        else { throw client.failure }
        return selected
    }

    private func write(_ values: [(String, String?)], layer: Layer, client: CodexConfigClient) throws {
        let edits: [[String: Any]] = values.map { ["keyPath": $0.0, "mergeStrategy": "replace", "value": $0.1 as Any? ?? NSNull()] }
        let result = try client.request("config/batchWrite", ["edits": edits, "filePath": layer.file,
            "expectedVersion": layer.version, "reloadUserConfig": false])
        guard result["status"] as? String == "ok" else { throw client.failure }
    }

    func prepare(_ id: UUID, executable: URL, environment: [String: String]? = nil, runningPID: pid_t? = nil) throws {
        guard owner == nil else { throw BridgeError.message("Another Voice chat is opening.") }
        try acquireDefaultsLease()
        defer { if owner == nil { releaseDefaultsLease() } }
        try recover(executable: executable, environment: environment)
        if let runningPID {
            try prepareDraft(id, pid: runningPID, executable: executable, environment: environment)
            return
        }
        let c = try client(executable, environment)
        defer { c.close() }
        let original = try layer(c)
        let changes = Self.requested.sorted { $0.key < $1.key }.compactMap { key, requested -> Edit? in
            let previous = original.values[key] as? String
            return previous == requested ? nil : Edit(key: key, previous: previous, temporary: requested)
        }
        guard !changes.isEmpty else { return }
        try persist(Saved(file: original.file, edits: changes))
        owner = id
        do {
            try write(changes.map { ($0.key, $0.temporary) }, layer: original, client: c)
            let updated = try layer(c, file: original.file)
            guard changes.allSatisfy({ updated.values[$0.key] as? String == $0.temporary }) else { throw c.failure }
        } catch ConfigWriteError.versionConflict {
            // The server rejected the entire batch before any change. A concurrent
            // user edit can legitimately equal one of our requested values.
            owner = nil
            try FileManager.default.removeItem(at: receipt)
            throw ConfigWriteError.versionConflict
        } catch {
            owner = nil
            try restore(executable: executable, environment: environment)
            throw error
        }
    }

    private static func rawEffort(_ label: String) -> String { label == "Extra High" ? "xhigh" : label.lowercased() }
    private static let order = ["model", "model_reasoning_effort", "service_tier"]
    private func label(_ key: String, _ choices: DraftChoices) -> String {
        switch key {
        case "model": return choices.model
        case "model_reasoning_effort": return choices.effort
        default: return choices.speed
        }
    }
    private func select(_ key: String, _ value: String, _ picker: VoiceDraftPicker,
                        beforeEffortStep: (String, String) throws -> Void = { _, _ in }) throws {
        switch key {
        case "model": try picker.selectModel(value)
        case "model_reasoning_effort": try picker.selectEffort(value, beforeStep: beforeEffortStep)
        default: try picker.selectSpeed(value)
        }
    }
    private func readLayer(_ exe: URL, _ env: [String: String]?, file: String? = nil) throws -> Layer {
        let c = try client(exe, env)
        defer { c.close() }
        return try layer(c, file: file)
    }

    // The warm renderer can acknowledge a selection before its config write lands.
    // Re-read the config API only when the actual user file changes. A healthy,
    // already-persisted selection returns on the first read. This runs off MainActor.
    private func persistedValue(_ key: String, movingFrom pending: Set<String?>,
                                file: String, executable: URL, environment: [String: String]?) throws -> String? {
        let url = URL(fileURLWithPath: file)
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        var previousBytes: Data?
        repeat {
            let bytes: Data
            do { bytes = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { bytes = Data() }
            if previousBytes != bytes {
                previousBytes = bytes
                let raw = try readLayer(executable, environment, file: file).values[key] as? String
                if !pending.contains(raw) { return raw }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw BridgeError.message("Codex hasn’t finished saving the picker change.")
    }

    private func nativeModelID(_ name: String, configPath: String) -> String? {
        // Desktop's display name may hide provider prefixes or replace hyphens with spaces.
        struct Model: Decodable { let slug: String; let display_name: String }
        struct Catalogue: Decodable { let models: [Model] }
        let url = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode(Catalogue.self, from: data).models else { return nil }
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let matches = models.filter { normalized($0.display_name) == normalized(name) }
        return matches.count == 1 ? matches[0].slug : nil
    }

    private func prepareDraft(_ id: UUID, pid: pid_t, executable: URL, environment: [String: String]?, speedOnly: CodexChatSpeed.Speed? = nil) throws {
        guard let launched = generation(pid) else { throw BridgeError.message("Codex closed while opening Voice.") }
        let picker = try openDraft(pid)
        draft = picker
        do {
            let previous = try picker.choices()
            let requestedChoices: DraftChoices
            if let speedOnly {
                requestedChoices = previous.speed == DraftChoices.speedUnavailable
                    ? .init(model: DraftChoices.voice.model, effort: DraftChoices.voice.effort, speed: speedOnly.rawValue)
                    : .init(model: previous.model, effort: previous.effort, speed: speedOnly.rawValue)
            } else { requestedChoices = .voice }
            // Keep this verified composer through Start even if it needed no edits.
            // Closing it here could return focus to an existing chat with different choices.
            if previous == requestedChoices { owner = id; return }
            let original = try readLayer(executable, environment)
            let requested = ["model": requestedChoices.model == previous.model
                ? original.values["model"] as? String ?? Self.model : Self.model,
                "model_reasoning_effort": Self.rawEffort(requestedChoices.effort),
                "service_tier": requestedChoices.speed == "Standard" ? "default" : requestedChoices.speed.lowercased()]
            let edits = Self.order.map { Edit(key: $0, previous: original.values[$0] as? String, temporary: requested[$0]!) }
            var saved = Saved(file: original.file, edits: edits, native: Native(pid: pid, launched: launched, previous: previous, attempted: [], settled: []))
            saved.native?.previousModelID = nativeModelID(previous.model, configPath: original.file)
            guard previous.model == requestedChoices.model || saved.native?.previousModelID != nil || original.values["model"] as? String != nil else {
                throw BridgeError.message("Couldn’t read the previous Codex model. No settings changed.")
            }
            saved.native?.requested = requestedChoices
            owner = id
            var current = previous
            for key in Self.order {
                let target = label(key, requestedChoices)
                guard label(key, current) != target else { continue }
                let layer = try readLayer(executable, environment, file: original.file)
                guard layer.values[key] as? String == original.values[key] as? String else { throw ConfigWriteError.versionConflict }
                if key == "service_tier", previous.speed == DraftChoices.speedUnavailable {
                    guard current.speed != DraftChoices.speedUnavailable else {
                        throw BridgeError.message("Couldn’t find the speed control for the Voice model.")
                    }
                    saved.native?.speedBeforeSwitch = current.speed
                }
                saved.native?.attempted.append(key)
                try persist(saved)
                var intermediate: Set<String?> = [layer.values[key] as? String]
                try select(key, target, picker) { before, after in
                    intermediate.insert(Self.rawEffort(before))
                    intermediate.insert(Self.rawEffort(after))
                    saved.native?.pendingEfforts = [before, after]
                    try self.persist(saved)
                }
                current = try picker.choices()
                guard label(key, current) == target else { throw BridgeError.message("Codex didn’t confirm the Voice launch choices.") }
                intermediate.remove(requested[key])
                guard try persistedValue(key, movingFrom: intermediate, file: original.file, executable: executable,
                                         environment: environment) == requested[key] else { throw ConfigWriteError.versionConflict }
                saved.native?.settled?.append(key)
                try persist(saved)
            }
            saved.native?.pendingEfforts = nil
            try persist(saved)
            guard current == requestedChoices else { throw BridgeError.message("The Codex Voice launch choices changed.") }
        } catch {
            do { try release(executable, environment) }
            catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
            throw error
        }
    }

    // Only reverse settings this launch changed that still carry our value. The picker
    // updates the warm renderer; the config transaction below preserves inherited keys.
    private func restoreDraft(_ saved: Saved, native: Native, executable: URL, environment: [String: String]?) throws -> [Edit] {
        let requested = native.requested ?? .voice
        let edits = saved.edits.filter { native.attempted.contains($0.key) }
        var current = try readLayer(executable, environment, file: saved.file)
        // A native selection may still be queued when physical input makes the draft
        // unreadable. Keep the recovery receipt instead of treating the old file value
        // as proof that nothing changed. Found by Claude Opus 5.5. Fixed by GPT-6.1 Sol.
        if generation(native.pid) == native.launched,
           edits.contains(where: { native.settled?.contains($0.key) != true &&
               current.values[$0.key] as? String == $0.previous && $0.previous != $0.temporary }),
           draft.flatMap({ try? $0.choices() }) == nil {
            throw BridgeError.message("Codex hasn’t finished saving. Its previous settings haven’t been restored yet.")
        }
        if generation(native.pid) == native.launched, let draft, let visible = try? draft.choices() {
            // A failed UI check may still have sent a key. Wait for that observed
            // action before deciding there is nothing to undo.
            for edit in edits where native.settled?.contains(edit.key) != true &&
                current.values[edit.key] as? String == edit.previous && edit.previous != edit.temporary {
                let now = label(edit.key, visible)
                let moved = now == label(edit.key, requested) || (edit.key == "model_reasoning_effort" &&
                    now != native.previous.effort && native.pendingEfforts?.contains(now) == true)
                if moved && now != label(edit.key, native.previous) {
                    _ = try persistedValue(edit.key, movingFrom: [edit.previous], file: saved.file,
                                           executable: executable, environment: environment)
                    current = try readLayer(executable, environment, file: saved.file)
                }
            }
        }
        let owned: [Edit] = edits.compactMap { edit in
            guard let raw = current.values[edit.key] as? String else { return nil }
            if raw == edit.temporary { return edit }
            // An interrupted arrow sequence may have already committed its intermediate step.
            guard edit.key == "model_reasoning_effort", raw != edit.previous,
                  native.pendingEfforts?.contains(where: { Self.rawEffort($0) == raw }) == true else { return nil }
            return Edit(key: edit.key, previous: edit.previous, temporary: raw)
        }
        guard generation(native.pid) == native.launched else { return owned }
        guard !owned.isEmpty else { return [] }
        // Desktop writes model and effort together. If another composer has changed
        // either since preparation, restore from a fresh draft carrying that manual pick.
        let coupled = ["model", "model_reasoning_effort"]
        let otherComposerChanged = saved.edits.contains { edit in
            guard coupled.contains(edit.key), !owned.contains(where: { $0.key == edit.key }) else { return false }
            let expected = native.attempted.contains(edit.key) ? edit.temporary : edit.previous
            return current.values[edit.key] as? String != expected
        }
        let picker: VoiceDraftPicker
        if !otherComposerChanged, let draft, (try? draft.choices()) != nil { picker = draft }
        else {
            draft?.closeIfEmpty()
            picker = try openDraft(native.pid)
            draft = picker
        }
        var cleanup: [Edit] = []
        // If the ordinary model hides Speed, restore the speed while its picker is still visible.
        let restoreOrder = native.speedBeforeSwitch == nil ? owned :
            owned.filter { $0.key == "service_tier" } + owned.filter { $0.key != "service_tier" }
        for edit in restoreOrder {
            let config = try readLayer(executable, environment, file: saved.file)
            let choices = try picker.choices()
            let visible = label(edit.key, choices)
            let sameSelection = edit.key == "model_reasoning_effort"
                ? Self.rawEffort(visible) == edit.temporary : visible == label(edit.key, requested)
            guard config.values[edit.key] as? String == edit.temporary, sameSelection else { continue }
            if edit.key == "model", let effort = config.values["model_reasoning_effort"] as? String,
               !owned.contains(where: { $0.key == "model_reasoning_effort" }), Self.rawEffort(choices.effort) != effort {
                // A stale picker would overwrite somebody else's effort when choosing the model.
                continue
            }
            let old = edit.key == "service_tier" ? (native.speedBeforeSwitch ?? native.previous.speed) : label(edit.key, native.previous)
            var pending: Set<String?> = [edit.temporary]
            try select(edit.key, old, picker) { before, after in
                pending.insert(Self.rawEffort(before)); pending.insert(Self.rawEffort(after))
            }
            guard label(edit.key, try picker.choices()) == old else { throw BridgeError.message("Couldn’t restore the previous Codex choices.") }
            let nativeRaw: String?
            switch edit.key {
            case "model_reasoning_effort": nativeRaw = Self.rawEffort(old)
            case "service_tier": nativeRaw = old == "Standard" ? "default" : old.lowercased()
            default: nativeRaw = native.previousModelID ?? edit.previous
            }
            pending.remove(nativeRaw)
            let raw = try persistedValue(edit.key, movingFrom: pending, file: saved.file, executable: executable, environment: environment)
            // Only remove/replace the exact value our picker was expected to save.
            // A later manual choice is authoritative.
            if let raw, raw != edit.previous, raw == nativeRaw {
                cleanup.append(Edit(key: edit.key, previous: edit.previous, temporary: raw))
            }
        }
        return cleanup
    }

    // Read-only still opens a menu, so it participates in the same UI lease. — GPT-6.1 Sol
    func observe(thread: UUID) async -> CodexChatSpeed.Result {
        guard owner == nil else { return .init(status: "busy", thread: thread, speed: nil, model: nil) }
        do {
            try acquireDefaultsLease()
            let id = UUID(); owner = id
            defer { if owner == id { owner = nil; releaseDefaultsLease() } }
            let operation = Task.detached { CodexChatSpeed.perform(thread: thread, speed: nil) }
            return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        } catch { return .init(status: "unavailable", thread: thread, speed: nil, model: nil) }
    }
    // Existing-chat speed and warm startup share this one defaults owner and recovery
    // receipt. A visible speed control changes only speed; a speedless model uses the
    // existing temporary eligible-model path, then restores its original choices. — GPT-6.1 Sol
    func existingChatSpeed(thread: UUID, speed: CodexChatSpeed.Speed = .ultrafast,
                           expectedCall: VoicePeerCall? = nil) async -> CodexChatSpeed.Result {
        guard let pid = VoiceBridge.currentApplication()?.processIdentifier,
              let executable = try? Self.executable(pid: pid) else {
            return .init(status: "unavailable", thread: thread, speed: nil, model: nil)
        }
        return await preservingSpeedDefaults(thread: thread, speed: speed, pid: pid, executable: executable, inspect: {
            let operation = Task.detached { CodexChatSpeed.perform(thread: thread, speed: nil, expectedCall: expectedCall) }
            return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        }) {
            let operation = Task.detached { CodexChatSpeed.perform(thread: thread, speed: speed, expectedCall: expectedCall) }
            return await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        }
    }

    // The same exact defaults transaction is injectable for offline protocol/rollback tests.
    // It never starts Voice or sends a message. — GPT-6.1 Sol
    func preservingSpeedDefaults(thread: UUID, speed: CodexChatSpeed.Speed, pid: pid_t,
                                 executable: URL, environment: [String: String]? = nil,
                                 inspect: (@Sendable () async -> CodexChatSpeed.Result)? = nil,
                                 apply: @Sendable () async -> CodexChatSpeed.Result) async -> CodexChatSpeed.Result {
        guard owner == nil else { return .init(status: "busy", thread: thread, speed: nil, model: nil) }
        let id = UUID()
        var applied: CodexChatSpeed.Result?
        do {
            try acquireDefaultsLease()
            defer { if owner == nil { releaseDefaultsLease() } }
            try recover(executable: executable, environment: environment)
            owner = id
            if let inspect {
                let before = await inspect()
                if !before.succeeded || before.speed == speed {
                    try release(executable, environment)
                    return before.succeeded
                        ? .init(status: "unchanged", thread: thread, speed: before.speed, model: before.model) : before
                }
            }
            try prepareDraft(id, pid: pid, executable: executable, environment: environment, speedOnly: speed)
            if !FileManager.default.fileExists(atPath: receipt.path) {
                // A warm picker may already show the target while the saved default differs.
                // Preserve that raw inherited/explicit value around the target's write too.
                let layer = try readLayer(executable, environment)
                try persist(Saved(file: layer.file, edits: [.init(key: "service_tier",
                    previous: layer.values["service_tier"] as? String,
                    temporary: speed == .standard ? "default" : speed.rawValue.lowercased())]))
            }
            let result = await apply()
            applied = result
            try release(executable, environment)
            return result
        } catch {
            if owner == id {
                do { try release(executable, environment) }
                catch { Diagnostics.shared.failure("voice.chat_speed.defaults_restore_failed", error) }
            }
            return .init(status: applied == nil ? "unavailable" : "defaultsUnconfirmed", thread: thread,
                         speed: applied?.speed, model: applied?.model)
        }
    }

    func recover(executable: URL, environment: [String: String]? = nil) throws {
        guard owner == nil else { return }
        let acquired = defaultsLease == nil
        try acquireDefaultsLease()
        defer { if acquired { releaseDefaultsLease() } }
        try restore(executable: executable, environment: environment)
    }
    private func restore(executable: URL, environment: [String: String]?) throws {
        defer { draft?.closeIfEmpty(); draft = nil }
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: receipt))
        let edits: [Edit]
        if let native = saved.native { edits = try restoreDraft(saved, native: native, executable: executable, environment: environment) }
        else { edits = saved.edits }
        let c = try client(executable, environment)
        defer { c.close() }
        func restoreOwnedKeys() throws -> Int {
            let current = try layer(c, file: saved.file)
            let owned = edits.filter { current.values[$0.key] as? String == $0.temporary }
            if !owned.isEmpty {
                try write(owned.map { ($0.key, $0.previous) }, layer: current, client: c)
                let checked = try layer(c, file: saved.file)
                guard owned.allSatisfy({ checked.values[$0.key] as? String == $0.previous }) else { throw c.failure }
            }
            return owned.count
        }
        let restored: Int
        do { restored = try restoreOwnedKeys() } catch ConfigWriteError.versionConflict {
            restored = try restoreOwnedKeys()
        }
        try FileManager.default.removeItem(at: receipt)
        Diagnostics.shared.record("voice.defaults.restored", numbers: ["keys": Double(restored)])
    }

    // The floating Voice UI can appear before thread creation. Use the existing
    // local session-start observer. Failed and abandoned launches release immediately.
    func finish(_ id: UUID, sent: Date?, executable: URL, environment: [String: String]? = nil,
                timeout: TimeInterval = 15) throws {
        guard owner == id else { return }
        if let sent, latestSessionStart.map({ $0 < sent }) ?? true {
            sentAt = sent
            expiry?.cancel()
            expiry = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard owner == id else { return }
                Diagnostics.shared.record("voice.defaults.session_unverified")
                do { try release(executable, environment) } catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
            }
        } else { try release(executable, environment) }
    }
    func observedSessionStart(_ date: Date, executable: URL, environment: [String: String]? = nil) throws {
        latestSessionStart = date
        if let sentAt, date >= sentAt, owner != nil { try release(executable, environment) }
    }
    private func release(_ exe: URL, _ environment: [String: String]?) throws {
        defer { releaseDefaultsLease() }
        expiry?.cancel(); expiry = nil; sentAt = nil; owner = nil
        try restore(executable: exe, environment: environment)
    }
    func shutdown() throws {
        guard draft != nil || FileManager.default.fileExists(atPath: receipt.path) else { return }
        if owner == nil { try recover(executable: Self.executable()) }
        else { try release(Self.executable(), nil) }
    }
    func recoverOnLaunch() {
        guard owner == nil, FileManager.default.fileExists(atPath: receipt.path) else { return }
        do { try recover(executable: Self.executable()) }
        catch { Diagnostics.shared.failure("voice.defaults.restore_failed", error) }
    }
}

// This short-lived client only reads and writes configuration. It never opens threads or calls.
// Bound the exchange so an unresponsive Codex binary cannot leave H Chat stuck on Start.
private final class CodexConfigClient {
    let failure = BridgeError.message("Couldn’t update the Codex Voice launch settings.")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var buffer = Data()
    private let deadline = ProcessInfo.processInfo.systemUptime + 8

    func start(_ executable: URL, environment: [String: String]?) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw failure }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func notifyInitialized() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"method\":\"initialized\"}\n".utf8))
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["id": nextID, "method": method, "params": params])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        while true {
            let line = try readLine()
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw failure }
            guard reply["id"] as? Int == nextID else { continue }
            if let error = reply["error"] as? [String: Any], let data = error["data"] as? [String: Any],
               data["config_write_error_code"] as? String == "configVersionConflict" {
                throw ConfigWriteError.versionConflict
            }
            guard let result = reply["result"] as? [String: Any] else { throw failure }
            return result
        }
    }

    private func readLine() throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < 16 * 1024 * 1024 else { throw failure }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let timeout = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&item, 1, timeout)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw failure }
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw failure
    }
}
