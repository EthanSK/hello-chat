// Agent Bridge edits the same in-memory settings, phrase rows and validated spellings as H Chat's settings window.
import AppKit
import CryptoKit
import Foundation

extension HAgentControl {
    func addSettings(to operations: inout [String: Operation]) {
        func add(_ name: String, _ kind: String = "read", _ fields: Fields = [:], _ run: @escaping (HControlRequest) async throws -> HControlOutcome) {
            operations[name] = Operation(kind: kind, fields: fields, run: run)
        }
        add("settings.read") { [unowned self] _ in .init(.confirmed, try self.settingsSnapshot()) }
        func write(_ name: String, _ fields: Fields, _ change: @escaping @MainActor (HControlRequest) throws -> Void) {
            var arguments = fields
            arguments["revision"] = .text
            add(name, "settings", arguments) { [unowned self] request in
                try self.requireRevision(request)
                try change(request)
                let revision = try self.settingsSnapshot()["revision"]
                return .init(.confirmed, ["revision": revision ?? NSNull()])
            }
        }
        let bools: [String: ReferenceWritableKeyPath<GateModel, Bool>] = [
            "soundEffects": \.soundEffects, "lowerSpotifyDuringChat": \.lowerSpotifyDuringChat, "saveTranscripts": \.saveTranscripts,
            "automaticListening": \.automaticListening, "similarPhrases": \.similarPhrases, "bringHomeForward": \.bringHomeForward
        ]
        for (name, key) in bools {
            write("settings." + name, ["value": .bool]) { [model] request in
                if let value = request.arguments["value"] as? Bool, model[keyPath: key] != value { model[keyPath: key] = value }
            }
        }
        write("settings.ultrafastForNewVoiceChats", ["value": .bool]) { request in
            if let value = request.arguments["value"] as? Bool { UserDefaults.standard.set(value, forKey: CodexVoiceSpeed.preferenceKey) }
        }
        write("settings.soundEffectsVolume", ["value": .number(0...1)]) { [model] request in
            if let value = (request.arguments["value"] as? NSNumber)?.doubleValue { model.soundEffectsVolume = value }
        }
        write("settings.spotifyVolumeLimit", ["value": .integer(0...100)]) { [model] request in model.spotifyVolumeLimit = request.integer("value") }
        write("settings.notificationRepliesEnabled", ["value": .bool]) { [model] request in
            if let value = request.arguments["value"] as? Bool { model.notificationReplies.settings.enabled = value }
        }
        write("settings.notificationReplyIdleSeconds", ["value": .integer(10...180)]) { [model] request in model.notificationReplies.settings.idleSeconds = request.integer("value") }
        write("settings.notificationReplySeconds", ["value": .integer(10...180)]) { [model] request in model.notificationReplies.settings.replySeconds = request.integer("value") }
        write("settings.rewindVideoSeconds", ["value": .integer(VideoCommand.durationRange)]) { [model] request in model.rewindVideoSeconds = request.integer("value") }
        write("settings.speechModel", ["value": .oneOf(SpeechModel.allCases.map(\.rawValue))]) { [model] request in
            guard let selected = SpeechModel(rawValue: request.string("value")) else { throw HControlFailure.invalid("Unknown speech model.") }
            model.speechModel = selected
        }
        write("settings.microphone", ["uid": .text]) { [model] request in
            let uid = request.string("uid")
            guard uid.isEmpty || model.inputs.devices.contains(where: { $0.uid == uid }) else { throw HControlFailure.unavailable("Unknown microphone.") }
            model.inputs.selectedUID = uid
        }
        write("settings.display", ["id": .text]) { request in
            let id = request.string("id")
            guard id.isEmpty || NSScreen.screens.contains(where: { WindowDisplay.identifier($0) == id }) else { throw HControlFailure.unavailable("Unknown display.") }
            UserDefaults.standard.set(id, forKey: WindowDisplay.preferenceKey)
        }
        for name in ["automaticChecks", "automaticDownloads"] {
            write("settings.update." + name, ["value": .bool]) { [updater] request in
                guard updater.configured, let value = request.arguments["value"] as? Bool else { throw HControlFailure.unavailable("Updater settings are unavailable.") }
                if name == "automaticChecks" { updater.automaticChecks = value }
                else {
                    guard updater.automaticChecks else { throw HControlFailure.unavailable("Enable automatic update checks first.") }
                    updater.automaticDownloads = value
                }
            }
        }
        let slots = HControlField.oneOf(PhraseSlot.allCases.map(\.rawValue))
        let repeats = repeatKeys
        write("settings.commandEnabled", ["command": .oneOf(HomeCommand.all.map(\.id)), "enabled": .bool]) { [model] request in
            guard let command = HomeCommand.all.first(where: { $0.id == request.string("command") }),
                  let enabled = request.arguments["enabled"] as? Bool else { throw HControlFailure.invalid("Choose a command and whether it is enabled.") }
            model.setCommandEnabled(enabled, command: command)
        }
        write("settings.repeat", ["command": .oneOf(repeats), "enabled": .bool]) { request in
            if let enabled = request.arguments["enabled"] as? Bool { CommandRepetition.setEnabled(enabled, command: request.string("command")) }
        }
        let cues = FeedbackSounds.Cue.allCases.map(\.rawValue)
        write("settings.sound", ["control": .oneOf(cues + ["speakerOutput"]), "choice": .oneOf(cues + ["default","off"])]) { request in
            UserDefaults.standard.set(request.string("choice"), forKey: FeedbackSounds.preferenceKey(request.string("control")))
        }
        write("settings.phrase.write", ["slot": slots, "row": .text, "text": .text]) { [model] request in
            let slot = try request.phraseSlot()
            let row = request.string("row")
            let new = request.string("text")
            let adding = row == "new"
            let id = try Self.rowID(row, slot: slot, model: model, allowNew: true)
            let old = try Self.rowText(id, slot: slot, model: model)
            let pieces = PhraseList.pieces(new)
            for piece in pieces {
                if let problem = model.spellingConflict([piece], for: slot, phrase: piece) { throw HControlFailure.conflict(problem) }
            }
            if adding && pieces.isEmpty { throw HControlFailure.invalid("Supply a phrase for the new row.") }
            let selected = adding ? model.addPhraseRow(slot) : id
            model.renamePhrase(slot, id: selected, old: adding ? "" : old, new: new)
            model.commitPhraseRow(slot, id: selected)
        }
        write("settings.phrase.restore", ["slot": slots]) { [model] request in
            let slot = try request.phraseSlot()
            let old = model[keyPath: model.phraseKeyPath(for: slot)]
            model.renamePhrase(slot, id: nil, old: old, new: slot.defaultText)
            model.commitPhraseRow(slot, id: nil)
        }
        write("settings.phrase.remove", ["slot": slots, "row": .text]) { [model] request in
            let slot = try request.phraseSlot()
            guard let id = try Self.rowID(request.string("row"), slot: slot, model: model, allowNew: false) else {
                throw HControlFailure.invalid("Use phrase.write with an empty value to clear the main row.")
            }
            model.removePhraseRow(slot, id: id)
        }
        write("settings.spellings.import", ["slot": slots, "row": .text, "text": .text]) { [model] request in
            let slot = try request.phraseSlot()
            let id = try Self.rowID(request.string("row"), slot: slot, model: model, allowNew: false)
            let phrase = try Self.rowText(id, slot: slot, model: model)
            guard !PhraseList.key(phrase).isEmpty else { throw HControlFailure.invalid("Choose a nonempty phrase.") }
            let entries: [String]
            do { entries = try PhraseDictionary.parse(request.string("text"), for: slot) }
            catch { throw HControlFailure.invalid(error.localizedDescription) }
            if let conflict = model.spellingConflict(entries, for: slot, phrase: phrase) { throw HControlFailure.conflict(conflict) }
            let stock = slot.stockSpellings(for: phrase)
            model.phraseDictionaries[slot.spellingKey(for: phrase)] = entries.map(PhraseList.key) == stock.map(PhraseList.key) ? nil : entries
        }
        write("settings.spellings.restore", ["slot": slots, "row": .text]) { [model] request in
            let slot = try request.phraseSlot()
            let id = try Self.rowID(request.string("row"), slot: slot, model: model, allowNew: false)
            let phrase = try Self.rowText(id, slot: slot, model: model)
            model.phraseDictionaries[slot.spellingKey(for: phrase)] = nil
        }
        add("settings.appSpellings", "settings", ["revision": .text, "bundleId": .text, "text": .text]) { [unowned self] request in
            let apps = await self.model.appSpellingChoices()
            try self.requireRevision(request)
            let id = request.string("bundleId")
            guard apps.contains(where: { $0.id == id }) else { throw HControlFailure.unavailable("Choose an installed app.") }
            let entries: [String]
            do { entries = try AppNameSpellings.parse(request.string("text")) }
            catch { throw HControlFailure.invalid(error.localizedDescription) }
            let collisions = self.model.appNameSpellings.conflicts(entries, for: id, among: apps)
            guard collisions.isEmpty else { throw HControlFailure.conflict("Already used by " + collisions.joined(separator: ", ") + ".") }
            self.model.appNameSpellings.overrides[id] = entries
            return .init(.confirmed, ["revision": try self.settingsSnapshot()["revision"] ?? NSNull()])
        }
        write("settings.appSpellings.restore", ["bundleId": .text]) { [model] request in
            let id = request.string("bundleId")
            guard !id.isEmpty, model.appNameSpellings.overrides[id] != nil || AppNameSpellings.defaults[id] != nil else {
                throw HControlFailure.unavailable("No app spelling override or built-in list for this ID.")
            }
            model.appNameSpellings.overrides[id] = nil
        }
        write("settings.speakerPrefixes.restore", [:]) { [model] _ in
            var settings = model.speakerOutputSettings
            settings.prefixes = SpeakerOutputSettings.defaultPrefixes
            try Self.saveSpeakerSettings(settings, model: model)
        }
        write("settings.speakerPrefixSpellings.restore", ["prefix": .text]) { [model] request in
            var settings = model.speakerOutputSettings
            let key = PhraseList.key(request.string("prefix"))
            guard SpeakerOutputSettings.lines(settings.prefixes).contains(where: { PhraseList.key($0) == key }) else {
                throw HControlFailure.conflict("The speaker prefix changed.")
            }
            settings.prefixSpellings?[key] = nil
            try Self.saveSpeakerSettings(settings, model: model)
        }
        write("settings.speakerDestinations", ["settings": .speakerSettings]) { [model] request in
            guard let object = request.arguments["settings"] else { throw HControlFailure.invalid("Supply the speaker settings.") }
            let settings: SpeakerOutputSettings
            do { settings = try JSONDecoder().decode(SpeakerOutputSettings.self, from: JSONSerialization.data(withJSONObject: object)) }
            catch { throw HControlFailure.invalid("Invalid speaker settings.") }
            try Self.saveSpeakerSettings(settings, model: model)
        }
    }

