import Foundation

@main enum VoiceChatHandoffTests {
    @MainActor static func main() async throws {
        // Words after the accepted wake, across recognition restarts.
        var speech = WakeSpeechCapture(text: "So Hello Chat", phrase: "Hello Chat", similar: true)
        precondition(speech.text.isEmpty, "Nothing is sent before words follow the wake")
        speech.update("So Hello Chat, what's the weather")
        precondition(speech.text == "what's the weather", "The wake phrase and words before it are cut")
        speech.update("So Hello Chat, what's the weather like?")
        speech.boundary()
        speech.update("And tomorrow")
        precondition(speech.text == "what's the weather like? And tomorrow", "Later pieces are added whole: \(speech.text)")

        var repeated = WakeSpeechCapture(text: "Hello Chat one", phrase: "Hello Chat", similar: true)
        repeated.update("Hello Chat one Hello Chat two")
        precondition(repeated.text == "one Hello Chat two", "A later repeat stays in the text instead of moving the cut")

        var revised = WakeSpeechCapture(text: "Hello Chat now", phrase: "Hello Chat", similar: false)
        revised.update("Yellow cat now")
        precondition(revised.text == "Yellow cat now", "A revision that drops the wake keeps the whole piece")

        var newest = WakeSpeechCapture(text: "Hello Chat stop. Hello Chat go", phrase: "Hello Chat", similar: true)
        precondition(newest.text == "go", "The newest match at detection is the accepted wake")
        newest.boundary(); newest.boundary()
        precondition(newest.text == "go", "Empty pieces add nothing")

        // Link building.
        let id = "01A1A93E-47F3-7942-92F9-38CDBA931633"
        precondition(VoiceChatHandoff.url(chat: id, prompt: "")?.absoluteString == "codex://threads/01a1a93e-47f3-7942-92f9-38cdba931633")
        let link = VoiceChatHandoff.url(chat: id, prompt: "1+1 & a=b #tag")!
        let prompt = URLComponents(url: link, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        precondition(prompt == "prompt=1%2B1%20%26%20a%3Db%20%23tag", "Plus, ampersand, equals and hash survive URLSearchParams: \(prompt ?? "nil")")
        precondition(VoiceChatHandoff.url(chat: "../settings", prompt: "x") == nil, "Only real chat IDs become links")

        // Handoff with an injected Codex.
        final class Fake {
            var clock = Date(timeIntervalSince1970: 1_000)
            var lookups = 0, chatAfter = 0
            var opened: [URL] = [], returns = 0
            var holds = true
            var askedSince: Date?
        }
        func handoff(_ fake: Fake) -> VoiceChatHandoff {
            VoiceChatHandoff(transport: .init(newVoiceChat: { since in
                fake.askedSince = since; fake.lookups += 1
                return fake.lookups > fake.chatAfter ? id : nil
            }, open: { fake.opened.append($0) }, composerHolds: { _ in fake.holds },
               pressReturn: { fake.returns += 1 }, now: { fake.clock },
               wait: { fake.clock = fake.clock.addingTimeInterval($0) }))
        }
        let started = Date(timeIntervalSince1970: 1_000)

        let sent = Fake(); sent.chatAfter = 3
        var spoken = "early"
        let outcome = try await handoff(sent).run(startedAt: started) { spoken }
        precondition(outcome == .sent && sent.returns == 1 && sent.lookups == 4, "Waits for the chat, then sends once")
        precondition(sent.askedSince == started.addingTimeInterval(-1), "Looks for chats created around the Start")
        precondition(sent.opened == [VoiceChatHandoff.url(chat: id, prompt: "early")], "Opens that chat with the words")

        let late = Fake(); late.chatAfter = 2
        spoken = "first"
        let lateHandoff = handoff(late)
        _ = try await lateHandoff.run(startedAt: started) { spoken += " then more"; return spoken }
        precondition(late.opened == [VoiceChatHandoff.url(chat: id, prompt: "first then more")], "Words are read once the chat exists")

        let missing = Fake(); missing.chatAfter = .max
        let none = try await handoff(missing).run(startedAt: started) { "words" }
        precondition(none == .noChat, "No chat, no action")
        precondition(missing.opened.isEmpty && missing.returns == 0)

        let quiet = Fake()
        let openedOnly = try await handoff(quiet).run(startedAt: started) { "" }
        precondition(openedOnly == .opened, "An empty capture still opens the chat")
        precondition(quiet.opened == [VoiceChatHandoff.url(chat: id, prompt: "")] && quiet.returns == 0, "Nothing is sent without words")

        let elsewhere = Fake(); elsewhere.holds = false
        let unconfirmed = try await handoff(elsewhere).run(startedAt: started) { "words" }
        precondition(unconfirmed == .unconfirmed, "Unconfirmed message box")
        precondition(elsewhere.returns == 0, "Return is never pressed unless the focused box holds the words")
        print("VoiceChatHandoffTests passed")
    }
}
