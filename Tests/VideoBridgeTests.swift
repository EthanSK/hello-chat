// Browser video phrases and the Agent Flow Bridge client, with an injected transport and clock.
// Never posts a real distributed notification and never touches Codex Voice.
import Foundation

private final class FakeTransport: VideoBridgeTransport {
    var onReply: (@MainActor (VideoBridgeReply) -> Void)?
    var posts: [(requestId: String, action: String, issuedAt: Int)] = []
    var lastSeconds: Int?
    func post(requestId: String, action: String, issuedAt: Int, seconds: Int?, volumePercent: Int?) { lastSeconds = seconds; posts.append((requestId, action, issuedAt)) }
}

private final class FakeTimers {
    var entries: [(seconds: TimeInterval, action: @MainActor () -> Void, cancelled: Bool)] = []
    func schedule(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let index = entries.count
        entries.append((seconds, action, false))
        return { [weak self] in self?.entries[index].cancelled = true }
    }
    var live: Int { entries.filter { !$0.cancelled }.count }
    @MainActor func fireLast() {
        guard let index = entries.lastIndex(where: { !$0.cancelled }) else { return }
        entries[index].cancelled = true
        entries[index].action()
    }
}

@main enum VideoBridgeTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }

        // Matcher: directional, narrow, shared with highlighting.
        let pause = PhrasePattern(slot: .pauseVideoPhrase, text: "Pause video", similar: true, dictionaries: .init())
        let play = PhrasePattern(slot: .playVideoPhrase, text: "Play video", similar: true, dictionaries: .init())
        for text in ["pause video", "pause the video", "Pause this video.", "paws the video"] {
            check(pause.matches(in: PhraseMatcher.words(text)).count == 1, "Pause accepts \(text)")
            check(play.matches(in: PhraseMatcher.words(text)).isEmpty, "Play never matches \(text)")
        }
        for text in ["play video", "play the video", "play this video"] {
            check(play.matches(in: PhraseMatcher.words(text)).count == 1, "Play accepts \(text)")
            check(pause.matches(in: PhraseMatcher.words(text)).isEmpty, "Pause never matches \(text)")
        }
        for text in ["pause", "play", "video", "played the video", "plays video", "pause the videos", "pause my video", "un pause the video"] {
            check(pause.matches(in: PhraseMatcher.words(text)).isEmpty && play.matches(in: PhraseMatcher.words(text)).isEmpty,
                  "Ordinary speech is not a video command: \(text)")
        }
        check(pause.kind(for: "pausethevideo") == .dictionary && pause.kind(for: "pausevideo") == .exact, "Highlight kinds agree with detection")
        let exact = PhrasePattern(slot: .pauseVideoPhrase, text: "Pause video", similar: false, dictionaries: .init())
        check(exact.matches(in: PhraseMatcher.words("paws the video")).isEmpty &&
              exact.matches(in: PhraseMatcher.words("pause the video")).count == 1,
              "Natural wording still works with alternate spellings off")
        let custom = PhrasePattern(slot: .pauseVideoPhrase, text: "Freeze clip", similar: true, dictionaries: .init())
        check(custom.matches(in: ["freeze", "clip"]).count == 1 && custom.matches(in: PhraseMatcher.words("pause the video")).isEmpty,
              "A custom video phrase matches exactly and drops the built-in spellings")
        let spellings = PhraseMatcher.knownSpellings(for: "Pause video", similar: true, ending: false)
        check(spellings.first == "Pause video", "Displayed spellings start with the saved phrase")
        check(spellings.contains("pause the video"), "Displayed spellings use normal word spacing")
        let crossesDirection = spellings.contains { $0.hasPrefix("play") }
        check(!crossesDirection, "Displayed spellings never cross direction")
        check(spellings.allSatisfy { PhraseMatcher.equivalent($0, to: "Pause video", similar: true) }, "Every displayed spelling is accepted")
        do { _ = try PhraseDictionary.parse("Play video", for: .pauseVideoPhrase); preconditionFailure("Opposite default accepted") }
        catch { checks += 1 }
        check(PhraseSlot.voiceSlots.count == 7 && PhraseSlot.videoSlots == [.pauseVideoPhrase, .playVideoPhrase, .rewindVideoPhrase, .rewindFivePhrase, .rewindTenPhrase, .youtubeVolumePhrase], "Video slots follow the Voice slots")

        for command in [VideoCommand.rewindFive, .rewindTen] {
            let phrase = command.slot.defaultText
            for (spoken, expected) in [(phrase, true), ("I should have a " + phrase, false), ("Don't " + phrase, false)] {
                var detector = VideoPhraseDetectors()
                detector.audio(level: 0.25, seconds: 0.12)
                detector.update(spoken, at: 1)
                let accepted = detector.poll(at: 1, aliases: [command: [PhrasePattern(text: phrase, similar: false)]],
                                             directCommands: [.rewindFive, .rewindTen])
                check((accepted.last?.command == command) == expected, "Rewind recognizes only a direct distance command")
            }
        }

        // Detection: mention, negation and occurrence rules, independent of bridge availability.
        let patterns: [VideoCommand: PhrasePattern] = [.pause: pause, .play: play]
        func detectors(_ text: String) -> VideoPhraseDetectors {
            var value = VideoPhraseDetectors()
            value.audio(level: 0.2, seconds: 0.1)
            value.update(text, at: 1)
            return value
        }
        var direct = detectors("Can you pause the video")
        check(direct.poll(at: 1, patterns: patterns).map(\.command) == [.pause], "Direct request is accepted")
        check(direct.poll(at: 2, patterns: patterns).isEmpty, "One occurrence is consumed once")
        direct.update("Can you pause the video please", at: 3)
        check(direct.poll(at: 3, patterns: patterns).isEmpty, "A revised hypothesis does not replay the command")
        direct.update("Can you pause the video please. Pause the video.", at: 4)
        check(direct.poll(at: 4, patterns: patterns).map(\.command) == [.pause], "A repeated request is a new occurrence")
        for text in ["Don't pause the video", "Do not play the video", "I said pause the video", "The pause video phrase works",
                     "Never play the video"] {
            var prose = detectors(text)
            check(prose.poll(at: 1, patterns: patterns).isEmpty, "Prose or negation is rejected: \(text)")
        }
        var futureTense = detectors("I’ll play the video later")
        check(futureTense.poll(at: 1, patterns: patterns, directOnly: true).isEmpty, "A plan to play later is not a direct playback request")
        var both = detectors("Pause the video. Play the video.")
        let accepted = both.poll(at: 1, patterns: patterns)
        check(accepted.map(\.command) == [.pause, .play] && VideoCommand.isSuperseded(.pause, at: 0, lastPlayback: 1) && !VideoCommand.isSuperseded(.play, at: 1, lastPlayback: 1),
              "Commands keep spoken order; the last direction decides")
        let allVideo = Dictionary(uniqueKeysWithValues: VideoCommand.allCases.map {
            ($0, [PhrasePattern(slot: $0.slot, text: $0.slot.defaultText, similar: true, dictionaries: .init())])
        })
        var defaultRewind = detectors("Rewind video")
        check(defaultRewind.poll(at: 1, aliases: allVideo, directCommands: [.rewind]).map(\.command) == [.rewind], "Generic rewind matches")
        defaultRewind.update("Rewind video five seconds", at: 2)
        check(defaultRewind.poll(at: 2, aliases: allVideo, directCommands: [.rewind, .rewindFive]).isEmpty, "Revision never seeks twice")
        var explicitFive = detectors("Rewind video five seconds")
        check(explicitFive.poll(at: 1, aliases: allVideo, directCommands: [.rewind, .rewindFive]).map(\.command) == [.rewindFive], "Explicit duration wins")
        var wrongDuration = detectors("Rewind video by fifteen seconds")
        check(wrongDuration.poll(at: 1, aliases: allVideo, directCommands: [.rewind, .rewindFive, .rewindTen]).isEmpty, "Unsupported distance does not use the default")
        check(VideoCommand.rewind.resolved(rewindSeconds: 5) == .rewindFive && VideoCommand.rewind.resolved(rewindSeconds: 10) == .rewindTen &&
              VideoCommand.rewind.resolved(rewindSeconds: 17) == .rewind && VideoCommand.rewindFive.resolved(rewindSeconds: 10) == .rewindFive, "The preference applies to the generic phrase and preserves explicit distances")
        func checkBatch(_ detector: inout VideoPhraseDetectors) -> [VideoCommand] {
            let matches = detector.poll(at: 2, aliases: allVideo, directCommands: [.rewindFive, .rewindTen])
            let lastPlayback = matches.lastIndex { $0.command.setsPlaybackState }
            return matches.enumerated().compactMap { index, match in
                VideoCommand.isSuperseded(match.command, at: index, lastPlayback: lastPlayback) ? nil : match.command
            }
        }
        var independent = detectors("Pause video. Rewind video ten seconds. Rewind video ten seconds.")
        check(checkBatch(&independent) == [.pause, .rewindTen, .rewindTen], "Keep independent commands and genuine repeated seeks in one revision")
        var revised = detectors("")
        func updateRewind(_ text: String, startsAt: Double) {
            let timing = PhraseMatcher.words(text).enumerated().map { index, word in
                let start = startsAt + Double(index) * 0.2
                return (word: word, start: start, end: start + 0.15)
            }
            revised.update(text, at: 1, timings: timing)
        }
        updateRewind("Rewind video five seconds", startsAt: 1)
        check(checkBatch(&revised) == [.rewindFive], "First seek requested")
        updateRewind("Rewind video ten seconds", startsAt: 1)
        check(checkBatch(&revised).isEmpty, "Same audio revised to another distance cannot seek twice")
        updateRewind("Rewind video five seconds. Rewind video ten seconds.", startsAt: 4)
        check(checkBatch(&revised).contains(.rewindTen), "A separate spoken seek survives")
        let end = PhrasePattern(slot: .sleepPhrase, text: "Bye Chat", similar: true, dictionaries: .init())
        var ended = detectors("Pause the video. Bye chat.")
        ended.cancelPending(patterns: patterns, endPattern: end)
        check(ended.poll(at: 1, patterns: patterns).isEmpty, "End wins over a video command in the same transcript")
        let empty: [VideoCommand: PhrasePattern] = [.pause: PhrasePattern(slot: .pauseVideoPhrase, text: "", similar: true, dictionaries: .init()), .play: play]
        var blank = detectors("pause video")
        check(blank.poll(at: 1, patterns: empty).isEmpty, "An empty phrase never matches")

        // Video commands consume earlier wakes, exactly as audio commands do; later wakes still work.
        let wakePattern = PhrasePattern(slot: .wakePhrase, text: "Hello Chat", similar: true, dictionaries: .init())
        var earlierWake = StandaloneWake()
        earlierWake.audio(level: 0.2, seconds: 0.1); earlierWake.update("Hello chat pause the video", at: 1)
        earlierWake.cancelPending(patterns: [wakePattern], endPattern: pause)
        check(!earlierWake.poll(at: 1, phrase: wakePattern.text, similar: true, patterns: [wakePattern]), "A wake before the video command cannot open Voice")
        var laterWake = StandaloneWake()
        laterWake.audio(level: 0.2, seconds: 0.1); laterWake.update("Pause the video. Hello chat", at: 1)
        laterWake.cancelPending(patterns: [wakePattern], endPattern: pause)
        check(laterWake.poll(at: 1, phrase: wakePattern.text, similar: true, patterns: [wakePattern]), "A wake after the video command still works")

        var mixedNarration = detectors("Play video as I was kind of pause video trying to see if there was actually any good")
        let mixedAccepted = mixedNarration.poll(at: 1, aliases: allVideo, directOnly: true, embeddedCommands: [.pause, .play])
        check(mixedAccepted.map(\.command) == [.play, .pause], "The reported narration-interrupted pause reaches dispatch")
        for prose in ["I want to pause video", "I said pause video", "it just pause video", "This will play video", "The pause video command", "Don't pause video", "I’ll play video later", "I clicked pause video"] {
            var spoken = detectors(prose)
            check(spoken.poll(at: 1, aliases: allVideo, directOnly: true, embeddedCommands: [.pause, .play]).isEmpty,
                  "Embedded playback keeps references and plans blocked: \(prose)")
        }
        var timedNarration = detectors("Some narration. Pause video trying to see")
        check(timedNarration.poll(at: 1, aliases: allVideo, directOnly: true, embeddedCommands: [.pause, .play]).map(\.command) == [.pause],
              "Playback interruption has no post-keyword quiet requirement")

        // Client: real availability only from a compatible reply; no replay; bounded timers.
        let transport = FakeTransport(), timers = FakeTimers()
        var nextID = 0, clock = 1_800_000_000_000
        let bridge = VideoBridge(transport: transport, now: { clock }, schedule: { timers.schedule($0, $1) },
            makeID: { nextID += 1; return String(format: "00000000-0000-4000-8000-%012d", nextID) })
        func reply(_ index: Int, _ state: String, changed: Bool? = nil, reason: String? = nil, version: Int? = 1, action: String? = nil) {
            let post = transport.posts[index]
            transport.onReply?(VideoBridgeReply(requestId: post.requestId, action: action ?? post.action, state: state,
                changed: changed, reason: reason, protocolVersion: version))
        }
        check(bridge.availability == .checking && !bridge.availability.isAvailable, "Unknown is not available")
        bridge.refresh(); bridge.refresh()
        check(transport.posts.count == 1 && transport.posts[0].action == "status" && transport.posts[0].issuedAt == clock,
              "One status request at a time, stamped with its issue time")
        check(UUID(uuidString: transport.posts[0].requestId) != nil, "Request ids are UUIDs")
        reply(0, "available")
        check(bridge.availability == .available && bridge.pendingCount == 0 && timers.live == 0, "Compatible status is available and its timer is cancelled")
        reply(0, "unavailable")
        check(bridge.availability == .available, "A repeated reply is ignored")

        bridge.refresh(); reply(1, "available", version: 2)
        check(bridge.availability == .unavailable(.incompatible), "Another protocol version is incompatible")
        bridge.refresh(); reply(2, "available", version: nil)
        check(bridge.availability == .unavailable(.incompatible), "An old bridge without a version is incompatible")
        bridge.refresh(); reply(3, "unavailable", version: nil)
        check(bridge.availability == .unavailable(.notConnected), "A disconnected Chrome extension is unavailable")
        bridge.refresh(); timers.fireLast()
        check(bridge.availability == .unavailable(.noReply) && bridge.pendingCount == 0, "No reply means unavailable, never stale ready")
        reply(4, "available")
        check(bridge.availability == .unavailable(.noReply), "A reply after its timeout is ignored")

        var outcomes: [VideoCommandOutcome] = []
        bridge.send(.pause) { outcomes.append($0) }
        check(transport.posts.last?.action == "pause", "Pause is sent once with its own direction")
        reply(transport.posts.count - 1, "done", changed: true, reason: "paused", action: "play")
        check(outcomes.isEmpty, "A reply for the other direction is ignored")
        reply(transport.posts.count - 1, "done", changed: true, reason: "paused")
        reply(transport.posts.count - 1, "done", changed: true, reason: "paused")
        check(outcomes == [.changed] && bridge.availability == .available, "A command reply proves availability; duplicates are dropped")
        bridge.send(.pause) { outcomes.append($0) }
        reply(transport.posts.count - 1, "done", changed: false, reason: "already-paused")
        check(outcomes.last == .unchanged("already-paused"), "Repeating pause keeps the video paused")
        check(VideoCommandOutcome.unchanged("already-paused").summary(for: .pause) == "Browser video is already paused", "Outcome wording")
        bridge.send(.play) { outcomes.append($0) }
        reply(transport.posts.count - 1, "rejected", reason: "stale-request")
        check(outcomes.last == .rejected && bridge.availability == .available, "A stale command is rejected without changing availability")

        // An older status answer cannot overwrite a newer command's availability.
        bridge.refresh(); let olderStatus = transport.posts.count - 1
        bridge.send(.play) { outcomes.append($0) }
        reply(transport.posts.count - 1, "done", changed: true, reason: "played")
        reply(olderStatus, "unavailable", version: nil)
        check(bridge.availability == .available && outcomes.last == .changed, "Late older status cannot overwrite newer availability")

        // A command timeout is unconfirmed, never retried, and only checks status.
        let before = transport.posts.count
        bridge.send(.pause) { outcomes.append($0) }
        timers.fireLast()
        check(outcomes.last == .unconfirmed, "Timeout reports unconfirmed")
        check(transport.posts.count == before + 2, "Timeout sends exactly one follow-up request")
        check(transport.posts.last?.action == "status", "The follow-up is a status check")
        let pausesAfterTimeout = transport.posts.dropFirst(before + 1).filter { $0.action == "pause" }.count
        check(pausesAfterTimeout == 0, "A timed-out pause is never resent")
        reply(before, "done", changed: true, reason: "paused")
        check(outcomes.last == .unconfirmed && outcomes.filter({ $0 == .unconfirmed }).count == 1, "A late command reply is ignored")
        bridge.send(.play) { outcomes.append($0) }
        reply(transport.posts.count - 1, "unavailable", version: nil)
        check(outcomes.last == .unavailable && bridge.availability == .unavailable(.notConnected), "Disconnected bridge reports unavailable at once")
        bridge.refresh(); bridge.send(.pause) { outcomes.append($0) }
        let count = outcomes.count
        bridge.stop()
        check(bridge.pendingCount == 0 && timers.live == 0 && outcomes.count == count, "Stop clears every pending request and timer")
        clock += 1
        let current = FakeTransport()
        let deadlines = FakeTimers()
        var gateResults: [VideoCommandOutcome] = []
        let checked = VideoBridge(transport: current, schedule: deadlines.schedule)
        checked.sendIfAvailable(.play) { gateResults.append($0) }
        check(current.posts.map(\.action) == ["status"], "Playback waits for the extension handshake")
        deadlines.fireLast()
        check(current.posts.map(\.action) == ["status"] && gateResults == [.unavailable], "Disconnected extension does not receive playback")
        checked.sendIfAvailable(.pause) { gateResults.append($0) }
        let request = current.posts.last!
        checked.receive(.init(requestId: request.requestId, action: request.action, state: "available", protocolVersion: 1))
        check(current.posts.map(\.action) == ["status", "status", "pause"], "A live compatible extension receives the action once")
        let paused = current.posts.last!
        checked.receive(.init(requestId: paused.requestId, action: paused.action, state: "done", changed: true, protocolVersion: 1))
        check(gateResults == [.unavailable, .changed], "The action's own reply confirms it")
        checked.sendIfAvailable(.rewindTen) { gateResults.append($0) }
        let rewindCheck = current.posts.last!
        check(rewindCheck.action == "rewindStatus", "Rewind requires its specific capability probe")
        checked.receive(.init(requestId: rewindCheck.requestId, action: rewindCheck.action, state: "rejected", protocolVersion: 1))
        check(current.posts.last?.action == "rewindStatus" && gateResults.last == .unavailable, "An older extension cannot receive seek commands")
        checked.sendIfAvailable(.rewind, seconds: 17) { gateResults.append($0) }
        let customCheck = current.posts.last!
        check(customCheck.action == "seekStatus", "Custom distance requires a live custom-seek receiver")
        checked.receive(.init(requestId: customCheck.requestId, action: "seekStatus", state: "done", changed: false, reason: "custom-seek-supported", protocolVersion: 1))
        let customRequest = current.posts.last!
        check(customRequest.action == "rewind" && current.lastSeconds == 17, "Custom seconds are carried once to the player")
        checked.receive(.init(requestId: customRequest.requestId, action: "rewind", state: "done", changed: true, reason: "rewound", protocolVersion: 1, movedSeconds: 3))
        check(gateResults.last == .rewound(3), "A clamped seek reports the actual distance")
        let countBeforeInvalid = current.posts.count
        checked.sendIfAvailable(.rewind, seconds: 0) { gateResults.append($0) }
        check(gateResults.last == .rejected && current.posts.count == countBeforeInvalid, "Invalid seconds send no request")
        for command in [VideoCommand.pause, .rewindTen, .rewind] {
            let start = current.posts.count
            checked.sendIfAvailable(command, seconds: 17, shouldSend: { false }) { gateResults.append($0) }
            let probe = current.posts.last!
            let reason = command == .rewind ? "custom-seek-supported" : (command == .rewindTen ? "rewind-supported" : nil)
            checked.receive(.init(requestId: probe.requestId, action: probe.action,
                state: command == .pause ? "available" : "done", changed: false, reason: reason, protocolVersion: 1))
            check(current.posts.count == start + 1 && gateResults.last == .rejected,
                  "A cancelled repeat cannot dispatch after its availability probe")
        }
        let rewindRepeat = PhrasePattern(slot: .rewindVideoPhrase, text: "Rewind video", similar: false, dictionaries: .init())
        check(rewindRepeat.matches(in: PhraseMatcher.words("Rewind video three times")).count == 1,
              "Generic rewind accepts an explicit repetition argument")
        check(rewindRepeat.matches(in: PhraseMatcher.words("Rewind video three seconds")).isEmpty,
              "A distance argument cannot become generic rewind repeats")
        print("Passed \(checks) video bridge checks")
    }
}
