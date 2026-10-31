import AVFoundation
import Foundation

// Stable persisted identities. Packaging and live recognition share this layout.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeet320, parakeet160, nemotron560, appleLocal
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
        self == .nemotron560 ? "encoder/encoder_int8.mlmodelc" : "streaming_encoder.mlmodelc"
    }
}

struct SpeechUpdate {
    var text: String?
    var reset = false
    var utteranceEnded = false
}

protocol SpeechBackend: Actor {
    func prepare(directory: URL) async throws -> Double
    func consume(_ mono: AVAudioPCMBuffer) async throws -> SpeechUpdate
    func finish() async throws -> String
    func resetForDiscontinuity() async throws
    func close() async
}
