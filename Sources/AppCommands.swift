import Foundation

// Ethan's "Switch app Chrome", "Open Safari" and "Zoom in". Pure parsing, matching and planning
// live here so tests never touch running apps, the file system or the keyboard.

enum ZoomDirection: String, CaseIterable, Hashable {
    case zoomIn, zoomOut
    var slot: PhraseSlot { self == .zoomIn ? .zoomInPhrase : .zoomOutPhrase }
    var title: String { self == .zoomIn ? "zoom in" : "zoom out" }
}

enum AppCommandKind: String, Equatable {
    case switchApp, openApp
    var slot: PhraseSlot {
        switch self {
        case .switchApp: return .switchAppPhrase
        case .openApp: return .openAppPhrase
        }
    }
}

struct AppCommandCandidate: Equatable {
    let kind: AppCommandKind
    let name: String            // The spoken app name, as heard.
    let bare: Bool              // "Open Safari" without the "app" word: needs a confident match.
    let alternateName: String?  // "Open app store" can also mean the App Store.
}

// App names need a real speech boundary. ASR can briefly punctuate "open Chrome settings"
// as two sentences while it is still revising the same utterance.
struct AppCommandDetector {
    static let finalizationSeconds = 0.8
    static let maximumNameWords = 4
    private static let tokenizer = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+|[.!?;\\n]+")
    // Only polite openers may precede a prefix; everything else (negation, "I said", a wake
    // phrase, discussion) makes it ordinary speech. Bare "open" is stricter still.
    private static let prefixLeftWords: Set<String> = ["please", "ok", "okay", "now", "can", "you", "could", "would", "and", "then"]
    private static let bareLeftWords: Set<String> = ["please", "ok", "okay", "now"]
    private var context: [String] = []
    private var sentenceStarts: [Int] = []
    private var leftBoundaries: [Int] = []
    private var endBoundaries: [Int] = []
    private var wordTimings: [(word: String, start: Double, end: Double)]?
    private var quiet = 0.0
    private var audioTime: Double?
    private var heardSpeech = false
    // Every quiet gap of at least 0.35 s, as a word index. Keeping only the latest one let a pause
    // inside or after a request replace the pause before it, and an index past the prefix used to
    // skip the left-context check entirely.
    private var audioBoundaries: [Int] = []
    private static let maximumAudioBoundaries = 64
    private var consumedAudio: [Range<Double>] = []
    private var consumedCount = 0
    private var revision = 0
    private var checkedRevision = -1
    private var waiting = false

    // Word-free evidence for diagnostics: why a prefix was or wasn't admitted.
    struct Evidence: Equatable {
        var leftWords = 0
        var nameWords = 0
        var timing = "none"      // model: real word spans; arrival: synthesized hypothesis times; mixed; none.
        var gapBefore: Double?   // Real gap before the prefix, when both words have model spans.
        var elapsed: Double?     // Pause after the name used for finalization.
    }

