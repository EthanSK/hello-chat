import Foundation

@main enum PhraseHighlightTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func runs(_ text: String, _ phrase: String = "Hello Chat", _ similar: Bool = true, limit: Int = 600) -> [PhraseHighlights.Run] {
            PhraseHighlights.runs(in: text, phrase: phrase, similar: similar, limit: limit)
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
        print("\(checks) phrase highlight checks passed")
    }
}
