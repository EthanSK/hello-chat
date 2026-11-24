/*
 ============================================================================
 **MOVED FROM — MOVE HISTORY**
 2026-11-24: HelloChatApp.swift, MainView's inline Switch speakers row.
 The speaker row is shared by Home and Settings. The shared sheet host, Enabled
 control and Disabled Commands section are new behavior, reusing the existing
 CommandPhrasesView and SpeakerOutputEditor rather than copying their settings.
 Origin: H Chat continuation 01a1f046-3f24-76c2-833d-80f22ec44dab. — GPT-6.1 Sol
 ============================================================================
 */
import SwiftUI

// The sheet belongs to the window, so disabling its row cannot dismiss an unfinished editor. — GPT-6.1 Sol
struct CommandSettingsHost: ViewModifier {
    @ObservedObject var model: GateModel
    let origin: CommandEditorRequest.Origin
    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.commandEditor?.origin == origin ? model.commandEditor : nil },
            set: { if $0 == nil { model.closeCommandSettings(from: origin) } }),
            onDismiss: { model.closeCommandSettings(from: origin) }) { request in
                if request.command == .speakerOutput {
                    SpeakerOutputEditor(initial: model.speakerOutputSettings,
                        otherPatterns: model.speakerOutputConflictingPhrases,
                        initialEnabled: model.commandAvailability.isEnabled(.speakerOutput),
                        saveEnabled: { model.setCommandEnabled($0, command: .speakerOutput) },
                        preview: model.previewSound, save: model.saveSpeakerOutputSettings)
                } else {
                    CommandPhrasesView(model: model, slots: request.command.slots)
                }
            }
            .onDisappear { model.closeCommandSettings(from: origin) }
    }
}

struct CommandEnabledToggle: View {
    let command: HomeCommand
    @Binding var isOn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Enabled", isOn: $isOn)
                .toggleStyle(.checkbox)
                .help("Listen for this command’s phrases and show it on Home. Turn it back on in Settings under Disabled Commands.")
                .accessibilityIdentifier(command.id + "Enabled")
            if !isOn {
                Text("When off, H Chat ignores these phrases. Find this command in Settings under Disabled Commands.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Extraction of MainView's existing speaker title, info, destinations and gear; both lists open the same editor. — GPT-6.1 Sol
struct SpeakerOutputCommandRow: View {
    @ObservedObject var model: GateModel
    let origin: CommandEditorRequest.Origin
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Switch speakers")
                    CommandInfoButton(title: "Switch speakers", detail: "Switches Mac audio to a speaker you’ve added. Say a phrase followed by its name. This keeps your microphone and alert output in place.")
                }
                let names = model.speakerOutputSettings.destinations.compactMap { SpeakerOutputSettings.lines($0.names).first }
                Text(names.isEmpty ? "No speakers added" : names.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CommandSettingsButton(title: "Switch speakers") { model.openCommandSettings(.speakerOutput, from: origin) }
                .disabled(model.commandEditor != nil)
                .accessibilityIdentifier("speakerOutputSettings")
        }
    }
}

struct DisabledCommandsSection: View {
    @ObservedObject var model: GateModel
    var body: some View {
        Section("Disabled Commands") {
            if model.disabledCommands.isEmpty {
                Text("None. Turn a command off from its gear on Home.").foregroundStyle(.secondary)
                    .accessibilityIdentifier("disabledCommandsEmpty")
            } else {
                Text("Open a command’s gear to turn it back on. Your phrases and settings are kept.")
                    .foregroundStyle(.secondary)
                ForEach(model.disabledCommands) { command in
                    if command == .speakerOutput {
                        SpeakerOutputCommandRow(model: model, origin: .settings)
                    } else {
                        PhraseFields(model: model, configuration: model.phraseConfiguration, slots: command.slots,
                            rewindSeconds: model.rewindVideoSeconds, origin: .settings).equatable()
                    }
                }
            }
        }.accessibilityIdentifier("disabledCommandsSection")
    }
}
