// Native Siri/Shortcuts actions. Vocal Shortcuts can map a personally trained
// phrase to these same actions without adding a recognizer to H Chat.
import AppIntents
import Foundation

enum HChatShortcutAction: String, CaseIterable {
    case start, end, muteMicrophone, unmuteMicrophone, silenceSpeakers, unsilenceSpeakers, status
}

enum HChatShortcutError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Open Hello Chat, then try again." }
}

@MainActor enum HChatShortcutActions {
    // The App initializer connects this to its one live GateModel. Keeping the
    // intent declarations independent also lets packaging extract their metadata
    // from this actual file, and tests run every route without a microphone/key.
    static var handler: ((HChatShortcutAction) async throws -> String)?
    static func perform(_ action: HChatShortcutAction) async throws -> String {
        guard let handler else { throw HChatShortcutError.unavailable }
        return try await handler(action)
    }
}

struct StartChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start chat"
    static var description = IntentDescription("Open Codex Voice, or resume its current chat.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.start))
    }
}

struct EndChatIntent: AppIntent {
    static var title: LocalizedStringResource = "End chat"
    static var description = IntentDescription("End Codex Voice, including a chat that is still opening.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.end))
    }
}

struct MuteChatMicrophoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute chat microphone"
    static var description = IntentDescription("Mute the microphone in an open Codex Voice chat.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.muteMicrophone))
    }
}

struct UnmuteChatMicrophoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Unmute chat microphone"
    static var description = IntentDescription("Unmute the microphone in an open Codex Voice chat.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.unmuteMicrophone))
    }
}

struct SilenceChatSpeakersIntent: AppIntent {
    static var title: LocalizedStringResource = "Silence chat speakers"
    static var description = IntentDescription("Silence audio from an open Codex Voice chat.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.silenceSpeakers))
    }
}

struct RestoreChatSpeakersIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore chat speakers"
    static var description = IntentDescription("Restore audio from an open Codex Voice chat.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.unsilenceSpeakers))
    }
}

struct ChatStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get chat status"
    static var description = IntentDescription("Check Codex Voice without changing its microphone or speakers.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await HChatShortcutActions.perform(.status))
    }
}

struct HChatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartChatIntent(), phrases: ["Start a chat with \(.applicationName)"],
                    shortTitle: "Start chat", systemImageName: "waveform")
        AppShortcut(intent: EndChatIntent(), phrases: ["End my chat with \(.applicationName)"],
                    shortTitle: "End chat", systemImageName: "stop.circle")
        AppShortcut(intent: MuteChatMicrophoneIntent(), phrases: ["Mute the chat microphone with \(.applicationName)"],
                    shortTitle: "Mute microphone", systemImageName: "mic.slash")
        AppShortcut(intent: UnmuteChatMicrophoneIntent(), phrases: ["Unmute the chat microphone with \(.applicationName)"],
                    shortTitle: "Unmute microphone", systemImageName: "mic")
        AppShortcut(intent: SilenceChatSpeakersIntent(), phrases: ["Silence chat speakers with \(.applicationName)"],
                    shortTitle: "Silence speakers", systemImageName: "speaker.slash")
        AppShortcut(intent: RestoreChatSpeakersIntent(), phrases: ["Restore chat speakers with \(.applicationName)"],
                    shortTitle: "Restore speakers", systemImageName: "speaker.wave.2")
        AppShortcut(intent: ChatStatusIntent(), phrases: ["Get chat status with \(.applicationName)"],
                    shortTitle: "Chat status", systemImageName: "info.circle")
    }
}
