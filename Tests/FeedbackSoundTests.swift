// Every phrase has its own sound: the typed mapping, the shipped assets and their character.
// Reads Resources/Sounds from the repository root. Never plays a sound.
import AppKit
import CryptoKit

private struct Wave { let format: Int; let channels: Int; let rate: Int; let bits: Int; let samples: [Double] }

private func readWave(_ data: Data) -> Wave? {
    let bytes = [UInt8](data)
    func u16(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
    func u32(_ index: Int) -> Int { u16(index) | u16(index + 2) << 16 }
    guard bytes.count > 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else { return nil }
    var offset = 12, format = 0, channels = 0, rate = 0, bits = 0
    var samples: [Double]?
    while offset + 8 <= bytes.count {
        let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self), size = u32(offset + 4), body = offset + 8
        guard body + size <= bytes.count else { return nil }
        if id == "fmt " {
            guard size >= 16 else { return nil }
            format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
        }
        if id == "data" { samples = stride(from: body, to: body + size - 1, by: 2).map { Double(Int16(bitPattern: UInt16(u16($0)))) / 32767 } }
        offset = body + size + size % 2
    }
    guard let samples else { return nil }
    return Wave(format: format, channels: channels, rate: rate, bits: bits, samples: samples)
}

// Loudest 100 ms RMS, the generator's own loudness measure.
private func loudness(_ samples: [Double], rate: Int) -> Double {
    let window = rate / 10
    return stride(from: 0, to: max(1, samples.count - window + 1), by: window / 4).map { start in
        (samples[start..<min(samples.count, start + window)].reduce(0) { $0 + $1 * $1 } / Double(window)).squareRoot()
    }.max() ?? 0
}

// A coarse shape: loudness and brightness over eight slices of the first 0.4 s.
private func fingerprint(_ samples: [Double], rate: Int) -> [Double] {
    let windows = 8, size = rate * 4 / 10 / windows
    var envelope: [Double] = [], crossings: [Double] = []
    for slice in 0..<windows {
        let window = (slice * size..<(slice + 1) * size).map { $0 < samples.count ? samples[$0] : 0 }
        envelope.append((window.reduce(0) { $0 + $1 * $1 } / Double(size)).squareRoot())
        let count = zip(window, window.dropFirst()).filter { ($0 < 0) != ($1 < 0) && abs($0) + abs($1) > 1e-3 }.count
        crossings.append(Double(count) / (Double(size) / Double(rate)) / 2000)
    }
    let peak = envelope.max() ?? 0
    return envelope.map { $0 / (peak > 0 ? peak : 1) } + crossings
}

