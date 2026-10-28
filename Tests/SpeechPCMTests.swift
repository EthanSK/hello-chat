import AVFoundation

@main enum SpeechPCMTests {
    static func main() {
        // Reproduce the failed route's hardware/client mismatch without
        // changing real devices: capture must follow 16kHz mono hardware,
        // never the previous 48kHz/20-channel client bus.
        for (rate, channels) in [(16000.0, UInt32(1)), (48000.0, UInt32(1)), (48000.0, UInt32(20)), (44100.0, UInt32(2))] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
            let hardware = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
            let capture = SpeechPCM.captureFormat(hardware: hardware)!
            precondition(capture.sampleRate == rate && capture.channelCount == channels)
            precondition(capture.commonFormat == .pcmFormatFloat32 && !capture.isInterleaved)
        }
        for (channels, interleaved) in [(UInt32(20), false), (UInt32(2), true), (UInt32(1), false)] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                       interleaved: interleaved, channelLayout: layout)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
            buffer.frameLength = 3
            let expected: [Float] = [0.02, -0.04, 0.08]
            for channel in 0..<Int(channels) {
                for frame in 0..<3 {
                    let value: Float = channel == 0 ? expected[frame] : 1
                    if interleaved { buffer.floatChannelData![0][frame * Int(channels) + channel] = value }
                    else { buffer.floatChannelData![channel][frame] = value }
                }
            }
            let mono = SpeechPCM.mono(buffer)!
            precondition(mono.format.channelCount == 1 && !mono.format.isInterleaved)
            precondition(mono.format.sampleRate == 48000 && mono.frameLength == 3)
            for frame in 0..<3 { precondition(mono.floatChannelData![0][frame] == expected[frame]) }
            let level = min(1, Double(sqrt(expected.reduce(0) { $0 + $1 * $1 } / 3)) * 8)
            precondition(abs(SpeechPCM.level(mono) - level) < 0.00001)
        }
        print("Passed speech PCM checks: 20-channel input, interleaved stereo, mono and meter consistency. No microphone or playback used.")
    }
}
