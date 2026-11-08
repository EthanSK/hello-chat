// Check retained transcript styling without a window, microphone or Voice keys.
import SwiftUI

@main enum TranscriptRenderingTests {
    static func main() {
        let cache = HeardTranscript.HighlightCache()
        let configuration = HeardTranscript.HighlightCache.Configuration(phrase: "Hello Chat", endPhrase: "Bye Chat", similar: true, controlPhrases: PhraseMatcher.controlPhrases)
        let separate = cache.render(["Hello", "Chat"], configuration: configuration)
        precondition(String(separate.characters) == "Hello\nChat")
        precondition(separate.runs.allSatisfy { $0.foregroundColor == nil }, "Separate contexts must not invent a highlighted command")
        let revised = cache.render(["Hello", "Chat is open. Mute Chat"], configuration: configuration)
        precondition(String(revised.characters) == "Hello\nChat is open. Mute Chat", "Revising the current segment preserves completed words")
        precondition(revised.runs.contains { $0.foregroundColor == .green }, "The current segment still highlights its complete exact command")
        let shortened = cache.render(["Earlier words"], configuration: configuration)
        precondition(String(shortened.characters) == "Earlier words", "A shorter new session cannot retain stale segments")
        precondition(cache.render([], configuration: configuration).characters.isEmpty)
        let custom = HeardTranscript.HighlightCache.Configuration(phrase: "Start Lantern", endPhrase: "End Lantern", similar: false, controlPhrases: [])
        let changed = cache.render(["Start Lantern"], configuration: custom)
        precondition(changed.runs.contains { $0.foregroundColor == .green }, "Changed phrase settings replace cached highlighting")
        print("Transcript rendering: full text, separate-context highlights, revisions, resets and changed phrases passed")
    }
}