@main enum FeedbackSoundTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        typealias Cue = FeedbackSounds.Cue
        let commandCues: Set<Cue> = [.silent, .videoPaused, .videoPlayed, .switchApp, .openApp, .zoomIn, .zoomOut]

        // Each phrase slot owns a distinct sound, including the two ways to silence speakers.
        let slotCues = Set(PhraseSlot.allCases.map(\.cue))
        check(slotCues.union([.microphoneDetected]) == Set(Cue.allCases) && !slotCues.contains(.microphoneDetected),
              "Every cue belongs to a phrase, except the neutral audio-detection tone")
        check(slotCues.count == PhraseSlot.allCases.count, "Every phrase slot has a distinct sound")
        check(PhraseSlot.wakePhrase.cue == .wake && PhraseSlot.sleepPhrase.cue == .ended, "Wake and End keep their chimes")
        check(VoiceAudioAction.allCases.map { $0.slots.map(\.cue) } ==
              [[.microphoneMuted], [.microphoneUnmuted], [.silent, .speakersMuted], [.speakersUnmuted]],
              "Audio wording picks its own confirmed-state sound")
        check(Set(VoiceAudioAction.allCases.flatMap(\.slots)) == Set(PhraseSlot.voiceSlots).subtracting([.wakePhrase, .sleepPhrase]),
              "Audio actions cover exactly the audio phrase fields")
        check(VideoCommand.allCases.map(\.slot.cue) == [.videoPaused, .videoPlayed], "Video commands")
        check([AppCommandKind.switchApp, .openApp].map(\.slot.cue) == [.switchApp, .openApp], "App commands")
        check(ZoomDirection.allCases.map(\.slot.cue) == [.zoomIn, .zoomOut], "Zoom commands")

        // Edited phrases and spoken app names never change which sound plays: the slot decides.
        var video = CommandPhraseDetectors<VideoCommand>()
        video.audio(level: 0.2, seconds: 0.1); video.update("Freeze clip", at: 1)
        let customVideo: [VideoCommand: PhrasePattern] = [
            .pause: PhrasePattern(slot: .pauseVideoPhrase, text: "Freeze clip", similar: true, dictionaries: .init()),
            .play: PhrasePattern(slot: .playVideoPhrase, text: "Resume clip", similar: true, dictionaries: .init())]
        check(video.poll(at: 1, patterns: customVideo).map(\.command.slot.cue) == [.videoPaused], "A custom video phrase keeps its sound")
        func appCue(_ text: String, switchPrefix: String, openPrefix: String) -> [Cue] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1); detector.audio(level: 0, seconds: 1)
            return detector.poll(switchPrefix: PhrasePattern(slot: .switchAppPhrase, text: switchPrefix, similar: true, dictionaries: .init()),
                                 openPrefix: PhrasePattern(slot: .openAppPhrase, text: openPrefix, similar: true, dictionaries: .init()))
                .map(\.kind.slot.cue)
        }
        for name in ["Chrome", "Safari", "Visual Studio Code"] {
            check(appCue("Jump to \(name)", switchPrefix: "Jump to", openPrefix: "Launch app") == [.switchApp], "Custom switch prefix, any app: \(name)")
            check(appCue("Launch app \(name)", switchPrefix: "Jump to", openPrefix: "Launch app") == [.openApp], "Custom open prefix, any app: \(name)")
        }

        let speakerSlots = VoiceAudioAction.silenceSpeakers.slots
        let overlapping = PhraseDictionaries(["silentchat": ["silence chat", "quiet speakers"]])
        let speakerPatterns = speakerSlots.map {
            PhrasePattern(slot: $0, text: $0.defaultText, similar: true, dictionaries: overlapping)
        }
        func speakerCue(_ transcript: String, patterns: [PhrasePattern]) -> Cue? {
            var detector = StandaloneWake()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(transcript, at: 1)
            guard detector.poll(at: 1, phrase: patterns[0].text, similar: true, rejectNegated: true, patterns: patterns),
                  let index = detector.acceptedPatternIndex else { return nil }
            check(!detector.poll(at: 2, phrase: patterns[0].text, similar: true, rejectNegated: true, patterns: patterns),
                  "An accepted speaker phrase is consumed once")
            return speakerSlots[index].cue
        }
        check(speakerCue("Silent Chat", patterns: speakerPatterns) == .silent, "First speaker phrase plays its sound")
        check(speakerCue("Silence Chat", patterns: speakerPatterns) == .speakersMuted, "Exact phrase takes priority over an overlapping alias")
        check(speakerCue("Quiet speakers", patterns: speakerPatterns) == .silent, "A dictionary alias keeps its slot's sound")
        let edited = zip(speakerSlots, ["Turn down voice", "Quiet now"]).map {
            PhrasePattern(slot: $0, text: $1, similar: true, dictionaries: .init())
        }
        check(speakerCue("Quiet now", patterns: edited) == .speakersMuted, "Edited speaker wording keeps its slot's sound")
        check(speakerCue("I said quiet now", patterns: edited) == nil, "A phrase mention has no speaker sound")
        let titles = PhraseSlot.allCases.map(\.soundTitle)
        check(Set(titles).count == titles.count && titles.contains("Silent") && titles.contains("Silence"),
              "The two speaker-silence previews are independently named")

        // Assets: exactly one short, audible, unclipped 16-bit mono file per cue.
        let directory = URL(fileURLWithPath: "Resources/Sounds", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        check(Set(files.map { $0.deletingPathExtension().lastPathComponent }) == Set(Cue.allCases.map(\.rawValue)), "No missing or orphaned sound files")
        var waves: [Cue: Wave] = [:], contents: [Data] = []
        for cue in Cue.allCases {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(cue.rawValue).wav"))
            guard let wave = readWave(data) else { preconditionFailure("\(cue.rawValue).wav is not a readable WAVE file") }
            let duration = Double(wave.samples.count) / Double(wave.rate), peak = wave.samples.map(abs).max() ?? 0
            check(wave.format == 1 && wave.channels == 1 && wave.rate == 44_100 && wave.bits == 16, "\(cue.rawValue) is 16-bit mono PCM")
            check(duration >= 0.15 && duration <= 0.45, "\(cue.rawValue) is short")
            check(peak > 0.05 && peak < 0.9, "\(cue.rawValue) is audible and unclipped")
            check(abs(wave.samples.first ?? 1) < 0.01 && abs(wave.samples.last ?? 1) < 0.01, "\(cue.rawValue) starts and ends without a click")
            waves[cue] = wave; contents.append(data)
        }
        check(Set(contents).count == contents.count, "Every cue file is different")
        let original: [Cue: String] = [
            .wake: "0215ae91cead1f983f293bd7dc7852553fc481c12a831e411fea5349443a770a",
            .ended: "a98d42b3e1636710909997b7776db950677fd7ab37663e3c0e1d17a778c6346c",
            .microphoneDetected: "8c55b5e52949c387d6514d4516eb4e874dcd8019e7e13e86a38d3d41c295ae81",
            .microphoneMuted: "4f6047585804db654864dc02a2a7cdf22289aef6a8bb91a5c5489e6568840713",
            .microphoneUnmuted: "47ef7eb9004c618175262ff6849dd1a09614c42894b56aaacdfb0bbf905c0fda",
            .speakersMuted: "4f33ce43310cdff71c9f876a434fbd62b202fcbe2b6dbc1137d100a3b125de0a",
            .speakersUnmuted: "2cf7c9e310ec03dad8768d5031f3fc941ab423d4439e73bb147da07d6b15b689"]
        for (cue, expected) in original {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(cue.rawValue).wav"))
            check(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected, "The original \(cue.rawValue) chime is unchanged")
        }
        check(Set(original.keys).union(commandCues) == Set(Cue.allCases), "Every cue is either an original chime or a command sound")

        // Command sounds match the chimes' level and are clearly unlike every other cue.
        let reference = loudness(waves[.microphoneMuted]!.samples, rate: 44_100)
        let shapes = waves.mapValues { fingerprint($0.samples, rate: $0.rate) }
        for cue in commandCues {
            let level = loudness(waves[cue]!.samples, rate: 44_100)
            check(abs(level - reference) <= reference * 0.1, "\(cue.rawValue) is as loud as the chimes")
            for other in Cue.allCases where other != cue {
                let distance = zip(shapes[cue]!, shapes[other]!).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
                check(distance >= 0.4, "\(cue.rawValue) sounds different from \(other.rawValue)")
            }
        }

        // Loading uses the same files; a missing file is skipped rather than crashing.
        let sounds = FeedbackSounds(locate: { directory.appendingPathComponent("\($0.rawValue).wav") })
        check(sounds.loadedCues == Set(Cue.allCases), "Every cue loads with NSSound")
        check(FeedbackSounds(locate: { _ in nil }).loadedCues.isEmpty, "Missing resources load nothing")

        print("Passed \(checks) feedback sound checks")
    }
}
