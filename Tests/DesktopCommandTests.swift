// App, zoom and music commands: parsing, resolution and native key contracts without dispatch.
// Everything is injected: no app is switched or opened and no real key event is posted.
import AppKit
import CoreGraphics

private struct KeyEvent: Equatable { let key: CGKeyCode; let flags: CGEventFlags; let down: Bool }
private final class KeyRecorder { var events: [KeyEvent] = []; var trustChecks = 0 }
private final class Probe {
    var session = DesktopSessionState.interactive
    var front: String?
    var bringsForward = true
    var verifies = true
    var activated: [String] = [], opened: [String] = []
    var scans = 0, sleeps = 0
}

@main enum DesktopCommandTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let numericApps = [AppCandidate(id: "live", names: ["Live 12"], url: nil, pid: 1),
                           AppCandidate(id: "chrome", names: ["Google Chrome", "Chrome"], url: nil, pid: 2)]
        let numericName = AppCommandCandidate(kind: .openApp, name: "Live 12", bare: false, wordRange: 0..<4, alternateName: nil)
        check(numericName.separatingCount(among: numericApps, spellings: .init()).name == "Live 12", "Exact numeric app name wins over count")
        let countedApp = AppCommandCandidate(kind: .switchApp, name: "Chrome twenty five times", bare: false, wordRange: 0..<6, alternateName: nil)
        let separated = countedApp.separatingCount(among: numericApps, spellings: .init())
        check(separated.name == "chrome" && separated.wordRange == 0..<3, "Resolved app excludes the count from its name and accepted range")
        let unknownApp = AppCommandCandidate(kind: .openApp, name: "Unrelated five", bare: true, alternateName: nil)
        check(unknownApp.separatingCount(among: numericApps, spellings: .init()).name == "Unrelated five", "Count stripping cannot invent an app match")
        var zoomPosts = 0
        var repeatedZoom = ZoomShortcut()
        repeatedZoom.session = { .interactive }; repeatedZoom.accessibilityTrusted = { true }
        repeatedZoom.currentFlags = { [] }; repeatedZoom.post = { key, flags, _ in
            check(key == ZoomShortcut.equalsKeyCode && flags == [.maskCommand, .maskShift], "Each repetition uses the unchanged native zoom shortcut")
            zoomPosts += 1; return true
        }
        let repeated = RepeatedCommands()
        repeated.update(["zoom", "in", "five"], timings: nil)
        repeated.begin(id: UUID(), range: 0..<2, repeats: true) { step in
            if case .success = repeatedZoom.perform(.zoomIn) { repeated.finish(step, .submitted) }
            else { repeated.finish(step, .failedBeforeDispatch) }
        }
        check(zoomPosts == 5, "Zoom in five submits exactly five injected native actions")
        var mediaPosts = 0, mediaCues = 0
        var mediaEnvironment = DesktopCommands.Environment()
        mediaEnvironment.mediaPlayPause.session = { .interactive }
        mediaEnvironment.mediaPlayPause.accessibilityTrusted = { true }
        mediaEnvironment.mediaPlayPause.post = { events in
            mediaPosts += 1
            let native = events.compactMap { NSEvent(cgEvent: $0) }
            check(native.count == 2 && native.allSatisfy { $0.type == .systemDefined && $0.subtype.rawValue == 8 && $0.data2 == -1 },
                  "Music uses one native system media-key pair, never a normal app shortcut")
            check(native.map(\.data1) == [(16 << 16) | (0x0A << 8), (16 << 16) | (0x0B << 8)],
                  "Music sends Play/Pause down then up, with no app-specific media command")
        }
        let media = DesktopCommands(environment: mediaEnvironment)
        check(media.toggleCurrentMedia { mediaCues += 1 }.diagnostic == "sent" && mediaPosts == 1 && mediaCues == 1,
              "One accepted music command submits exactly one pair and one dispatch cue")
        mediaEnvironment.mediaPlayPause.session = { .locked }
        check(DesktopCommands(environment: mediaEnvironment).toggleCurrentMedia { mediaCues += 1 }.diagnostic != "sent"
              && mediaPosts == 1 && mediaCues == 1, "Locked desktop sends no media event or success cue")
        mediaEnvironment.mediaPlayPause.session = { .interactive }
        mediaEnvironment.mediaPlayPause.accessibilityTrusted = { false }
        check(DesktopCommands(environment: mediaEnvironment).toggleCurrentMedia { mediaCues += 1 }.diagnostic == "accessibility"
              && mediaPosts == 1 && mediaCues == 1, "Missing Accessibility sends nothing and reports recovery")
        mediaEnvironment.mediaPlayPause.accessibilityTrusted = { true }
        mediaEnvironment.mediaPlayPause.makeEvents = { nil }
        check(DesktopCommands(environment: mediaEnvironment).toggleCurrentMedia { mediaCues += 1 }.diagnostic == "event-failed"
              && mediaPosts == 1 && mediaCues == 1, "Event creation failure does not partially send or retry")
        var nativeRequests = 0, axRequests = 0, workspaceRequests = 0, identityReads = 0
        check(await RunningAppActivation.request(identityMatches: { true }, native: { nativeRequests += 1; return true },
            accessibility: { axRequests += 1; return true }, workspace: { workspaceRequests += 1; return true })
              && nativeRequests == 1 && axRequests == 0 && workspaceRequests == 0,
              "An accepted native activation never adds a second request")
        check(await RunningAppActivation.request(identityMatches: { true }, native: { false },
            accessibility: { axRequests += 1; return true }, workspace: { workspaceRequests += 1; return true })
              && axRequests == 1 && workspaceRequests == 0,
              "A refused native activation permits one Accessibility request")
        check(await RunningAppActivation.request(identityMatches: { true }, native: { false },
            accessibility: { axRequests += 1; return false }, workspace: { workspaceRequests += 1; return true })
              && axRequests == 2 && workspaceRequests == 1,
              "After both refusals, Launch Services gets one request")
        check(!(await RunningAppActivation.request(identityMatches: { true }, native: { false },
            accessibility: { false }, workspace: { workspaceRequests += 1; return false })) && workspaceRequests == 2,
              "Three refusals report failure; nothing is retried")
        check(!(await RunningAppActivation.request(identityMatches: { identityReads += 1; return identityReads == 1 }, native: { false },
            accessibility: { axRequests += 1; return true }, workspace: { workspaceRequests += 1; return true }))
              && axRequests == 2 && workspaceRequests == 2,
              "An exited or replaced process between attempts cannot receive the fallback")
        check(!(await RunningAppActivation.request(identityMatches: { false }, native: { nativeRequests += 1; return true },
            accessibility: { axRequests += 1; return true })) && nativeRequests == 1 && axRequests == 2,
              "A stale target receives no activation request")
        var frontmost = false, strictNative = 0, strictAX = 0, strictWorkspace = 0
        check(await RunningAppActivation.request(identityMatches: { true }, native: {
            strictNative += 1; return true
        }, accessibility: {
            strictAX += 1; frontmost = true; return true
        }, workspace: { strictWorkspace += 1; return true }, isFrontmost: { frontmost })
            && strictNative == 1 && strictAX == 1 && strictWorkspace == 0,
            "Accepted navigation in a background app still uses the native AX foreground route")
        check(!(await RunningAppActivation.request(identityMatches: { true }, native: { true },
            accessibility: { true }, workspace: { true }, isFrontmost: { false })),
            "Three accepted dispatches without actual foreground state cannot claim success")
        var generation = 1
        check(!(await RunningAppActivation.request(identityMatches: { generation == 1 }, native: {
            generation = 2; return true
        }, accessibility: { strictAX += 1; return true }, isFrontmost: { true })) && strictAX == 1,
            "An accepted native request cannot bless a changed process or dispatch its AX fallback")
        let cancelledStrictActivation = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await RunningAppActivation.request(identityMatches: { true }, native: {
                strictNative += 1; return true
            }, accessibility: { strictAX += 1; return true }, isFrontmost: { true })
        }
        check(!(await cancelledStrictActivation.value) && strictNative == 1 && strictAX == 1,
              "Cancelled navigation sends no native foreground request")
        func failureText(_ decision: AppCommandDecision) -> String? { if case .failure(let text) = decision { return text }; return nil }

        // Cancellation between activation routes must not post the next request.
        let cancelledActivation = Task { @MainActor in
            var fallback = 0
            let result = await RunningAppActivation.request(identityMatches: { true }, native: {
                withUnsafeCurrentTask { $0?.cancel() }; return false
            }, accessibility: { fallback += 1; return true })
            return (result, fallback)
        }
        let cancelledResult = await cancelledActivation.value
        check(!cancelledResult.0 && cancelledResult.1 == 0, "Cancellation after native refusal prevents Accessibility")
        let cancelledWorkspace = Task { @MainActor in
            var fallback = 0
            let result = await RunningAppActivation.request(identityMatches: { true }, native: { false }, accessibility: {
                withUnsafeCurrentTask { $0?.cancel() }; return false
            }, workspace: { fallback += 1; return true })
            return (result, fallback)
        }
        let cancelledWorkspaceResult = await cancelledWorkspace.value
        check(!cancelledWorkspaceResult.0 && cancelledWorkspaceResult.1 == 0, "Cancellation after AX refusal prevents Launch Services")

        // Slots: four new canonical preferences after the unchanged Voice and Browser fields.
        check(PhraseSlot.voiceSlots.count == 7 && PhraseSlot.videoSlots == [.pauseVideoPhrase, .playVideoPhrase, .rewindVideoPhrase, .rewindFivePhrase, .rewindTenPhrase], "Existing fields are intact")
        check(PhraseSlot.desktopSlots == [.switchAppPhrase, .openAppPhrase, .zoomInPhrase, .zoomOutPhrase, .showVoicePhrase, .setSpeedPhrase], "Desktop fields follow them")
        check(PhraseSlot.desktopSlots.map(\.rawValue) == ["switchAppPhrase", "openAppPhrase", "zoomInPhrase", "zoomOutPhrase", "showVoicePhrase", "setSpeedPhrase"], "Canonical preference names")
        check(PhraseSlot.desktopSlots.map(\.defaultText) == ["Switch app", "Open app", "Zoom in", "Zoom out", "Show voice", "Set speed"], "Defaults")
        check(PhraseSlot.switchAppPhrase.example != nil && PhraseSlot.openAppPhrase.example == nil && PhraseSlot.zoomInPhrase.example == nil,
              "The combined app setting carries one example")
        check(PhraseSlot.switchAppPhrase.label.hasSuffix("prefix") && PhraseSlot.openAppPhrase.label.hasSuffix("prefix"), "App commands are labelled as prefixes")

        // App command detection.
        let switchPrefix = PhrasePattern(slot: .switchAppPhrase, text: "Switch app", similar: true, dictionaries: .init())
        let openPrefix = PhrasePattern(slot: .openAppPhrase, text: "Open app", similar: true, dictionaries: .init())
        let combined = ["Switch app", "Open app", "Switch up", "Switch to", "Switch"].map {
            PhrasePattern(slot: .switchAppPhrase, text: $0, similar: true, dictionaries: .init())
        }
        for phrase in ["Switch app Chrome", "Switch Chrome", "Switch Google Chrome", "Switch app Google Chrome"] {
            var d = AppCommandDetector(usesEditableShortForms: true)
            d.audio(level: 0.2, seconds: 0.1, at: 1)
            d.update(phrase, at: 1)
            let result = d.poll(switchPrefixes: combined, openPrefixes: [], immediateSwitchNames: ["Google Chrome", "Chrome"])
            check(result.count == 1, "Exact requested Chrome form needs no silence: " + phrase)
            let actualChrome = AppCandidate(id: "com.google.Chrome", names: ["Google Chrome"], pid: 11)
            check(AppCommandPlanner.decide(result[0], running: [actualChrome], installed: [], spellings: .init()) == .activate(actualChrome), "Each form resolves the installed browser")
            check(d.poll(switchPrefixes: combined, openPrefixes: [], immediateSwitchNames: ["Google Chrome", "Chrome"]).isEmpty, "Same hypothesis cannot switch twice")
        }
        for text in ["Don't switch Chrome", "I said switch app Chrome", "The phrase switch Google Chrome", "Switch app Chrome tomorrow", "Switch Chrome settings", "Can you add switch Chrome"] {
            var d = AppCommandDetector()
            d.audio(level: 0.2, seconds: 0.1, at: 1); d.update(text, at: 1)
            check(d.poll(switchPrefixes: combined, openPrefixes: [], immediateSwitchNames: ["Google Chrome", "Chrome"]).isEmpty, "Immediate Chrome keeps mention/negation/qualification guards: " + text)
        }
        var narration = AppCommandDetector()
        narration.audio(level: 0.2, seconds: 0.1, at: 1)
        narration.update("the documentary continues switch Google Chrome being very critical for safety", at: 1)
        check(narration.poll(switchPrefixes: combined, openPrefixes: [], immediateSwitchNames: ["Google Chrome", "Chrome"]).map(\.name) == ["google chrome"], "Exact Chrome request interrupts continuous narration without taking its following words as an app name")
        let speakerPrefixes = ["Switch speakers", "Switch speaker", "Switch audio"].map { PhrasePattern(text: $0, similar: false) }
        var incompleteSpeaker = AppCommandDetector()
        incompleteSpeaker.audio(level: 0.2, seconds: 0.1)
        incompleteSpeaker.update("Switch speakers kitchen", at: 1, timings: [("switch",0,0.2),("speakers",0.2,0.4),("kitchen",1.3,1.5)])
        incompleteSpeaker.audio(level: 0, seconds: 1)
        check(incompleteSpeaker.poll(switchPrefixes: combined, openPrefixes: [], reservedSwitchPrefixes: speakerPrefixes).isEmpty,
              "A hesitation after a speaker prefix cannot open an app named Speakers")
        var explicitApp = AppCommandDetector()
        explicitApp.audio(level: 0.2, seconds: 0.1); explicitApp.update("Switch app Speakers", at: 1)
        explicitApp.audio(level: 0, seconds: 1)
        check(explicitApp.poll(switchPrefixes: combined, openPrefixes: [], reservedSwitchPrefixes: speakerPrefixes).first?.name == "speakers",
              "Explicit Switch app keeps its existing meaning")
        var appTimingFlip = AppCommandDetector()
        appTimingFlip.audio(level: 0.2, seconds: 0.1)
        appTimingFlip.update("Switch app Chrome", at: 3, timings: [("switch",3,3),("app",3,3),("chrome",3,3)])
        appTimingFlip.audio(level: 0, seconds: 1)
        check(appTimingFlip.poll(switchPrefixes: combined, openPrefixes: []).count == 1, "Arrival-timed app request runs once")
        appTimingFlip.update("Switch app Chrome please", at: 4, timings: [("switch",0,0.2),("app",0.2,0.4),("chrome",0.4,0.6),("please",0.6,0.8)])
        check(appTimingFlip.poll(switchPrefixes: combined, openPrefixes: []).isEmpty, "Audio timing replacement cannot reopen the app")
        var speakerThenApp = AppCommandDetector()
        speakerThenApp.audio(level: 0.2, seconds: 0.1)
        speakerThenApp.update("Switch audio to kitchen. Switch app Chrome", at: 1)
        speakerThenApp.consume(overlapping: 0..<4, switchPrefixes: combined, openPrefixes: [])
        speakerThenApp.audio(level: 0, seconds: 1)
        let laterApp = speakerThenApp.poll(switchPrefixes: combined, openPrefixes: [])
        check(laterApp.count == 1 && laterApp[0].name == "chrome", "Speaker command cannot launch an app or swallow a later app command")
        var appThenSpeaker = AppCommandDetector()
        appThenSpeaker.audio(level: 0.2, seconds: 0.1)
        appThenSpeaker.update("Open Safari. Switch audio to kitchen", at: 1)
        appThenSpeaker.consume(overlapping: 2..<6, switchPrefixes: combined, openPrefixes: [])
        appThenSpeaker.audio(level: 0, seconds: 1)
        let earlierApp = appThenSpeaker.poll(switchPrefixes: combined, openPrefixes: [])
        check(earlierApp.count == 1 && earlierApp[0].name == "safari", "Speaker command preserves an earlier pending app command")
        for text in ["Switch Chrome", "Switch to Chrome", "Switch up Chrome", "Switch app Chrome", "Open app Chrome", "Open Chrome"] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 1)
            let heard = detector.poll(switchPrefixes: combined, openPrefixes: [])
            check(heard.count == 1 && heard[0].name == "chrome", "Any unified app row resolves one app name: \(text)")
            check(detector.poll(switchPrefixes: combined, openPrefixes: []).isEmpty, "Overlapping prefixes never dispatch twice")
        }
        for text in ["Don't switch Chrome", "I said switch to Chrome", "The switch app command is broken", "Open Chrome settings"] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 1)
            let heard = detector.poll(switchPrefixes: combined, openPrefixes: [])
            check(heard.isEmpty || heard.allSatisfy { AppCommandPlanner.decide($0, running: [], installed: []) == .ignore }, "App grouping preserves discussion/negation and strict bare Open")
        }
        for (text, kind) in [("Switch app", AppCommandKind.switchApp), ("Open app", AppCommandKind.openApp)] {
            var detector = AppCommandDetector()
            let tokens = PhraseMatcher.words(text)
            let timing: [(word: String, start: Double, end: Double)] = [(tokens[0], 0, 0.2), (tokens[1], 0.2, 0.35)]
            detector.audio(level: 0.2, seconds: 0.1, at: 1.4)
            detector.update(text, at: 1.4, timings: timing)
            check(detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Prefix-only hypothesis sends nothing")
            detector.update(text + " Chrome", at: 1.6, timings: timing + [("chrome", 0.45, 0.8)])
            detector.audio(level: 0.2, seconds: 0.1, at: 1.8)
            let completed = detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix)
            check(completed.count == 1 && completed[0].kind == kind && completed[0].name == "chrome", "A delayed name completes the original occurrence")
            check(detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "A completed delayed name cannot replay")
            var cancelled = AppCommandDetector()
            cancelled.audio(level: 0.2, seconds: 0.1, at: 1.4)
            cancelled.update(text, at: 1.4, timings: timing)
            _ = cancelled.poll(switchPrefix: switchPrefix, openPrefix: openPrefix)
            cancelled.consumeAll(switchPrefix: switchPrefix, openPrefix: openPrefix)
            cancelled.update(text + " Chrome", at: 1.6, timings: timing + [("chrome", 0.45, 0.8)])
            cancelled.audio(level: 0.2, seconds: 0.1, at: 1.8)
            check(cancelled.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "End cancellation also consumes a prefix awaiting its name")
        }
        func heard(_ text: String, quiet: Double = 1) -> [AppCommandCandidate] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            if quiet > 0 { detector.audio(level: 0, seconds: quiet) }
            return detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix)
        }
        func command(_ kind: AppCommandKind, _ name: String, bare: Bool = false, alternate: String? = nil) -> AppCommandCandidate {
            AppCommandCandidate(kind: kind, name: name, bare: bare, alternateName: alternate)
        }
        check(heard("Switch app Chrome") == [command(.switchApp, "chrome")], "Switch app Chrome")
        check(heard("Switch app Chat GPT") == [command(.switchApp, "chat gpt")], "Switch app Chat GPT")
        check(heard("Switch app BS Code") == [command(.switchApp, "bs code")], "Switch app BS Code")
        check(heard("Switch app to Chrome.") == [command(.switchApp, "chrome")], "Switch app to Chrome")
        check(heard("Can you switch app Chrome please") == [command(.switchApp, "chrome")], "Polite switch")
        check(heard("Open Safari") == [command(.openApp, "safari", bare: true)], "Open Safari")
        check(heard("Please open Safari please") == [command(.openApp, "safari", bare: true)], "Polite bare open")
        check(heard("Open app Safari") == [command(.openApp, "safari", alternate: "app safari")], "Open app Safari")
        check(heard("Can you open app Safari") == [command(.openApp, "safari", alternate: "app safari")], "Polite full open")
        check(heard("Open the App Store") == [command(.openApp, "app store", bare: true)], "Open the App Store")
        check(heard("Open app store") == [command(.openApp, "store", alternate: "app store")], "Open app store keeps the App Store reading")
        check(heard("Open Visual Studio Code") == [command(.openApp, "visual studio code", bare: true)], "Multi-word names")
        check(heard("Switch app Chrome. Open Safari.") == [command(.switchApp, "chrome"), command(.openApp, "safari", bare: true)],
              "Two commands keep spoken order")
        for text in ["Don't open Safari", "Don’t open Safari", "Do not switch app Chrome", "Never open app Safari", "I said switch app Chrome",
                     "Hello chat open Safari", "We should open Safari", "Can you open Safari", "The switch app prefix works",
                     "Switch app prefix works", "Open app command is broken", "Open the door and switch app Chrome", "Switch app",
                     "Open app Microsoft Visual Studio Code Insiders", "Reopen Safari", "Opened Safari"] {
            check(heard(text).isEmpty, "Negation, mention, discussion or mixed speech is ignored: \(text)")
        }

        // The app name settles on an audio pause, even when a model added punctuation early.
        var partial = AppCommandDetector()
        partial.audio(level: 0.2, seconds: 0.1)
        partial.update("Open Chrome", at: 1)
        check(partial.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "A partial Open Chrome waits")
        partial.audio(level: 0.2, seconds: 0.1)
        partial.update("Open Chrome settings", at: 2)
        check(partial.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Still speaking")
        partial.audio(level: 0, seconds: 0.5)
        check(partial.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Half a second is not the end")
        partial.audio(level: 0, seconds: 0.4)
        let settled = partial.poll(switchPrefix: switchPrefix, openPrefix: openPrefix)
        check(settled == [command(.openApp, "chrome settings", bare: true)], "The whole utterance is the name")
        check(partial.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Finalized once")
        check(heard("Switch app Chrome. Thanks", quiet: 0).isEmpty, "Punctuation alone does not finalize")
        check(heard("Switch app Chrome", quiet: 0).isEmpty, "An open sentence waits for silence")

        var timed = AppCommandDetector()
        let timings: [(word: String, start: Double, end: Double)] = [("open", 0.0, 0.3), ("safari", 0.4, 0.8)]
        timed.audio(level: 0.2, seconds: 0.1, at: 0.5)
        timed.update("Open Safari", at: 1, timings: timings)
        timed.audio(level: 0, seconds: 0.4, at: 1.2)
        check(timed.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Aligned audio: 0.4 s after the last word waits")
        timed.audio(level: 0, seconds: 0.5, at: 1.7)
        check(timed.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).map(\.name) == ["safari"], "Aligned audio: 0.9 s finalizes")
        timed.update("Open Safari.", at: 2, timings: timings)
        check(timed.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "A revised hypothesis of the same audio does not refire")
        var punctuated = AppCommandDetector()
        punctuated.audio(level: 0.2, seconds: 0.5, at: 0.9)
        punctuated.update("Open Safari. Settings", at: 1, timings: timings + [("settings", 0.82, 1.1)])
        punctuated.audio(level: 0, seconds: 1, at: 2.1)
        check(punctuated.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Punctuation inside speech cannot open Safari")
        var separate = AppCommandDetector()
        separate.audio(level: 0.2, seconds: 0.5, at: 2)
        separate.update("Open Safari. Thanks", at: 2, timings: timings + [("thanks", 1.7, 2)])
        check(separate.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).map(\.name) == ["safari"], "An actual gap can end a prior request")
        check(heard("Open GitHub Desktop App").first?.name == "github desktop app", "An installed name can end in App")

        // Synthetic real-audio spans reproduce the observed shape: a model can
        // append a fresh request to earlier discussion without any punctuation.
        func spans(_ text: String, gaps: [Int: Double] = [:]) -> [(word: String, start: Double, end: Double)] {
            var time = 0.0
            return PhraseMatcher.words(text).enumerated().map { index, word in
                time += gaps[index] ?? 0.05
                let start = time; time += 0.15
                return (word, start, time)
            }
        }
        for (text, expected) in [("it picked up open Chrome", false), ("it picked up. Open Chrome", true)] {
            let words = PhraseMatcher.words(text)
            let timing = spans(text, gaps: [words.firstIndex(of: "open")!: 0.65])
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1, at: timing.last!.end)
            detector.update(text, at: 1, timings: timing)
            detector.audio(level: 0, seconds: 1, at: timing.last!.end + 1)
            check(!detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty == expected,
                  "A hesitation before a quoted app command is not a new instruction: "+text)
        }
        let appText = "we discussed open Chrome and the app command open Chrome thanks"
        let appSpans = spans(appText, gaps: [8: 0.7, 10: 0.9])
        var noisyApp = AppCommandDetector()
        noisyApp.audio(level: 0.2, seconds: 1, at: appSpans.last!.end)
        noisyApp.update(appText, at: 1, timings: appSpans)
        var decisions: [(String, AppCommandDetector.Evidence)] = []
        check(noisyApp.poll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix], onDecision: { decisions.append(($1, $2)) })
              == [command(.openApp, "chrome", bare: true)],
              "Real word gaps isolate a later Open Chrome despite background noise and no punctuation")
        check(decisions.map(\.0) == ["rejected_context", "accepted"] && decisions.allSatisfy { $0.1.timing == "model" }
              && decisions.map { $0.1.leftWords } == [2, 0] && decisions.map { $0.1.nameWords } == [7, 1]
              && abs((decisions[0].1.gapBefore ?? 0) - 0.05) < 1e-6 && abs((decisions[1].1.gapBefore ?? 0) - 0.7) < 1e-6
              && abs((decisions[1].1.elapsed ?? 0) - 0.9) < 1e-6,
              "Diagnostics separate discussion before a prefix from a real pause, without any words")
        var untimed: [AppCommandDetector.Evidence] = []
        var plain = AppCommandDetector()
        plain.audio(level: 0.2, seconds: 0.1); plain.update("we discussed switch app chrome", at: 1); plain.audio(level: 0, seconds: 1)
        _ = plain.poll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix], onDecision: { untimed.append($2) })
        check(untimed.map(\.timing) == ["none"] && untimed.first?.gapBefore == nil && untimed.first?.leftWords == 2,
              "Text without model spans is labelled, never given an invented gap")
        check(noisyApp.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "A timed app request is consumed once")
        var noisyTail = AppCommandDetector()
        let tailSpans = spans("open Chrome")
        noisyTail.audio(level: 0.2, seconds: 1, at: tailSpans.last!.end + 0.81)
        noisyTail.update("open Chrome", at: 1, timings: tailSpans)
        check(noisyTail.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).count == 1,
              "The existing finalization interval uses real word end time even if RMS never becomes quiet")
        for badSpans in [spans(appText), appSpans.map { (word: $0.word, start: $0.start, end: $0.start) }, Array(appSpans.dropLast())] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 1)
            detector.update(appText, at: 1, timings: badSpans)
            detector.audio(level: 0, seconds: 1)
            check(detector.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty,
                  "No gap, synthetic arrival timestamps or misaligned spans cannot split discussion into commands")
        }

        // Duplicates: one action per spoken occurrence.
        var once = AppCommandDetector()
        once.audio(level: 0.2, seconds: 0.1); once.update("Switch app Chrome", at: 1); once.audio(level: 0, seconds: 1)
        check(once.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).count == 1, "First occurrence acts")
        check(once.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "Polled again: nothing")
        once.update("Switch app Chrome please", at: 2)
        check(once.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "A revision does not replay")
        once.update("Switch app Chrome please. Switch app Safari", at: 3)
        check(once.poll(switchPrefix: switchPrefix, openPrefix: openPrefix) == [command(.switchApp, "safari")], "A new occurrence acts once")
        var ended = AppCommandDetector()
        ended.audio(level: 0.2, seconds: 0.1); ended.update("Open Safari. Bye chat.", at: 1)
        ended.consumeAll(switchPrefix: switchPrefix, openPrefix: openPrefix)
        ended.audio(level: 0, seconds: 1)
        check(ended.poll(switchPrefix: switchPrefix, openPrefix: openPrefix).isEmpty, "End wins over app commands in the same transcript")
        check(AppCommandDetector.barePrefix(for: PhrasePattern(text: "Launch app", similar: false)).map(\.text) == "launch" &&
              AppCommandDetector.barePrefix(for: PhrasePattern(text: "Open", similar: false)) == nil, "Bare form follows a custom prefix")

        // Extra listed phrases: each is a prefix for its own section. Only Open app phrases have the
        // bare short form; Switch app phrases never gain one.
        let bringUp = PhrasePattern(slot: .switchAppPhrase, text: "Bring up", similar: true, dictionaries: .init())
        let launchApp = PhrasePattern(slot: .openAppPhrase, text: "Launch app", similar: true, dictionaries: .init())
        func heardListed(_ text: String, switches: [PhrasePattern] = [switchPrefix, bringUp],
                         opens: [PhrasePattern] = [openPrefix, launchApp]) -> [AppCommandCandidate] {
            var detector = AppCommandDetector()
            detector.audio(level: 0.2, seconds: 0.1); detector.update(text, at: 1); detector.audio(level: 0, seconds: 1)
            return detector.poll(switchPrefixes: switches, openPrefixes: opens)
        }
        check(heardListed("Bring up Chrome") == [command(.switchApp, "chrome")], "An extra Switch app phrase is a prefix")
        check(heardListed("Switch app Chrome") == [command(.switchApp, "chrome")], "The main phrase still works beside it")
        check(heardListed("Launch Safari") == [command(.openApp, "safari", bare: true)] &&
              heardListed("Open Safari") == [command(.openApp, "safari", bare: true)], "Each Open app phrase keeps its short form")
        for text in ["Switch Chrome", "Bring Chrome", "Don't bring up Chrome", "I said launch app Safari"] {
            check(heardListed(text).isEmpty, "No new short form, mention or negation: \(text)")
        }
        let switchTo = PhrasePattern(slot: .switchAppPhrase, text: "Switch app to", similar: true, dictionaries: .init())
        check(heardListed("Switch app to Chrome", switches: [switchPrefix, switchTo]) == [command(.switchApp, "chrome")],
              "Overlapping listed phrases are one spoken occurrence")
        var revisedAlias = AppCommandDetector()
        revisedAlias.audio(level: 0.2, seconds: 0.1); revisedAlias.update("Switch app Chrome", at: 1); revisedAlias.audio(level: 0, seconds: 1)
        check(revisedAlias.poll(switchPrefixes: [switchPrefix, bringUp], openPrefixes: [openPrefix]).count == 1, "First listed phrase acts")
        revisedAlias.update("Bring up Chrome", at: 2)
        check(revisedAlias.poll(switchPrefixes: [switchPrefix, bringUp], openPrefixes: [openPrefix]).isEmpty,
              "A revision to another listed phrase is the same occurrence")

        // A pause heard after the prefix used to skip the left-context check: "the switch app chrome",
        // a 0.5 s pause, then more words was admitted. The words before the prefix still count.
        var latePause = AppCommandDetector()
        latePause.audio(level: 0.2, seconds: 0.1); latePause.update("the switch app chrome", at: 1)
        latePause.audio(level: 0, seconds: 0.5); latePause.audio(level: 0.2, seconds: 0.1)
        latePause.update("the switch app chrome thanks", at: 2); latePause.audio(level: 0, seconds: 1)
        var latePauseDecision = ""
        check(latePause.poll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix],
                             onDecision: { _, decision, _ in latePauseDecision = decision }).isEmpty && latePauseDecision == "rejected_context",
              "A later pause never removes the words before a prefix")
        // Every pause is kept, so hesitating inside a request keeps the pause before it.
        var hesitant = AppCommandDetector()
        hesitant.audio(level: 0.2, seconds: 0.1); hesitant.update("we talked about it", at: 1)
        hesitant.audio(level: 0, seconds: 0.4); hesitant.audio(level: 0.2, seconds: 0.1)
        hesitant.update("we talked about it switch app", at: 2)
        hesitant.audio(level: 0, seconds: 0.4); hesitant.audio(level: 0.2, seconds: 0.1)
        hesitant.update("we talked about it switch app chrome", at: 3); hesitant.audio(level: 0, seconds: 1)
        check(hesitant.poll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix]) == [command(.switchApp, "chrome")],
              "A pause before the prefix still separates it from earlier discussion after a second pause")

        // Resolution. Ethan, 14 November 2026: Switch app and Open app are interchangeable. Both bring
        // a running app forward and open an installed one that isn't running. This replaces the old
        // contract (Switch: running apps only; Open: installed apps only), checked below as changes.
        let chrome = AppCandidate(id: "com.google.Chrome", names: ["Google Chrome"], pid: 11)
        let chatGPT = AppCandidate(id: "com.openai.chat", names: ["ChatGPT"], pid: 12)
        let codex = AppCandidate(id: "com.openai.codex", names: ["Codex"], pid: 13)
        let code = AppCandidate(id: "com.microsoft.VSCode", names: ["Code", "Visual Studio Code"], pid: 14)
        let running = [chrome, chatGPT, codex, code]
        // App-name spellings are independent of command-prefix dictionaries and native names.
        let spellingValues = try! AppNameSpellings.parse("  Coding room \nBS Code\nbs-code\n\n")
        check(spellingValues == ["Coding room", "BS Code"], "App spellings trim and deduplicate normalized names")
        let customNames = AppNameSpellings(overrides: [code.id: spellingValues])
        check(AppNameSpellings(saved: customNames.overrides) == customNames, "Bundle-keyed spellings round-trip without changing other app defaults")
        check(AppNameSpellings(saved: [code.id: []]).spellings(for: code.id).isEmpty, "Explicit empty means app names only")
        check(!AppNameSpellings().spellings(for: code.id).isEmpty, "Missing means built-in spellings")
        check(AppResolver.resolve("Coding room", among: running, allowFuzzy: false, spellings: customNames) == .match(code, .alias), "Custom spelling identifies the selected app")
        check(AppResolver.resolve("VSC", among: running, allowFuzzy: false, spellings: customNames) == .none, "Custom spellings replace built-in alternatives")
        check(AppResolver.resolve("Visual Studio Code", among: running, allowFuzzy: false, spellings: customNames) == .match(code, .exact), "Native names still work after dictionary replacement")
        check(AppResolver.resolve("Coding room", among: running, allowFuzzy: false) == .none, "Restoring built-in removes the custom spelling")
        check(AppNameSpellings().spellings(for: "com.ethansk.VoiceInkPlusPlus").contains("Agent Floor"), "Common Agent Flow speech substitution is provided")
        let agentFlow = AppCandidate(id: "com.ethansk.VoiceInkPlusPlus", names: ["Agent Flow"], pid: 70)
        let rekordbox = AppCandidate(id: "com.pioneerdj.rekordboxdj", names: ["rekordbox"], pid: 71)
        check(AppResolver.resolve("agent floor", among: [agentFlow], allowFuzzy: false) == .match(agentFlow, .alias), "Default app-specific spelling uses bundle identity")
        check(AppResolver.resolve("record books", among: [rekordbox], allowFuzzy: false) == .match(rekordbox, .alias), "Record books resolves to Rekordbox")
        check(AppNameSpellings.cleaned(["A", "a!", "one two three four five", String(repeating: "x", count: 121)]) == ["A"], "Malformed saved entries are bounded without touching native names")
        for bad in ["one two three four five", String(repeating: "x", count: 121), Array(repeating: "word", count: 101).joined(separator: "\n")] {
            do { _ = try AppNameSpellings.parse(bad); check(false, "Invalid app spelling must not save") }
            catch { check(true, "Invalid app spelling is rejected with a specific error") }
        }
        let sameSpelling = AppNameSpellings(overrides: [code.id: ["coding room"], chrome.id: ["Coding room"]])
        check(sameSpelling.needsCatalog("coding room"), "Colliding app aliases require all installed targets")
        check(AppCommandPlanner.decideRunning(command(.switchApp, "coding room"), running: [code], spellings: sameSpelling) == nil, "A running alias cannot hide a closed collision")
        let closedChrome = AppCandidate(id: chrome.id, names: chrome.names, url: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        if case .failure = AppCommandPlanner.decide(command(.switchApp, "coding room"), running: [code], installed: [closedChrome], spellings: sameSpelling) {
            check(true, "An ambiguous custom name never dispatches")
        } else { check(false, "An ambiguous custom name must be refused") }
        let closedSafari = AppCandidate(id: "com.apple.Safari", names: ["Safari"], url: URL(fileURLWithPath: "/Applications/Safari.app"))
        let nativeCollision = AppNameSpellings(overrides: [code.id: ["Safari"]])
        check(AppCommandPlanner.decide(command(.openApp, "Safari", bare: true), running: [code], installed: [closedSafari], spellings: nativeCollision) == .open(closedSafari), "Closed app's native name wins over a running custom alias")
        check(nativeCollision.conflicts(["Safari"], for: code.id, among: [code, closedSafari]) == ["Safari"], "Editor identifies a conflicting native app name")
        check(sameSpelling.conflicts(["coding room"], for: code.id, among: [code, closedChrome]) == [chrome.displayName], "Editor identifies a competing app's spelling")
        check(AppNameSpellings().conflicts(["Chat GPT"], for: codex.id, among: [codex, chatGPT]).isEmpty, "Existing ordered ChatGPT family remains editable")
        func decide(_ kind: AppCommandKind, _ name: String, bare: Bool = false, alternate: String? = nil,
                    running: [AppCandidate], installed: [AppCandidate] = []) -> AppCommandDecision {
            AppCommandPlanner.decide(command(kind, name, bare: bare, alternate: alternate), running: running, installed: installed)
        }
        func target(_ decision: AppCommandDecision) -> String? {
            switch decision {
            case .activate(let app): return "activate \(app.id) \(app.pid ?? -1)"
            case .open(let app): return "open \(app.id)"
            default: return nil
            }
        }
        for kind in [AppCommandKind.switchApp, .openApp] {
            check(decide(kind, "chrome", running: running) == .activate(chrome), "Chrome alias: \(kind)")
            let chromeWrapper = AppCandidate(id: "example.workflow", names: ["Chrome"], pid: 20)
            check(decide(kind, "chrome", running: [chromeWrapper, chrome]) == .activate(chrome), "Chrome alias selects the browser over a named wrapper")
            check(decide(kind, "chorme", running: running) == .activate(chrome), "Close spelling of a known alias")
            check(decide(kind, "chat gpt", running: running) == .activate(chatGPT), "Chat GPT is ChatGPT when it is open")
            check(decide(kind, "bs code", running: running) == .activate(code), "BS Code is VS Code")
            check(decide(kind, "visual studio code", running: running) == .activate(code), "Exact bundle name")
            check(decide(kind, "googel chrome", running: running) == .activate(chrome), "Conservative fuzzy match")
        }
        // A running alias target wins over launching a preferred app that isn't open.
        check(decide(.openApp, "chat gpt", running: [chrome, codex],
                     installed: [AppCandidate(id: "com.openai.chat", names: ["ChatGPT"], url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))])
              == .activate(codex), "Chat GPT brings the open Codex forward")
        let impostor = AppCandidate(id: "com.example.chat", names: ["ChatGPT"], pid: 20)
        check(failureText(decide(.switchApp, "chat gpt", running: [chatGPT, impostor]))?.contains("Say the full app name") == true,
              "An ambiguous exact name is never masked by the alias")
        let notes = [AppCandidate(id: "a.notes", names: ["Notes"], pid: 21), AppCandidate(id: "b.notes", names: ["Notes"], pid: 22)]
        check(failureText(decide(.switchApp, "notes", running: notes)) != nil, "Two apps with one name are ambiguous")
        let rhymes = [AppCandidate(id: "a.notion", names: ["Notion"], pid: 23), AppCandidate(id: "a.motion", names: ["Motion"], pid: 24)]
        if case .ambiguous(let names) = AppResolver.resolve("lotion", among: rhymes, allowFuzzy: true) {
            check(Set(names) == ["Notion", "Motion"], "Fuzzy ties name both apps")
        } else { preconditionFailure("Fuzzy ties are rejected, never chosen first") }
        check(AppResolver.resolve("ab", among: [AppCandidate(id: "x.ac", names: ["AC"])], allowFuzzy: true) == .none, "Short names never fuzzy-match")

        func installedApp(_ id: String, _ name: String) -> AppCandidate {
            AppCandidate(id: id, names: [name], url: URL(fileURLWithPath: "/Applications/\(name).app"))
        }
        let safari = installedApp("com.apple.Safari", "Safari"), appStore = installedApp("com.apple.AppStore", "App Store")
        let installedChrome = installedApp("com.google.Chrome", "Google Chrome")
        let installed = [safari, appStore, installedChrome]
        // Closed apps: both phrases open the verified installed copy.
        for kind in [AppCommandKind.switchApp, .openApp] {
            check(decide(kind, "safari", running: [], installed: installed) == .open(safari), "Closed Safari opens: \(kind)")
            check(decide(kind, "chrome", running: [], installed: installed) == .open(installedChrome), "Closed Chrome opens: \(kind)")
            check(decide(kind, "safar", running: running, installed: installed) == .open(safari), "A full prefix may fuzzy-match a closed app: \(kind)")
            check(failureText(decide(kind, "chrome settings", running: [], installed: installed)) == "No app matches “chrome settings”.",
                  "A full prefix reports no match: \(kind)")
        }
        // Changed: Switch app used to answer "No open app matches “safari”" here.
        check(target(decide(.switchApp, "safari", running: running, installed: installed)) == "open com.apple.Safari",
              "Switch app opens an installed app that isn't running")
        // Changed: Open used to launch through Launch Services even when the app was already open.
        check(decide(.openApp, "chrome", bare: true, running: running, installed: installed) == .activate(chrome),
              "Open Chrome brings the running browser forward")
        // Changed: bare Open used to ignore running apps that aren't in an application folder.
        check(decide(.openApp, "codex", bare: true, running: running, installed: installed) == .activate(codex),
              "Open Codex brings the running app forward")
        check(decide(.openApp, "safari", bare: true, running: running, installed: installed) == .open(safari), "Open Safari")
        check(decide(.openApp, "app store", bare: true, running: running, installed: installed) == .open(appStore), "Open the App Store")
        check(decide(.openApp, "store", alternate: "app store", running: running, installed: installed) == .open(appStore), "Open app store")
        check(decide(.openApp, "store", alternate: "app store", running: running,
                     installed: installed + [installedApp("x.score", "Score")]) == .open(appStore), "Exact App Store beats fuzzy Score")
        for name in ["safar", "door", "chrome settings", "googel chrome"] {
            check(decide(.openApp, name, bare: true, running: running, installed: installed) == .ignore, "Bare open stays ordinary speech: \(name)")
        }
        // No wrong app: a close spelling of a running app can't beat an installed app's exact name.
        let notion = AppCandidate(id: "a.notion", names: ["Notion"], pid: 30), motion = installedApp("a.motion", "Motion")
        for kind in [AppCommandKind.switchApp, .openApp] {
            check(decide(kind, "motion", running: [notion], installed: [motion]) == .open(motion), "Exact closed Motion beats running Notion: \(kind)")
            check(decide(kind, "notion", running: [notion], installed: [motion, installedApp("a.notion", "Notion")]) == .activate(notion),
                  "Running Notion is brought forward, never opened again: \(kind)")
        }
        // A running copy absorbs the installed names, so an installed-only name still reaches it.
        let openCode = AppCandidate(id: "com.microsoft.VSCode", names: ["Code"], pid: 31)
        check(target(decide(.switchApp, "visual studio code", running: [openCode], installed: [installedApp("com.microsoft.VSCode", "Visual Studio Code")]))
              == "activate com.microsoft.VSCode 31", "Installed names reach the running process")

        // Installed catalog: intended roots, one ordinary nested level, never inside a bundle.
        check(InstalledAppCatalog.roots(home: URL(fileURLWithPath: "/Users/test")).map(\.url.path) ==
              ["/Applications", "/System/Applications", "/Users/test/Applications"], "Standard application folders only")
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        let tree: [String: [URL]] = [
            "/Fake/Applications": [url("/Fake/Applications/Install Staging.noindex"), url("/Fake/Applications/Safari.app"), url("/Fake/Applications/Utilities"), url("/Fake/Applications/.Secret.app"),
                                   url("/Fake/Applications/Chrome Installer.app"), url("/Fake/Applications/Font.app"), url("/Fake/Applications/Safari Copy.app")],
            "/Fake/Applications/Utilities": [url("/Fake/Applications/Utilities/Terminal.app"), url("/Fake/Applications/Utilities/Deeper")],
            "/Fake/Applications/Utilities/Deeper": [url("/Fake/Applications/Utilities/Deeper/Buried.app")],
            "/Fake/Applications/Safari.app": [url("/Fake/Applications/Safari.app/Contents/Helper.app")],
            "/Fake/System": [url("/Fake/System/Calculator.app"), url("/Fake/System/Sub")],
            "/Fake/System/Sub": [url("/Fake/System/Sub/Hidden.app")],
        ]
        let bundles: [String: InstalledAppCatalog.BundleInfo] = [
            "/Fake/Applications/Safari.app": .init(id: "com.apple.Safari", packageType: "APPL", names: ["Safari"]),
            "/Fake/Applications/.Secret.app": .init(id: "x.secret", packageType: "APPL", names: ["Secret"]),
            "/Fake/Applications/Chrome Installer.app": .init(id: "com.google.installer", packageType: "APPL", names: ["Chrome Installer"]),
            "/Fake/Applications/Font.app": .init(id: "x.font", packageType: "BNDL", names: ["Font"]),
            "/Fake/Applications/Safari Copy.app": .init(id: "com.apple.Safari", packageType: "APPL", names: ["Safari"]),
            "/Fake/Applications/Utilities/Terminal.app": .init(id: "com.apple.Terminal", packageType: nil, names: ["Terminal"]),
            "/Fake/Applications/Utilities/Deeper/Buried.app": .init(id: "x.buried", packageType: "APPL", names: ["Buried"]),
            "/Fake/Applications/Safari.app/Contents/Helper.app": .init(id: "x.helper", packageType: "APPL", names: ["Helper"]),
            "/Fake/System/Calculator.app": .init(id: "com.apple.calculator", packageType: "APPL", names: ["Calculator"]),
            "/Fake/System/Sub/Hidden.app": .init(id: "x.hidden", packageType: "APPL", names: ["Hidden"]),
        ]
        var listed: [String] = []
        let scanned = InstalledAppCatalog.scan(
            roots: [.init(url: url("/Fake/Applications"), nested: true), .init(url: url("/Fake/System"), nested: false)],
            list: { listed.append($0.path); return tree[$0.path] ?? [] }, read: { bundles[$0.path] })
        check(scanned.map(\.id) == ["com.apple.Safari", "com.apple.Safari", "com.apple.Terminal", "com.apple.calculator"],
              "Hidden, installer, non-application and deeper entries are excluded")
        check(!listed.contains("/Fake/Applications/Install Staging.noindex"), "The scan never enters an install staging directory")
        check(AppResolver.resolve("Safari", among: scanned, allowFuzzy: false) == .ambiguous(["Safari", "Safari"]), "Unresolved copies are ambiguous")
        let registered = InstalledAppCatalog.preferRegisteredCopies(scanned) { _ in url("/Fake/Applications/Safari Copy.app") }
        check(registered.filter { $0.id == "com.apple.Safari" }.map(\.url) == [url("/Fake/Applications/Safari Copy.app")], "The registered catalog copy wins")
        check(InstalledAppCatalog.preferRegisteredCopies(scanned) { _ in url("/Downloads/Safari.app") } == scanned, "Registration cannot introduce an external app")
        check(!listed.contains { $0.hasSuffix(".app") }, "The scan never lists inside an app bundle")
        check(!listed.contains("/Fake/Applications/Utilities/Deeper") && !listed.contains("/Fake/System/Sub"), "One nested level, only where allowed")
        check(scanned[0].url?.path == "/Fake/Applications/Safari.app" && scanned[0].pid == nil, "Installed apps carry their bundle URL")
        check(InstalledAppCatalog.isExcluded("Install macOS Sequoia") && InstalledAppCatalog.isExcluded("Zoom Rollback")
              && !InstalledAppCatalog.isExcluded("Safari"), "Installers and rollbacks are never Open targets")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("HChatDesktopTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        func makeBundle(_ bundle: URL, id: String, name: String) throws {
            try fileManager.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleName": name]
            try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try makeBundle(root.appendingPathComponent("Lantern.app"), id: "test.lantern", name: "Lantern")
        try makeBundle(root.appendingPathComponent("Lantern.app/Contents/Nested.app"), id: "test.nested", name: "Nested")
        try makeBundle(root.appendingPathComponent("Utilities/Beacon.app"), id: "test.beacon", name: "Beacon")
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: root.appendingPathComponent("Utilities"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: root.appendingPathComponent("Lantern.app/Contents/Nested.app"))
        try Data("note".utf8).write(to: root.appendingPathComponent("readme.txt"))
        check(InstalledAppCatalog.listDirectory(root).map(\.lastPathComponent) == ["Alias.app", "Lantern.app", "Utilities"],
              "Real listing keeps bundles and ordinary folders, never symlinked folders or files")
        check(InstalledAppCatalog.listDirectory(root.appendingPathComponent("Lantern.app")).isEmpty, "Real listing never enters a bundle")
        let lantern = InstalledAppCatalog.readBundle(root.appendingPathComponent("Lantern.app"))
        check(lantern?.id == "test.lantern" && lantern?.packageType == "APPL" && lantern?.names.contains("Lantern") == true, "Native bundle metadata")
        check(InstalledAppCatalog.scan(roots: [.init(url: root, nested: true)], list: InstalledAppCatalog.listDirectory,
                                       read: InstalledAppCatalog.readBundle).map(\.id) == ["test.lantern", "test.beacon"], "Real scan")

        // Zoom phrases: directional, mention and negation rejected, one action per occurrence.
        let zoomPatterns: [ZoomDirection: PhrasePattern] = [
            .zoomIn: PhrasePattern(slot: .zoomInPhrase, text: "Zoom in", similar: true, dictionaries: .init()),
            .zoomOut: PhrasePattern(slot: .zoomOutPhrase, text: "Zoom out", similar: true, dictionaries: .init())]
        func zoomHeard(_ text: String) -> [ZoomDirection] {
            var detectors = CommandPhraseDetectors<ZoomDirection>()
            detectors.audio(level: 0.2, seconds: 0.1); detectors.update(text, at: 1)
            return detectors.poll(at: 1, patterns: zoomPatterns, directOnly: true).map(\.command)
        }
        check(zoomHeard("Zoom in") == [.zoomIn] && zoomHeard("Zoom out please") == [.zoomOut] && zoomHeard("Can you zoom in") == [.zoomIn], "Zoom phrases")
        check(zoomHeard("Zoom in. Zoom out.") == [.zoomIn, .zoomOut], "Spoken order")
        for text in ["Don't zoom in", "Do not zoom out", "I said zoom in", "The zoom in button", "Zoom in phrase works", "I could zoom in on that", "Zoom in on the diagram", "Zoom", "Zoom inside"] {
            check(zoomHeard(text).isEmpty, "Not a zoom command: \(text)")
        }
        let zoomText = "the zoom in command is not working zoom in zoom out"
        let zoomSpans = spans(zoomText, gaps: [7: 0.7, 9: 0.7])
        var noisyZoom = CommandPhraseDetectors<ZoomDirection>()
        noisyZoom.audio(level: 0.2, seconds: 1)
        noisyZoom.update(zoomText, at: 1, timings: zoomSpans)
        check(noisyZoom.poll(at: 1, patterns: zoomPatterns, directOnly: true).map(\.command) == [.zoomIn, .zoomOut],
              "Timed desktop boundaries isolate fresh zoom commands from earlier discussion")
        check(noisyZoom.poll(at: 2, patterns: zoomPatterns, directOnly: true).isEmpty, "No timed zoom replay")
        for badSpans in [spans(zoomText), zoomSpans.map { (word: $0.word, start: $0.start, end: $0.start) }] {
            var detectors = CommandPhraseDetectors<ZoomDirection>()
            detectors.audio(level: 0.2, seconds: 1); detectors.update(zoomText, at: 1, timings: badSpans)
            check(detectors.poll(at: 1, patterns: zoomPatterns, directOnly: true).isEmpty, "Discussion needs a real word gap")
        }
        var stillNegated = CommandPhraseDetectors<ZoomDirection>()
        let negatedText = "earlier discussion do not zoom in"
        stillNegated.audio(level: 0.2, seconds: 1)
        stillNegated.update(negatedText, at: 1, timings: spans(negatedText, gaps: [2: 0.7]))
        check(stillNegated.poll(at: 1, patterns: zoomPatterns, directOnly: true).isEmpty, "A real gap never removes a command's own negation")
        var zoomOnce = CommandPhraseDetectors<ZoomDirection>()
        zoomOnce.audio(level: 0.2, seconds: 0.1); zoomOnce.update("Zoom in", at: 1)
        check(zoomOnce.poll(at: 1, patterns: zoomPatterns).count == 1, "Zoom acts")
        zoomOnce.update("Zoom in please", at: 2)
        check(zoomOnce.poll(at: 2, patterns: zoomPatterns).isEmpty, "A revision does not zoom twice")
        let end = PhrasePattern(slot: .sleepPhrase, text: "Bye Chat", similar: true, dictionaries: .init())
        var zoomEnded = CommandPhraseDetectors<ZoomDirection>()
        zoomEnded.audio(level: 0.2, seconds: 0.1); zoomEnded.update("Zoom in. Bye chat.", at: 1)
        zoomEnded.cancelPending(patterns: zoomPatterns, endPattern: end)
        check(zoomEnded.poll(at: 1, patterns: zoomPatterns).isEmpty, "End wins over zoom")
        // Listed extra phrases share the direction's detector and its one occurrence count. The
        // default phrases above take the same path with one phrase each.
        let enlarge = PhrasePattern(slot: .zoomInPhrase, text: "Enlarge", similar: true, dictionaries: .init())
        let zoomAliases: [ZoomDirection: [PhrasePattern]] = [.zoomIn: [zoomPatterns[.zoomIn]!, enlarge], .zoomOut: [zoomPatterns[.zoomOut]!]]
        var aliasZoom = CommandPhraseDetectors<ZoomDirection>()
        aliasZoom.audio(level: 0.2, seconds: 0.1); aliasZoom.update("Enlarge", at: 1)
        check(aliasZoom.poll(at: 1, aliases: zoomAliases, directOnly: true).map(\.command) == [.zoomIn], "An extra zoom phrase zooms in")
        aliasZoom.update("Zoom in", at: 2)
        check(aliasZoom.poll(at: 2, aliases: zoomAliases, directOnly: true).isEmpty, "A revision to the main phrase doesn't zoom twice")
        for text in ["Don't enlarge", "The enlarge button"] {
            var detectors = CommandPhraseDetectors<ZoomDirection>()
            detectors.audio(level: 0.2, seconds: 0.1); detectors.update(text, at: 1)
            check(detectors.poll(at: 1, aliases: zoomAliases, directOnly: true).isEmpty, "Extra phrases keep negation and mention rules: \(text)")
        }
        let goodnight = PhrasePattern(slot: .sleepPhrase, text: "Goodnight chat", similar: true, dictionaries: .init())
        var aliasEnded = CommandPhraseDetectors<ZoomDirection>()
        aliasEnded.audio(level: 0.2, seconds: 0.1); aliasEnded.update("Zoom in. Goodnight chat.", at: 1)
        aliasEnded.cancelPending(patterns: zoomPatterns, endPattern: end)
        var stillPending = aliasEnded
        check(stillPending.poll(at: 1, patterns: zoomPatterns).count == 1, "The main End phrase alone doesn't cover an extra End phrase")
        aliasEnded.cancelPending(aliases: zoomAliases, endPatterns: [end, goodnight])
        check(aliasEnded.poll(at: 1, aliases: zoomAliases).isEmpty, "An extra End phrase wins over zoom too")

        // Zoom key contract (Agentic Mouse): Cmd+Shift+Equals (24) in, Cmd+Minus (27) out, one balanced pair.
        func shortcut(_ recorder: KeyRecorder, trusted: Bool = true, session: DesktopSessionState = .interactive,
                      held: CGEventFlags = [], failDown: Bool = false) -> ZoomShortcut {
            var value = ZoomShortcut()
            value.post = { key, flags, original in
                if failDown { return false }
                recorder.events.append(KeyEvent(key: key, flags: flags, down: true))
                recorder.events.append(KeyEvent(key: key, flags: original, down: false))
                return true
            }
            value.accessibilityTrusted = { recorder.trustChecks += 1; return trusted }
            value.session = { session }
            value.currentFlags = { held }
            return value
        }
        func failure(_ result: Result<Void, ZoomShortcutError>) -> ZoomShortcutError? { if case .failure(let error) = result { return error }; return nil }
        let zoomIn = KeyRecorder()
        check(failure(shortcut(zoomIn).perform(.zoomIn)) == nil, "Zoom in sent")
        check(zoomIn.events == [KeyEvent(key: 24, flags: [.maskCommand, .maskShift], down: true), KeyEvent(key: 24, flags: [], down: false)],
              "Zoom in is Command-Shift-Equals, one down/up pair")
        let zoomOut = KeyRecorder()
        check(failure(shortcut(zoomOut).perform(.zoomOut)) == nil, "Zoom out sent")
        check(zoomOut.events == [KeyEvent(key: 27, flags: [.maskCommand], down: true), KeyEvent(key: 27, flags: [], down: false)],
              "Zoom out is Command-Minus, one down/up pair")
        let held = KeyRecorder()
        _ = shortcut(held, held: [.maskAlternate]).perform(.zoomIn)
        check(held.events.map(\.flags) == [[.maskCommand, .maskShift], [.maskAlternate]], "Key-up restores the modifiers held before sending")
        let untrusted = KeyRecorder()
        check(failure(shortcut(untrusted, trusted: false).perform(.zoomIn)) == .accessibilityPermissionMissing && untrusted.events.isEmpty,
              "No Accessibility trust: no events")
        let locked = KeyRecorder()
        check(failure(shortcut(locked, session: .locked).perform(.zoomOut)) == .desktopUnavailable(.locked)
              && locked.events.isEmpty && locked.trustChecks == 0, "Locked desktop: no events")
        let broken = KeyRecorder()
        check(failure(shortcut(broken, failDown: true).perform(.zoomIn)) == .eventCreationFailed && broken.events.isEmpty, "No key-up without a key-down")

        // DesktopCommands with an injected environment.
        let probe = Probe()
        var environment = DesktopCommands.Environment()
        environment.session = { probe.session }
        environment.running = { running }
        environment.activate = { app in probe.activated.append(app.id); if probe.bringsForward { probe.front = app.id }; return true }
        environment.isFrontmost = { probe.front == $0.id }
        environment.frontmostName = { "Safari" }
        environment.installed = { probe.scans += 1; return installed }
        environment.verify = { _ in probe.verifies }
        environment.open = { app in probe.opened.append(app.id); if probe.bringsForward { probe.front = app.id }; return true }
        environment.sleep = { _ in probe.sleeps += 1 }
        environment.zoom = shortcut(KeyRecorder())
        let commands = DesktopCommands(environment: environment)

        var spellingScans = 0
        var spellingActivations: [String] = []
        let spellingCommands = DesktopCommands(environment: .init(
            running: { [code] },
            activate: { spellingActivations.append($0.id); return true },
            isFrontmost: { _ in true },
            installed: { spellingScans += 1; return [closedChrome, AppCandidate(id: code.id, names: code.names)] }))
        let spellingMenu = await spellingCommands.spellingChoices()
        check(Set(spellingMenu.map(\.id)) == Set([chrome.id, code.id]) && spellingMenu.count == 2,
              "App spelling choices group running/installed copies without activation")
        check(spellingActivations.isEmpty, "Browsing spelling choices never opens or activates an app")
        let spellingResult = await spellingCommands.perform(command(.switchApp, "coding room"), spellings: customNames)
        check(spellingResult.diagnostic == "frontmost" && spellingActivations == [code.id], "Execution receives the current custom spelling configuration")
        let restoredResult = await spellingCommands.perform(command(.openApp, "coding room", bare: true))
        check(restoredResult.diagnostic == "ignored" && spellingActivations.count == 1, "A later restored configuration cannot reuse the previous alias")
        check(spellingScans == 1, "The editor and commands share one bounded app catalog cache")

        var result = await commands.perform(command(.switchApp, "chrome"))
        check(result == DesktopCommandResult(message: "Switched to Google Chrome", diagnostic: "frontmost"), "Switch confirms the front app")
        check(probe.activated == [chrome.id] && probe.opened.isEmpty && probe.scans == 0,
              "An exact running match activates it without reading the installed catalog")
        probe.bringsForward = false
        result = await commands.perform(command(.switchApp, "codex"))
        check(result.diagnostic == "dispatched" && result.message == "Asked Codex to come forward, but it isn't in front yet." && probe.sleeps == 10,
              "Dispatch is not reported as success")
        probe.bringsForward = true
        // Changed (Ethan, 14 November 2026): Switch app used to refuse a closed app.
        result = await commands.perform(command(.switchApp, "safari"))
        check(result == DesktopCommandResult(message: "Opened Safari", diagnostic: "frontmost") && probe.opened == [safari.id]
              && probe.scans == 1, "Switch app opens a closed installed app")
        result = await commands.perform(command(.openApp, "safari", bare: true))
        check(result == DesktopCommandResult(message: "Opened Safari", diagnostic: "frontmost") && probe.opened == [safari.id, safari.id], "Open Safari")
        // Changed: bare Open used to ignore running Codex, and Open app used to relaunch running Chrome.
        result = await commands.perform(command(.openApp, "codex", bare: true))
        check(result == DesktopCommandResult(message: "Switched to Codex", diagnostic: "frontmost") && probe.activated.last == codex.id
              && probe.opened.count == 2, "Open Codex brings the running app forward")
        result = await commands.perform(command(.openApp, "chrome", alternate: "app chrome"))
        check(result.message == "Switched to Google Chrome" && probe.activated.last == chrome.id && probe.opened.count == 2,
              "Open app Chrome switches to the running browser")
        check(probe.scans == 1, "The installed catalog is cached, not rescanned per command")
        probe.verifies = false
        result = await commands.perform(command(.openApp, "app store", bare: true))
        check(result.message == "App Store is no longer installed there." && probe.opened.count == 2, "A vanished bundle is not opened")
        probe.verifies = true
        _ = await commands.perform(command(.openApp, "safari", bare: true))
        check(probe.scans == 2, "A vanished bundle refreshes the catalog")
        let activationsBeforeUnknown = probe.activated.count, opensBeforeUnknown = probe.opened.count
        result = await commands.perform(command(.switchApp, "lantern"))
        check(result == DesktopCommandResult(message: "No app matches “lantern”.", diagnostic: "not-resolved")
              && probe.activated.count == activationsBeforeUnknown && probe.opened.count == opensBeforeUnknown,
              "An unknown app is reported, and nothing is switched or opened")
        probe.session = .locked
        let activations = probe.activated.count
        result = await commands.perform(command(.switchApp, "chrome"))
        check(result.message == "Unlock your Mac, then try again." && probe.activated.count == activations, "Locked desktop: nothing switches")
        probe.session = .interactive
        let openedBeforeLock = probe.opened
        var interrupted = environment
        interrupted.installed = { probe.session = .locked; return installed }
        let interruptedResult = await DesktopCommands(environment: interrupted).perform(command(.openApp, "safari"))
        check(interruptedResult.diagnostic == "session-locked" && probe.opened == openedBeforeLock, "A lock during catalog lookup prevents opening")
        check(commands.zoom(.zoomIn) == DesktopCommandResult(message: "Sent zoom in to Safari", diagnostic: "sent"), "Zoom reports dispatch")

        // Command sounds: `dispatched` runs once when macOS accepts the request, before front-app
        // confirmation, and never for ignored, unresolved, failed, locked or cancelled work.
        final class Timeline { var events: [String] = [] }
        let timeline = Timeline()
        probe.session = .interactive; probe.verifies = true
        var slow = environment
        slow.activate = { _ in timeline.events.append("activate"); return true }
        slow.open = { _ in timeline.events.append("open"); return true }
        slow.isFrontmost = { _ in false }
        slow.sleep = { _ in timeline.events.append("sleep") }
        let pending = DesktopCommands(environment: slow)
        result = await pending.perform(command(.switchApp, "chrome")) { timeline.events.append("sound") }
        check(Array(timeline.events.prefix(2)) == ["activate", "sound"] && timeline.events.filter { $0 == "sound" }.count == 1
              && result.diagnostic == "dispatched", "Switch sounds once at dispatch, without waiting for the app to come forward")
        timeline.events.removeAll()
        result = await pending.perform(command(.openApp, "safari", bare: true)) { timeline.events.append("sound") }
        check(Array(timeline.events.prefix(2)) == ["open", "sound"] && timeline.events.filter { $0 == "sound" }.count == 1
              && result.diagnostic == "dispatched", "Open sounds once when the open request is accepted")
        // Both phrases sound once for running and closed apps alike.
        timeline.events.removeAll()
        result = await pending.perform(command(.openApp, "codex", bare: true)) { timeline.events.append("sound") }
        check(Array(timeline.events.prefix(2)) == ["activate", "sound"] && timeline.events.filter { $0 == "sound" }.count == 1,
              "Open sounds once when a running app is asked forward")
        timeline.events.removeAll()
        result = await pending.perform(command(.switchApp, "safari")) { timeline.events.append("sound") }
        check(Array(timeline.events.prefix(2)) == ["open", "sound"] && timeline.events.filter { $0 == "sound" }.count == 1,
              "Switch sounds once when a closed app is opened")
        var sounds = 0
        for name in ["chrome", "codex", "safari"] {
            _ = await commands.perform(command(.switchApp, name)) { sounds += 1 }
        }
        check(sounds == 3, "The spoken app name doesn't change whether the command sounds")
        sounds = 0
        _ = await commands.perform(command(.openApp, "door", bare: true)) { sounds += 1 }
        _ = await commands.perform(command(.switchApp, "lantern")) { sounds += 1 }
        probe.verifies = false
        _ = await commands.perform(command(.openApp, "safari", bare: true)) { sounds += 1 }
        probe.verifies = true
        var refusing = environment
        refusing.activate = { _ in false }
        refusing.open = { _ in false }
        _ = await DesktopCommands(environment: refusing).perform(command(.switchApp, "chrome")) { sounds += 1 }
        _ = await DesktopCommands(environment: refusing).perform(command(.openApp, "safari", bare: true)) { sounds += 1 }
        probe.session = .locked
        _ = await commands.perform(command(.switchApp, "chrome")) { sounds += 1 }
        probe.session = .interactive
        _ = await DesktopCommands(environment: interrupted).perform(command(.openApp, "safari")) { sounds += 1 }
        probe.session = .interactive
        var locksAfterOpening = environment
        locksAfterOpening.open = { _ in probe.session = .locked; return true }
        let lateOpen = await DesktopCommands(environment: locksAfterOpening).perform(command(.openApp, "safari")) { sounds += 1 }
        check(lateOpen.diagnostic == "session-locked", "A lock while macOS opens an app suppresses the pending cue")
        probe.session = .interactive
        let cancelled = Task { await commands.perform(command(.switchApp, "chrome")) { timeline.events.append("cancelled sound") } }
        cancelled.cancel()
        check(await cancelled.value.diagnostic == "cancelled", "A cancelled command does nothing")
        check(sounds == 0 && !timeline.events.contains("cancelled sound"),
              "Ordinary speech, unknown apps, vanished bundles, refusals, locks and cancellations stay silent")
        _ = commands.zoom(.zoomOut) { sounds += 1 }
        var blocked = environment
        blocked.zoom = shortcut(KeyRecorder(), trusted: false)
        _ = DesktopCommands(environment: blocked).zoom(.zoomIn) { sounds += 1 }
        blocked.zoom = shortcut(KeyRecorder(), session: .locked)
        _ = DesktopCommands(environment: blocked).zoom(.zoomIn) { sounds += 1 }
        check(sounds == 1, "Zoom sounds only when its keys are sent")

        print("Passed \(checks) desktop command checks")
    }
}
