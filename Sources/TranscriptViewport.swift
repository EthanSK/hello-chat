import Foundation

struct TranscriptViewport {
    static func minimumHeight(scale: Double) -> CGFloat { max(72, 52 * scale) }

    static func height(viewport: CGFloat, top: CGFloat?, scale: Double) -> CGFloat {
        let preferred = max(160, min(300, viewport * 0.5))
        guard let top, top >= 0 else { return preferred }
        let available = viewport - top - 20
        // Ethan's "enough of the actual transcript view is visible": don't
        // collapse an offscreen panel into a sliver just to make its tail fit.
        guard available >= minimumHeight(scale: scale) else { return preferred }
        return min(preferred, available)
    }

    static func isReadable(viewport: CGFloat, top: CGFloat?, height: CGFloat, scale: Double) -> Bool {
        guard let top else { return false }
        let visible = max(0, min(viewport, top + height) - max(0, top))
        return visible >= minimumHeight(scale: scale) && visible >= height * 0.6
    }
}
