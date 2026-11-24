// The signed desktop process serves the versioned Agent Bridge catalogue using H Chat's live objects.
import AppKit
import Foundation

@MainActor final class HAgentControl {
    typealias Fields = [String: HControlField]
    typealias Arguments = [String: Any]
    struct Operation {
        let kind: String
        let fields: Fields
        let run: (HControlRequest) async throws -> HControlOutcome
        var schema: [String: Any] {
            ["kind": kind, "arguments": ["type": "object", "additionalProperties": false,
                "required": fields.keys.sorted(), "properties": fields.mapValues(\.schema)] as [String: Any]]
        }
    }
    let model: GateModel
    let updater: AppUpdater
    let zoom: InterfaceZoom
    var openWindow: ((String) -> Void)?
    private var mailbox: HControlMailbox?
    private(set) lazy var operations = catalogue()
    private var activeAction: UUID?
    private var resources = ResourceUsage()

    init(_ model: GateModel, zoom: InterfaceZoom, updater: AppUpdater, openWindow: ((String) -> Void)? = nil) {
        self.model = model; self.zoom = zoom; self.updater = updater; self.openWindow = openWindow
    }

    func start() {
        guard mailbox == nil else { return }
        let service = HControlMailbox { [weak self] request in
            guard let self else { throw HControlFailure.unavailable("H Chat is closing.") }
            return try await self.handle(request)
        }
        do { try service.start(); mailbox = service }
        catch { Diagnostics.shared.failure("agent.control.unavailable", error) }
    }

    func handle(_ request: HControlRequest) async throws -> HControlOutcome {
        guard let operation = operations[request.operation] else { throw HControlFailure.unavailable("Unknown operation. Read capabilities on this Mac.") }
        guard Set(operation.fields.keys) == Set(request.arguments.keys) else { throw HControlFailure.invalid("The supplied fields do not match the operation schema.") }
        for (key, field) in operation.fields {
            guard let value = request.arguments[key], field.accepts(value) else { throw HControlFailure.invalid("Invalid value for " + key + ".") }
        }
        try request.checkExpiry()
        if model.quitting && operation.kind != "read" { throw HControlFailure.unavailable("H Chat is closing.") }
        // Cancellation checks the active Start's request and generation, and leaves its reservation
        // with the original task until that task completes.
        if operation.kind == "action", request.operation != "voice.cancelStart" {
            guard activeAction == nil else { throw HControlFailure.unavailable("Another agent control action is still running.") }
            activeAction = request.id
            defer { activeAction = nil }
            return try await operation.run(request)
        }
        return try await operation.run(request)
    }

