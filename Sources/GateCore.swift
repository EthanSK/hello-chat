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
enum VoiceAudioAction: String, CaseIterable, Hashable {
    case muteMicrophone, unmuteMicrophone, silenceSpeakers, unsilenceSpeakers
    var targetMuted: Bool {
        switch self {
        case .muteMicrophone, .silenceSpeakers: return true
        case .unmuteMicrophone, .unsilenceSpeakers: return false
        }
    }
    var controlsSpeakers: Bool {
        switch self {
        case .muteMicrophone, .unmuteMicrophone: return false
        case .silenceSpeakers, .unsilenceSpeakers: return true
        }
    }
    func isMuted(in snapshot: VoiceSnapshot) -> Bool? {
        if controlsSpeakers { return snapshot.outputMuted }
        return snapshot.microphone.map { $0 == .muted }
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

// One list owns every default field, its saved key and its dictionary identity.
// The two browser-video slots come last so Voice fields keep their order.
enum PhraseSlot: String, CaseIterable, Identifiable {
    case wakePhrase, sleepPhrase, mutePhrase, unmutePhrase, silentPhrase, silencePhrase, unsilencePhrase
    case pauseVideoPhrase, playVideoPhrase
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wakePhrase: return "Wake phrase"
        case .sleepPhrase: return "End phrase"
        case .mutePhrase: return "Mute phrase"
        case .unmutePhrase: return "Unmute phrase"
        case .silentPhrase: return "Silent phrase"
        case .silencePhrase: return "Silence phrase"
        case .unsilencePhrase: return "Unsilence phrase"
        case .pauseVideoPhrase: return "Pause video phrase"
        case .playVideoPhrase: return "Play video phrase"
        }
    }
    var defaultText: String {
        switch self {
        case .wakePhrase: return "Hello Chat"
        case .sleepPhrase: return "Bye Chat"
        case .mutePhrase: return "Mute Chat"
        case .unmutePhrase: return "Unmute Chat"
        case .silentPhrase: return "Silent Chat"
        case .silencePhrase: return "Silence Chat"
        case .unsilencePhrase: return "Unsilence Chat"
        case .pauseVideoPhrase: return "Pause video"
        case .playVideoPhrase: return "Play video"
        }
    }
    // Browser-video phrases go through Agent Flow Bridge and never reach Codex Voice.
    var controlsVideo: Bool { self == .pauseVideoPhrase || self == .playVideoPhrase }
    static let voiceSlots = allCases.filter { !$0.controlsVideo }
    static let videoSlots = allCases.filter(\.controlsVideo)
    var ending: Bool { self == .sleepPhrase }
    var identifier: String { self == .sleepPhrase ? "endPhrase" : rawValue }
    func isDefault(_ text: String) -> Bool { PhraseMatcher.words(text) == PhraseMatcher.words(defaultText) }
    func savedValue(in defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: rawValue) else { return defaultText }
        // Standardize only the old shipped lowercase audio defaults. Custom text stays verbatim.
        return !ending && self != .wakePhrase && saved == defaultText.lowercased() ? defaultText : saved
    }
}

