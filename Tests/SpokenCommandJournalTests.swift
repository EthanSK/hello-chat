import Foundation

@main enum SpokenCommandJournalTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--claim-fixture", let frame = UUID(uuidString: arguments[3]) {
            let journal = SpokenCommandJournal(directory: URL(fileURLWithPath: arguments[2]), now: { 1000 })
            let state = try journal.decide(action: "rewindFivePhrase", target: "", session: "concurrent",
                                           frame: frame, from: 998, through: 1000, allowFallback: true)
            print(state)
            return
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("HChat-command-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        var journal = SpokenCommandJournal(directory: path)
        journal.now = { 1000 }
        let frame = UUID(), session = "test-session"
        func decision(_ action: String, _ target: String = "", claim: Bool = false, id: UUID = frame) throws -> String {
            try journal.decide(action: action, target: target, session: session, frame: id, from: 997, through: 1002, allowFallback: claim)
        }
        func expect(_ value: String, _ other: String) { precondition(value == other, "Expected "+other+", got "+value) }
        let music = "pauseMusicPhrase"
        guard case .run(let receipt) = try journal.begin(music, target: "", session: session, at: 999) else { fatalError() }
        try expect(decision(music), "attempted")
        journal.finish(receipt, .submitted)
        try expect(decision(music, claim: true), "submitted")
        // The timestamped Spotify incident: the native press succeeded and teardown repeated.
        // Neither seeing that press nor processing the same handoff again grants another press.
        try expect(decision(music, claim: true), "submitted")
        try expect(decision(music, claim: true, id: UUID()), "ambiguous")
        try expect(decision("speakerOutput", "kitchen"), "missing")
        try expect(decision("speakerOutput", "kitchen", claim: true), "fallbackGranted")
        if case .run = try journal.begin("speakerOutput", target: "kitchen", session: session, at: 999) { fatalError("late duplicate") }
        try expect(decision("speakerOutput", "kitchen", claim: true), "alreadyClaimed")
        // A new later utterance, a different device and a different call retain their own ownership.
        for (target, call, at) in [("kitchen", session, 1005.0), ("other", session, 999), ("kitchen", "later", 999)] {
            if case .covered = try journal.begin("speakerOutput", target: target, session: call, at: at) { fatalError("unrelated command") }
        }
        guard case .run(let app) = try journal.begin("app", target: "codex", session: session, at: 999) else { fatalError() }
        journal.finish(app, .confirmed)
        try expect(decision("app", "chrome", claim: true), "ambiguous")
        try expect(decision("app", "codex"), "confirmed")
        try expect(decision("pauseVideoPhrase", claim: true), "ambiguous")
        // A distinct later utterance can reserve a directional browser fallback once.
        let videoFrame = UUID()
        func videoDecision() throws -> String {
            try journal.decide(action: "pauseVideoPhrase", target: "", session: session, frame: videoFrame,
                               from: 1000, through: 1002, allowFallback: true)
        }
        guard case .run(let video) = try journal.begin("pauseVideoPhrase", target: "", session: session, at: 1001) else { fatalError() }
        journal.finish(video, .failedBeforeDispatch)
        try expect(videoDecision(), "fallbackGranted")
        try expect(videoDecision(), "alreadyClaimed")
        try expect(journal.decide(action: music, target: "", session: session, frame: UUID(), from: 910, through: 915, allowFallback: true), "stale")
        guard case .run(let unidentified) = try journal.begin("showVoicePhrase", target: "", session: nil, at: 999) else { fatalError() }
        journal.finish(unidentified, .submitted)
        try expect(decision("showVoicePhrase", claim: true), "ambiguous")
        // Simultaneous coordinator handoffs and a late recognizer share the on-disk lock.
        var claimers: [(Process, Pipe)] = []
        let concurrentFrame = UUID()
        for _ in 0..<4 {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: arguments[0])
            child.arguments = ["--claim-fixture", path.path, concurrentFrame.uuidString]
            child.standardOutput = pipe
            try child.run()
            claimers.append((child, pipe))
        }
        let results = claimers.map { child, pipe in
            child.waitUntilExit()
            precondition(child.terminationStatus == 0)
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        precondition(results.filter { $0 == "fallbackGranted" }.count == 1 && results.filter { $0 == "alreadyClaimed" }.count == 3)
        if case .run = try journal.begin("rewindTenPhrase", target: "", session: "concurrent", at: 999) { fatalError("Late conflicting seek") }
        // Actual “Play video” followed by “Any updates Pause video”. The frame helper
        // passes this bounded interval; claim must return the completed native pause.
        let stamp = 1_795_389_041.885
        let mixed = SpokenCommandJournal(directory: journal.directory.appendingPathComponent("mixed"), now: { stamp + 1 })
        for (action, time) in [("playVideoPhrase", 1_795_389_031.119021), ("pauseVideoPhrase", 1_795_389_038.6439228)] {
            guard case .run(let id) = try mixed.begin(action, target: "", session: session, at: time) else { fatalError() }
            mixed.finish(id, .confirmed)
        }
        let handled = try mixed.decide(action: "pauseVideoPhrase", target: "", session: session, frame: UUID(),
                                       from: 1_795_389_037.393, through: stamp + 2, allowFallback: true)
        precondition(handled == "confirmed")
        let batch = SpokenCommandJournal(directory: path.appendingPathComponent("batch"), now: { 1000 })
        guard case .run(let batchID) = try batch.begin("zoomInPhrase", target: "", session: session, at: 999) else { fatalError() }
        func batchDecision(_ claim: Bool = true) throws -> String {
            try batch.decide(action: "zoomInPhrase", target: "", session: session, frame: frame, from: 998, through: 1001, allowFallback: claim)
        }
        for completed in 0..<5 {
            let entry = batch.progress(batchID, requested: 5, completed: completed, phase: .attempted)
            precondition(entry?.requestedCount == 5 && entry?.completedCount == completed)
            try expect(batchDecision(), "attempted")
        }
        batch.progress(batchID, requested: 5, completed: 5, phase: .submitted)
        try expect(batchDecision(), "submitted")
        batch.progress(batchID, requested: 5, completed: 2, phase: .failedBeforeDispatch)
        try expect(batchDecision(), "unknown")
        let data = try Data(contentsOf: path.appendingPathComponent("batch/recent.json"))
        let entries = try JSONDecoder().decode([SpokenCommandJournal.Entry].self, from: data)
        precondition(entries.count == 1)
        var batchTime = 1000.0
        let longBatch = SpokenCommandJournal(directory: path.appendingPathComponent("long-batch"), now: { batchTime })
        guard case .run(let longID) = try longBatch.begin("speakerOutput", target: "old-name", session: session, at: 999) else { fatalError() }
        precondition(longBatch.retarget(longID, to: "exact-device"))
        batchTime = 1170
        precondition(longBatch.progress(longID, requested: 100, completed: 10, phase: .attempted) != nil)
        batchTime = 1300
        precondition(longBatch.progress(longID, requested: 100, completed: 20, phase: .attempted)?.at == 999,
                     "Progress extends a long batch without changing the original speech timestamp")
        var clock = 1000.0
        let lease = SpokenCommandJournal(directory: path.appendingPathComponent("long-batch"), now: { clock })
        guard case .run(let leaseID) = try lease.begin("app", target: "chrome5", session: session, at: 999) else { fatalError() }
        precondition(lease.retarget(leaseID, to: "com.google.chrome"))
        for n in 0..<5 {
            clock = 1000 + Double(n * 100)
            precondition(lease.progress(leaseID, requested: 5, completed: n, phase: .attempted) != nil)
        }
        precondition(lease.progress(leaseID, requested: 5, completed: 5, phase: .confirmed)?.at == 999,
                     "Long batches retain the original spoken time while progress preserves ownership")
        print("Spoken commands: pending, confirmed, submitted, missed, late recognition, retry, wrong target, repeat, batch ownership and stale checks passed")
    }
}
