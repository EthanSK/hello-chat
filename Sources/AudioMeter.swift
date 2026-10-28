import Combine

// Only the waveform observes this object. Audio levels must never invalidate the
// transcript, settings, menu bar and entire window for every microphone buffer.
@MainActor final class AudioMeter: ObservableObject {
    @Published var level = 0.0
}