// Dictionaries are explicit full phrases, one per line. Blank means the default phrase only.
enum PhraseDictionary {
    static let maximumBytes = 256 * 1024
    static let maximumEntries = 2_000
    enum ValidationError: LocalizedError {
        case tooLarge, tooMany, invalidLine(Int), conflictingCommand(Int, String), notText
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Dictionary must be 256 KB or smaller."
            case .tooMany: return "Dictionary can contain up to 2,000 spellings."
            case .invalidLine(let line): return "Line \(line) needs letters or numbers and at most 120 characters."
            case .conflictingCommand(let line, let label): return "Line \(line) is already the default \(label.lowercased())."
            case .notText: return "Choose a UTF-8 plain text file."
            }
        }
    }
    static func parse(_ text: String, for slot: PhraseSlot? = nil) throws -> [String] {
        guard text.utf8.count <= maximumBytes else { throw ValidationError.tooLarge }
        var entries: [String] = [], seen: Set<String> = []
        for (index, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            guard value.count <= 120, !PhraseMatcher.words(value).isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError.invalidLine(index + 1)
            }
            let normalized = PhraseMatcher.words(value).joined()
            if let slot, let other = PhraseSlot.allCases.first(where: { PhraseMatcher.words($0.defaultText).joined() == normalized }),
               slot != other, Set([slot, other]) != Set([.silentPhrase, .silencePhrase]) {
                throw ValidationError.conflictingCommand(index + 1, other.label) // Keep explicit dictionaries from reversing another built-in command; Silent/Silence intentionally share an action.
            }
            if seen.insert(normalized).inserted { entries.append(value) }
            guard entries.count <= maximumEntries else { throw ValidationError.tooMany }
        }
        return entries
    }
    static func read(_ url: URL, for slot: PhraseSlot? = nil) throws -> [String] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ValidationError.notText }
        return try parse(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")), for: slot)
    }
}

struct PhraseDictionaries: Equatable {
    private let spellings: [String: [String]]
    private let normalized: [String: Set<String>]
    private let spans: [String: Int]
    init(_ spellings: [String: [String]] = [:]) {
        self.spellings = spellings
        normalized = spellings.mapValues { Set($0.map { PhraseMatcher.words($0).joined() }) }
        spans = normalized.mapValues { $0.map(\.count).max() ?? 0 }
    }
    subscript(_ key: String) -> [String]? { spellings[key] }
    func contains(_ candidate: String, for key: String) -> Bool { normalized[key]?.contains(candidate) == true }
    func maximumSpan(for key: String) -> Int { spans[key] ?? 0 }
}

// Slot identity keeps an edited phrase exact even when its text happens to be another slot's default.
struct PhrasePattern: Equatable {
    let text: String
    let similar: Bool
    let ending: Bool
    let dictionaries: PhraseDictionaries
    init(text: String, similar: Bool, ending: Bool = false, dictionaries: PhraseDictionaries = .init()) {
        self.text = text; self.similar = similar; self.ending = ending; self.dictionaries = dictionaries
    }
    init(slot: PhraseSlot, text: String, similar: Bool, dictionaries: PhraseDictionaries) {
        self.init(text: text, similar: similar && slot.isDefault(text), ending: slot.ending, dictionaries: dictionaries)
    }
    func matches(in tokens: [String], timings: [(word: String, start: Double, end: Double)]? = nil) -> [(start: Int, end: Int)] {
        PhraseMatcher.matches(in: tokens, phrase: text, similar: similar, ending: ending, timings: timings, dictionaries: dictionaries)
    }
    func kind(for candidate: String) -> PhraseMatcher.MatchKind? {
        PhraseMatcher.matchKind(candidate, to: text, similar: similar, ending: ending, dictionaries: dictionaries)
    }
}

