import Foundation

@main enum PhraseHighlightTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func runs(_ text: String, _ phrase: String = "Hello Chat", _ similar: Bool = true, end: String = "", limit: Int = 600) -> [PhraseHighlights.Run] {
            PhraseHighlights.runs(in: text, phrase: phrase, endPhrase: end, similar: similar, limit: limit)
        }
        let original = "🎙️ Café: Hello, CHAT! As well chat. HelloChad — ordinary words."
        let styled = runs(original)
        check(styled.map(\.text).joined() == original, "Never rewrite recognized text, punctuation or emoji")
        check(styled.filter { $0.kind == .exact }.map(\.text) == ["Hello, CHAT"], "Exact normalized match has original source range")
        check(styled.filter { $0.kind == .dictionary }.map(\.text) == ["As well chat", "HelloChad"], "Dictionary ranges share the detector")
        check(runs("Hey Chatt", "Hey Chat").first?.kind == .fuzzy, "Custom phrase edit classified separately")
        check(runs("Hey Chat", "Hey Chat").first?.kind == .exact, "Custom exact phrase wins")
        check(runs("H E L L O C H A T").map(\.text).joined() == "H E L L O C H A T", "Spelled letters preserve text around the detector's accepted span")
        check(runs("Hello Chat / Harlow Chat", "Hello Chat", false).filter { $0.kind != nil }.count == 1, "Exact-only preference excludes aliases")
        check(runs("My phrase", "My phrase").first?.kind == .exact, "Uses saved custom phrase")
        check(runs("Hello Chat", "Different phrase").allSatisfy { $0.kind == nil }, "No hardcoded default highlighting")
        check(runs("Hello Chat", limit: 5).map(\.text).joined() == " Chat", "Bounded suffix remains identical")
        check(runs("Hello Chat", limit: 5).allSatisfy { $0.kind == nil }, "No highlighting an incomplete clipped command")
        check(runs("hello chat").first?.kind == .exact, "Complete phrase at both boundaries")
        check(runs("hello chat hello chad hello chat").filter { $0.kind != nil }.count == 3, "All occurrences highlighted once")
        check(runs("hello chance").first?.kind == .dictionary, "Wake prefix uses the shared dictionary highlight")
        check(runs("hello chance", "Hello Chat", false).allSatisfy { $0.kind == nil }, "Exact mode does not highlight the new alias")
        check(runs("I said Hello Chat").contains { $0.kind == .exact }, "Textual highlight does not claim context accepted activation")
        check(runs("pie charts and by that").allSatisfy { $0.kind == nil }, "Unmatched text remains neutral")
        check(runs("it's too high at low speed").allSatisfy { $0.kind == nil }, "Ordinary high at cannot highlight as a wake")
        check(runs("high at. Hi Chat").filter { $0.kind != nil }.map(\.text) == ["Hi Chat"], "A real wake after high at still highlights")
        check(runs("High At", "High At", false).first?.kind == .exact, "An exact custom phrase remains available")
        check(runs("").isEmpty && runs("Hello Chat", limit: 0).isEmpty, "Empty and zero viewport")
        check(runs("... 👋").map(\.text).joined() == "... 👋", "No token input preserved")
        let screenshot = "Hello, this is a test. What's going on? Hello chat. Bye chat by chat why does the end voice end phrase not highlight"
        let both = runs(screenshot, end: "Bye Chat")
        check(both.map(\.text).joined() == screenshot, "Both command highlights preserve the exact screenshot transcript")
        let commands = both.filter { $0.kind != nil }
        check(commands.map(\.text) == ["Hello chat", "Bye chat", "by chat"], "Wake, exact end and misheard end all highlight")
        check(commands.map(\.kind) == [.exact, .exact, .dictionary], "Closing aliases use the detector's end-only dictionary")
        check(runs("Bye, CHAT! ByteChat. by charts.", end: "Bye Chat").filter { $0.kind != nil }.map(\.kind) == [.exact, .dictionary, .dictionary], "End variants share exact and dictionary colours")
        check(runs("Bye Chat by chat", "Hello Chat", false, end: "Bye Chat").filter { $0.kind != nil }.map(\.text) == ["Bye Chat"], "Exact-only mode excludes end aliases")
        check(runs("pie charts and by that", end: "Bye Chat").allSatisfy { $0.kind == nil }, "Ordinary end lookalikes stay neutral")
        check(runs("Start Lantern. End Lantern. Hello Chat. Bye Chat.", "Start Lantern", end: "End Lantern").filter { $0.kind != nil }.map(\.text) == ["Start Lantern", "End Lantern"], "Both saved custom phrases replace defaults")
        check(runs("Bye Chat", end: "Different phrase").allSatisfy { $0.kind == nil }, "Changing the saved end phrase removes its old highlight")
        check(runs("Bye Chat", end: "Bye Chat", limit: 5).allSatisfy { $0.kind == nil }, "A clipped end phrase is never highlighted as complete")
        let overlap = runs("Bye Chat", "Bye Chatt", end: "Bye Chat")
        check(overlap.map(\.text).joined() == "Bye Chat" && overlap.count == 1 && overlap.first?.kind == .exact, "Exact end wins an overlapping fuzzy wake without duplicating text")
        check(runs("Hello Chat", end: "Hello Chat").filter { $0.kind != nil }.count == 1, "Identical temporary field values highlight once")
        check(runs("Hello Chat", "Hello", false, end: "Hello Chat").filter { $0.kind != nil }.map(\.text) == ["Hello Chat"], "Longer exact custom phrase wins a shared prefix")
        print("\(checks) phrase highlight checks passed")
    }
}