    private func catalogue() -> [String: Operation] {
        var operations = [String: Operation]()
        func add(_ name: String, _ kind: String = "read", _ fields: Fields = [:], _ run: @escaping (HControlRequest) async throws -> HControlOutcome) {
            operations[name] = Operation(kind: kind, fields: fields, run: run)
        }
        add("capabilities") { [unowned self] _ in
            .init(.confirmed, ["version": AppVersion.display, "protocol": 1, "operations": Dictionary(uniqueKeysWithValues: self.operations.map { name, operation in (name, self.describe(name, operation)) })])
        }
        add("status") { [model] _ in
            .init(.confirmed, ["version": AppVersion.display, "status": model.status, "busy": model.busy, "listening": model.enabled,
                "recognitionRunning": model.detectionRunning, "dockedDisplays": model.dock.externalDisplays, "onPower": model.dock.onPower,
                "cachedVoice": model.voiceText, "archiveError": model.archiveError as Any? ?? NSNull(),
                "lastCommand": model.lastCommandMessage as Any? ?? NSNull(), "lastCommandDetail": model.lastCommandDetail as Any? ?? NSNull(), "lastEvent": model.lastEvent,
                "speechCheck": model.speechCheckText, "speechCheckRunning": model.checkingSpeech, "localModel": model.computeText,
                "video": model.videoBridge.availability.detail, "spotify": model.spotifyVolume.message, "backup": TranscriptBackupConfiguration.message])
        }
        add("voice.identity") { _ in
            let status = await Task.detached { VoicePeerControl.localStatus() }.value
            return .init(status.status == .unknown ? .unknown : .confirmed, ["status": status.status.rawValue, "call": status.call?.token as Any? ?? NSNull()])
        }
        add("voice.cancelStart", "action", ["startRequestId": .uuid]) { [unowned self] request in
            try request.checkExpiry()
            guard let id = UUID(uuidString: request.string("startRequestId")), self.activeAction == id else {
                throw HControlFailure.conflict("This Start request is no longer opening.")
            }
            try self.model.cancelRemoteStart(request: id)
            return .init(.confirmed, message: "Start cancelled before H Chat sent the native Voice shortcut.")
        }
        for shortcut in HChatShortcutAction.allCases {
            let targeted = [.end, .muteMicrophone, .unmuteMicrophone, .silenceSpeakers, .unsilenceSpeakers, .ultrafast].contains(shortcut)
            add("shortcut." + shortcut.rawValue, shortcut == .status ? "read" : "action", targeted ? ["call": .text] : [:]) { [model] request in
                let guardCall = try targeted ? HControlCall(request) : nil
                if shortcut == .end, let guardCall {
                    // End is scoped to the requested session at the native press itself. — GPT-6.2 Astra
                    try await Task.detached {
                        try VoiceBridge.pressEnd(pid: guardCall.call.pid, requireUniqueEnd: true, beforePress: guardCall.check)
                    }.value
                    return .init(.sent, message: "End sent to the requested call.")
                }
                if shortcut == .callDot || shortcut == .hangUpDot {
                    let result = await model.performDotShortcut(shortcut == .callDot ? .start : .hangUp, valid: { request.current(at: Date().timeIntervalSince1970) })
                    let state: HControlOutcome.State = result.confirmed ? .confirmed : (result.submitted ? .sent : (result.beforeDispatch ? .unavailable : .unknown))
                    return .init(state, message: result.message)
                }
                let message = try await model.performShortcut(shortcut, remoteGuard: guardCall, remoteStartRequest: shortcut == .start ? request.id : nil, beforeRemoteDispatch: request.checkExpiry)
                switch shortcut {
                case .start, .ultrafast: return .init(.confirmed, message: message)
                case .status: return .init(message.contains("unknown") ? .unknown : .confirmed, message: message)
                case .muteMicrophone, .unmuteMicrophone, .silenceSpeakers, .unsilenceSpeakers, .callDot, .hangUpDot: return .init(.sent, message: message)
                case .end: throw HControlFailure.invalid("A current call identity is required.")
                }
            }
        }
        add("voice.refresh", "action") { [model] _ in
            guard !model.busy else { throw HControlFailure.unavailable("H Chat is busy.") }
            model.refreshVoice(); return .init(.accepted, message: "H Chat is refreshing its Voice status.")
        }
        add("voice.show", "action") { _ in
            let result = await ShowVoiceCommand.perform()
            return .init(result.didOpen ? .sent : .unavailable, message: result.message)
        }
        add("paired.configuration") { _ in
            guard let configuration = VoicePeerConfiguration.installed else { return .init(.confirmed, ["enabled": false, "protocol": VoicePeerReceipt.protocolVersion]) }
            return .init(.confirmed, ["enabled": true, "protocol": VoicePeerReceipt.protocolVersion,
                "peer": configuration.machine, "role": configuration.role.rawValue, "schedule": try configuration.schedule.map(HControlField.json) ?? NSNull()])
        }
        add("paired.status") { _ in
            let status = await Task.detached { VoicePeerControl.respond(.init(action: .status, call: nil, expires: Date().timeIntervalSince1970 + 4)) }.value
            return .init(.confirmed, try HControlField.json(status))
        }
        add("paired.confirmEnd", "read", ["call": .text]) { request in
            guard let call = VoicePeerCall(token: request.string("call")) else { throw HControlFailure.invalid("Invalid call identity.") }
            let status = await Task.detached { VoicePeerControl.respond(.init(action: .confirmEnd, call: call, expires: min(request.expires, Date().timeIntervalSince1970 + 4))) }.value
            return .init(status.status == .unknown ? .unknown : .confirmed, try HControlField.json(status))
        }
        for (name, action) in [("paired.resolve", VoicePeerMailbox.Action.resolve), ("paired.end", .end)] {
            add(name, "action", ["call": .text, "otherCall": .text]) { request in
                guard let target = VoicePeerCall(token: request.string("call")), let other = VoicePeerCall(token: request.string("otherCall")) else {
                    throw HControlFailure.invalid("Supply both exact call identities.")
                }
                let receipt = await Task.detached {
                    VoicePeerControl.respond(.init(action: action, call: target, expires: min(request.expires, Date().timeIntervalSince1970 + 12), otherCall: other))
                }.value
                let state: HControlOutcome.State
                switch receipt.status {
                case .resolved, .ended: state = .confirmed
                case .changed: state = .conflict
                case .endRequested: state = .sent
                case .disabled, .inactive: state = .unavailable
                case .active, .unknown: state = .unknown
                }
                return .init(state, try HControlField.json(receipt))
            }
        }
        add("listening.set", "action", ["enabled": .bool]) { [model] request in
            guard !model.busy else { throw HControlFailure.unavailable("H Chat is busy.") }
            if model.listeningToggleOn != (request.arguments["enabled"] as? Bool) { model.toggle(preservingCall: true) }
            return .init(.accepted, ["listening": model.enabled, "status": model.status])
        }
        add("recognition.check", "action") { [model] _ in
            if let reason = model.speechCheckUnavailableReason { throw HControlFailure.unavailable(reason) }
            model.checkSpeech(); return .init(.accepted, message: "Read status for the speech check result.")
        }
        add("devices") { [model] _ in
            .init(.confirmed, ["microphones": model.inputs.devices.map { ["uid": $0.uid, "name": $0.name] },
                "displays": NSScreen.screens.map { ["id": WindowDisplay.identifier($0), "name": $0.localizedName] },
                "outputs": await Task.detached { SpeakerOutput.available() }.value])
        }
        add("permissions") { [model] _ in
            model.refreshPermissions()
            return .init(.confirmed, ["microphone": model.micAllowed, "accessibility": model.accessibilityAllowed, "spotifyNeedsPermission": model.spotifyVolume.permissionRequired])
        }
        add("permissions.request", "action", ["permission": .oneOf(["microphone","accessibility","spotify"])]) { [model] request in
            switch request.string("permission") {
            case "microphone": model.requestAudioPermissions()
            case "accessibility": model.requestAccessibilityPermission()
            default: model.spotifyVolume.requestPermission()
            }
            return .init(.accepted, message: "macOS handles the permission request on the receiving Mac.")
        }
        add("desktop.apps") { [model] _ in
            .init(.confirmed, await model.appSpellingChoices().map { ["id": $0.id, "name": $0.displayName, "spellings": model.appNameSpellings.spellings(for: $0.id)] as [String: Any] })
        }
        add("desktop.open", "action", ["bundleId": .text]) { [model] request in
            let apps = await model.appSpellingChoices()
            guard let app = apps.first(where: { $0.id == request.string("bundleId") }) else { throw HControlFailure.unavailable("App is unavailable.") }
            try request.checkExpiry()
            let result = await model.desktopCommands.openIdentified(app, valid: { request.current(at: Date().timeIntervalSince1970) })
            return .init(result.diagnostic == "frontmost" ? .confirmed : (result.diagnostic == "dispatched" ? .sent : .unavailable), message: result.message)
        }
        add("desktop.zoom", "action", ["direction": .oneOf(ZoomDirection.allCases.map(\.rawValue))]) { [model] request in
            guard let direction = ZoomDirection(rawValue: request.string("direction")) else { throw HControlFailure.invalid("Unknown zoom direction.") }
            var sent = false
            let result = model.desktopCommands.zoom(direction) { sent = true }
            return .init(sent ? .sent : .unavailable, message: result.message)
        }
        add("music.toggle", "action") { [model] _ in
            var sent = false
            let result = model.desktopCommands.toggleCurrentMedia { sent = true }
            return .init(sent ? .sent : .unavailable, message: result.message)
        }
        add("video.control", "action", ["command": .oneOf(VideoCommand.allCases.map(\.rawValue))]) { [model] request in
            guard let command = VideoCommand(rawValue: request.string("command")) else { throw HControlFailure.invalid("Unknown video command.") }
            let result = await withCheckedContinuation { continuation in
                model.videoBridge.sendIfAvailable(command, seconds: model.rewindVideoSeconds, shouldSend: { request.current(at: Date().timeIntervalSince1970) }) { continuation.resume(returning: $0) }
            }
            return .init(result.confirms(command) ? .confirmed : (result == .unconfirmed ? .unknown : .unavailable), message: result.summary(for: command))
        }
        add("video.refresh", "action") { [model] _ in model.refreshVideoBridge(); return .init(.accepted) }
        add("spotify.volume", "action", ["value": .integer(0...100)]) { [model] request in
            .init(.confirmed, try await model.spotifyVolume.setVolume(to: request.integer("value"), beforeWrite: request.checkExpiry))
        }
        add("output.switch", "action", ["output": .text]) { [model] request in
            guard !model.switchingSpeakerOutput else { throw HControlFailure.unavailable("A speaker change is already running.") }
            return try await Task.detached {
                let name = request.string("output")
                guard SpeakerOutput.available().contains(name) else { throw HControlFailure.unavailable("Unknown speaker output.") }
                try request.checkExpiry()
                let result = SpeakerOutput.switchTo(name)
                return .init(result.verified ? .confirmed : (result.phase == .failedBeforeDispatch ? .unavailable : .unknown), message: result.message)
            }.value
        }
        add("sound.preview", "action", ["cue": .oneOf(FeedbackSounds.Cue.allCases.map(\.rawValue))]) { [model] request in
            guard let cue = FeedbackSounds.Cue(rawValue: request.string("cue")) else { throw HControlFailure.invalid("Unknown sound.") }
            model.previewSound(cue); return .init(.sent)
        }
        add("history.open", "action") { [model] _ in model.openCommandHistory(); return .init(.accepted) }
        add("history.commands", "read", ["limit": .integer(1...200)]) { request in
            .init(.confirmed, try await Task.detached { try Diagnostics.shared.commandHistory(limit: request.integer("limit")) }.value)
        }
        add("transcripts.current") { [model] _ in
            .init(.confirmed, ["batch": model.transcriptBatchID.uuidString, "text": model.transcript, "saving": model.saveTranscripts])
        }
        add("archive.days", "read", ["before": .text, "limit": .integer(1...100)]) { request in
            .init(.confirmed, try await Task.detached {
                try HControlArchive.days(before: request.string("before"), limit: request.integer("limit"))
            }.value)
        }
        add("archive.list", "read", ["day": .text, "after": .text, "limit": .integer(1...100)]) { request in
            .init(.confirmed, try await Task.detached {
                try HControlArchive.documents(day: request.string("day"), after: request.string("after"), limit: request.integer("limit"))
            }.value)
        }
        add("archive.read", "read", ["day": .text, "id": .text, "offset": .integer(0...Int(Int32.max)), "limit": .integer(1...32768)]) { request in
            .init(.confirmed, try await Task.detached {
                try HControlArchive.read(day: request.string("day"), id: request.string("id"), offset: request.integer("offset"), limit: request.integer("limit"))
            }.value)
        }
        add("diagnostics.show", "action") { _ in
            NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.directory.appendingPathComponent("events.jsonl")])
            return .init(.sent)
        }
        add("diagnostics") { [unowned self] _ in
            .init(.confirmed, ["recent": Diagnostics.shared.tail(), "resources": self.resources.sample(), "processMB": ResourceUsage.footprintMB(), "neuralMB": ResourceUsage.neuralFootprintMB()])
        }
        add("window.open", "action", ["window": .oneOf(["main","settings"])]) { [unowned self] request in
            guard let open = self.openWindow else { throw HControlFailure.unavailable("H Chat has no window or menu ready to open another window.") }
            open(request.string("window")); return .init(.sent)
        }
        add("window.zoom", "action", ["direction": .oneOf(["increase","decrease","reset"])]) { [zoom] request in
            switch request.string("direction") { case "increase": zoom.increase(); case "decrease": zoom.decrease(); default: zoom.reset() }
            return .init(.confirmed, zoom.scale)
        }
        add("update.status") { [updater] _ in .init(.confirmed, ["configured": updater.configured, "canCheck": updater.canCheck, "waitingToInstall": updater.waitingToInstall]) }
        add("update.check", "action") { [updater] _ in
            guard updater.canCheck else { throw HControlFailure.unavailable("Update checking is unavailable.") }
            updater.checkForUpdates(); return .init(.accepted)
        }
        add("update.resume", "action") { [updater] _ in
            guard updater.waitingToInstall else { throw HControlFailure.unavailable("No update is waiting to install.") }
            return .init(.accepted, afterReceipt: { updater.resumeIfIdle() })
        }
        add("app.quit", "action") { [model] _ in .init(.accepted, afterReceipt: { model.quit() }) }
        addSettings(to: &operations)
        addNotificationReplies(to: &operations)
        return operations
    }
    private func describe(_ name: String, _ operation: Operation) -> [String: Any] {
        var description = operation.schema
        let availability: String, reason: String?
        if operation.kind != "read", model.quitting {
            (availability, reason) = ("unavailable", "H Chat is closing.")
        } else if name == "window.open", openWindow == nil {
            (availability, reason) = ("unavailable", "A desktop window or menu must first attach its window action.")
        } else if name == "update.check", !updater.canCheck {
            (availability, reason) = ("unavailable", "The updater cannot currently check for updates.")
        } else if name == "update.resume", !updater.waitingToInstall {
            (availability, reason) = ("unavailable", "No update is waiting to install.")
        } else if name.hasPrefix("settings.update."), !updater.configured {
            (availability, reason) = ("unavailable", "Sparkle is unavailable.")
        } else if name == "settings.update.automaticDownloads", !updater.automaticChecks {
            (availability, reason) = ("unavailable", "Enable automatic checks first.")
        } else if name.hasPrefix("paired."), name != "paired.configuration", VoicePeerConfiguration.installed == nil {
            (availability, reason) = ("unavailable", "Paired Voice priority is disabled on this Mac.")
        } else if name == "recognition.check", let blocked = model.speechCheckUnavailableReason {
            (availability, reason) = ("unavailable", blocked)
        } else if name == "voice.cancelStart" {
            (availability, reason) = ("conditional", "Requires the pending shortcut.start request ID before native dispatch or reuse of an existing call.")
        } else if operation.fields["call"] != nil {
            (availability, reason) = ("conditional", "Requires the exact current call identity and any native permissions.")
        } else if operation.kind == "action" {
            (availability, reason) = ("conditional", "H Chat checks the native destination and permissions when this action runs.")
        } else if operation.kind == "settings" {
            (availability, reason) = ("conditional", "Requires a current revision from settings.read.")
        } else {
            (availability, reason) = ("available", nil)
        }
        description["availability"] = availability
        if let reason { description["reason"] = reason }
        return description
    }

}