    mutating func reset() { self = AppCommandDetector() }
    mutating func audio(level: Double, seconds: Double, at time: Double? = nil) {
        audioTime = time
        if level < 0.02 { quiet += seconds }
        else {
            if quiet >= 0.35, heardSpeech, audioBoundaries.last != context.count {
                audioBoundaries.append(context.count)
                if audioBoundaries.count > Self.maximumAudioBoundaries { audioBoundaries.removeFirst() }
            }
            heardSpeech = true; quiet = 0
        }
    }
    mutating func update(_ text: String, at time: Double, timings: [(word: String, start: Double, end: Double)]? = nil) {
        var words: [String] = [], starts: [Int] = []
        let source = text.lowercased() as NSString
        for match in Self.tokenizer.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range)
            if token.rangeOfCharacter(from: .alphanumerics) != nil { words.append(token) } else { starts.append(words.count) }
        }
        wordTimings = timings
        let left = DesktopSpeechBoundaries.indices(words: words, timings: timings, gap: 0.35)
        let ends = DesktopSpeechBoundaries.indices(words: words, timings: timings, gap: Self.finalizationSeconds)
        guard words != context || starts != sentenceStarts || left != leftBoundaries || ends != endBoundaries else { return }
        if !audioBoundaries.isEmpty {
            let common = zip(context, words).prefix { $0 == $1 }.count
            var clamped: [Int] = []
            for boundary in audioBoundaries.map({ min($0, common) }) where clamped.last != boundary { clamped.append(boundary) }
            audioBoundaries = clamped
        }
        context = words; sentenceStarts = starts; leftBoundaries = left; endBoundaries = ends; revision += 1
    }
    // End wins over every app command heard so far in this transcript.
    mutating func consumeAll(switchPrefix: PhrasePattern, openPrefix: PhrasePattern) {
        consumeAll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix])
    }
    mutating func consumeAll(switchPrefixes: [PhrasePattern], openPrefixes: [PhrasePattern]) {
        let found = prefixes(switchPrefixes: switchPrefixes, openPrefixes: openPrefixes)
        for (index, prefix) in found.enumerated() { consume(index: index, start: prefix.start, end: prefix.end) }
        waiting = false; checkedRevision = revision
    }
    mutating func poll(switchPrefix: PhrasePattern, openPrefix: PhrasePattern,
                       onDecision: ((AppCommandKind, String) -> Void)? = nil) -> [AppCommandCandidate] {
        poll(switchPrefixes: [switchPrefix], openPrefixes: [openPrefix], onDecision: { kind, decision, _ in onDecision?(kind, decision) })
    }
    // Each listed phrase is a prefix for its own section. Only Open app phrases have the bare short
    // form ("Open Safari"); Switch app phrases never gain one.
    mutating func poll(switchPrefixes: [PhrasePattern], openPrefixes: [PhrasePattern],
                       onDecision: ((AppCommandKind, String, Evidence) -> Void)? = nil) -> [AppCommandCandidate] {
        guard heardSpeech, checkedRevision != revision || waiting else { return [] }
        checkedRevision = revision; waiting = false
        var result: [AppCommandCandidate] = []
        let alignedTimings = wordTimings.flatMap { $0.map(\.word) == context ? $0 : nil }
        for (index, prefix) in prefixes(switchPrefixes: switchPrefixes, openPrefixes: openPrefixes).enumerated() {
            if let range = audioRange(start: prefix.start, end: prefix.end, timings: alignedTimings) {
                if consumedAudio.contains(where: { $0.overlaps(range) }) { continue }
            } else if index < consumedCount { continue }
            let sentenceStart = (sentenceStarts + leftBoundaries).filter { $0 <= prefix.start }.max() ?? 0
            let sentenceEnd = max(prefix.end, (sentenceStarts + endBoundaries).filter { $0 > prefix.start }.min() ?? context.count)
            let elapsed: Double
            if let alignedTimings, sentenceEnd < context.count {
                elapsed = alignedTimings[sentenceEnd].start - alignedTimings[sentenceEnd - 1].end
            } else if let audioTime, let alignedTimings {
                let last = alignedTimings[sentenceEnd - 1]
                // Background playback can keep RMS above the quiet threshold.
                // Real model spans still show that the spoken request ended.
                elapsed = last.end > last.start ? audioTime - last.end : min(quiet, audioTime - last.end)
            } else { elapsed = quiet }
            var evidence = Self.evidence(prefix: prefix.start, end: sentenceEnd, timings: alignedTimings)
            evidence.elapsed = elapsed.isFinite ? elapsed : nil
            if sentenceEnd < context.count, alignedTimings != nil, elapsed + 1e-9 < Self.finalizationSeconds {
                consume(index: index, start: prefix.start, end: prefix.end)
                onDecision?(prefix.kind, "rejected_no_audio_boundary", evidence)
                continue
            }
            guard elapsed.isFinite, elapsed + 1e-9 >= Self.finalizationSeconds else {
                waiting = true; break // Still speaking: keep this occurrence pending.
            }
            // The context starts at the latest pause or sentence start before the prefix. A pause
            // heard after it says nothing about the words before it.
            let leftStart = max(audioBoundaries.last(where: { $0 <= prefix.start }) ?? 0, sentenceStart)
            let left = context[leftStart..<prefix.start]
            let name = Self.trimmed(Array(context[prefix.end..<sentenceEnd]), kind: prefix.kind)
            evidence.leftWords = left.count; evidence.nameWords = name.count
            guard left.allSatisfy((prefix.bare ? Self.bareLeftWords : Self.prefixLeftWords).contains) else {
                consume(index: index, start: prefix.start, end: prefix.end)
                onDecision?(prefix.kind, "rejected_context", evidence); continue
            }
            // ASR can deliver the prefix first even after its audio clock has advanced. No name
            // at the current tail is not a rejected occurrence: a later text revision can supply
            // it. Leave it unconsumed without polling unchanged text or adding another wait.
            if name.isEmpty, sentenceEnd == context.count { continue }
            consume(index: index, start: prefix.start, end: prefix.end)
            guard (1...Self.maximumNameWords).contains(name.count), !Self.isDiscussion(name) else {
                onDecision?(prefix.kind, "rejected_name_or_discussion", evidence); continue
            }
            var alternate: String?
            if prefix.kind == .openApp, !prefix.bare, prefix.start + 1 < prefix.end, context[prefix.end - 1] == "app" {
                let bareName = Self.trimmed(Array(context[(prefix.end - 1)..<sentenceEnd]), kind: .openApp)
                if bareName.count <= Self.maximumNameWords { alternate = bareName.joined(separator: " ") }
            }
            result.append(AppCommandCandidate(kind: prefix.kind, name: name.joined(separator: " "), bare: prefix.bare, alternateName: alternate))
            onDecision?(prefix.kind, "accepted", evidence)
        }
        return result
    }
    private static func evidence(prefix start: Int, end: Int, timings: [(word: String, start: Double, end: Double)]?) -> Evidence {
        var evidence = Evidence()
        guard let timings, start < end, end <= timings.count else { return evidence }
        let window = timings[max(0, start - 1)..<end]
        let real = window.filter { $0.end > $0.start }.count
        evidence.timing = real == window.count ? "model" : (real == 0 ? "arrival" : "mixed")
        if start > 0, timings[start - 1].end > timings[start - 1].start, timings[start].end > timings[start].start {
            evidence.gapBefore = timings[start].start - timings[start - 1].end
        }
        return evidence
    }
    // "The switch app prefix works", "open app command is broken": talk about the feature.
    private static let discussionLeads: Set<String> = ["phrase", "prefix", "command", "commands", "feature", "button", "word"]
    private static let discussionVerbs: Set<String> = ["is", "isn", "isnt", "was", "wasn", "does", "doesn", "doesnt",
                                                       "should", "works", "worked", "working", "fails", "failed"]
    static func isDiscussion(_ name: [String]) -> Bool {
        guard let first = name.first else { return false }
        return discussionLeads.contains(first) || name.contains(where: discussionVerbs.contains)
    }
    // "Switch app to Chrome", "Open the App Store", "Open Safari please".
    private static func trimmed(_ words: [String], kind: AppCommandKind) -> [String] {
        var name = words[...]
        if kind == .switchApp, name.first == "to" { name = name.dropFirst() }
        if name.first == "the" { name = name.dropFirst() }
        if name.last == "please" { name = name.dropLast() }
        return Array(name)
    }
    private func prefixes(switchPrefixes: [PhrasePattern], openPrefixes: [PhrasePattern]) -> [(start: Int, end: Int, kind: AppCommandKind, bare: Bool)] {
        var found: [(start: Int, end: Int, kind: AppCommandKind, bare: Bool)] = []
        for pattern in switchPrefixes {
            for match in pattern.matches(in: context, timings: wordTimings) { found.append((match.start, match.end, .switchApp, false)) }
        }
        for pattern in openPrefixes {
            for match in pattern.matches(in: context, timings: wordTimings) { found.append((match.start, match.end, .openApp, false)) }
        }
        let full = found
        for pattern in openPrefixes {
            guard let bare = Self.barePrefix(for: pattern) else { continue }
            for match in bare.matches(in: context, timings: wordTimings) where !full.contains(where: { $0.start == match.start }) {
                found.append((match.start, match.end, .openApp, true))
            }
        }
        // Overlapping listed phrases ("switch app" and "switch app to") are one spoken occurrence.
        var kept: [(start: Int, end: Int, kind: AppCommandKind, bare: Bool)] = []
        for prefix in found.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end })
        where kept.allSatisfy({ $0.end <= prefix.start || prefix.end <= $0.start }) { kept.append(prefix) }
        return kept
    }
    // "Open app" also listens for bare "open"; a custom "Launch app" listens for "launch".
    static func barePrefix(for pattern: PhrasePattern) -> PhrasePattern? {
        let words = PhraseMatcher.words(pattern.text)
        guard words.count >= 2, words.last == "app" else { return nil }
        return PhrasePattern(text: words.dropLast().joined(separator: " "), similar: false)
    }
    private func audioRange(start: Int, end: Int, timings: [(word: String, start: Double, end: Double)]?) -> Range<Double>? {
        guard let timings, start < end, end <= timings.count else { return nil }
        let from = timings[start].start, to = timings[end - 1].end
        return from.isFinite && to.isFinite && from <= to ? from..<max(to, from.nextUp) : nil
    }
    private mutating func consume(index: Int, start: Int, end: Int) {
        consumedCount = max(consumedCount, index + 1)
        let alignedTimings = wordTimings.flatMap { $0.map(\.word) == context ? $0 : nil }
        if let range = audioRange(start: start, end: end, timings: alignedTimings),
           !consumedAudio.contains(where: { $0.overlaps(range) }) { consumedAudio.append(range) }
    }
}

