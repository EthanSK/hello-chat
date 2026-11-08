import SwiftUI

// Extraction of existing highlighted text rendering from HelloChatApp.swift.
// Shared by the live transcript panel and isolated visual previews.
struct HeardTranscript: View, Equatable {
    var text = ""
    var segments: [String]? = nil
    let phrase: String
    let endPhrase: String
    let similar: Bool
    let enabled: Bool
    var controlPhrases: [String] = PhraseMatcher.controlPhrases
    var patterns: [PhrasePattern]? = nil
    @State private var highlights = HighlightCache()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.segments == rhs.segments && lhs.phrase == rhs.phrase
            && lhs.endPhrase == rhs.endPhrase && lhs.similar == rhs.similar
            && lhs.enabled == rhs.enabled && lhs.controlPhrases == rhs.controlPhrases && lhs.patterns == rhs.patterns
    }
    var body: some View {
        let values = segments ?? (text.isEmpty ? [] : [text])
        if values.isEmpty {
            Text(enabled ? "Nothing heard yet" : "Start listening to see what's heard")
        } else {
            Text(highlights.render(values, configuration: .init(phrase: phrase, endPhrase: endPhrase, similar: similar, controlPhrases: controlPhrases, patterns: patterns)))
        }
    }

    // One Text preserves selection across recognition boundaries. Cache each
    // segment's expensive matching so a new word does not re-scan old speech.
    final class HighlightCache {
        struct Configuration: Equatable {
            let phrase: String
            let endPhrase: String
            let similar: Bool
            let controlPhrases: [String]
            var patterns: [PhrasePattern]? = nil
        }
        private var configuration: Configuration?
        private var sources: [String] = []
        private var rendered: [AttributedString] = []

        func render(_ segments: [String], configuration: Configuration) -> AttributedString {
            if self.configuration != configuration {
                sources = []; rendered = []; self.configuration = configuration
            }
            for (index, text) in segments.enumerated() {
                if index < sources.count, sources[index] == text { continue }
                let value = style(text, configuration: configuration)
                if index < sources.count { sources[index] = text; rendered[index] = value }
                else { sources.append(text); rendered.append(value) }
            }
            if sources.count > segments.count {
                sources.removeLast(sources.count - segments.count)
                rendered.removeLast(rendered.count - segments.count)
            }
            var result = AttributedString()
            for (index, value) in rendered.enumerated() {
                if index > 0 { result.append(AttributedString("\n")) }
                result.append(value)
            }
            return result
        }
        private func style(_ text: String, configuration: Configuration) -> AttributedString {
            var result = AttributedString()
            for run in PhraseHighlights.runs(in: text, phrase: configuration.phrase, endPhrase: configuration.endPhrase,
                                            similar: configuration.similar, controlPhrases: configuration.controlPhrases, patterns: configuration.patterns) {
                var part = AttributedString(run.text)
                if let kind = run.kind {
                    let color: Color = kind == .exact ? .green : (kind == .dictionary ? .orange : .purple)
                    part.foregroundColor = color
                    part.backgroundColor = color.opacity(0.12)
                    part.inlinePresentationIntent = .stronglyEmphasized
                }
                result.append(part)
            }
            return result
        }
    }
}
