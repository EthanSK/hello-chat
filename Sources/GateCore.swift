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
    // The phrase fields that request this action, in detection order.
    var slots: [PhraseSlot] {
        switch self {
        case .muteMicrophone: return [.mutePhrase]
        case .unmuteMicrophone: return [.unmutePhrase]
        case .silenceSpeakers: return [.silentPhrase, .silencePhrase]
        case .unsilenceSpeakers: return [.unsilencePhrase]
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
// Voice, browser, music and desktop fields retain their own display groups.
enum PhraseSlot: String, CaseIterable, Identifiable {
    case wakePhrase, sleepPhrase, mutePhrase, unmutePhrase, silentPhrase, silencePhrase, unsilencePhrase
    case pauseVideoPhrase, playVideoPhrase
    case pauseMusicPhrase, playMusicPhrase
    case switchAppPhrase, openAppPhrase, zoomInPhrase, zoomOutPhrase
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
        case .pauseMusicPhrase: return "Pause music phrase"
        case .playMusicPhrase: return "Play music phrase"
        case .switchAppPhrase, .openAppPhrase: return "App prefix"
        case .zoomInPhrase: return "Zoom in phrase"
        case .zoomOutPhrase: return "Zoom out phrase"
        }
    }
    // Shown under the field. App prefixes are followed by an app name; both bring an app forward,
    // opening it if needed (Ethan, 14 November 2026: "open should switch ... make it interchangeable").
    var example: String? {
        switch self {
        case .switchAppPhrase: return "Say a prefix followed by an app name. Open brings it forward too."
        case .pauseMusicPhrase: return "Both music phrases send one Play/Pause press to the current media session."
        default: return nil
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
        case .pauseMusicPhrase: return "Pause music"
        case .playMusicPhrase: return "Play music"
        case .switchAppPhrase: return "Switch app"
        case .openAppPhrase: return "Open app"
        case .zoomInPhrase: return "Zoom in"
        case .zoomOutPhrase: return "Zoom out"
        }
    }
    // Browser-video phrases go through Agent Flow Bridge and never reach Codex Voice.
    var controlsVideo: Bool { self == .pauseVideoPhrase || self == .playVideoPhrase }
    var controlsMusic: Bool { self == .pauseMusicPhrase || self == .playMusicPhrase }
    // Desktop phrases act on Mac apps and never reach Codex Voice either.
    var controlsDesktop: Bool { [.switchAppPhrase, .openAppPhrase, .zoomInPhrase, .zoomOutPhrase].contains(self) }
    static let voiceSlots = allCases.filter { !$0.controlsVideo && !$0.controlsMusic && !$0.controlsDesktop }
    static let videoSlots = allCases.filter(\.controlsVideo)
    static let musicSlots = allCases.filter(\.controlsMusic)
    static let desktopSlots = allCases.filter(\.controlsDesktop)
    // Refactor of fieldGroups: Ethan’s “one setting” for Switch/Open now applies to
    // every command, retaining all saved slots, dictionaries and sounds. — GPT-6.1 Sol
    static func settingsGroups(_ slots: [PhraseSlot]) -> [[PhraseSlot]] {
        var groups: [[PhraseSlot]] = []
        for slot in slots {
            if let index = groups.firstIndex(where: { $0.first?.action == slot.action }) { groups[index].append(slot) }
            else { groups.append([slot]) }
        }
        return groups
    }
    var ending: Bool { self == .sleepPhrase }
    var identifier: String { self == .sleepPhrase ? "endPhrase" : rawValue }
    func isDefault(_ text: String) -> Bool { PhraseMatcher.words(text) == PhraseMatcher.words(defaultText) }
    func savedValue(in defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: rawValue) else { return defaultText }
        // Standardize only the old shipped lowercase audio defaults. Custom text stays verbatim.
        return !ending && self != .wakePhrase && saved == defaultText.lowercased() ? defaultText : saved
    }
    // The command each section requests. Silent/Silence and, since Ethan's 14 November 2026
    // decision, Switch app/Open app are two sections for one action; each keeps its own sound.
    var action: PhraseAction {
        switch self {
        case .wakePhrase: return .wake
        case .sleepPhrase: return .end
        case .mutePhrase: return .muteMicrophone
        case .unmutePhrase: return .unmuteMicrophone
        case .silentPhrase, .silencePhrase: return .silenceSpeakers
        case .unsilencePhrase: return .unsilenceSpeakers
        case .pauseVideoPhrase: return .pauseVideo
        case .playVideoPhrase: return .playVideo
        case .pauseMusicPhrase, .playMusicPhrase: return .mediaPlayPause
        case .switchAppPhrase, .openAppPhrase: return .app
        case .zoomInPhrase: return .zoomIn
        case .zoomOutPhrase: return .zoomOut
        }
    }
}