// An app the command may act on. Running apps carry a process id; installed apps a bundle URL.
struct AppCandidate: Equatable, Sendable {
    var id: String
    var names: [String]
    var url: URL?
    var pid: Int32?
    var displayName: String { names.first ?? id }
}

enum AppMatchConfidence: Equatable { case exact, alias, fuzzy }

enum AppResolution: Equatable {
    case match(AppCandidate, AppMatchConfidence)
    case ambiguous([String])
    case none
}

enum AppResolver {
    // Tightly scoped spoken names, in preference order. "BS Code" is how recognition hears VS Code.
    static let aliases: [String: [String]] = [
        "chrome": ["com.google.Chrome"],
        "chatgpt": ["com.openai.chat", "com.openai.codex"],
        "codex": ["com.openai.codex"],
        "vscode": ["com.microsoft.VSCode"],
        "bscode": ["com.microsoft.VSCode"],
        "vsc": ["com.microsoft.VSCode"],
    ]
    static let fuzzyThreshold = 0.8
    static let fuzzyMargin = 0.1
    static let minimumFuzzyLength = 4

    static func key(_ text: String) -> String { PhraseMatcher.words(text).joined() }

    static func resolve(_ spoken: String, among candidates: [AppCandidate], allowFuzzy: Bool) -> AppResolution {
        let target = key(spoken)
        guard !target.isEmpty else { return .none }
        let preferred = aliases[target] ?? []
        // “Chrome” names the real browser even when a local Automator wrapper has that display name.
        if target == "chrome", let browser = preferred.first {
            let matches = candidates.filter { $0.id == browser }
            if !matches.isEmpty { return uniqueAlias(matches) }
        }
        let exact = candidates.filter { $0.names.contains { key($0) == target } }
        if exact.count == 1 { return .match(exact[0], .exact) }
        if exact.count > 1 {
            // Two apps with the same name are reported, unless both belong to one alias family.
            let ids = Set(exact.map(\.id))
            if ids.count > 1, ids.isSubset(of: preferred), let id = preferred.first(where: ids.contains) {
                return uniqueAlias(exact.filter { $0.id == id })
            }
            return .ambiguous(exact.map(\.displayName))
        }
        if let id = preferred.first(where: { id in candidates.contains { $0.id == id } }) {
            return uniqueAlias(candidates.filter { $0.id == id })
        }
        guard allowFuzzy, target.count >= minimumFuzzyLength else { return .none }
        let scored = candidates.map { app in
            let spokenNames = aliases.compactMap { $0.value.contains(app.id) ? $0.key : nil }
            let keys = app.names.map(key) + spokenNames
            return (app: app, score: keys.map { similarity(target, $0) }.max() ?? 0)
        }
            .sorted { $0.score > $1.score }
        guard let best = scored.first, best.score >= fuzzyThreshold else { return .none }
        if scored.count > 1, best.score - scored[1].score < fuzzyMargin {
            return .ambiguous(scored.prefix(3).map { $0.app.displayName }) // Include close rivals just below the floor.
        }
        return .match(best.app, .fuzzy)
    }

