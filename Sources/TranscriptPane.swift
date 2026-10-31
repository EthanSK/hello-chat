import SwiftUI

struct TranscriptPane: View {
    static let coordinateSpace = "transcriptViewport"
    let text: String
    let phrase: String
    let endPhrase: String
    let similar: Bool
    let enabled: Bool
    let viewportHeight: CGFloat
    let scale: Double
    @State private var top: CGFloat?
    @State private var followsLatest = true
    @State private var userScrolling = false
    @State private var heldText: String?

    private var height: CGFloat {
        TranscriptViewport.height(viewport: viewportHeight, top: top, scale: scale)
    }
    private var readable: Bool {
        TranscriptViewport.isReadable(viewport: viewportHeight, top: top, height: height, scale: scale)
    }
    private func atEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeardTranscript(text: heldText ?? text, phrase: phrase, endPhrase: endPhrase, similar: similar, enabled: enabled)
                        .equatable()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityIdentifier("heardText")
                    Color.clear.frame(height: 1).id("transcriptTail")
                }
                .padding(.trailing, 4)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollGeometryChange(for: Bool.self, of: atEnd) { _, atEnd in
                if userScrolling { followsLatest = atEnd }
            }
            .onScrollPhaseChange { _, phase, context in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if userScrolling { followsLatest = atEnd(context.geometry) }
            }
            .onChange(of: text) { _, value in
                if value.isEmpty { heldText = nil; followsLatest = true }
                if followsLatest && readable { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
            .onChange(of: followsLatest) { _, follows in
                // Keep the existing bounded text stable while it is being read.
                heldText = follows ? nil : text
                if follows && readable { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
            .onChange(of: readable) { _, visible in
                if visible && followsLatest { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
            .onChange(of: height) { _, _ in
                if followsLatest && readable { proxy.scrollTo("transcriptTail", anchor: .bottom) }
            }
        }
        .frame(height: height)
        .background {
            GeometryReader { geometry in
                Color.clear.onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named(Self.coordinateSpace)).minY
                } action: { top = $0 }
            }
        }
        .accessibilityIdentifier("transcriptScroll")
    }
}