enum PhraseAction: String, CaseIterable {
    case wake, end, muteMicrophone, unmuteMicrophone, silenceSpeakers, unsilenceSpeakers, pauseVideo, playVideo, mediaPlayPause, app, zoomIn, zoomOut
    var settingsTitle: String {
        switch self {
        case .wake: return "Wake phrases"
        case .end: return "End phrases"
        case .muteMicrophone: return "Mute microphone"
        case .unmuteMicrophone: return "Unmute microphone"
        case .silenceSpeakers: return "Silence speakers"
        case .unsilenceSpeakers: return "Unsilence speakers"
        case .pauseVideo: return "Pause video"
        case .playVideo: return "Play video"
        case .mediaPlayPause: return "Music"
        case .app: return "App prefixes"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        }
    }
    var slots: [PhraseSlot] { PhraseSlot.allCases.filter { $0.action == self } }
}

// Ethan's extra phrases (14 November 2026): each section keeps its saved main phrase and can list
// more explicit phrases below it. Typing "Open app / Switch app" is another way to add rows.
struct PhraseRow: Identifiable, Equatable {
    let id: UUID
    var text: String
    init(_ text: String, id: UUID = UUID()) { self.id = id; self.text = text }
}

enum PhraseList {
    static let defaultsKey = "phraseAliases"
    // Store each batch once. A deleted row stays deleted when a later version adds defaults.
    static func seedDefaults(in defaults: UserDefaults, conflictsWithSpeaker: (PhrasePattern) -> Bool = { _ in false }) {
        let batches: [(key: String, additions: [(PhraseSlot, [String])])] = [
            ("phraseDefaults20261115", [(.wakePhrase, ["Hey Chat"]), (.sleepPhrase, ["Goodbye Chat"]),
                                       (.switchAppPhrase, ["Switch up", "Switch to", "Switch"])]),
            ("mutePhraseDefaults20261118", [(.mutePhrase, ["Mute mic"]), (.silentPhrase, ["Mute speakers"])])
        ]
        for batch in batches where !defaults.bool(forKey: batch.key) {
            let saved = defaults.object(forKey: defaultsKey)
            var rows = decode(saved)
            let dictionaries = defaults.dictionary(forKey: "phraseDictionaries") as? [String: [String]] ?? [:]
            var seen = Set(PhraseSlot.allCases.flatMap { slot in
                [slot.savedValue(in: defaults)] + (rows[slot] ?? []) + (dictionaries[slot.rawValue] ?? [])
            }.map(key))
            for (slot, phrases) in batch.additions where slot.isDefault(slot.savedValue(in: defaults)) {
                // The two speaker trigger families share a panel. Respect a customized primary in either.
                if slot == .silentPhrase && !PhraseSlot.silencePhrase.isDefault(PhraseSlot.silencePhrase.savedValue(in: defaults)) { continue }
                for phrase in phrases where !seen.contains(key(phrase)) {
                    let pattern = PhrasePattern(slot: slot, text: phrase, similar: false, dictionaries: .init())
                    guard !conflictsWithSpeaker(pattern) else { continue }
                    rows[slot, default: []].append(phrase)
                    seen.insert(key(phrase))
                }
            }
            defaults.set(encode(rows, preserving: saved), forKey: defaultsKey)
            defaults.set(true, forKey: batch.key)
        }
    }
    static func key(_ text: String) -> String { PhraseMatcher.words(text).joined() }
    // Trimmed, nonempty pieces in typed order.
    static func pieces(_ text: String) -> [String] {
        text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    // Applied when a row is submitted or loses focus, never per keystroke. The first piece stays in
    // the row; later pieces are new rows, skipping any already listed. Existing rows are never removed.
    static func commit(_ text: String, others: [String]) -> (text: String, added: [String])? {
        guard text.contains("/") else { return nil }
        let parts = pieces(text)
        var seen = Set(others.map(key)), added: [String] = []
        if let first = parts.first { seen.insert(key(first)) }
        for part in parts.dropFirst() where !key(part).isEmpty && seen.insert(key(part)).inserted { added.append(part) }
        return (parts.first ?? "", added)
    }
    // One section's rows after its main row (`index` nil) or an extra row is submitted or left.
    // New pieces go directly below the row they were typed in. An extra row left without letters
    // or numbers can't match and isn't saved, so it goes; the main row always stays.
    static func commit(main: String, rows: [PhraseRow], at index: Int?) -> (main: String, rows: [PhraseRow]) {
        var main = main, rows = rows
        let row = index.map { $0 + 1 } ?? 0
        let all = [main] + rows.map(\.text)
        if let committed = commit(all[row], others: all.indices.filter { $0 != row }.map { all[$0] }) {
            rows.insert(contentsOf: committed.added.map { PhraseRow($0) }, at: row)
            if let index { rows[index].text = committed.text } else { main = committed.text }
        }
        if let index, key(rows[index].text).isEmpty { rows.remove(at: index) }
        return (main, rows)
    }
    static func decode(_ value: Any?) -> [PhraseSlot: [String]] {
        guard let saved = value as? [String: [String]] else { return [:] }
        var result: [PhraseSlot: [String]] = [:]
        for slot in PhraseSlot.allCases { if let rows = saved[slot.rawValue], !rows.isEmpty { result[slot] = rows } }
        return result
    }
    // Blank rows stay visible while editing but aren't saved. Unknown keys from another build are kept.
    static func encode(_ rows: [PhraseSlot: [String]], preserving saved: Any?) -> [String: [String]] {
        var result = (saved as? [String: [String]] ?? [:]).filter { key, _ in PhraseSlot(rawValue: key) == nil }
        for (slot, texts) in rows {
            let kept = texts.filter { !key($0).isEmpty }
            if !kept.isEmpty { result[slot.rawValue] = kept }
        }
        return result
    }
}

// Every section's rows, main phrase first. The first section to claim a phrase keeps it: main
// phrases before extra rows, then section order. A repeat for the same action is redundant; a
// repeat for a different action is ignored so a new row can never take over a working command.
struct PhraseConfiguration: Equatable {
    enum Issue: Equatable { case duplicate(PhraseSlot), conflict(PhraseSlot) }
    let rows: [PhraseSlot: [String]]
    private(set) var issues: [PhraseSlot: [Int: Issue]] = [:]
    private var active: [PhraseSlot: [String]] = [:]

