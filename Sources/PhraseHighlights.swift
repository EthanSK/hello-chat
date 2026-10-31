import Foundation

// Ethan's "HUD" is the Heard (local model) transcript in the native window.
// Preserve the model's actual text, punctuation and case while colouring only
// complete matcher spans. Discussion filtering still owns activation separately.
enum PhraseHighlights {
    struct Run: Equatable {
        var text: String
        var kind: PhraseMatcher.MatchKind?
    }

    private struct Span {
        let start: Int
        let end: Int
        let kind: PhraseMatcher.MatchKind
        var priority: Int { kind == .exact ? 0 : (kind == .dictionary ? 1 : 2) }
    }

    static func runs(in text: String, phrase: String, endPhrase: String = "", similar: Bool, limit: Int = 600) -> [Run] {
        guard limit > 0, !text.isEmpty else { return [] }
        let visibleStart = text.index(text.endIndex, offsetBy: -min(limit, text.count))
        var ranges: [Range<String.Index>] = []
        var tokens: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let start = text.rangeOfCharacter(from: .alphanumerics, range: cursor..<text.endIndex)?.lowerBound {
            let end = text.rangeOfCharacter(from: .alphanumerics.inverted, range: start..<text.endIndex)?.lowerBound ?? text.endIndex
            // Use the detector's tokenizer, including its lowercase handling.
            for token in PhraseMatcher.words(String(text[start..<end])) {
                tokens.append(token); ranges.append(start..<end)
            }
            cursor = end
        }
        var candidates: [Span] = []
        for (savedPhrase, ending) in [(phrase, false), (endPhrase, true)] {
            // End phrases use the detector's closing-command dictionary too:
            // Ethan's "by chat" must colour like the accepted Bye Chat variant.
            for match in PhraseMatcher.matches(in: tokens, phrase: savedPhrase, similar: similar, ending: ending) {
                guard ranges[match.start].lowerBound >= visibleStart,
                      let kind = PhraseMatcher.matchKind(tokens[match.start..<match.end].joined(),
                          to: savedPhrase, similar: similar, ending: ending) else { continue }
                candidates.append(Span(start: match.start, end: match.end, kind: kind))
            }
        }
        // Custom phrases can overlap, including while a field is being edited.
        // Prefer exact matches, then longer spans, without duplicating text.
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.end - $0.start != $1.end - $1.start { return $0.end - $0.start > $1.end - $1.start }
            return $0.start < $1.start
        }
        var matches: [Span] = []
        for candidate in candidates where matches.allSatisfy({ $0.end <= candidate.start || candidate.end <= $0.start }) {
            matches.append(candidate)
        }
        matches.sort { $0.start < $1.start }
        var result: [Run] = []
        cursor = visibleStart
        for match in matches {
            let range = ranges[match.start].lowerBound..<ranges[match.end - 1].upperBound
            if cursor < range.lowerBound { result.append(Run(text: String(text[cursor..<range.lowerBound]))) }
            result.append(Run(text: String(text[range]), kind: match.kind))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result.append(Run(text: String(text[cursor...])) ) }
        return result
    }
}
