import AVFoundation
import Foundation

// AVAudioConverter owns a filter history: keep it for the whole stream. The
// FluidAudio convenience converter creates and ends one converter per buffer.
final class SpeechResampler {
    private let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if input.format.sampleRate == 16000, input.format.channelCount == 1 { return input }
        if converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: target) }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32) else {
            throw BridgeError.message("Couldn't prepare microphone audio for local speech.")
        }
        var sent = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if sent { state.pointee = .noDataNow; return nil }
            sent = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw BridgeError.message("Couldn't convert microphone audio for local speech.") }
        return output.frameLength > 0 ? output : nil
    }
    func reset() { converter = nil }
}
