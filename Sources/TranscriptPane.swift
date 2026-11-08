import SwiftUI
import AppKit

struct TranscriptPane: View {
    static let coordinateSpace = "transcriptViewport"
    let segments: [String]
    let phrase: String
    let endPhrase: String
    let similar: Bool
    let enabled: Bool
    let viewportHeight: CGFloat
    let scale: Double
    var controlPhrases: [String] = PhraseMatcher.controlPhrases
    @State private var top: CGFloat?

    private var height: CGFloat {
        TranscriptViewport.height(viewport: viewportHeight, top: top, scale: scale)
    }
    var body: some View {
        NativeTranscript(segments: segments, phrase: phrase, endPhrase: endPhrase, similar: similar,
                         enabled: enabled, scale: scale, controlPhrases: controlPhrases)
            .frame(height: height)
            .background {
                GeometryReader { geometry in
                    Color.clear.onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(Self.coordinateSpace)).minY
                    } action: { top = $0 }
                }
            }
    }
}

// SwiftUI Text drew the entire long history on every revision. NSTextView owns
// efficient scrolling and continuous selection; the matcher still styles each
// recognition segment separately through the same cache used by previews.
private struct NativeTranscript: NSViewRepresentable {
    let segments: [String]
    let phrase: String
    let endPhrase: String
    let similar: Bool
    let enabled: Bool
    let scale: Double
    let controlPhrases: [String]

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.setAccessibilityIdentifier("transcriptScroll")
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityIdentifier("heardText")
        text.setAccessibilityLabel("Heard transcript")
        scroll.documentView = text
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        DispatchQueue.main.async { context.coordinator.applyLatest(forceLayout: true) } // Initial SwiftUI sizing arrives after the first text update.
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let cache = context.coordinator.cache
        let values = segments.isEmpty ? [enabled ? "Nothing heard yet" : "Start listening to see what's heard"] : segments
        let styled = segments.isEmpty ? AttributedString(values[0]) : cache.render(values, configuration: .init(phrase: phrase, endPhrase: endPhrase, similar: similar, controlPhrases: controlPhrases))
        let font = NSFont.systemFont(ofSize: 13 * scale)
        let native = NSMutableAttributedString(string: String(styled.characters), attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        var location = 0
        for run in styled.runs {
            let length = String(styled.characters[run.range]).utf16.count
            if let color = run.foregroundColor {
                let nativeColor: NSColor = color == .green ? .systemGreen : (color == .orange ? .systemOrange : .systemPurple)
                native.addAttributes([.foregroundColor: nativeColor, .backgroundColor: nativeColor.withAlphaComponent(0.12),
                                      .font: NSFont.boldSystemFont(ofSize: font.pointSize)], range: NSRange(location: location, length: length))
            }
            location += length
        }
        context.coordinator.latest = native
        if segments.isEmpty { context.coordinator.followsLatest = true }
        if context.coordinator.followsLatest { context.coordinator.applyLatest() }
    }

    final class Coordinator: NSObject {
        let cache = HeardTranscript.HighlightCache()
        weak var scroll: NSScrollView?
        var latest = NSAttributedString()
        var followsLatest = true
        private var applying = false
        private var viewportSize = NSSize.zero
        private var documentHeight: CGFloat = 0
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func scrolled() {
            guard !applying, let scroll, let text = scroll.documentView as? NSTextView else { return }
            if scroll.contentSize != viewportSize || text.bounds.height != documentHeight {
                viewportSize = scroll.contentSize; documentHeight = text.bounds.height
                if followsLatest { applyLatest(forceLayout: true) }
                return // Resizing the viewport or text is not a user scroll away from the bottom.
            }
            followsLatest = scroll.documentVisibleRect.maxY >= text.bounds.maxY - 24
            if followsLatest { applyLatest() }
        }
        func applyLatest(forceLayout: Bool = false) {
            guard !applying, let scroll, let text = scroll.documentView as? NSTextView,
                  let storage = text.textStorage, forceLayout || !storage.isEqual(to: latest) else { return }
            applying = true
            defer { applying = false }
            let selection = text.selectedRanges
            if !storage.isEqual(to: latest) { storage.setAttributedString(latest) }
            text.selectedRanges = selection.map { value in
                let range = value.rangeValue
                let start = min(range.location, storage.length)
                return NSValue(range: NSRange(location: start, length: min(range.length, storage.length - start)))
            }
            if let container = text.textContainer, let layout = text.layoutManager {
                container.containerSize = NSSize(width: max(1, scroll.contentSize.width), height: CGFloat.greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                text.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, layout.usedRect(for: container).height)))
            }
            viewportSize = scroll.contentSize; documentHeight = text.bounds.height
            text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }
}
