import AVFoundation
import Foundation

enum BridgeError: Error { case message(String) }
@main struct SpeechResamplerTests {
 static func main() throws {
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  func buffer(_ start: Int, _ count: Int) -> AVAudioPCMBuffer {
   let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; b.frameLength = AVAudioFrameCount(count)
   for i in 0..<count { let t = Double(start+i)/48000; b.floatChannelData![0][i] = Float(sin(2 * .pi * (220*t + 90*t*t)) * 0.2) }
   return b
  }
  let whole = try SpeechResampler().convert(buffer(0,480000))!
  let converter = SpeechResampler(); var actual: [Float] = []; var offset = 0
  while offset<480000 { let n=min(4096,480000-offset); if let b=try converter.convert(buffer(offset,n)) { actual.append(contentsOf: UnsafeBufferPointer(start:b.floatChannelData![0],count:Int(b.frameLength))) }; offset += n }
  let expected = Array(UnsafeBufferPointer(start: whole.floatChannelData![0],count:Int(whole.frameLength)))
  let error = zip(actual,expected).map { abs($0-$1) }.max() ?? 0
  print("chunked_frames=\(actual.count) whole_frames=\(expected.count) max_sample_error=\(error)")
  guard actual.count == expected.count, error<0.00001 else { throw BridgeError.message("continuity mismatch") }
  converter.reset()
  let restarted=try converter.convert(buffer(0,4096))!
  let fresh=try SpeechResampler().convert(buffer(0,4096))!
  guard restarted.frameLength==fresh.frameLength else { throw BridgeError.message("reset mismatch") }
  print("Persistent resampler continuity and reset passed.")
 }
}
