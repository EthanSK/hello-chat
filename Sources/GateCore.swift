import Foundation

enum MicrophoneState: String, Codable {
    case muted, listening

    // Both desktop Voice presentations label the action the button will perform.
    // Keep exact matches so speaker controls or unrelated text cannot authorize a toggle.
    static func accessibilityLabel(_ label: String) -> MicrophoneState? {
        switch label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "unmute microphone", "turn on microphone": return .muted
        case "mute microphone", "turn off microphone": return .listening
        default: return nil
        }
    }
}
enum PhraseCommand: Equatable { case wake, sleep }

struct MicrophoneOwnership {
    private(set) var ownsUnmute = false
    mutating func willToggle(to target: MicrophoneState) {
        if target == .listening { ownsUnmute = true }
    }
    mutating func confirmed(_ state: MicrophoneState) {
        if state == .muted { ownsUnmute = false }
    }
}

struct PhraseMatcher {
    enum MatchKind: String { case exact, dictionary, fuzzy }
    static let microphonePhrases = ["mute chat", "silent chat", "silence chat"] // Shared by detection and transcript highlighting; no fuzzy microphone aliases.

    // Presentation uses the same acceptance rules as command detection. A
    // highlighted phrase is a textual match, not proof a Voice action ran.
    static func matchKind(_ candidate: String, to phrase: String, similar: Bool,
                          ending: Bool = false) -> MatchKind? {
        guard equivalent(candidate, to: phrase, similar: similar, allowEndAddressEdit: ending) else { return nil }
        let expected = words(phrase)
        if words(candidate).joined() == expected.joined() { return .exact }
        if (!ending && expected == ["hello", "chat"]) || (ending && expected == ["bye", "chat"]) {
            return .dictionary
        }
        return .fuzzy
    }
    // Shared local command dictionary. Ethan calls the helper H Chat and
    // discusses the End command as B Chat; those names must stay inert.
    // Normalize spacing first so joined words and spelled-out letters work too.
    // Ethan now says "Hey Chat" when talking about the app, so Hey/Hay/Hei
    // addresses are deliberately absent; "Hey Chat" must never wake (1 Nov).
    private static let helloAddresses: Set<String> = [
        "hello", "helo", "hellow", "helloh", "hellou", "hallo", "halloo", "hullo", "hulo",
        "halo", "hollow", "yellow", "yello", "ello", "alo", "allo", "alow", "heylow",
        "hiya", "ohhello",
        "helow", "helloo", "hellooo", "helllo", "heello", "heelo", "helloe", "hella",
        "halloh", "hallou", "hallooo", "halow", "halou", "haloo", "hollo", "hillo",
        "hulloh", "hullooo", "hulow", "hullow", "herlo", "herlow", "hurlo", "hallow",
        "heylo", "haylo", "haylow", "heylow", "hailo", "yelo", "yelloh", "yelloo",
        "eloh", "elo", "elloh", "elloo", "elow", "alloh", "alloo", "aloo", "allow",
        "ahlo", "ahllo", "ohlo", "hola", "ola", "ohla", "holla", "holler",
        "hai", "heh", "hiyah", "haya", "hiyaa",
        "ohello", "wellhello", "whyhello", "hellohello",
        "hilo", "hilow", "hiloh", "hiloe", "uhlo", "uhlow", "ahlow", "helllow", "harlow",
        "ullo", "ulow", "ulo", "ullow", "erlo", "arlo", "orlo", "arlow", "aloe", "ellough"
    ]
    private static let byeAddresses: Set<String> = [
        "bye", "by", "buy", "byte", "bi", "bai", "bhai", "boy", "boi",
        "byebye", "byby", "buybuy", "goodbye", "goodby", "goodbuy", "goodbi", "goodbai",
        "byeey", "byee", "byeee", "byy", "baye", "bay", "bey", "bie",
        "bei", "baye", "baai", "baay", "bahye", "beye", "bhy", "bii", "buyy",
        "beye", "bigh", "bite", "bight", "bhye", "bhaiy", "baii", "boey",
        "pie", "pye", "pai", "pi", "y", "vai", "vie", "vy",
        "byebuy", "buybye", "byebai", "byeboy", "byebee", "byebye", "byebyebye",
        "goodbyee", "goodbyeee", "goodbay", "goodboy", "goodbite", "goodbey", "goodbie",
        "gudbye", "gudby", "gudbuy", "gudbai", "godbye", "godby", "godbuy",
        "buoy", "bubye", "buhbye", "bubai", "bubuy", "buhby", "bah", "buh", "baibye", "byeby"
    ]
    private static let chatNames: Set<String> = [
        "chat", "chad", "chatt", "chats", "chart", "charts", "chet", "chit",
        "chads", "chatts", "chard", "chards", "chaz", "chaat", "chaht", "chate",
        "chett", "chut", "chutt", "chot", "chott", "chert", "chirt", "cheat",
        "chatgpt", "chatgbt", "chatgpd", "chatgtp", "chants"
    ]
    // Build the large dictionary once, not on each audio frame: components
    // cover joined/spelled words and phonetic names. Names must keep Chat's
    // "ch" start. Ethan found the old sh/cat/hat/that names too lenient on
    // 1 Nov: "UI shit" highlighted as Bye Chat, and one-edit names such as
    // "what" let "by what" end a call. Don't re-add them. Exact mode and
    // custom phrases retain their existing narrower rules.
    private static let expandedNames = chatNames.union(oneEdits("chat").filter { $0.hasPrefix("ch") })
    // Ethan heard "hello chance" when addressing Hello Chat. Keep this
    // observed alias wake-only; "bye chance" must not end a conversation.
    private static let observedWakeVariants: Set<String> = ["hellochance"]
    private static let wakeVariants = combinations(
        // "he'll chat" normalizes to hellchat. Ethan's unwanted launch at
        // 21:49:34 on 27 October reproduced through the generated "hell"
        // address. Exclude it here and reject the normalized phrases below:
        // other generated component splits (hellc + hat) can produce them too.
        helloAddresses.union(oneEdits("hello").filter { $0.hasPrefix("h") && $0 != "hell" }), expandedNames)
        .union(observedWakeVariants)
    // B Chat includes the likely "be" / "bee" recognition spellings. The old
    // UI alias also matched ordinary references to a user-interface chat.
    // Subtract after expansion so generated edits cannot reintroduce either.
    private static let safeDiscussionVariants = combinations(["b", "be", "bee", "ui", "uai"], expandedNames)
    private static let endVariants = combinations(
        byeAddresses.union(oneEdits("bye").filter { $0.hasPrefix("b") && $0.count >= 2 }), expandedNames)
        .subtracting(safeDiscussionVariants)
    // "as well chat" is Ethan's screenshot/log example. Opus's phonetic
    // suggestion favours Hello, not Bye; a closing alias would interrupt
    // ordinary "do that as well, Chat" requests. Keep this wake-only.
    private static let weakWakeVariants = combinations(
        ["aswell", "aswel", "azwell", "aswelll"],
        ["chat", "chats", "chad", "chatt"])
    private static let observedEndVariants: Set<String> = ["bythecharts"]
    private static let ordinaryWakePhrases: Set<String> = [
        "allowchat", "hihat", "hihats", "highhat", "highhats", "yellowhat", "yellowhats", "hellnochat",
        // "High at" joins to highat, which the generated dictionary can split
        // as hi + ghat (a one-letter Chat edit). Keep ordinary speech excluded
        // here so wake detection and phrase highlighting use the same rule.
        "highat",
        "hellchat", "hellchats", "hellchad", "hellchatt", "hellchart", "hellcharts"]
    // Ethan reported saying Bye Chat; recognition saved High Chat and opened Voice.
    // Hi/High must not be implicit Hello aliases. Keep the guard in the shared
    // matcher so highlighting agrees, while an explicit custom Hi/High phrase
    // still follows the normal exact/custom rules below.
    private static let excludedShortGreetings = combinations(["hi", "high", "ohhi", "hihi"], expandedNames)
    private static let ordinaryEndPhrases: Set<String> = [
        "piechart", "piecharts", "barchart", "barcharts", "bythat", "byethat", "buythat",
        "mychat", "whychat", "viachat", "wechat", "buyhats", "bethat"]
    static var defaultVariantCounts: (wake: Int, end: Int, weakWake: Int) {
        (wakeVariants.union(weakWakeVariants).subtracting(ordinaryWakePhrases).subtracting(excludedShortGreetings).count,
         endVariants.union(observedEndVariants).subtracting(ordinaryEndPhrases).count, weakWakeVariants.count)
    }
    static var defaultVariantsOverlap: Bool {
        !wakeVariants.union(weakWakeVariants).isDisjoint(with: endVariants.union(observedEndVariants))
    }
    private static let maximumDefaultSpan = max(
        wakeVariants.map(\.count).max() ?? 9, endVariants.map(\.count).max() ?? 9)
    private static func combinations(_ addresses: Set<String>, _ names: Set<String>) -> Set<String> {
        Set(addresses.flatMap { address in names.map { address + $0 } })
    }
    private static func oneEdits(_ word: String) -> Set<String> {
        let chars = Array(word), alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var result: Set<String> = [word]
        for index in chars.indices {
            var deleted = chars; deleted.remove(at: index); result.insert(String(deleted))
            for letter in alphabet {
                var replaced = chars; replaced[index] = letter; result.insert(String(replaced))
            }
            if index + 1 < chars.count {
                var swapped = chars; swapped.swapAt(index, index + 1); result.insert(String(swapped))
            }
        }
        for index in 0...chars.count {
            for letter in alphabet {
                var inserted = chars; inserted.insert(letter, at: index); result.insert(String(inserted))
            }
        }
        return result
    }
    static func isWeakWakeVariant(_ candidate: String) -> Bool {
        weakWakeVariants.contains(candidate)
    }
    private var consumedWakes = 0
    private var consumedEnds = 0
    mutating func reset() { consumedWakes = 0; consumedEnds = 0 }
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func equivalent(_ candidate: String, to phrase: String, similar: Bool, allowEndAddressEdit: Bool = false) -> Bool {
        let expected = words(phrase), actual = words(candidate).joined()
        return equivalentCompact(actual, expected: expected, compact: expected.joined(), similar: similar, allowEndAddressEdit: allowEndAddressEdit)
    }
    private static func equivalentCompact(_ actual: String, expected: [String], compact: String, similar: Bool, allowEndAddressEdit: Bool) -> Bool {
        if actual == compact { return !compact.isEmpty }
        if similar, expected == ["hello", "chat"], !allowEndAddressEdit {
            // Ethan wants "hello" followed by any word beginning C H to wake.
            // The existing compact form also preserves joined/spelled variants.
            return !ordinaryWakePhrases.contains(actual) && !excludedShortGreetings.contains(actual) &&
                (wakeVariants.contains(actual) || weakWakeVariants.contains(actual) || actual.hasPrefix("helloch"))
        }
        if similar, expected == ["bye", "chat"], allowEndAddressEdit {
            return !ordinaryEndPhrases.contains(actual) && (endVariants.contains(actual) || observedEndVariants.contains(actual))
        }
        // Keep the address and the start of the name intact. A single spelling
        // edit can cover Chat/Chad/Chatt without accepting HR, Hey that or Hey cat.
        guard similar, expected.count >= 2, let last = expected.last, last.count >= 4 else { return false }
        // Ethan's "ByteChat" / "B-Y chat" refer to the Bye Chat end command.
        // Accept speech-to-text homophones only for Bye, with the full saved
        // name intact; do not broaden wake phrases or exact matching mode.
        if allowEndAddressEdit, expected.count == 2, expected[0] == "bye",
           ["by", "byte", "buy"].contains(where: { actual == $0 + last }) { return true }
        // Ethan's repeated "by charts" / "by chats" are confirmed mishearings
        // of Bye Chat. Keep this end-only dictionary specific to that name.
        if allowEndAddressEdit, expected == ["bye", "chat"],
           ["bye", "by", "byte", "buy"].contains(where: { address in
               ["chart", "charts", "chats"].contains { actual == address + $0 }
           }) { return true }
        // Local short-phrase recognition can spell the spoken address Hi/Hay.
        // Only allow those addresses with the exact saved name, in fuzzy mode.
        if !allowEndAddressEdit, expected.count == 2, expected[0] == "hey",
           ["hi" + last, "hay" + last].contains(actual) { return true }
        let anchor = expected.dropLast().joined() + last.prefix(2)
        if actual.hasPrefix(anchor) { return oneEditApart(Array(actual), Array(compact)) }
        // End phrases may contain a short homophone such as Bye/By. Keep the
        // complete name and address prefix, and still allow only one total edit.
        guard allowEndAddressEdit, expected.count == 2, let first = expected.first,
              first.count >= 2, actual.hasPrefix(first.prefix(2)), actual.hasSuffix(last) else { return false }
        return oneEditApart(Array(actual), Array(compact))
    }
    private static func oneEditApart(_ a: [Character], _ b: [Character]) -> Bool {
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if a.count == b.count {
                if i + 1 < a.count, j + 1 < b.count, a[i] == b[j + 1], a[i + 1] == b[j] { i += 2; j += 2 }
                else { i += 1; j += 1 }
            } else if a.count > b.count { i += 1 } else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
    static func matches(in tokens: [String], phrase: String, similar: Bool, ending: Bool = false,
                        timings: [(word: String, start: Double, end: Double)]? = nil) -> [(start: Int, end: Int)] {
        let expected = words(phrase)
        guard !expected.isEmpty else { return [] }
        let compact = expected.joined()
        let common = similar && (expected == ["hello", "chat"] && !ending || expected == ["bye", "chat"] && ending)
        let maxSpan = common ? maximumDefaultSpan : expected.count + 1
        var result: [(start: Int, end: Int)] = [], start = 0
        while start < tokens.count {
            var found = false
            var candidate = ""
            for length in 1...min(maxSpan, tokens.count - start) {
                let end = start + length
                // Tokens are already normalized; don't tokenize the growing
                // candidate and saved phrase again for every possible span.
                candidate += tokens[end - 1]
                guard equivalentCompact(candidate, expected: expected, compact: compact,
                                        similar: similar, allowEndAddressEdit: ending) else { continue }
                guard closeInTime(start: start, end: end, tokens: tokens, timings: timings) else { continue }
                result.append((start, end)); start = end; found = true; break
            }
            // "Good bye Chat" must be one command, not a second nested "bye Chat".
            if !found { start += 1 }
        }
        return result
    }
    // Ethan's "hello ... much later ... chat" must not become a command.
    // These are model audio timestamps when exposed, with observed revision
    // times as fallback. No wait is added after a naturally spoken phrase.
    static func closeInTime(start: Int, end: Int, tokens: [String],
                            timings: [(word: String, start: Double, end: Double)]?) -> Bool {
        guard let timings else { return true } // Text-only callers have no audio clock.
        guard timings.map(\.word) == tokens, start >= 0, end <= timings.count, start < end else { return false }
        let phrase = timings[start..<end]
        guard phrase.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              let first = phrase.first, let last = phrase.last,
              last.end - first.start <= max(3, Double(end - start) * 1.5) else { return false }
        for index in (start + 1)..<end {
            guard timings[index].start >= timings[index - 1].start,
                  timings[index].start - timings[index - 1].end <= 1.5 else { return false }
        }
        return true
    }
    // While Ethan dictates into Agent Flow, only a standalone "ByteChat" /
    // "by chat" (including repetitions) may interrupt Voice. Talking about
    // the phrase must not end the call. Reuse the same dictionary as detection.
    static func isStandaloneEnd(_ text: String, phrase: String, similar: Bool,
                                timings: [(word: String, start: Double, end: Double)]? = nil) -> Bool {
        let tokens = words(text)
        guard !tokens.isEmpty else { return false }
        var covered = 0
        for match in matches(in: tokens, phrase: phrase, similar: similar, ending: true, timings: timings) {
            guard match.start == covered else { return false }
            covered = match.end
        }
        return covered == tokens.count
    }
    mutating func consume(_ text: String, wake: String, sleep: String, similar: Bool = false,
                          timings: [(word: String, start: Double, end: Double)]? = nil) -> PhraseCommand? {
        let tokens = Self.words(text)
        var latest: (end: Int, command: PhraseCommand, ordinal: Int)?
        var wakes = 0, ends = 0
        // Count phrase occurrences, rather than character positions: revising
        // an earlier word must not turn the same phrase into a new command.
        // Backends explicitly reset this matcher at their context boundary.
        for (phrase, command) in [(wake, PhraseCommand.wake), (sleep, .sleep)] {
            for match in Self.matches(in: tokens, phrase: phrase, similar: similar, ending: command == .sleep, timings: timings) {
                    let end = match.end
                    if command == .wake { wakes += 1 } else { ends += 1 }
                    let ordinal = command == .wake ? wakes : ends
                    if latest == nil || end >= latest!.end { latest = (end, command, ordinal) }
            }
        }
        defer { consumedWakes = max(consumedWakes, wakes); consumedEnds = max(consumedEnds, ends) }
        guard let latest, latest.ordinal > (latest.command == .wake ? consumedWakes : consumedEnds) else { return nil }
        return latest.command
    }

}

struct VoiceSnapshot: Codable {
    var pid: Int32?
    var inputRunning: Bool
    var recorderRunning: Bool
    var microphone: MicrophoneState?
    var accessibilityAllowed: Bool
    var endControlAvailable = false
    var controlsComplete = true
    var scanNodes = 0
    var scanTimeouts = 0
    var scanDepth = 0
    var scanFailure = ""
    var applicationReady = true
    var applicationLaunching = false
    var applicationHasWindow = true
    var applicationHasWebContent = true
    var applicationAbsent = false
    var callPresent: Bool { pid != nil && inputRunning }
}

// A cached expected state never authorizes a new toggle. Unknown means stop and ask for a fresh
// check; this prevents background AX failures or Agent Flow changes from inverting a muted call.
enum GateDecision: Equatable {
    case unchanged, toggle, unavailable
    static func set(_ target: MicrophoneState, current: MicrophoneState?) -> GateDecision {
        guard let current else { return .unavailable }
        return current == target ? .unchanged : .toggle
    }
}