    init(rows: [PhraseSlot: [String]]) {
        self.rows = rows
        var owners: [String: PhraseSlot] = [:], claimed: [PhraseSlot: [Int]] = [:]
        let order = PhraseSlot.allCases.map { ($0, 0) }
            + PhraseSlot.allCases.flatMap { slot in (1..<max(1, rows[slot]?.count ?? 0)).map { (slot, $0) } }
        for (slot, index) in order {
            guard let text = rows[slot]?[safe: index] else { continue }
            let key = PhraseList.key(text)
            guard !key.isEmpty else { continue }
            if let owner = owners[key] {
                issues[slot, default: [:]][index] = owner.action == slot.action ? .duplicate(owner) : .conflict(owner)
            } else {
                owners[key] = slot; claimed[slot, default: []].append(index)
            }
        }
        for (slot, indices) in claimed { active[slot] = indices.sorted().compactMap { rows[slot]?[safe: $0] } }
    }
    // Phrases that take part in detection, highlighting and startup capture, in row order.
    func phrases(for slot: PhraseSlot) -> [String] { active[slot] ?? [] }
    func issue(_ slot: PhraseSlot, row: Int) -> Issue? { issues[slot]?[row] }
    var allPhrases: [String] { PhraseSlot.allCases.flatMap { phrases(for: $0) } }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
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
               slot.action != other.action {
                throw ValidationError.conflictingCommand(index + 1, other.label) // Same-action aliases are safe; never reverse another built-in command.
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

// Desktop commands can follow earlier speech in one unpunctuated ASR result.
// Use real word spans, never synthesized hypothesis-arrival timestamps, to
// recognize the same audio boundary already used by the microphone detector.
enum DesktopSpeechBoundaries {
    static func indices(words: [String], timings: [(word: String, start: Double, end: Double)]?, gap: Double) -> [Int] {
        guard let timings, timings.map(\.word) == words, timings.count > 1 else { return [] }
        return (1..<timings.count).filter { index in
            let previous = timings[index - 1], next = timings[index]
            return previous.start.isFinite && previous.end.isFinite && next.start.isFinite && next.end.isFinite &&
                previous.end > previous.start && next.end > next.start &&
                next.start - previous.end + 1e-9 >= gap
        }
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
    // Real-word speech substitutions only (Ethan, 15 November 2026). No generated letter edits.
    // Explicit dictionaries and custom rows remain user-owned and are never pruned.
    private static let audioVariants: [String: Set<String>] = [
        mutePhrase: combinations(["mute", "muted"], ["chat", "chad"]),
        unmutePhrase: combinations(["unmute", "unmuted"], ["chat", "chad"]),
        silentPhrase: combinations(["silent", "silenced"], ["chat", "chad"]),
        silencePhrase: combinations(["silence", "silenced"], ["chat", "chad"]),
        unsilencePhrase: combinations(["unsilence", "unsilenced"], ["chat", "chad"]),
    ]

    static func hasOpenEndedWakeVariants(_ phrase: String, similar: Bool, ending: Bool, dictionaries: PhraseDictionaries = .init()) -> Bool {
        false // The shipped dictionary is now finite; no unlisted CH-word or letter-edit expansion.
    }
    private static func usesWakeDictionary(_ expected: [String], similar: Bool, ending: Bool) -> Bool {
        similar && expected == ["hello", "chat"] && !ending
    }
    // The popover derives its finite list from the matcher and displays ordinary word spacing.
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
        } else if let variants = audioVariants[expected.joined(separator: " ")] {
            candidates = variants
        } else if let variants = videoVariants[expected.joined(separator: " ")] {
            candidates = variants
        } else {
            return [phrase]
        }
        candidates.remove(compact)
        return [phrase] + candidates.filter {
            equivalentCompact($0, expected: expected, compact: compact, similar: similar, allowEndAddressEdit: ending)
        }.sorted().map { spelling in
            if let full = wakeSpellings.union(endSpellings).first(where: { words($0).joined() == spelling }) { return full }
            if spelling == "aswellchat" { return "as well chat" }
            for name in ["chad", "chat"] where spelling.hasSuffix(name) {
                return String(spelling.dropLast(name.count)) + " " + name
            }
            for name in ["thevideo", "thisvideo", "video"] where spelling.hasSuffix(name) {
                let tail = name == "video" ? name : String(name.dropLast(5)) + " video"
                return String(spelling.dropLast(name.count)) + " " + tail
            }
            return spelling
        }
    }

    // Presentation uses the same acceptance rules as command detection. A
    // highlighted phrase is a textual match, not proof a Voice action ran.
    static func matchKind(_ candidate: String, to phrase: String, similar: Bool,
                          ending: Bool = false, dictionaries: PhraseDictionaries = .init()) -> MatchKind? {
        guard equivalent(candidate, to: phrase, similar: similar, allowEndAddressEdit: ending, dictionaries: dictionaries) else { return nil }
        let expected = words(phrase)
        let actual = words(candidate).joined(), compact = expected.joined()
        if actual == compact { return .exact }
        if similar && dictionaries.contains(actual, for: compact) { return .dictionary }
        if (!ending && expected == ["hello", "chat"]) || (ending && expected == ["bye", "chat"])
            || controlPhrases.contains(expected.joined(separator: " "))
            || videoVariants[expected.joined(separator: " ")] != nil {
            return .dictionary
        }
        return .fuzzy
    }
    // Ethan replaced the huge combinatorial dictionary on 15 November 2026 with plausible
    // real-word ASR substitutions. Spellings below are explicit full phrases, not arbitrary
    // address/name cross-products. H Chat / B Chat discussion names remain absent. The older
    // Hey-as-discussion rule is superseded by his explicit request to add Hey Chat as a default.
    private static let wakeSpellings: Set<String> = [
        "hello chat", "hello chad", "hello chats", "hello chart", "hello charts", "hello chance",
        "hallo chat", "hallo chad", "hullo chat", "hullo chad", "hullo chart", "halo chat", "hollow chat",
        "yellow chat", "hello chard", "hello chants", "oh hello chat",
    ]
    private static let endSpellings: Set<String> = [
        "bye chat", "by chat", "buy chat", "byte chat", "bite chat",
        "bye chad", "by chad", "bye chats", "by chats", "bye chart", "by chart",
        "bye charts", "by charts", "buy charts", "byte charts", "by the charts",
        "goodbye chat", "good bye chat", "goodbye chad", "good buy charts", "bye bye chat",
    ]
    private static let wakeVariants = Set(wakeSpellings.map { words($0).joined() })
    private static let endVariants = Set(endSpellings.map { words($0).joined() })
    // Retain this observed phrase's existing extra context checks; it is never an End alias.
    private static let weakWakeVariants: Set<String> = ["aswellchat"]
    private static let observedEndVariants: Set<String> = []
    static var defaultVariantCounts: (wake: Int, end: Int, weakWake: Int) {
        (wakeVariants.union(weakWakeVariants).count, endVariants.count, weakWakeVariants.count)
    }
    static var defaultVariantsOverlap: Bool { !wakeVariants.union(weakWakeVariants).isDisjoint(with: endVariants) }
    private static let maximumDefaultSpan = max(
        wakeVariants.map(\.count).max() ?? 9, endVariants.map(\.count).max() ?? 9)
    private static func combinations(_ addresses: Set<String>, _ names: Set<String>) -> Set<String> {
        Set(addresses.flatMap { address in names.map { address + $0 } })
    }
    static func isWeakWakeVariant(_ candidate: String) -> Bool { weakWakeVariants.contains(candidate) }
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
            return wakeVariants.contains(actual) || weakWakeVariants.contains(actual)
        }
        if similar, expected == ["bye", "chat"], allowEndAddressEdit {
            return endVariants.contains(actual)
        }
        if let variants = audioVariants[expected.joined(separator: " ")] { return variants.contains(actual) }
        // Ordinary variants such as "pause the video" work even without similar
        // spellings. Edited/custom phrases never acquire generated alternatives.
        return videoVariants[expected.joined(separator: " ")]?.contains(actual) == true
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
    var savedVoiceActive: Bool? = nil
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

    // Codex exposes End on a pending Voice panel before audio is connected.
    // A microphone control is stronger. With End alone, require corroboration
    // from audio input or a saved live session in the same Codex process.
    var voiceConnectionEvidence: String? {
        guard pid != nil, accessibilityAllowed else { return nil }
        if microphone != nil { return "microphone_control" }
        guard endControlAvailable else { return nil }
        if savedVoiceActive == true { return "end_control_and_saved_session" }
        return inputRunning ? "end_control_and_input" : nil
    }
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
