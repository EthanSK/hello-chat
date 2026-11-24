// Invoke every real AppIntent with an injected handler. No native Voice call,
// microphone, shortcut key, listening preference or audio output is touched.
import AppIntents
import Foundation

@main enum AppShortcutTests {
    enum Failure: Error { case expected }
    @MainActor static func main() async throws {
        var received: [HChatShortcutAction] = []
        HChatShortcutActions.handler = { action in
            received.append(action)
            return action.rawValue
        }
        let values = [try await StartChatIntent().perform().value,
                      try await EndChatIntent().perform().value,
                      try await MuteChatMicrophoneIntent().perform().value,
                      try await UnmuteChatMicrophoneIntent().perform().value,
                      try await SilenceChatSpeakersIntent().perform().value,
                      try await RestoreChatSpeakersIntent().perform().value,
                      try await SetVoiceUltrafastIntent().perform().value,
                      try await ChatStatusIntent().perform().value,
                      try await CallDotIntent().perform().value,
                      try await HangUpDotIntent().perform().value]
        precondition(received == HChatShortcutAction.allCases)
        precondition(values == received.map(\.rawValue))
        HChatShortcutActions.handler = { _ in throw Failure.expected }
        do {
            _ = try await MuteChatMicrophoneIntent().perform()
            preconditionFailure("A failed operation must not report success")
        } catch Failure.expected {}
        HChatShortcutActions.handler = nil
        do {
            _ = try await StartChatIntent().perform()
            preconditionFailure("An uninitialized app must not report success")
        } catch HChatShortcutError.unavailable {}
        print("App Shortcuts: ten real intent routes, result values and failure propagation passed; no live controls.")
    }
}
