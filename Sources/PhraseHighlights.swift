import Foundation

// Ethan's "HUD" is the Heard (local model) transcript in the native window.
// Preserve the model's actual text, punctuation and case while colouring only
// complete matcher spans. Discussion filtering still owns activation separately.
enum PhraseHighlights {
    struct Run: Equatable {
        var text: String
        var kind: PhraseMatcher.MatchKind?
    }

    static func runs(in text: String, phrase: String, similar: Bool, limit: Int = 600) -> [Run] {
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
        let matches = PhraseMatcher.matches(in: tokens, phrase: phrase, similar: similar)
        var result: [Run] = []
        cursor = visibleStart
        for match in matches {
            let range = ranges[match.start].lowerBound..<ranges[match.end - 1].upperBound
            // A clipped phrase must not look like a complete accepted command.
            guard range.lowerBound >= visibleStart,
                  let kind = PhraseMatcher.matchKind(tokens[match.start..<match.end].joined(), to: phrase, similar: similar) else { continue }
            if cursor < range.lowerBound { result.append(Run(text: String(text[cursor..<range.lowerBound]))) }
            result.append(Run(text: String(text[range]), kind: kind))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result.append(Run(text: String(text[cursor...])) ) }
        return result
    }
}