struct PhraseMatcher {
    enum MatchKind: String { case exact, dictionary, fuzzy }
    static let mutePhrase = PhraseSlot.mutePhrase.defaultText.lowercased(), unmutePhrase = PhraseSlot.unmutePhrase.defaultText.lowercased()
    static let silentPhrase = PhraseSlot.silentPhrase.defaultText.lowercased(), silencePhrase = PhraseSlot.silencePhrase.defaultText.lowercased(), unsilencePhrase = PhraseSlot.unsilencePhrase.defaultText.lowercased()
    static let microphonePhrases = [mutePhrase]
    static let controlPhrases = [mutePhrase, unmutePhrase, silentPhrase, silencePhrase, unsilencePhrase]
    // Ethan's natural "pause the video" / "play video". Verbs stay directional: "play" never
    // matches pause, and only the listed determiners may sit between the verb and "video".
    static let pauseVideoPhrase = PhraseSlot.pauseVideoPhrase.defaultText.lowercased(), playVideoPhrase = PhraseSlot.playVideoPhrase.defaultText.lowercased()
    static let videoPhrases = [pauseVideoPhrase, playVideoPhrase]
    private static let videoVariants: [String: Set<String>] = [
        pauseVideoPhrase: combinations(["pause", "paws"], ["video", "thevideo", "thisvideo"]),
        playVideoPhrase: combinations(["play"], ["video", "thevideo", "thisvideo"]),
    ]
    private static let defaultEndings = Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map { (words($0.defaultText).joined(), $0.ending) }) // Normalize defaults once; this lookup runs for every candidate span.
    private static let audioDictionaryNames: Set<String> = ["chat", "chad", "chatt"] // Deliberately narrower than the wake dictionary; never turn "unmute" into "mute".

    static func hasOpenEndedWakeVariants(_ phrase: String, similar: Bool, ending: Bool, dictionaries: PhraseDictionaries = .init()) -> Bool {
        dictionaries[words(phrase).joined()] == nil && usesWakeDictionary(words(phrase), similar: similar, ending: ending)
    }
    private static func usesWakeDictionary(_ expected: [String], similar: Bool, ending: Bool) -> Bool {
        similar && expected == ["hello", "chat"] && !ending
    }
    // The information popover derives its known spellings from the matcher.
    // It is not an exhaustive list of spacing or open-ended wake combinations.
    static func knownSpellings(for phrase: String, similar: Bool, ending: Bool, dictionaries: PhraseDictionaries = .init()) -> [String] {
        let expected = words(phrase), compact = expected.joined()
        guard !compact.isEmpty else { return [] }
        guard similar || videoVariants[expected.joined(separator: " ")] != nil else { return [phrase] }
        guard let slot = PhraseSlot.allCases.first(where: { $0.isDefault(phrase) && $0.ending == ending }) else { return [phrase] }
        if similar, let entries = dictionaries[words(slot.defaultText).joined()] {
            return [phrase] + entries.filter { words($0).joined() != compact }
        }
        var candidates: Set<String>
        if usesWakeDictionary(expected, similar: similar, ending: ending) {
            candidates = wakeVariants.union(weakWakeVariants)
        } else if ending, expected == ["bye", "chat"] {
            candidates = endVariants.union(observedEndVariants)
        } else if controlPhrases.contains(expected.joined(separator: " ")) {
            candidates = combinations(oneEdits(expected[0]), audioDictionaryNames)
        } else if let variants = videoVariants[expected.joined(separator: " ")] {
            candidates = variants
        } else {
            return [phrase]
        }
        candidates.remove(compact)
        return [phrase] + candidates.filter {
            equivalentCompact($0, expected: expected, compact: compact, similar: similar, allowEndAddressEdit: ending)
        }.sorted()
    }

    // Presentation uses the same acceptance rules as command detection. A
    // highlighted phrase is a textual match, not proof a Voice action ran.
    static func matchKind(_ candidate: String, to phrase: String, similar: Bool,
                          ending: Bool = false, dictionaries: PhraseDictionaries = .init()) -> MatchKind? {
        guard equivalent(candidate, to: phrase, similar: similar, allowEndAddressEdit: ending, dictionaries: dictionaries) else { return nil }
        let expected = words(phrase)
        if words(candidate).joined() == expected.joined() { return .exact }
        if (!ending && expected == ["hello", "chat"]) || (ending && expected == ["bye", "chat"])
            || controlPhrases.contains(expected.joined(separator: " "))
            || videoVariants[expected.joined(separator: " ")] != nil {
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
    static func equivalent(_ candidate: String, to phrase: String, similar: Bool, allowEndAddressEdit: Bool = false, dictionaries: PhraseDictionaries = .init()) -> Bool {
        let expected = words(phrase), actual = words(candidate).joined()
        return equivalentCompact(actual, expected: expected, compact: expected.joined(), similar: similar, allowEndAddressEdit: allowEndAddressEdit, dictionaries: dictionaries)
    }
    private static func equivalentCompact(_ actual: String, expected: [String], compact: String, similar: Bool, allowEndAddressEdit: Bool, dictionaries: PhraseDictionaries = .init()) -> Bool {
        if actual == compact { return !compact.isEmpty }
        guard defaultEndings[compact] == allowEndAddressEdit else { return false }
        let naturalVideoVariant = videoVariants[expected.joined(separator: " ")]?.contains(actual) == true &&
            !actual.hasPrefix("paws")
        if !similar { return naturalVideoVariant }
        if dictionaries[compact] != nil {
            return dictionaries.contains(actual, for: compact) // Explicit overrides replace generated alternatives, including the open-ended wake rule.
        }
        if usesWakeDictionary(expected, similar: similar, ending: allowEndAddressEdit) {
            // Ethan wants "hello" followed by any word beginning C H to wake.
            // The existing compact form also preserves joined/spelled variants.
            return !ordinaryWakePhrases.contains(actual) && !excludedShortGreetings.contains(actual) &&
                (wakeVariants.contains(actual) || weakWakeVariants.contains(actual) || actual.hasPrefix("helloch"))
        }
        if similar, expected == ["bye", "chat"], allowEndAddressEdit {
            return !ordinaryEndPhrases.contains(actual) && (endVariants.contains(actual) || observedEndVariants.contains(actual))
        }
        if similar, controlPhrases.contains(expected.joined(separator: " ")) {
            return audioDictionaryNames.contains { name in
                guard actual.hasSuffix(name) else { return false }
                let verb = String(actual.dropLast(name.count)), expectedVerb = expected[0]
                // The archive recorded "unsilenced chat". Allow one spelling
                // edit in the verb while preserving its directional prefix and
                // the narrow Chat dictionary; mute can never become unmute.
                return verb == expectedVerb || (verb.hasPrefix(expectedVerb.prefix(3))
                    && oneEditApart(Array(verb), Array(expectedVerb)))
            }
        }
        // Ordinary variants such as "pause the video" work even without similar
        // spellings. Edited/custom phrases never acquire generated alternatives.
        return videoVariants[expected.joined(separator: " ")]?.contains(actual) == true
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
                        timings: [(word: String, start: Double, end: Double)]? = nil, dictionaries: PhraseDictionaries = .init()) -> [(start: Int, end: Int)] {
        let expected = words(phrase)
        guard !expected.isEmpty else { return [] }
        let compact = expected.joined()
        let common = similar && (expected == ["hello", "chat"] && !ending || expected == ["bye", "chat"] && ending)
        let overrideSpan = similar ? dictionaries.maximumSpan(for: compact) : 0
        let maxSpan = max(common ? maximumDefaultSpan : expected.count + 1, overrideSpan) // Explicit aliases can be longer; preserve existing scan bounds for every unmodified phrase.
        var result: [(start: Int, end: Int)] = [], start = 0
        while start < tokens.count {
            if start > 0, tokens[start - 1] == "un",
               controlPhrases.contains(expected.joined(separator: " ")) || videoPhrases.contains(expected.joined(separator: " ")),
               expected.first?.hasPrefix("un") == false {
                start += 1; continue // A split "un mute" / "un silence" / "un pause" must never also match the opposite command.
            }
            var found = false
            var candidate = ""
            let lengths = Array(1...min(maxSpan, tokens.count - start))
            let exactLength = lengths.first { tokens[start..<(start + $0)].joined() == compact }
            for length in exactLength.map({ [$0] }) ?? lengths { // Preserve a full spelled-out command before a shorter dictionary prefix such as H E L L O C H.
                let end = start + length
                // Tokens are already normalized; don't tokenize the growing
                // candidate and saved phrase again for every possible span.
                candidate = tokens[start..<end].joined()
                guard equivalentCompact(candidate, expected: expected, compact: compact,
                                        similar: similar, allowEndAddressEdit: ending, dictionaries: dictionaries) else { continue }
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
    // times as fallback. StandaloneWake owns the separate post-keyword pause.
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
    var outputMuted: Bool? = nil
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
