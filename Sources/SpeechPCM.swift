import AVFoundation

enum SpeechPCM {
    // The input node cannot resample hardware audio. After route/rate changes,
    // its old output format can still describe the previous device (e.g. a
    // 48kHz/20-channel interface while hardware is now 16kHz/mono).
    static func captureFormat(hardware: AVAudioFormat) -> AVAudioFormat? {
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0 else { return nil }
        guard let layout = hardware.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.channelCount) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                             interleaved: false, channelLayout: layout)
    }
    // Feed Speech exactly the channel shown by the microphone meter. USB audio
    // interfaces can expose many unrelated inputs; they are not a speech mix.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let input = buffer.floatChannelData?[0], buffer.frameLength > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = buffer.frameLength
        let stride = buffer.stride
        for frame in 0..<Int(buffer.frameLength) { destination[frame] = input[frame * stride] }
        return output
    }

    static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var energy: Float = 0
        for frame in 0..<Int(buffer.frameLength) {
            let sample = samples[frame * buffer.stride]
            energy += sample * sample
        }
        return min(1, Double(sqrt(energy / Float(buffer.frameLength))) * 8)
    }
}
