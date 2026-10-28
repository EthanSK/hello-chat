import Foundation

@main enum CoreTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    static func main() throws {
        for phrase in ["Bye Chat", "ByeChat", "bye chad", "by chat", "bychat", "Byte Chat", "ByteChat", "B-Y Chat", "B Y Chat", "B.Y. Chat", "buy chat", "by charts", "Bye Charts", "Buy Charts", "ByteCharts", "by chats", "bye chart"] {
            var endMatcher = PhraseMatcher()
            check(endMatcher.consume(phrase, wake: "Hey Chat", sleep: "Bye Chat", similar: true) == .sleep, "Configured Bye Chat end phrase: \(phrase)")
        }
        for phrase in ["byte charity", "by charity", "he chat"] {
            var endMatcher = PhraseMatcher()
            check(endMatcher.consume(phrase, wake: "Hey Chat", sleep: "Bye Chat", similar: true) == nil, "End homophone support keeps wake and name boundaries: \(phrase)")
        }
        check(!PhraseMatcher.equivalent("Byte Chat", to: "Bye Chat", similar: false, allowEndAddressEdit: true), "Exact mode still excludes homophones")
        check(!PhraseMatcher.equivalent("Byte Chat", to: "Bye Chat", similar: true), "End homophones must not broaden wake matching")
        for phrase in ["UI Chat", "UIChat", "U-I Chat", "U I C H A T", "by chad", "bye chaz",
                       "buy chatt", "bai charts", "bi chat", "boy chat", "good bye chat", "goodbye chad",
                       "good buy charts", "B Y E C H A T", "Bye bye Chat", "byee chat"] {
            var end = PhraseMatcher()
            check(end.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .sleep, "Broad end spelling: \(phrase)")
            check(end.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "No repeated end from same words")
        }
        for phrase in ["Helo Chat", "Hallo Chad", "Hullo Chart", "Hello chats", "Helloo Chatt",
                       "Hlelo Chta", "Halo Chat", "Yellow Chat", "Yello Chad", "Ello Chat", "A low Chat",
                       "Hey low Chat", "HelloChat", "Hi Chat", "Hey Chat", "Hiya Chat", "H E L L O C H A T"] {
            var wake = PhraseMatcher()
            check(wake.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "Broad wake spelling: \(phrase)")
        }
        for phrase in ["Hello cat", "Hello hat", "Hello that", "Hello shat", "Hello shut", "Hello chads",
                       "Hellow shot", "Holla Chat", "Hola Chat", "Yelloo Chet", "Oh hello Chat",
                       "Hello charts", "Hello chance", "hello charity", "hello chatter", "Hello chocolate",
                       "hello ch", "HelloChance", "As well chat", "aswellchat", "azwellchat"] {
            var wake = PhraseMatcher()
            check(wake.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake,
                  "Sensitivity-first default wake: \(phrase)")
        }
        for phrase in ["Pie Chat", "Bite Chat", "Good boy charts", "Bye shad", "Buoy Chat", "buh bye chat",
                       "bye hat", "buy cats", "good bye chads", "gudbuychat", "B Y E C H A T", "by the charts"] {
            var end = PhraseMatcher()
            check(end.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .sleep,
                  "Sensitivity-first default end: \(phrase)")
        }
        var contextual = PhraseMatcher()
        check(contextual.consume("as well chat", wake: "", sleep: "Bye Chat", similar: true) == nil,
              "The screenshot phrase must never accidentally end a request")
        check(contextual.consume("do that as well chat", wake: "", sleep: "Bye Chat", similar: true) == nil,
              "An ordinary as well Chat request cannot end Voice")
        var customEnd = PhraseMatcher()
        check(customEnd.consume("as well chat", wake: "Computer Listen", sleep: "As Well Chat") == .sleep,
              "An exact custom end remains explicit even when its words are a contextual default alias")
        check(!PhraseMatcher.equivalent("hello that", to: "Hello Chat", similar: false), "Exact mode stays exact")
        check(!PhraseMatcher.equivalent("hello chance", to: "Hello Chat", similar: false), "Exact mode excludes the new prefix")
        check(!PhraseMatcher.equivalent("hello chance", to: "Hey Chat", similar: true), "The prefix is limited to the default wake phrase")
        check(!PhraseMatcher.equivalent("bye chance", to: "Bye Chat", similar: true, allowEndAddressEdit: true), "Chance cannot end Voice")
        check(PhraseMatcher.matchKind("hello chance", to: "Hello Chat", similar: true) == .dictionary, "The observed wake uses dictionary highlighting")
        check(!PhraseMatcher.equivalent("as well chat", to: "Computer Listen", similar: true), "Custom phrases keep their scope")
        check(!PhraseMatcher.isWeakWakeVariant("aswellthat"), "Ordinary as well that must not become a weak command")
        let variants = PhraseMatcher.defaultVariantCounts
        check(variants.wake > 5000 && variants.end > 5000, "Large dictionaries are composed from bounded components")
        check(!PhraseMatcher.defaultVariantsOverlap, "Wake and end dictionaries must be disjoint")
        print("Default dictionary: \(variants.wake) wake, \(variants.end) end, \(variants.weakWake) weak-wake compact spellings")
        for phrase in ["he'll chat", "he’ll chat", "hell chat", "hellchat", "he'll chats", "he'll chad", "he'll chart",
                       "help chat", "yellow chair", "yellow chance", "hello Janet", "make a pie chart",
                       "bar charts", "why chat", "by that", "bye that", "buy that", "my chat", "we chat",
                       "be that", "you don't need to be that good at what you do",
                       "allow chat", "hi hat", "high hat", "yellow hats", "buy hats",
                       "how are you", "buy a chart", "by chance", "bye chance", "UI settings", "just chat"] {
            var none = PhraseMatcher()
            check(none.consume(phrase, wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "Keep two recognizable command parts: \(phrase)")
        }
        var nested = PhraseMatcher()
        check(nested.consume("good bye chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .sleep, "Good bye is one end")
        check(nested.consume("goodbye chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "Joined revision must not replay")
        check(nested.consume("goodbye chat bye chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .sleep, "Nested alias must not swallow the next genuine end")
        check(PhraseMatcher.matches(in: PhraseMatcher.words("good bye chat"), phrase: "Bye Chat", similar: true, ending: true).count == 1, "No overlapping command occurrences")
        var revised = PhraseMatcher()
        check(revised.consume("hello chance", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "Observed mishearing wakes")
        check(revised.consume("hello change", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "A CH-word revision must not replay the wake")
        check(revised.consume("hello change hello chocolate", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "A later CH-word greeting remains a new wake")
        revised.reset()
        check(revised.consume("ok hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "Initial progressive wake")
        check(revised.consume("okay hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "A revised prefix must not replay wake")
        check(revised.consume("okay hello chat hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "A later repeated wake remains a new command")
        revised.reset()
        check(revised.consume("ok hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "Initial before combined revision and append")
        check(revised.consume("okay hello chat hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == .wake, "Prefix revision plus a new repeated wake must emit the later wake")
        check(revised.consume("okay hello chat hello chat", wake: "Hello Chat", sleep: "Bye Chat", similar: true) == nil, "Repeated revised transcript cannot replay")
        var matcher = PhraseMatcher()
        check(matcher.consume("Hey, CHAT!", wake: "Hey Chat", sleep: "Thanks Chat") == .wake, "Wake punctuation and case")
        check(matcher.consume("Hey Chat tell me", wake: "Hey Chat", sleep: "Thanks Chat") == nil, "Repeated partial does not repeat command")
        check(matcher.consume("Hey Chat tell me thanks chat", wake: "Hey Chat", sleep: "Thanks Chat") == .sleep, "Later mute in same transcript")
        matcher.reset()
        check(matcher.consume("hey chatter", wake: "Hey Chat", sleep: "Thanks Chat") == nil, "No substring wake")
        check(matcher.consume("hey chat thanks chat", wake: "Hey Chat", sleep: "Thanks Chat") == .sleep, "Latest command wins")
        matcher.reset()
        check(matcher.consume("hey chat", wake: "Hey Chat", sleep: "Thanks Chat") == .wake, "New speech session can wake again")
        matcher.reset()
        check(matcher.consume("HeyChat", wake: "Hey Chat", sleep: "Thanks Chat") == .wake, "Joined wake phrase")
        check(matcher.consume("Hey Chat", wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == nil, "Spacing revision cannot repeat a command")
        check(matcher.consume("Hey Chat thankschat", wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == .sleep, "Joined end phrase after wake")
        for positive in ["hey chad", "hey chatt", "hey chta", "Hey, CHAD!", "hey c hat", "hi chat", "HiChat", "hay chat"] {
            matcher.reset()
            check(matcher.consume(positive, wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == .wake, "Small spelling difference: \(positive)")
        }
        for negative in ["hi Charles", "hi chad", "hay cat", "HR", "hey that", "hey cat", "hey Janet", "hey chatter", "chat", "thanks that", "the chat", "hey charity"] {
            matcher.reset()
            check(matcher.consume(negative, wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == nil, "Reject unrelated speech: \(negative)")
        }
        matcher.reset()
        check(PhraseMatcher.equivalent("hi chat", to: "Hey Chat", similar: false) == false, "Exact mode rejects alternate address")
        check(matcher.consume("Hey Chad", wake: "Hey Chat", sleep: "Thanks Chat", similar: false) == nil, "Exact mode remains available")
        check(matcher.consume("Hey Chad", wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == .wake, "Fuzzy wake after exact miss")
        check(matcher.consume("Hey Chatt", wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == nil, "A revised spelling at the same start cannot trigger twice")
        check(matcher.consume("Hey Chatt tell me thanks chad", wake: "Hey Chat", sleep: "Thanks Chat", similar: true) == .sleep, "Fuzzy end after earlier wake")
        check(GateDecision.set(.muted, current: nil) == .unavailable, "Unknown state never toggles")
        check(GateDecision.set(.listening, current: nil) == .unavailable, "Unknown wake never toggles")
        check(GateDecision.set(.muted, current: .muted) == .unchanged, "Already muted stays muted")
        check(GateDecision.set(.listening, current: .muted) == .toggle, "Known muted can unmute")
        check(MicrophoneState.accessibilityLabel("Unmute microphone") == .muted, "Muted desktop Voice control")
        check(MicrophoneState.accessibilityLabel("Mute microphone") == .listening, "Listening desktop Voice control")
        check(MicrophoneState.accessibilityLabel("Turn on microphone") == .muted, "Muted integrated Voice control")
        check(MicrophoneState.accessibilityLabel("Turn off microphone") == .listening, "Listening integrated Voice control")
        check(MicrophoneState.accessibilityLabel("  TURN ON MICROPHONE\n") == .muted, "Normalize accessibility labels")
        check(MicrophoneState.accessibilityLabel("Unmute speakers") == nil, "Speaker control cannot authorize microphone toggle")
        check(MicrophoneState.accessibilityLabel("Turn on microphone for this app") == nil, "Unrelated text cannot authorize microphone toggle")
        check(VoiceBridge.isEndVoiceLabel("End Voice"), "Native integrated end action")
        check(VoiceBridge.isEndVoiceLabel("End voice chat"), "Native composer end action")
        check(VoiceBridge.isEndVoiceLabel("Stop voice chat"), "Native floating end action")
        check(!VoiceBridge.isEndVoiceLabel("Start voice chat"), "An end action must never start Voice")
        var ownership = MicrophoneOwnership()
        ownership.confirmed(.listening)
        check(!ownership.ownsUnmute, "A pre-existing listening call does not belong to Hey Chat")
        ownership.willToggle(to: .muted)
        check(!ownership.ownsUnmute, "A failed initial mute does not claim the user's call")
        ownership.willToggle(to: .listening)
        check(ownership.ownsUnmute, "An unmute attempt retains cleanup ownership until confirmed muted")
        ownership.confirmed(.muted)
        check(!ownership.ownsUnmute, "A confirmed mute releases unmute ownership")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeyChatTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bindings = root.appendingPathComponent("keybindings.json")
        let recovery = root.appendingPathComponent("recovery.json")
        let previous: [[String: String]] = [
            ["command": VoiceBridge.startCommand, "key": "Command+Control+Option+Shift+F17"],
            ["command": VoiceBridge.muteCommand, "key": "Command+Control+Option+Shift+F20"],
            ["command": "unrelated", "key": "Command+J"]
        ]
        func write(_ value: [[String: String]]) throws { try JSONSerialization.data(withJSONObject: value).write(to: bindings) }
        func read() throws -> [[String: String]] { try JSONSerialization.jsonObject(with: Data(contentsOf: bindings)) as! [[String: String]] }
        try write(previous)
        let lease = ShortcutLease(bindingsURL: bindings, recoveryURL: recovery)
        try lease.acquire()
        check(lease.deliveryKey == previous[1]["key"], "Keep the desktop's registered shortcut while leasing the file")
        var current = try read()
        check(current.contains(["command": VoiceBridge.muteCommand, "key": VoiceBridge.privateMuteKey]), "Reserve private shortcut")
        check(!current.contains(previous[1]), "Agent Flow binding absent during ownership")
        current.append(["command": "userAdded", "key": "Command+K"])
        try write(current)
        try ShortcutLease(bindingsURL: bindings, recoveryURL: recovery).restore()
        current = try read()
        check(current.contains(previous[1]), "Crash recovery restores previous mute binding")
        check(current.contains(["command": "userAdded", "key": "Command+K"]), "Preserve unrelated user edits")
        check(!FileManager.default.fileExists(atPath: recovery.path), "Recovery receipt cleared")
        try lease.acquire()
        current = try read().map { $0["command"] == VoiceBridge.muteCommand ? ["command": VoiceBridge.muteCommand, "key": "Command+M"] : $0 }
        try write(current)
        try lease.restore()
        check(lease.deliveryKey == nil, "Release the registered shortcut after restoration")
        current = try read()
        check(current.contains(["command": VoiceBridge.muteCommand, "key": "Command+M"]), "Respect edited mute binding")
        try write(previous + [["command": "userReserved", "key": VoiceBridge.privateMuteKey]])
        let before = try Data(contentsOf: bindings)
        do { try lease.acquire(); fatalError("Must reject shortcut collision") } catch is BridgeError { checks += 1 }
        let afterCollision = try Data(contentsOf: bindings)
        check(afterCollision == before, "Collision leaves user file unchanged")
        print("Passed \(checks) checks: phrase boundaries, duplicate recognition, safe mute decisions, shortcut ownership and recovery.")
    }
}
