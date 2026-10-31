import Foundation

@main enum TranscriptViewportTests {
    static func main() {
        precondition(TranscriptViewport.height(viewport: 600, top: 380, scale: 1) == 200)
        precondition(TranscriptViewport.height(viewport: 600, top: 590, scale: 1) == 300)
        precondition(TranscriptViewport.height(viewport: 600, top: nil, scale: 1) == 300)
        precondition(TranscriptViewport.height(viewport: 1200, top: 100, scale: 1) == 300)
        precondition(TranscriptViewport.isReadable(viewport: 600, top: 380, height: 200, scale: 1))
        precondition(!TranscriptViewport.isReadable(viewport: 600, top: 590, height: 300, scale: 1))
        precondition(!TranscriptViewport.isReadable(viewport: 600, top: nil, height: 300, scale: 1))
        precondition(!TranscriptViewport.isReadable(viewport: 600, top: -250, height: 300, scale: 1))
        precondition(TranscriptViewport.isReadable(viewport: 600, top: -20, height: 300, scale: 1))
        precondition(!TranscriptViewport.isReadable(viewport: 40, top: 0, height: 160, scale: 1))
        print("Transcript bounds and partial-visibility checks passed")
    }
}