    private static func uniqueAlias(_ apps: [AppCandidate]) -> AppResolution {
        apps.count == 1 ? .match(apps[0], .alias) : .ambiguous(apps.map(\.displayName))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        var beforePrevious = previous
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                if i >= 2, j >= 2, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = min(current[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

enum AppCommandDecision: Equatable {
    case activate(AppCandidate)
    case open(AppCandidate)
    case ignore            // Bare "open" without a confident app match is ordinary speech.
    case failure(String)
}

// Switch app and Open app are interchangeable (Ethan, 14 November 2026): both bring an open app
// forward and open an installed app that isn't running. This supersedes the earlier running-only
// Switch app. Only the bare "Open Safari" form stays stricter: it needs an exact name or alias.
enum AppCommandPlanner {
    // An exact name or alias of a running app wins without reading the installed catalog.
    static func decideRunning(_ candidate: AppCommandCandidate, running: [AppCandidate]) -> AppCommandDecision? {
        switch AppResolver.resolve(candidate.name, among: running, allowFuzzy: false) {
        case .match(let app, _): return .activate(app)
        case .ambiguous(let names): return candidate.bare ? .ignore : .failure(ambiguity(candidate.name, names))
        case .none: break
        }
        if let alternate = candidate.alternateName,
           case .match(let app, _) = AppResolver.resolve(alternate, among: running, allowFuzzy: false) { return .activate(app) }
        return nil
    }
    // Everything else compares running and verified installed apps together, so a close spelling of
    // a running app can't beat the exact name of an installed one. A running copy is preferred.
    static func decide(_ candidate: AppCommandCandidate, running: [AppCandidate], installed: [AppCandidate]) -> AppCommandDecision {
        if let decision = decideRunning(candidate, running: running) { return decision }
        let apps = merged(running: running, installed: installed)
        let exact = AppResolver.resolve(candidate.name, among: apps, allowFuzzy: false)
        if case .none = exact, let alternate = candidate.alternateName,
           case .match(let app, _) = AppResolver.resolve(alternate, among: apps, allowFuzzy: false) {
            return target(app)
        }
        let resolution = exact == .none && !candidate.bare
            ? AppResolver.resolve(candidate.name, among: apps, allowFuzzy: true) : exact
        switch resolution {
        case .match(let app, _): return target(app)
        case .ambiguous(let names): return candidate.bare ? .ignore : .failure(ambiguity(candidate.name, names))
        case .none: return candidate.bare ? .ignore : .failure("No app matches “\(candidate.name)”.")
        }
    }
    // A running app absorbs its installed copies' names; installed apps that aren't running follow.
    static func merged(running: [AppCandidate], installed: [AppCandidate]) -> [AppCandidate] {
        let runningIDs = Set(running.map(\.id))
        let open = running.map { app -> AppCandidate in
            var app = app
            for copy in installed where copy.id == app.id {
                for name in copy.names where !app.names.contains(name) { app.names.append(name) }
            }
            return app
        }
        return open + installed.filter { !runningIDs.contains($0.id) }
    }
    private static func target(_ app: AppCandidate) -> AppCommandDecision { app.pid == nil ? .open(app) : .activate(app) }
    private static func ambiguity(_ name: String, _ names: [String]) -> String {
        "“\(name)” matches \(names.joined(separator: " and ")). Say the full app name."
    }
}

// Installed apps for Open: only the standard application folders and one level of ordinary
// subfolders such as Utilities. Never looks inside an app bundle, follows URLs or runs anything.
struct InstalledAppCatalog {
    struct Root: Equatable { let url: URL; let nested: Bool }
    struct BundleInfo: Equatable { let id: String; let packageType: String?; let names: [String] }
    static let maximumApps = 1_500
    static let maximumEntriesPerFolder = 1_000

    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Root] {
        [Root(url: URL(fileURLWithPath: "/Applications", isDirectory: true), nested: true),
         Root(url: URL(fileURLWithPath: "/System/Applications", isDirectory: true), nested: true),
         Root(url: home.appendingPathComponent("Applications", isDirectory: true), nested: true)]
    }

    // Installers, uninstallers and rollback copies are never Open targets.
    static func isExcluded(_ name: String) -> Bool {
        let words = Set(PhraseMatcher.words(name))
        return name.hasPrefix(".") || name.lowercased().hasSuffix(".noindex") ||
            !words.isDisjoint(with: ["install", "installer", "uninstall", "uninstaller", "rollback", "rollbacks", "staging", "backups", "backup"])
    }

    static func scan(roots: [Root], list: (URL) -> [URL], read: (URL) -> BundleInfo?) -> [AppCandidate] {
        var result: [AppCandidate] = [], seen: Set<URL> = []
        func add(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath()
            guard result.count < maximumApps, isInstalledLocation(url, roots: roots),
                  let info = read(url), !info.id.isEmpty,
                  info.packageType == nil || info.packageType == "APPL",
                  !seen.contains(canonical) else { return }
            let fileName = url.deletingPathExtension().lastPathComponent
            var names: [String] = []
            for name in info.names + [fileName] where !name.isEmpty && !names.contains(name) { names.append(name) }
            guard !names.contains(where: isExcluded) else { return }
            seen.insert(canonical)
            result.append(AppCandidate(id: info.id, names: names, url: url))
        }
        for root in roots {
            let entries = list(root.url).prefix(maximumEntriesPerFolder).filter { !isExcluded($0.lastPathComponent) }
            for entry in entries where entry.pathExtension.lowercased() == "app" { add(entry) }
            for folder in entries where root.nested && folder.pathExtension.lowercased() != "app" {
                for nested in list(folder).prefix(maximumEntriesPerFolder)
                where nested.pathExtension.lowercased() == "app" && !isExcluded(nested.lastPathComponent) { add(nested) }
            }
        }
        return result
    }

    static func isInstalledLocation(_ url: URL, roots: [Root]) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        if roots.contains(where: { root in
            let prefix = root.url.resolvingSymlinksInPath().path + "/"
            guard canonical.path.hasPrefix(prefix) else { return false }
            let components = canonical.path.dropFirst(prefix.count).split(separator: "/")
            return (1...(root.nested ? 2 : 1)).contains(components.count) &&
                !components.contains { isExcluded(String($0)) }
        }) { return true }
        // Safari is a system-supplied link from /Applications into a signed macOS Cryptex.
        guard url.path == "/Applications/Safari.app" else { return false }
        return ["/System/Cryptexes/App/System/Applications/Safari.app",
                "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"].contains(canonical.path)
    }

    // The system's registered copy breaks ties only between copies already found in the catalog.
    static func preferRegisteredCopies(_ apps: [AppCandidate], registered: (String) -> URL?) -> [AppCandidate] {
        let groups = Dictionary(grouping: apps, by: \.id)
        var seen: Set<String> = []
        return apps.flatMap { app -> [AppCandidate] in
            guard seen.insert(app.id).inserted, let copies = groups[app.id] else { return [] }
            guard copies.count > 1, let selected = registered(app.id)?.resolvingSymlinksInPath(),
                  var preferred = copies.first(where: { $0.url?.resolvingSymlinksInPath() == selected }) else { return copies }
            for name in copies.flatMap(\.names) where !preferred.names.contains(name) { preferred.names.append(name) }
            return [preferred]
        }
    }

    // Lists a folder's immediate children only; app bundles are packages and are never entered here.
    // System apps such as Safari can be symlinked .app entries, so those are kept, but a symlinked
    // ordinary folder is never followed into.
    static func listDirectory(_ url: URL) -> [URL] {
        guard url.pathExtension.lowercased() != "app" else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]) else { return [] }
        return entries.filter { entry in
            // Safari's supported /Applications link can carry Finder's hidden flag.
            // The catalog still excludes dotfiles and staging/rollback names.
            guard !entry.lastPathComponent.hasPrefix(".") else { return false }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isHidden != true || entry.path == "/Applications/Safari.app" else { return false }
            if entry.pathExtension.lowercased() == "app" { return values?.isDirectory == true || values?.isSymbolicLink == true }
            return values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Native bundle metadata plus the Finder's localized name. Reads Info.plist only.
    static func readBundle(_ url: URL) -> BundleInfo? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let localized = FileManager.default.displayName(atPath: url.path)
        let names = [localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized,
                     info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String].compactMap { $0 }
        return BundleInfo(id: id, packageType: info["CFBundlePackageType"] as? String, names: names)
    }
}
