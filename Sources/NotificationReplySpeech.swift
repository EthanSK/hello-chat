// Map the existing recognizer's resettable word clock onto captured host uptime for notification replies. — GPT-6.1 Sol
import Foundation

/// Timing adapter only: it owns no microphone, model, audio buffer or second transcript pipeline. — GPT-6.1 Sol
struct NotificationReplySpeech {
    private(set) var batch = UUID()
    private var text = ""
    private var supplied: [(word: String, start: Double, end: Double)] = []
    private var stableWords = 0
    private var reliable = false
    private(set) var capturedThrough = -Double.infinity
    private var clockOffset = 0.0
    private var anchored = false
    private var previousWords: [NotificationReplyCore.Word] = []
    private var previousRevision: UInt64?

    mutating func boundary() {
        batch = UUID(); text = ""; supplied = []; stableWords = 0; reliable = false
        capturedThrough = -.infinity; clockOffset = 0
        anchored = false; previousWords = []; previousRevision = nil
    }
    mutating func observe(text newText: String?, timings: [(word: String, start: Double, end: Double)]?,
                          inputTime: Double?, capturedAt: Double, finalWords: Int?, ended: Bool, revision: UInt64? = nil) -> NotificationReplyCore.Recognition? {
        guard let inputTime, inputTime.isFinite, capturedAt.isFinite else { return nil }
        // The full fed-sample clock includes priming and undecoded samples. Decoded chunk progress cannot anchor word time. — GPT-6.1 Sol
        if !anchored { clockOffset = capturedAt - inputTime; anchored = true }
        capturedThrough = capturedAt
        if let newText {
            text = newText
            let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            reliable = timings?.map(\.word) == words
            supplied = reliable ? timings ?? [] : []
        }
        guard !text.isEmpty else { return nil }
        if ended { stableWords = supplied.count }
        if let finalWords { stableWords = max(stableWords, finalWords) }
        let mapped: [NotificationReplyCore.Word] = reliable ? supplied.map { .init(text: $0.word, start: $0.start + clockOffset, end: $0.end + clockOffset) } : []
        // Agreeing prefixes across real inference progress can start composition without a pause; they never finalize End reply. — GPT-6.1 Sol
        let advanced = revision.map { value in previousRevision.map { value > $0 } ?? false } ?? false
        let confirmed = advanced ? zip(previousWords, mapped).prefix {
            $0.text == $1.text && abs($0.start - $1.start) < 0.05
        }.count : 0
        previousWords = mapped; previousRevision = revision
        return .init(batch: batch, text: text, words: mapped, stableWords: min(stableWords, supplied.count), confirmedStartWords: confirmed)
    }
    func modelTime(for hostTime: Double) -> Double? {
        guard hostTime.isFinite, hostTime <= capturedThrough else { return nil }
        return max(0, hostTime - clockOffset)
    }
    func hostTime(forDecodedTime time: Double) -> Double? {
        guard anchored, time.isFinite else { return nil }
        return time + clockOffset
    }
}
