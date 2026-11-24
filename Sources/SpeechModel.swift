import AVFoundation
import Foundation

// Stable persisted identities. Packaging and live recognition share this layout.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case nemotron560, parakeet320, parakeet160, appleLocal
    static let defaultModel: SpeechModel = .nemotron560
    static func saved(in preferences: UserDefaults = .standard) -> SpeechModel {
        SpeechModel(rawValue: preferences.string(forKey: "speechModel") ?? "") ?? defaultModel
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .parakeet320: return "Parakeet EOU · 320 ms"
        case .parakeet160: return "Parakeet EOU · 160 ms"
        case .nemotron560: return "Nemotron · 560 ms"
        case .appleLocal: return "Apple Speech · local"
        }
    }
    var detail: String {
        self == .appleLocal ? "On-device Apple speech. Neural Engine placement isn't exposed by Apple." : "Local Core ML · Neural Engine + CPU · GPU off"
    }
    var neuralPlacementKnown: Bool { self != .appleLocal }
    var hasNativeUtteranceEnd: Bool { self == .parakeet320 || self == .parakeet160 }
    var directory: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("LocalSpeech", isDirectory: true) else { return nil }
        switch self {
        case .parakeet320, .appleLocal: return root
        case .parakeet160, .nemotron560: return root.appendingPathComponent(rawValue, isDirectory: true)
        }
    }
    var encoderPath: String {
        // SpeechModels.json remaps the compatible v2 graph here; this guard and
        // the pinned SDK load the same single encoder, with unchanged weights.
        self == .nemotron560 ? "encoder/encoder_int8.mlmodelc" : "streaming_encoder.mlmodelc"
    }
}

struct SpeechUpdate {
    var text: String?
    var audioTime: Double // Audio progress on the same resettable clock as wordTimings, including model priming.
    var reset = false
    var utteranceEnded = false
    var wordTimings: [(word: String, start: Double, end: Double)]? = nil
    var finalizedWordCount: Int? = nil
    var inputAudioTime: Double? = nil // Full fed-input timeline, including priming, before decoder chunk rounding.
    var recognitionRevision: UInt64? = nil
    var lostAudio = false // A recovery reset after dropped input is different from a normal context rollover. — GPT-6.1 Sol
}

protocol SpeechBackend: Actor {
    func prepare(directory: URL) async throws -> Double
    func consume(_ mono: AVAudioPCMBuffer) async throws -> SpeechUpdate
    func finish() async throws -> String
    func resetForDiscontinuity() async throws
    func finalizeRecognition(through time: Double) async throws
    func finalizeNotificationEnd(through time: Double) async throws -> SpeechUpdate?
    func close() async
}

extension SpeechBackend {
    // Optional analyzer-prefix request. Neural Reply activation uses agreeing
    // real inference revisions; explicit notification End has its own hook.
    func finalizeRecognition(through time: Double) async throws { }
    func finalizeNotificationEnd(through time: Double) async throws -> SpeechUpdate? { nil }
}
