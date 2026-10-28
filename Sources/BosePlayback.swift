import CoreAudio
import Foundation

// Ethan's "on the Bose" means this speaker is selected for playback, not merely
// paired. Pause capture to protect music; his later "always be" request keeps
// the app alive so a route change can resume it without manually reopening.
enum BosePlayback {
    /// Reads the playback route without opening an audio stream or changing devices.
    static var isSelected: Bool? {
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0, deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &deviceSize, &device) == noErr else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?, nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String? == "Bose Flex 2 SoundLink"
    }
}