    private static func saveSpeakerSettings(_ settings: SpeakerOutputSettings, model: GateModel) throws {
        guard Set(settings.destinations.map(\.id)).count == settings.destinations.count, model.saveSpeakerOutputSettings(settings) else {
            throw HControlFailure.conflict("The speaker names or spellings conflict.")
        }
    }

    private var repeatKeys: [String] {
        HomeCommand.all.map(\.id).sorted()
    }

    private func settingsSnapshot() throws -> [String: Any] {
        let phrases = Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map { slot in
            let main = model[keyPath: model.phraseKeyPath(for: slot)]
            @MainActor func row(_ id: String, _ text: String) -> [String: Any] {
                let key = slot.spellingKey(for: text)
                return ["id": id, "text": text, "spellings": model.phraseDictionaries[key] ?? slot.stockSpellings(for: text)]
            }
            let rows = [row("main", main)] + (model.phraseAliases[slot] ?? []).map { row($0.id.uuidString, $0.text) }
            return (slot.rawValue, rows)
        })
        let speaker = model.speakerOutputSettings
        let speakerSpellings = Dictionary(uniqueKeysWithValues: Set(SpeakerOutputSettings.lines(speaker.prefixes).map(PhraseList.key)).map { key in
            (key, speaker.prefixSpellings?[key] ?? SpeakerOutputSettings.builtInSpellings(for: key))
        })
        let soundKeys = FeedbackSounds.Cue.allCases.map(\.rawValue) + ["speakerOutput"]
        let settings: [String: Any] = ["soundEffects": model.soundEffects, "soundEffectsVolume": model.soundEffectsVolume,
            "lowerSpotifyDuringChat": model.lowerSpotifyDuringChat, "spotifyVolumeLimit": model.spotifyVolumeLimit,
            "saveTranscripts": model.saveTranscripts, "automaticListening": model.automaticListening, "similarPhrases": model.similarPhrases,
            "bringHomeForward": model.bringHomeForward,
            "commands": Dictionary(uniqueKeysWithValues: HomeCommand.all.map { ($0.id, model.commandAvailability.isEnabled($0)) }),
            "notificationRepliesEnabled": model.notificationReplies.settings.enabled,
            "notificationReplyIdleSeconds": model.notificationReplies.settings.idleSeconds,
            "notificationReplySeconds": model.notificationReplies.settings.replySeconds,
            "notificationReplySpellings": model.phraseDictionaries[NotificationReplyCore.Commands.replySpellingKey] ?? NotificationReplyCore.Commands.defaultReplySpellings,
            "notificationEndReplySpellings": model.phraseDictionaries[NotificationReplyCore.Commands.endReplySpellingKey] ?? NotificationReplyCore.Commands.defaultEndReplySpellings,
            "notificationCancelReplySpellings": model.phraseDictionaries[NotificationReplyCore.Commands.cancelReplySpellingKey] ?? NotificationReplyCore.Commands.defaultCancelReplySpellings,
            "ultrafastForNewVoiceChats": UserDefaults.standard.object(forKey: CodexVoiceSpeed.preferenceKey) as? Bool ?? true,
            "speechModel": model.speechModel.rawValue, "microphone": model.inputs.selectedUID,
            "display": UserDefaults.standard.string(forKey: WindowDisplay.preferenceKey) ?? "", "rewindVideoSeconds": model.rewindVideoSeconds,
            "automaticChecks": updater.automaticChecks, "automaticDownloads": updater.automaticDownloads,
            "phrases": phrases, "appSpellings": model.appNameSpellings.overrides, "speakerDestinations": try HControlField.json(speaker),
            "effectiveSpeakerPrefixSpellings": speakerSpellings,
            "repeat": Dictionary(uniqueKeysWithValues: repeatKeys.map { ($0, CommandRepetition.enabled($0)) }),
            "sound": Dictionary(uniqueKeysWithValues: soundKeys.map { ($0, UserDefaults.standard.string(forKey: FeedbackSounds.preferenceKey($0)) ?? "default") })]
        let bytes = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        let revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ["revision": revision, "settings": settings]
    }

    private func requireRevision(_ request: HControlRequest) throws {
        try request.checkExpiry()
        guard request.string("revision") == (try settingsSnapshot()["revision"] as? String) else {
            throw HControlFailure.conflict("Settings changed. Read settings.read before editing again.")
        }
    }
    private static func rowID(_ row: String, slot: PhraseSlot, model: GateModel, allowNew: Bool) throws -> UUID? {
        if row == "main" || (allowNew && row == "new") { return nil }
        guard let id = UUID(uuidString: row), model.phraseAliases[slot]?.contains(where: { $0.id == id }) == true else { throw HControlFailure.conflict("The phrase row changed.") }
        return id
    }
    private static func rowText(_ id: UUID?, slot: PhraseSlot, model: GateModel) throws -> String {
        guard let id else { return model[keyPath: model.phraseKeyPath(for: slot)] }
        guard let row = model.phraseAliases[slot]?.first(where: { $0.id == id }) else { throw HControlFailure.conflict("The phrase row changed.") }
        return row.text
    }
}

private extension HControlRequest {
    func phraseSlot() throws -> PhraseSlot {
        guard let slot = PhraseSlot(rawValue: string("slot")) else { throw HControlFailure.invalid("Unknown phrase slot.") }
        return slot
    }
}
