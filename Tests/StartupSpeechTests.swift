// Offline checks for the real startup buffer and cross-process mailbox contract.
// No microphone, playback, Codex UI, message injection or Voice calls are used.
import Foundation
import Darwin

private final class StartupEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StartupSpeechFile.Event] = []
    func append(_ event: StartupSpeechFile.Event) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var snapshot: [StartupSpeechFile.Event] { lock.lock(); defer { lock.unlock() }; return events }
}

@main enum StartupSpeechTests {
    static func main() async throws {
        func expect(_ value: Bool, _ message: String = "Startup speech check failed", line: UInt = #line) {
            precondition(value, message, line: line)
        }
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a task-owned fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        expect(root.path.contains(".noindex"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = StartupSpeechFile(directory: fixture)
        let consumer = UUID()

        let skills = root.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: skills) }
        let contract = root.appendingPathComponent("contract-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: contract) }
        let original = Data("---\nname: hello-chat-voice-startup\ndescription: New actual Voice coordinator only.\n---\nFirst contract".utf8)
        try original.write(to: contract)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .installed)
        let skillDirectory = skills.appendingPathComponent(StartupSpeechSkillInstaller.name)
        let installedSkill = skillDirectory.appendingPathComponent("SKILL.md")
        expect(try Data(contentsOf: installedSkill) == original)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .unchanged)
        let unrelated = skills.appendingPathComponent("personal-note.md")
        try Data("Leave this alone".utf8).write(to: unrelated)
        let extra = skillDirectory.appendingPathComponent("user-note.txt")
        try Data("Keep my notes".utf8).write(to: extra)
        let updated = original + Data("\nUpdated contract".utf8)
        try updated.write(to: contract)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .updated)
        expect(try Data(contentsOf: installedSkill) == updated)
        expect(try String(contentsOf: unrelated, encoding: .utf8) == "Leave this alone")
        expect(try String(contentsOf: extra, encoding: .utf8) == "Keep my notes")
        try Data("My edited skill".utf8).write(to: installedSkill)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .conflict)
        expect(try String(contentsOf: installedSkill, encoding: .utf8) == "My edited skill")
        try FileManager.default.removeItem(at: skillDirectory)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: false)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .conflict)
        try FileManager.default.removeItem(at: skillDirectory)
        try FileManager.default.createSymbolicLink(at: skillDirectory, withDestinationURL: root)
        expect(try StartupSpeechSkillInstaller.install(contract: contract, skills: skills) == .conflict)
        print("Startup skill: create, idempotence, update, user edits, unowned directory, symlink and unrelated-file preservation passed")

        // The bundled contract is the only reader documentation. Keep it aligned
        // with every status, boundary and bound this reader/producer uses, and
        // prove an app update replaces its own unchanged older copy.
        let repository = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let bundled = repository.appendingPathComponent("Resources/VoiceStartup.md")
        let bundledData = try Data(contentsOf: bundled)
        let bundledText = String(decoding: bundledData, as: UTF8.self)
        for status in ["speech", "capturing", "empty", "unrelated", "claimed", "busy", "unavailable"] {
            expect(bundledText.contains("`\(status)`"), "The app-owned skill must document status \(status)")
        }
        for boundary in StartupSpeechFile.Boundary.allCases {
            expect(bundledText.contains("`\(boundary.rawValue)`"), "The app-owned skill must document boundary \(boundary.rawValue)")
        }
        expect(bundledText.contains("\(Int(StartupSpeechBuffer.pauseSeconds)) seconds without new recognized")
               && bundledText.contains("\(Int(StartupSpeechBuffer.openLimitSeconds)) seconds of audio")
               && bundledText.contains("\(Int(StartupSpeechFile.abandonedAfter / 60)) minutes after its request"), "Skill timing must match the code")
        let propagation = root.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: propagation) }
        let previousContract = root.appendingPathComponent("contract-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: previousContract) }
        try Data("---\nname: hello-chat-voice-startup\ndescription: Previous build.\n---\nCapturing-only reader".utf8).write(to: previousContract)
        expect(try StartupSpeechSkillInstaller.install(contract: previousContract, skills: propagation) == .installed)
        expect(try StartupSpeechSkillInstaller.install(contract: bundled, skills: propagation) == .updated, "An app update replaces its own unchanged older skill")
        expect(try Data(contentsOf: propagation.appendingPathComponent("\(StartupSpeechSkillInstaller.name)/SKILL.md")) == bundledData)
        expect(try StartupSpeechSkillInstaller.install(contract: bundled, skills: propagation) == .unchanged)
        print("Startup skill: bundled contract documents every status/boundary/bound and propagates over an older owned copy")

        var capture = StartupSpeechBuffer(id: UUID(), text: "The video said hello chat. Hello chat, turn the kitchen light on?",
            wakeRange: 5..<7, phrase: "Hello Chat", similar: true)
        expect(capture.text == "turn the kitchen light on?")
        capture.observe("The video said hello chat. HelloChat, turn the kitchen lights blue.")
        expect(capture.text == "turn the kitchen lights blue.", "Joined wake corrections must not drop the first request word")
        capture.observe("The video said hello chat. Hello chat, turn the kitchen lights red.")
        expect(capture.text == "turn the kitchen lights red.", "Partial hypotheses replace instead of duplicating speech")
        expect(!capture.markVoiceOpened(), "Opening Voice must not freeze an unfinished hypothesis")
        capture.observe("The video said hello chat. Hello chat, turn the kitchen lights red and dim them.")
        expect(capture.text == "turn the kitchen lights red and dim them.")
        expect(capture.markUtteranceEnded(), "Opened Voice plus finished speech completes the request")
        capture.boundary(); capture.observe("And dim them to fifty percent.")
        expect(capture.text == "turn the kitchen lights red and dim them. And dim them to fifty percent.")

        var beforeOpen = StartupSpeechBuffer(id: UUID(), text: "Hello chat this is a", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        expect(!beforeOpen.markUtteranceEnded())
        beforeOpen.speechResumed()
        expect(!beforeOpen.markVoiceOpened(), "Resumed audio must invalidate the old boundary before text catches up")
        beforeOpen.observe("Hello chat this is a complete opening request.")
        expect(!beforeOpen.markVoiceOpened(), "A newer hypothesis invalidates an earlier utterance-end signal")
        expect(beforeOpen.markUtteranceEnded())
        expect(beforeOpen.text == "this is a complete opening request.")

        let dictionaryPattern = PhrasePattern(slot: .wakePhrase, text: "Hello Chat", similar: true,
            dictionaries: .init(["hellochat": ["Open Lantern", "Open the orange lantern near the back door and listen for my request now"]]))
        var dictionaryOpening = StartupSpeechBuffer(id: UUID(), text: "Open Lantern, turn on the lights", wakeRange: 0..<2, pattern: dictionaryPattern)
        expect(dictionaryOpening.alignment == .wake && dictionaryOpening.text == "turn on the lights" && dictionaryOpening.hasOpeningWords)
        dictionaryOpening.observe("Open Lantern. Open Lantern.")
        expect(!dictionaryOpening.hasOpeningWords)
        dictionaryOpening.observe("Open Lantern. Open Lantern. Turn on the lights")
        expect(dictionaryOpening.hasOpeningWords && dictionaryOpening.text == "Open Lantern. Turn on the lights")
        let longAlias = "Open the orange lantern near the back door and listen for my request now"
        var longOpening = StartupSpeechBuffer(id: UUID(), text: longAlias + ", tell me the time", wakeRange: 0..<15, pattern: dictionaryPattern)
        expect(longOpening.alignment == .wake && longOpening.text == "tell me the time" && longOpening.hasOpeningWords)
        longOpening.observe(longAlias + ", tell me the date")
        expect(longOpening.text == "tell me the date")

        var custom = StartupSpeechBuffer(id: UUID(), text: "Good morning computer, open the calendar.",
            wakeRange: 0..<3, phrase: "Good morning computer", similar: true)
        expect(custom.text == "open the calendar.")
        custom.observe("Good morning computer, open tomorrow's calendar.")
        expect(custom.text == "open tomorrow's calendar.")
        var manual = StartupSpeechBuffer(id: UUID(), text: "Earlier conversation", wakeRange: nil, phrase: "Hello Chat", similar: true)
        manual.observe("Earlier conversation What time is it?")
        expect(manual.text == "What time is it?")
        manual.boundary(); manual.observe(String(repeating: "🎵", count: 9_000))
        expect(manual.text.count == StartupSpeechFile.textLimit && manual.truncated)

        // 7 Nov incident: steady sound kept the level-based pause unsatisfied for
        // 96 s. Startup bounds count processed audio after Voice opened.
        var opening = StartupSpeechBuffer(id: UUID(), text: "Hello chat what is", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        opening.audioProcessed(seconds: 6)
        expect(opening.boundaryReached == nil, "No startup boundary before Voice opens")
        expect(!opening.markVoiceOpened())
        expect(opening.boundaryReached == nil, "Connecting alone must not end capture, even after earlier quiet")
        opening.audioProcessed(seconds: 1.5)
        opening.observe("Hello chat what is the meaning of life?")
        // Room sound or playback without recognised words: the raw level keeps
        // resuming, but the opening text doesn't change.
        for _ in 0..<22 { opening.speechResumed(); opening.audioProcessed(seconds: 0.085) }
        expect(opening.boundaryReached == nil, "A pause under two seconds keeps the opening")
        for _ in 0..<2 { opening.speechResumed(); opening.audioProcessed(seconds: 0.085) }
        expect(opening.boundaryReached == .pause, "Sound without recognised words must not hold capture open")
        expect(opening.text == "what is the meaning of life?")

        var paused = StartupSpeechBuffer(id: UUID(), text: "Hello chat turn the kitchen lights", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = paused.markVoiceOpened()
        paused.audioProcessed(seconds: 1.9)
        paused.observe("Hello chat turn the kitchen lights red")
        paused.audioProcessed(seconds: 1.9)
        expect(paused.boundaryReached == nil && paused.text == "turn the kitchen lights red", "Shorter mid-request pauses keep one request")

        var launching = StartupSpeechBuffer(id: UUID(), text: "Hello chat", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        launching.audioProcessed(seconds: 10)
        _ = launching.markVoiceOpened()
        launching.audioProcessed(seconds: 1.9)
        expect(launching.boundaryReached == nil, "Quiet while Codex launches doesn't count toward the post-open pause")
        launching.audioProcessed(seconds: 0.1)
        expect(launching.boundaryReached == nil && launching.text.isEmpty,
               "Do not seal an empty opening before delayed recognition arrives")
        launching.audioProcessed(seconds: 3)
        launching.observe("Hello chat this is a delayed opening")
        expect(launching.boundaryReached == nil && launching.text == "this is a delayed opening")
        launching.audioProcessed(seconds: 2)
        expect(launching.boundaryReached == .pause)

        // A repeated wake is a command retry, not the start of the request.
        // The reported 19:49 failure sealed only "Hello chat" after two seconds.
        var repeatedWake = StartupSpeechBuffer(id: UUID(), text: "Hello chat. Hello chat.", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = repeatedWake.markVoiceOpened()
        repeatedWake.audioProcessed(seconds: 2.1)
        expect(repeatedWake.boundaryReached == nil, "A repeated wake alone must not seal the opening before the question")
        expect(!repeatedWake.markUtteranceEnded(), "A wake retry isn't a finished request even at an utterance boundary")
        repeatedWake.observe("Hello chat. Hello chat. What's for dinner?")
        expect(repeatedWake.text == "Hello chat. What's for dinner?")
        repeatedWake.audioProcessed(seconds: 2.1)
        expect(repeatedWake.boundaryReached == .pause)
        let background = String(repeating: "background ", count: 130)
        var afterVideo = StartupSpeechBuffer(id: UUID(), text: background + "Hello chat", wakeRange: 130..<132, phrase: "Hello Chat", similar: true)
        _ = afterVideo.markVoiceOpened()
        afterVideo.observe(background + "Hello chat. Hello chat.")
        afterVideo.audioProcessed(seconds: 2.1)
        expect(!afterVideo.hasOpeningWords && afterVideo.boundaryReached == nil,
               "Earlier video speech must not count as opening words after a repeated wake")
        afterVideo.observe(background + "Hello chat. Hello chat. What's for dinner?")
        expect(afterVideo.hasOpeningWords && afterVideo.text == "Hello chat. What's for dinner?")
        var customRetry = StartupSpeechBuffer(id: UUID(), text: "Good morning computer. Good morning computer.", wakeRange: 0..<3, phrase: "Good morning computer", similar: false)
        _ = customRetry.markVoiceOpened()
        customRetry.audioProcessed(seconds: 2.1)
        expect(customRetry.boundaryReached == nil, "Custom wake retries use the same opening rule")
        customRetry.audioProcessed(seconds: 28)
        expect(customRetry.boundaryReached == .limit, "Wake-only capture retains the existing hard bound")
        var aliasRetry = StartupSpeechBuffer(id: UUID(), text: "HelloChat. Hullo chad.", wakeRange: 0..<1, phrase: "Hello Chat", similar: true)
        _ = aliasRetry.markVoiceOpened(); aliasRetry.audioProcessed(seconds: 2.1)
        expect(!aliasRetry.hasOpeningWords && aliasRetry.boundaryReached == nil, "Known wake spellings must not impersonate opening words")

        let eventLog = StartupEventLog()
        let traceDirectory = root.appendingPathComponent("trace-\(UUID().uuidString)")
        let traced = StartupSpeechFile(directory: traceDirectory, onEvent: { eventLog.append($0) })
        let traceID = UUID(), readerID = UUID(), traceTime = Date()
        expect(await traced.begin(id: traceID, text: "private opening words", truncated: false, at: traceTime))
        traced.update(id: traceID, text: "private opening words extended", truncated: true, boundary: .pause)
        await traced.flush()
        expect(try traced.consume(voiceCreatedAt: traceTime, threadID: readerID).status == "speech")
        let events = eventLog.snapshot
        expect(events.map(\.operation) == [.begin, .write, .read])
        expect(events.last?.reader == readerID && events.last?.request == traceID && events.last?.revision == 1)
        expect(events.allSatisfy { $0.elapsedMS >= 0 && $0.elapsedMS.isFinite })
        for event in events {
            let metadata = try JSONSerialization.data(withJSONObject: ["event": event.name, "numbers": event.numbers, "info": event.info])
            expect(!String(decoding: metadata, as: UTF8.self).contains("private opening"), "Diagnostic events must never contain captured words")
        }
        try FileManager.default.removeItem(at: traceDirectory)
        print("Startup retry: repeated/custom/alias wake greetings wait for content; metadata-only producer/read traces passed")

        var noWords = StartupSpeechBuffer(id: UUID(), text: "Hello chat", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = noWords.markVoiceOpened()
        noWords.audioProcessed(seconds: StartupSpeechBuffer.openLimitSeconds)
        expect(noWords.boundaryReached == .limit, "An empty opening still has a hard bound")

        var long = StartupSpeechBuffer(id: UUID(), text: "Hello chat", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = long.markVoiceOpened()
        var spoken = "Hello chat", frames = 0
        while long.boundaryReached == nil {
            long.speechResumed(); long.audioProcessed(seconds: 0.085); frames += 1
            if frames % 6 == 0 { spoken += " word\(frames)"; long.observe(spoken) }
            expect(frames < 1_000, "Continuous recognised sound must still end")
        }
        expect(long.boundaryReached == .limit && long.openSeconds >= StartupSpeechBuffer.openLimitSeconds
               && long.openSeconds < StartupSpeechBuffer.openLimitSeconds + 0.1)
        expect(long.text.hasPrefix("word6 word12 ") && long.text.hasSuffix(" word\(frames - frames % 6)"),
               "Long noisy speech before the limit is kept whole")

        var shifting = StartupSpeechBuffer(id: UUID(), text: "Hello chat open the", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = shifting.markVoiceOpened()
        shifting.audioProcessed(seconds: 1.5)
        shifting.observe("Okay so open the calendar")
        shifting.audioProcessed(seconds: 1.5)
        expect(shifting.boundaryReached == nil && shifting.text == "open the", "An unaligned revision is still recognizer activity")

        var resetting = StartupSpeechBuffer(id: UUID(), text: "Hello chat set a timer", wakeRange: 0..<2, phrase: "Hello Chat", similar: true)
        _ = resetting.markVoiceOpened()
        resetting.boundary(); resetting.observe("for ten minutes")
        expect(resetting.text == "set a timer for ten minutes" && resetting.boundaryReached == nil,
               "A recognizer context reset after opening continues the same request")
        resetting.audioProcessed(seconds: .nan); resetting.audioProcessed(seconds: -5); resetting.audioProcessed(seconds: .infinity)
        expect(resetting.openSeconds == 0, "Invalid frame durations are ignored")
        print("Startup boundaries: post-open pause, short pauses, launch quiet, 30 s limit, unaligned revisions and context resets passed")

        // The mailbox expires old captures. Start the shared timestamp after
        // the installer/recognition fixtures so slow CI setup doesn't age them.
        let now = Date()
        let first = UUID()
        expect(await store.begin(id: first, text: "", truncated: false, at: now))
        let emptyOpening = try store.consume(voiceCreatedAt: now, threadID: consumer)
        expect(emptyOpening.status == "capturing" && emptyOpening.request == nil)
        store.update(id: first, text: "this is a", truncated: false)
        await store.flush()
        let partial = try store.consume(voiceCreatedAt: now, threadID: consumer)
        expect(partial.status == "capturing" && partial.request?.text == "this is a" && partial.request?.phase == .capturing,
               "Reading a partial opening shows it, labelled capturing")
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).request?.text == "this is a", "Reading a partial opening must not consume it")
        store.update(id: first, text: "RequestPrefix: switch on the lamp.", truncated: false, boundary: .utterance)
        await store.flush()
        let delivery = try store.consume(voiceCreatedAt: now, threadID: consumer)
        expect(delivery.status == "speech" && delivery.request?.text == "RequestPrefix: switch on the lamp." && delivery.request?.boundary == .utterance)
        let pending = fixture.appendingPathComponent("pending.json")
        let receipt = try JSONDecoder().decode(StartupSpeechFile.Document.self, from: Data(contentsOf: pending))
        expect(receipt.phase == .consumed && receipt.text.isEmpty && receipt.claimedBy == consumer)
        let permissions = try FileManager.default.attributesOfItem(atPath: pending.path)[.posixPermissions] as! NSNumber
        expect(permissions.intValue == 0o600)
        store.update(id: first, text: "Late ASR result must never reappear", truncated: false, boundary: .utterance)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: UUID()).status == "empty")

        let second = UUID()
        expect(await store.begin(id: second, text: "The next request", truncated: false, at: now))
        store.update(id: second, text: "The next request", truncated: false, boundary: .utterance)
        store.update(id: first, text: "Old writer", truncated: false, boundary: .utterance); store.cancel(id: first)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now.addingTimeInterval(60), threadID: UUID()).status == "unrelated")
        // The same original coordinator can consume later; no arbitrary expiry
        // deletes a request which the user wanted retained until it is read.
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer, now: now.addingTimeInterval(3600)).request?.id == second)

        let cancelled = UUID()
        expect(await store.begin(id: cancelled, text: "Cancelled request", truncated: false, at: now))
        store.cancel(id: cancelled); store.update(id: cancelled, text: "Late cancel result", truncated: false)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "empty")

        let racing = UUID()
        expect(await store.begin(id: racing, text: "Read once", truncated: false, at: now))
        store.update(id: racing, text: "Read once", truncated: false, boundary: .utterance)
        await store.flush()
        let contenders = (0..<2).map { _ in Task.detached { try? store.consume(voiceCreatedAt: now, threadID: UUID()).status } }
        var winners = 0
        for contender in contenders { if await contender.value == "speech" { winners += 1 } }
        expect(winners == 1, "Concurrent consumers must deliver once")

        let locked = UUID()
        expect(await store.begin(id: locked, text: "Locked request", truncated: false, at: now))
        store.update(id: locked, text: "Locked request", truncated: false, boundary: .utterance)
        await store.flush()
        let lock = open(fixture.appendingPathComponent(".lock").path, O_RDWR)
        expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Busy lock was ignored") }
        catch { expect((error as NSError).code == Int(EWOULDBLOCK)) }
        flock(lock, LOCK_UN); close(lock)
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "speech")

        let contended = UUID()
        expect(await store.begin(id: contended, text: "", truncated: false, at: now))
        let readerLock = open(fixture.appendingPathComponent(".lock").path, O_RDWR)
        expect(readerLock >= 0 && flock(readerLock, LOCK_EX | LOCK_NB) == 0)
        // Model a reader holding the real cross-process file lock while the
        // final recognition result is queued. The production writer must keep it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.update(id: contended, text: "Complete despite a concurrent reader", truncated: false, boundary: .utterance)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                flock(readerLock, LOCK_UN); close(readerLock); done.resume()
            }
        }
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).request?.text == "Complete despite a concurrent reader", "A busy reader must not drop the final write")

        // Provisional reads: prompt, labelled, owned by one coordinator and never consumed.
        let provisional = UUID(), owner = UUID(), other = UUID()
        expect(await store.begin(id: provisional, text: "", truncated: false, at: now))
        var read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "capturing" && read.request == nil)
        store.update(id: provisional, text: "what is the", truncated: false)
        await store.flush()
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "capturing" && read.request?.id == provisional && read.request?.phase == .capturing
               && read.request?.text == "what is the" && read.request?.boundary == nil, "Recognised words are visible while capturing")
        let firstRevision = read.request?.revision ?? -1
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.request?.revision == firstRevision && read.request?.text == "what is the", "Repeated provisional reads return the same revision")
        expect(try store.consume(voiceCreatedAt: now, threadID: other).status == "claimed", "Another coordinator can't use an owned request")
        store.update(id: provisional, text: "what is the meaning of life?", truncated: false)
        await store.flush()
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        let correctedRevision = read.request?.revision ?? -1
        expect(read.request?.text == "what is the meaning of life?" && correctedRevision > firstRevision, "Corrections replace text and advance its revision")
        store.update(id: provisional, text: "what is the meaning of life?", truncated: false)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).request?.revision == correctedRevision, "An unchanged hypothesis isn't a new revision")
        store.update(id: provisional, text: "what is the meaning of life?", truncated: false, boundary: .pause)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: other).status == "claimed")
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "speech" && read.request?.id == provisional && read.request?.phase == .ready && read.request?.boundary == .pause
               && read.request?.revision == correctedRevision && read.request?.truncated == true,
               "A text-stability cutoff is a sealed prefix, not proof of a complete utterance")
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).status == "empty", "The final read happens once")

        let bounded = UUID()
        expect(await store.begin(id: bounded, text: "", truncated: false, at: now))
        store.update(id: bounded, text: "a long opening still going", truncated: false, boundary: .limit)
        await store.flush()
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "speech" && read.request?.boundary == .limit && read.request?.truncated == true, "A time-limited opening is labelled truncated")

        for boundary in StartupSpeechFile.Boundary.allCases {
            let request = UUID()
            expect(await store.begin(id: request, text: "opening words", truncated: false, at: now))
            store.update(id: request, text: "opening words", truncated: false, boundary: boundary)
            await store.flush()
            let result = try store.consume(voiceCreatedAt: now, threadID: owner)
            expect(result.request?.truncated == (boundary != .utterance),
                   "Only a recognizer utterance boundary may be presented without an incomplete-prefix warning")
            expect(result.request?.revision == 0, "Metadata-only finalization does not change the text revision")
        }

        let ended = UUID()
        expect(await store.begin(id: ended, text: "turn off", truncated: false, at: now))
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).request?.text == "turn off")
        store.cancel(id: ended); store.update(id: ended, text: "turn off everything", truncated: false, boundary: .utterance)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).status == "empty", "End cancels a provisionally read request")

        // Provisional and final readers racing the ready write deliver once.
        let racingFinal = UUID()
        expect(await store.begin(id: racingFinal, text: "deliver once", truncated: false, at: now))
        store.update(id: racingFinal, text: "deliver once", truncated: false, boundary: .utterance)
        let readers = (0..<6).map { _ in Task.detached { try? store.consume(voiceCreatedAt: now, threadID: owner) } }
        var finals = 0
        for reader in readers {
            guard let result = await reader.value else { continue }
            expect(["capturing", "speech", "empty"].contains(result.status))
            if result.status == "speech" { finals += 1; expect(result.request?.text == "deliver once") }
        }
        await store.flush()
        if try store.consume(voiceCreatedAt: now, threadID: owner).status == "speech" { finals += 1 }
        expect(finals == 1, "Racing reads deliver the final request exactly once")

        let contested = UUID()
        expect(await store.begin(id: contested, text: "one owner", truncated: false, at: now))
        let rivals = (0..<4).map { _ in UUID() }
        let attempts = rivals.map { rival in Task.detached { (rival, try? store.consume(voiceCreatedAt: now, threadID: rival)) } }
        var owners = Set<UUID>()
        for attempt in attempts {
            let (rival, result) = await attempt.value
            if result?.status == "capturing" { owners.insert(rival) }
            else { expect(result == nil || result?.status == "claimed") }
        }
        expect(owners.count <= 1, "Only one coordinator can own a request")

        // A new call replaces the request; the old coordinator, writer and claim can't reach it.
        let older = UUID(), newer = UUID(), newOwner = UUID()
        expect(await store.begin(id: older, text: "old words", truncated: false, at: now))
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).request?.id == older)
        expect(await store.begin(id: newer, text: "", truncated: false, at: now.addingTimeInterval(40)))
        store.update(id: older, text: "stale writer", truncated: false, boundary: .pause); store.cancel(id: older)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).status == "unrelated", "An earlier coordinator can't read the next call's request")
        read = try store.consume(voiceCreatedAt: now.addingTimeInterval(41), threadID: newOwner, now: now.addingTimeInterval(42))
        expect(read.status == "capturing" && read.request == nil, "A new request starts unclaimed and empty")
        store.update(id: newer, text: "new words", truncated: false)
        await store.flush()
        read = try store.consume(voiceCreatedAt: now.addingTimeInterval(41), threadID: newOwner, now: now.addingTimeInterval(43))
        expect(read.request?.id == newer && read.request?.text == "new words")

        // A capture left `capturing` by a stopped app is finalised once, labelled incomplete.
        let abandoned = UUID()
        expect(await store.begin(id: abandoned, text: "turn on the", truncated: false, at: now))
        read = try store.consume(voiceCreatedAt: now, threadID: owner, now: now.addingTimeInterval(StartupSpeechFile.abandonedAfter - 1))
        expect(read.status == "capturing")
        read = try store.consume(voiceCreatedAt: now, threadID: owner, now: now.addingTimeInterval(StartupSpeechFile.abandonedAfter + 1))
        expect(read.status == "speech" && read.request?.text == "turn on the" && read.request?.boundary == .interrupted
               && read.request?.truncated == true, "An abandoned capture is delivered once as an incomplete prefix")
        store.update(id: abandoned, text: "late live writer", truncated: false, boundary: .utterance)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: owner, now: now.addingTimeInterval(StartupSpeechFile.abandonedAfter + 2)).status == "empty",
               "A late writer can't resurrect a finalised capture")

        let burst = UUID()
        expect(await store.begin(id: burst, text: "", truncated: false, at: now))
        for index in 1...500 { store.update(id: burst, text: "word \(index)", truncated: false) }
        await store.flush()
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.request?.text == "word 500" && (read.request?.revision ?? 0) <= 500, "Bursts coalesce to the latest bounded text")

        // Format 1 stays compatible both ways: 1.0.6 documents decode here, and
        // a 1.0.6 reader ignores the optional revision/boundary keys.
        func writeRaw(_ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: pending)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        }
        let legacy: [String: Any] = ["formatVersion": 1, "id": UUID().uuidString, "requestedAt": now.timeIntervalSince1970,
                                     "updatedAt": now.timeIntervalSince1970, "phase": "capturing", "text": "legacy words", "truncated": false]
        try writeRaw(legacy)
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "capturing" && read.request?.text == "legacy words" && read.request?.revision == nil)
        var legacyReady = legacy; legacyReady["phase"] = "ready"
        try writeRaw(legacyReady)
        read = try store.consume(voiceCreatedAt: now, threadID: owner)
        expect(read.status == "speech" && read.request?.text == "legacy words" && read.request?.boundary == nil)
        struct LegacyDocument: Decodable {
            let formatVersion: Int; let id: UUID; let requestedAt: Double; let updatedAt: Double
            let phase: String; let text: String; let truncated: Bool; let claimedBy: UUID?
        }
        expect(await store.begin(id: UUID(), text: "new format", truncated: false, at: now))
        store.update(id: read.request!.id, text: "ignored old id", truncated: false)
        await store.flush()
        expect(try store.consume(voiceCreatedAt: now, threadID: owner).request?.text == "new format")
        let legacyView = try JSONDecoder().decode(LegacyDocument.self, from: Data(contentsOf: pending))
        expect(legacyView.formatVersion == 1 && legacyView.phase == "capturing" && legacyView.text == "new format" && legacyView.claimedBy == owner)
        print("Startup provisional reads: ownership, revisions, final read-once, limit, cancellation, races, replacement, abandonment, coalescing and format compatibility passed")

        // Repeated new calls must reuse the mailbox instead of retaining one
        // file/descriptor per request. A small allowance covers runtime caches;
        // a descriptor leak on the repeated path would grow by hundreds here.
        func openDescriptors() -> Int { (0..<256).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let descriptorsBefore = openDescriptors()
        for index in 0..<200 {
            let request = UUID(), created = Date()
            expect(await store.begin(id: request, text: "request \(index)", truncated: false, at: created))
            expect(try store.consume(voiceCreatedAt: created, threadID: owner).status == "capturing")
            store.update(id: request, text: "request \(index) finished", truncated: false, boundary: .utterance)
            await store.flush()
            expect(try store.consume(voiceCreatedAt: created, threadID: owner).status == "speech")
        }
        expect(openDescriptors() <= descriptorsBefore + 4, "Repeated calls must not accumulate file descriptors")
        expect(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.path)) == Set(["pending.json", ".lock"]),
               "Repeated calls must not accumulate temporary/request files")
        print("Startup resource bounds: 200 new-call cycles retained one mailbox and no descriptor growth")

        expect(await store.begin(id: UUID(), text: "Older unpublished request", truncated: false, at: now))
        // A grapheme can contain many bytes. Force the bounded file write to
        // fail and prove a new call cannot inherit the previous call's words.
        let tooManyBytes = String(repeating: "a" + String(repeating: "\u{0301}", count: 10), count: StartupSpeechFile.textLimit)
        expect(!(await store.begin(id: UUID(), text: tooManyBytes, truncated: false, at: now)))
        expect(try store.consume(voiceCreatedAt: now, threadID: consumer).status == "empty")

        func reject(_ data: Data) throws {
            try data.write(to: pending)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Malformed mailbox accepted") }
            catch { expect(error is CocoaError || error is DecodingError) }
        }
        try reject(Data("{broken".utf8))
        try reject(Data(repeating: 65, count: 65_537))
        try FileManager.default.removeItem(at: pending)
        let outside = root.appendingPathComponent("outside-\(UUID().uuidString).json")
        try Data("private outside content".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: outside)
        do { _ = try store.consume(voiceCreatedAt: now, threadID: consumer); fatalError("Symlink accepted") }
        catch { expect(error is CocoaError) }
        expect(try String(contentsOf: outside, encoding: .utf8) == "private outside content")
        print("Startup speech: revision, custom wake, boundaries, bounded text, read-once, overwrite, cancellation, stale-call, lock and malformed-file checks passed")
    }
}