enum HControlField {
    case text, uuid, bool, integer(ClosedRange<Int>), number(ClosedRange<Double>), oneOf([String]), speakerSettings
    var schema: [String: Any] {
        switch self {
        case .text: return ["type":"string", "maxLength": 32768]
        case .uuid: return ["type":"string", "format":"uuid"]
        case .bool: return ["type":"boolean"]
        case .integer(let range): return ["type":"integer", "minimum":range.lowerBound, "maximum":range.upperBound]
        case .number(let range): return ["type":"number", "minimum":range.lowerBound, "maximum":range.upperBound]
        case .oneOf(let options): return ["type":"string", "enum": options]
        case .speakerSettings:
            let destination: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["id", "names", "output"],
                "properties": ["id": ["type": "string", "format": "uuid"], "names": ["type": "string"], "output": ["type": "string"]]]
            return ["type":"object", "additionalProperties": false, "required": ["prefixes", "destinations"], "properties": [
                "prefixes": ["type": "string"], "destinations": ["type": "array", "items": destination] as [String: Any],
                "prefixSpellings": ["type": "object", "additionalProperties": ["type": "array", "items": ["type": "string"]]] as [String: Any]] as [String: Any]]
        }
    }
    func accepts(_ value: Any) -> Bool {
        switch self {
        case .text: return (value as? String).map { $0.count <= 32768 } == true
        case .uuid: return (value as? String).flatMap(UUID.init(uuidString:)) != nil
        case .bool: return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
        case .integer(let range): return Self.numberValue(value).map { $0.rounded() == $0 && Double(range.lowerBound) <= $0 && $0 <= Double(range.upperBound) } == true
        case .number(let range): return Self.numberValue(value).map(range.contains) == true
        case .oneOf(let options): return (value as? String).map(options.contains) == true
        case .speakerSettings:
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["prefixes","destinations","prefixSpellings"]),
                  let rows = object["destinations"] as? [[String: Any]], rows.allSatisfy({ Set($0.keys) == ["id","names","output"] }) else { return false }
            return true
        }
    }
    static func numberValue(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

extension HControlRequest {
    func checkExpiry() throws {
        guard current(at: Date().timeIntervalSince1970) else { throw HControlFailure.invalid("The request expired.") }
    }
    func string(_ key: String) -> String { arguments[key] as? String ?? "" }
    func integer(_ key: String) -> Int { (arguments[key] as? NSNumber)?.intValue ?? 0 }
}

struct HControlCall {
    let call: VoicePeerCall
    let launch: Date
    let expires: Double
    init(_ request: HControlRequest) throws {
        guard let call = VoicePeerCall(token: request.string("call")), let app = VoiceBridge.currentApplication(),
              app.processIdentifier == call.pid, let launch = app.launchDate else { throw HControlFailure.conflict("The requested call is unavailable.") }
        self.call = call; self.launch = launch; self.expires = request.expires
        try check()
    }
    func check() throws {
        guard VoicePeerControl.stillCurrent(call, since: launch, expires: expires) else { throw HControlFailure.conflict("The call changed or the request expired.") }
    }
}
