import SwiftUI

// Extraction of existing highlighted text rendering from HelloChatApp.swift.
// Shared by the live transcript panel and isolated visual previews.
struct HeardTranscript: View, Equatable {
    let text: String
    let phrase: String
    let endPhrase: String
    let similar: Bool
    let enabled: Bool
    private var styled: AttributedString {
        var result = AttributedString()
        for run in PhraseHighlights.runs(in: text, phrase: phrase, endPhrase: endPhrase, similar: similar) {
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
    var body: some View {
        if text.isEmpty {
            Text(enabled ? "Nothing heard yet" : "Start listening to see what's heard")
        } else { Text(styled) }
    }
}
