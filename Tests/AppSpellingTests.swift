// App prefixes, app-name spellings and their saved-settings upgrade (Ethan, 20 November 2026:
// "Show me Codex", "Show Codex", "Show app Codex", "Open app Codex", "Switch app Chrome", plus
// sensible speech-recognition spellings). Pure inputs, disposable defaults suites and an injected
// app catalogue only: no app is switched or opened, and no microphone or Voice call is used.
import Foundation

@main enum AppSpellingTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        var suites: [String] = []
        func fresh() -> UserDefaults {
            let name = "HelloChat-AppSpellings-\(UUID().uuidString)"
            suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        defer { for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }

        // Native names as this Mac's bundles report them: Codex's bundle name is ChatGPT, VS Code's is
        // Code and Ableton's is Live, and an Automator wrapper is also called Chrome.
        func installed(_ id: String, _ names: [String]) -> AppCandidate {
            AppCandidate(id: id, names: names, url: URL(fileURLWithPath: "/Applications/\(names[0]).app"))
        }
        let codex = AppCandidate(id: "com.openai.codex", names: ["Codex", "ChatGPT"], pid: 101)
        let chrome = AppCandidate(id: "com.google.Chrome", names: ["Google Chrome", "Chrome"], pid: 102)
        let code = installed("com.microsoft.VSCode", ["Visual Studio Code", "Code"])
        let live = installed("com.ableton.live", ["Ableton Live 12 Suite", "Live"])
        let claude = installed("com.anthropic.claudefordesktop", ["Claude"])
        let agentFlow = installed("com.ethansk.VoiceInkPlusPlus", ["Agent Flow", "AgentFlow"])
        let agenticMouse = installed("com.ethan.agentic-mouse", ["Agentic Mouse", "AgenticMouse"])
        let obs = installed("com.ethansk.obs-plus-plus", ["OBS++"])
        let obScene = installed("com.ethansk.OBScene", ["OBScene"])
        let notion = installed("notion.id", ["Notion"])
        let rekordbox = installed("com.pioneerdj.rekordboxdj", ["rekordbox"])
        let notes = installed("com.apple.Notes", ["Notes"])
        let catalogue = [code, live, claude, agentFlow, agenticMouse, obs, obScene, notion, rekordbox, notes,
                         installed("com.apple.automator.Chrome", ["Chrome NoMediaKeys", "Chrome"]),
                         installed("com.prakashjoshipax.VoiceInk", ["VoiceInk"]),
                         installed("ai.opencode.desktop", ["OpenCode"]),
                         installed("com.openclawdex.app", ["OpenClawdex"]),
                         installed("com.t3tools.t3code", ["T3 Code (Beta)"]),
                         installed("com.ethansk.FloatingMouse", ["Floating Mouse"]),
                         installed("com.lujjjh.LinearMouse", ["LinearMouse"]),
                         installed("com.agentsneversleep.app", ["Agents Never Sleep"]),
                         installed("com.ethansk.agentswarmmanagement", ["Agent Swarm Management"]),
                         installed("com.apple.Preview", ["Preview"]),
                         installed("com.apple.dt.Xcode", ["Xcode"])]
        let running = [codex, chrome]
        let everything = running + catalogue

        // Built-in catalogue: nothing from the 15 November table is removed, and later additions follow it.
        let original: [String: [String]] = [
            "com.google.Chrome": ["Chrome"], "com.openai.chat": ["Chat GPT"],
            "com.openai.codex": ["Codex", "Chat GPT", "Code X", "Code ex"],
            "com.microsoft.VSCode": ["VS Code", "BS Code", "VSC", "Vee Ess Code"],
            "com.ethansk.VoiceInkPlusPlus": ["Agent Flow", "Agent Flo", "Agent Floor"],
            "com.ethan.agentic-mouse": ["Agentic Mouse", "Agentic Mice"], "com.spotify.client": ["Spotify", "Spot if I"],
            "com.anthropic.claudefordesktop": ["Claude", "Claud", "Cloud"], "notion.id": ["Notion", "No shun"],
            "com.ethansk.obs-plus-plus": ["OBS", "OBS plus plus"], "com.ethansk.OBScene": ["OB Scene"],
            "com.pioneerdj.rekordboxdj": ["Record box", "Record books"],
        ]
        for (id, values) in original {
            check(Array((AppNameSpellings.defaults[id] ?? []).prefix(values.count)) == values, "15 November built-ins are intact: \(id)")
        }
        for upgrade in AppNameSpellings.upgrades {
            for (id, added) in upgrade.additions {
                check(Array((AppNameSpellings.defaults[id] ?? []).suffix(added.count)) == added, "Upgrade additions are also built-ins: \(id)")
                check(AppNameSpellings.cleaned(added) == added, "Upgrade additions are valid, distinct spellings: \(id)")
            }
        }
        let builtIn = AppNameSpellings()
        for (key, ids) in builtIn.aliases where ids.count > 1 {
            check(AppNameSpellings.isChatGPTFamily(key, ids: ids), "Only the ordered ChatGPT family shares a built-in spelling: \(key)")
        }
        for id in AppNameSpellings.defaults.keys {
            check(builtIn.conflicts(builtIn.spellings(for: id), for: id, among: everything).isEmpty,
                  "No built-in spelling of \(id) is another installed app's native name")
        }
        // Strict lookup (exact name or spelling, no fuzzy guess), as used after Open, Show and Show me.
        let expected: [(String, AppCandidate)] = [
            ("codex", codex), ("Codecs", codex), ("Kodaks", codex), ("codec", codex), ("code decks", codex),
            ("code ex", codex), ("CODEX", codex), ("chat gbt", codex), ("Chad GPT", codex), ("chrome", chrome),
            ("visual studio", code), ("VS code", code), ("ableton", live), ("Abelton", live), ("ableton live", live),
            ("clawed", claude), ("agents flow", agentFlow), ("agent flows", agentFlow), ("agent mouse", agenticMouse),
            ("a genetic mouse", agenticMouse), ("OBS plus", obs), ("OB seen", obScene), ("notions", notion),
            ("record boxes", rekordbox), ("record books", rekordbox),
        ]
        for (spoken, app) in expected {
            guard case .match(let found, _) = AppResolver.resolve(spoken, among: everything, allowFuzzy: false, spellings: builtIn) else {
                check(false, "Built-in spelling must resolve: \(spoken)"); continue
            }
            check(found.id == app.id, "\(spoken) names \(app.displayName)")
        }
        let chatApp = installed("com.openai.chat", ["ChatGPT"])
        for spoken in ["chat gpt", "chat gbt", "chad gpt"] {
            guard case .match(let found, _) = AppResolver.resolve(spoken, among: [codex, chatApp], allowFuzzy: false, spellings: builtIn) else {
                check(false, "ChatGPT family must resolve: \(spoken)"); continue
            }
            check(found.id == chatApp.id, "The ChatGPT app keeps its existing preference over Codex: \(spoken)")
        }

        // Saved spelling upgrade. Ethan's current list and both 20 November rollbacks contain exactly this.
        let ethanSpellings = ["Codex", "Chat GPT", "Code ex", "Codec"]
        let marker = AppNameSpellings.upgrades[0].marker
        let codexAdditions = AppNameSpellings.upgrades[0].additions[codex.id] ?? []
        check(["Codec", "Codecs", "Kodaks"].allSatisfy(codexAdditions.contains), "Codex gains the recognized Codec, Codecs and Kodaks spellings")
        func savedSpellings(_ defaults: UserDefaults) -> [String: [String]]? {
            defaults.object(forKey: AppNameSpellings.defaultsKey) as? [String: [String]]
        }
        let ethan = fresh()
        ethan.set([codex.id: ethanSpellings], forKey: AppNameSpellings.defaultsKey)
        let beforeUpgrade = AppNameSpellings(saved: ethan.object(forKey: AppNameSpellings.defaultsKey))
        let afterUpgrade = AppNameSpellings.load(from: ethan)
        let upgradedCodex: [String] = ethanSpellings + codexAdditions.filter { $0 != "Codec" }
        check(savedSpellings(ethan) == [codex.id: upgradedCodex], "His saved Codex list keeps every entry and its order, gains only new spellings, and no other app gains a saved list")
        check(upgradedCodex.contains("Codecs") && upgradedCodex.contains("Kodaks") && !upgradedCodex.contains("Code X"),
              "Codecs and Kodaks are added; an older built-in missing from a saved list is not restored")
        check(ethan.bool(forKey: marker) && afterUpgrade.spellings(for: codex.id) == upgradedCodex, "The upgrade is recorded and used")
        check(afterUpgrade.spellings(for: live.id) == ["Ableton", "Ableton Live", "Abelton"], "Apps without a saved list use new built-ins directly")
        let afterDeletion: [String] = ethanSpellings + ["Code decks"]
        ethan.set([codex.id: afterDeletion], forKey: AppNameSpellings.defaultsKey)
        check(AppNameSpellings.load(from: ethan).spellings(for: codex.id) == afterDeletion, "Spellings deleted after the upgrade stay deleted")
        check(savedSpellings(ethan) == [codex.id: afterDeletion], "A later launch doesn't rewrite the saved list")

        let empty = fresh()
        empty.set([code.id: [String](), "com.example.custom": ["Thing one"]], forKey: AppNameSpellings.defaultsKey)
        let emptyLoaded = AppNameSpellings.load(from: empty)
        let untouched: [String: [String]] = [code.id: [], "com.example.custom": ["Thing one"]]
        check(savedSpellings(empty) == untouched, "An explicit empty list and an unknown app's list are untouched")
        check(empty.bool(forKey: marker), "The upgrade is still recorded")
        check(emptyLoaded.spellings(for: code.id).isEmpty, "Explicit empty still means native names only")
        check(AppResolver.resolve("visual studio", among: everything, allowFuzzy: false, spellings: emptyLoaded) == .none,
              "A new built-in doesn't reach an explicitly empty app")
        check(AppResolver.resolve("visual studio code", among: everything, allowFuzzy: false, spellings: emptyLoaded) == .match(code, .exact),
              "Its native name still works")

        let collision = fresh()
        collision.set([codex.id: ["Codex"], notion.id: ["codecs"]], forKey: AppNameSpellings.defaultsKey)
        _ = AppNameSpellings.load(from: collision)
        let collisionCodex: [String] = ["Codex"] + codexAdditions.filter { $0 != "Codecs" }
        let collisionExpected: [String: [String]] = [codex.id: collisionCodex, notion.id: ["codecs", "Notions"]]
        check(savedSpellings(collision) == collisionExpected, "A new built-in already used by another app's saved list is skipped, never shared")

        let nativeDefaults = AppNameSpellings(overrides: [notion.id: ["Codecs"]])
        check(!nativeDefaults.spellings(for: codex.id).contains("Codecs") && nativeDefaults.aliases["codecs"] == [notion.id],
              "A saved alias wins over new suggestions even when Codex has no saved list")
        let cased = fresh()
        cased.set([codex.id: ["CODEX", "codecs", "chat gbt"]], forKey: AppNameSpellings.defaultsKey)
        _ = AppNameSpellings.load(from: cased)
        let casedCodex: [String] = ["CODEX", "codecs", "chat gbt"] + codexAdditions.filter { !["Codecs", "Chat GBT"].contains($0) }
        check(savedSpellings(cased) == [codex.id: casedCodex], "Case and spacing differences never add duplicates, and saved text keeps its case")

        let malformed = fresh()
        malformed.set("not a list", forKey: AppNameSpellings.defaultsKey)
        check(AppNameSpellings.load(from: malformed).overrides.isEmpty && malformed.string(forKey: AppNameSpellings.defaultsKey) == "not a list"
              && malformed.bool(forKey: marker), "Malformed saved spellings are left as they are")
        let none = fresh()
        check(AppNameSpellings.load(from: none) == AppNameSpellings() && none.object(forKey: AppNameSpellings.defaultsKey) == nil,
              "A new install saves no spelling list")
        let done = fresh()
        done.set([codex.id: ["Codex"]], forKey: AppNameSpellings.defaultsKey)
        done.set(true, forKey: marker)
        check(AppNameSpellings.load(from: done).spellings(for: codex.id) == ["Codex"], "An applied upgrade never runs again")

        // App prefixes. Ethan's saved rows and markers, from the current preferences and both rollbacks.
        let showRows = ["Show app", "Show me", "Show", "Open"]
        let phrases = fresh()
        phrases.set(["mutePhrase": ["Mute mic"], "silentPhrase": ["Mute speakers"], "sleepPhrase": ["Goodbye Chat"],
                     "switchAppPhrase": ["Switch up", "Switch to", "Switch"], "wakePhrase": ["Hey Chat", "Hello Shat"]],
                    forKey: PhraseList.defaultsKey)
        phrases.set(true, forKey: "phraseDefaults20261115")
        phrases.set(true, forKey: "mutePhraseDefaults20261118")
        phrases.set("Hello Chat", forKey: "wakePhrase")
        phrases.set("Bye Chat", forKey: "sleepPhrase")
        PhraseList.seedDefaults(in: phrases)
        var rows = PhraseList.decode(phrases.object(forKey: PhraseList.defaultsKey))
        check(rows[.openAppPhrase] == showRows && phrases.bool(forKey: PhraseList.editableShortFormsKey),
              "Show app, Show me, Show and Open are listed once as editable rows")
        let unchangedRows: [(PhraseSlot, [String])] = [(.switchAppPhrase, ["Switch up", "Switch to", "Switch"]), (.wakePhrase, ["Hey Chat", "Hello Shat"]),
                                                       (.sleepPhrase, ["Goodbye Chat"]), (.mutePhrase, ["Mute mic"]), (.silentPhrase, ["Mute speakers"])]
        for (slot, saved) in unchangedRows {
            check(Array((rows[slot] ?? []).prefix(saved.count)) == saved, "Existing rows, including his own Hello Shat, keep their order: \(slot.rawValue)")
        }
        let configuration = PhraseConfiguration(rows: Dictionary(uniqueKeysWithValues: PhraseSlot.allCases.map {
            ($0, [$0.savedValue(in: phrases)] + (rows[$0] ?? []))
        }))
        let configuredOpen: [String] = ["Open app"] + showRows
        check(configuration.phrases(for: .openAppPhrase) == configuredOpen, "Every new app row takes part in detection")
        for row in 1...showRows.count {
            check(configuration.issue(.openAppPhrase, row: row) == nil, "The new app rows have no conflict: \(row)")
        }
        check(configuration.phrases(for: .showVoicePhrase) == ["Show voice"], "Show voice keeps its phrase")
        rows[.openAppPhrase] = nil
        phrases.set(PhraseList.encode(rows, preserving: phrases.object(forKey: PhraseList.defaultsKey)), forKey: PhraseList.defaultsKey)
        PhraseList.seedDefaults(in: phrases)
        check(PhraseList.decode(phrases.object(forKey: PhraseList.defaultsKey))[.openAppPhrase] == nil, "Deleted Show rows stay deleted")
        let newInstall = fresh()
        PhraseList.seedDefaults(in: newInstall)
        let newRows = PhraseList.decode(newInstall.object(forKey: PhraseList.defaultsKey))
        check(newRows[.openAppPhrase] == showRows && newRows[.switchAppPhrase] == ["Switch up", "Switch to", "Switch"], "New installs list the Show rows")
        for (key, value) in [("openAppPhrase", "Launch app"), ("switchAppPhrase", "Jump to")] {
            let custom = fresh()
            custom.set(value, forKey: key)
            PhraseList.seedDefaults(in: custom)
            check(PhraseList.decode(custom.object(forKey: PhraseList.defaultsKey))[.openAppPhrase] == nil
                  && !custom.bool(forKey: PhraseList.editableShortFormsKey), "A customized app prefix gains no Show rows and keeps its short form")
        }
        let owned = fresh()
        owned.set(true, forKey: "phraseDefaults20261115")
        owned.set(["zoomInPhrase": ["Show"]], forKey: PhraseList.defaultsKey)
        PhraseList.seedDefaults(in: owned)
        let ownedRows = PhraseList.decode(owned.object(forKey: PhraseList.defaultsKey))
        check(ownedRows[.zoomInPhrase] == ["Show"], "Another command keeps its own phrase")
        check(ownedRows[.openAppPhrase] == ["Show app", "Show me", "Open"], "A phrase another command uses is never taken over")

        let speakerConflict = fresh()
        let customSpeaker = PhrasePattern(text: "Open kitchen", similar: false)
        PhraseList.seedDefaults(in: speakerConflict) { !$0.matches(in: PhraseMatcher.words(customSpeaker.text)).isEmpty }
        check(!speakerConflict.bool(forKey: PhraseList.editableShortFormsKey), "A protected longer speaker phrase cannot remove the old Open Safari short form")
        let speakerRows = PhraseList.decode(speakerConflict.object(forKey: PhraseList.defaultsKey))
        for (text, expected) in [("Open Safari", ["safari"]), ("Open kitchen", [])] {
            var detector = AppCommandDetector(usesEditableShortForms: speakerConflict.bool(forKey: PhraseList.editableShortFormsKey))
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 1)
            let prefixes = (["Open app"] + (speakerRows[.openAppPhrase] ?? [])).map { PhrasePattern(text: $0, similar: false) }
            check(detector.poll(switchPrefixes: [], openPrefixes: prefixes, reserved: [customSpeaker]).map(\.name) == expected,
                  "Open stays available outside the custom speaker command: " + text)
        }

        // Detection with his prefixes after the upgrade.
        func patterns(_ slot: PhraseSlot, _ texts: [String]) -> [PhrasePattern] {
            texts.map { PhrasePattern(slot: slot, text: $0, similar: true, dictionaries: .init()) }
        }
        let switches = patterns(.switchAppPhrase, ["Switch app", "Switch up", "Switch to", "Switch"])
        let opens = patterns(.openAppPhrase, ["Open app"] + showRows)
        let showVoice = patterns(.showVoicePhrase, ["Show voice"])
        func summary(_ command: AppCommandCandidate) -> String {
            "\(command.kind.rawValue) \(command.name) bare=\(command.bare) alternate=\(command.alternateName ?? "-")"
        }
        func heard(_ text: String, reserved: [PhrasePattern]? = nil, openRows: [PhrasePattern]? = nil,
                   editable: Bool = true) -> (commands: [AppCommandCandidate], decisions: [String]) {
            var detector = AppCommandDetector(usesEditableShortForms: editable)
            var decisions: [String] = []
            detector.audio(level: 0.2, seconds: 0.1)
            detector.update(text, at: 1)
            detector.audio(level: 0, seconds: 1)
            let commands = detector.poll(switchPrefixes: switches, openPrefixes: openRows ?? opens, reserved: reserved ?? showVoice,
                                         onDecision: { _, decision, _ in decisions.append(decision) })
            return (commands, decisions)
        }
        func plan(_ command: AppCommandCandidate, spellings: AppNameSpellings? = nil, apps: [AppCandidate]? = nil) -> AppCommandDecision {
            AppCommandPlanner.decide(command, running: running, installed: apps ?? catalogue, spellings: spellings ?? afterUpgrade)
        }
        let requests: [(String, String, AppCommandDecision)] = [
            ("Show me Codex", "openApp codex bare=true alternate=-", .activate(codex)),
            ("Show Codex", "openApp codex bare=true alternate=-", .activate(codex)),
            ("Show app Codex", "openApp codex bare=false alternate=app codex", .activate(codex)),
            ("Open app Codex", "openApp codex bare=false alternate=app codex", .activate(codex)),
            ("Switch app Kodaks?", "switchApp kodaks bare=false alternate=-", .activate(codex)),
            ("Switch app Chrome", "switchApp chrome bare=false alternate=-", .activate(chrome)),
            ("SHOW ME CODEX", "openApp codex bare=true alternate=-", .activate(codex)),
            ("show App codecs", "openApp codecs bare=false alternate=app codecs", .activate(codex)),
            ("Switch app Kodaks", "switchApp kodaks bare=false alternate=-", .activate(codex)),
            ("Please show me Codex please", "openApp codex bare=true alternate=-", .activate(codex)),
            ("OK show Ableton", "openApp ableton bare=true alternate=-", .open(live)),
            ("Again show app Codex", "openApp codex bare=false alternate=app codex", .activate(codex)),
            ("Switch to Chrome", "switchApp chrome bare=false alternate=-", .activate(chrome)),
            ("Open Codex", "openApp codex bare=true alternate=-", .activate(codex)),
        ]
        for (text, expectedSummary, decision) in requests {
            let result = heard(text)
            check(result.commands.map(summary) == [expectedSummary], "Detected once: \(text)")
            check(result.commands.first.map { plan($0) } == decision, "Resolved: \(text)")
        }
        // Each listed short form is its own row: deleting one removes only that form.
        check(heard("Show Codex", openRows: patterns(.openAppPhrase, ["Open app", "Show app", "Show me", "Open"])).commands.isEmpty
              && heard("Show me Codex", openRows: patterns(.openAppPhrase, ["Open app", "Show app", "Show me", "Open"])).commands.count == 1,
              "Deleting Show removes only Show Codex")
        check(heard("Open Codex", openRows: patterns(.openAppPhrase, ["Open app"] + showRows.dropLast())).commands.isEmpty
              && heard("Open app Codex", openRows: patterns(.openAppPhrase, ["Open app"] + showRows.dropLast())).commands.count == 1,
              "Deleting Open removes only the Open short form")
        check(heard("Open Codex", openRows: patterns(.openAppPhrase, ["Open app"]), editable: false).commands.map(summary)
              == ["openApp codex bare=true alternate=-"], "Before the upgrade, Open app keeps its implicit short form")
        // Ordinary language. A short form needs an exact name or spelling, keeps "the", and stays
        // silent when nothing matches; Code, Notes and Preview are real names here.
        for text in ["Show me the code", "Show me the notes", "Show the preview", "Show me how to do it",
                     "Show me what you found", "Show codes", "Show me Codex the file"] {
            let result = heard(text)
            check(result.commands.count == 1 && plan(result.commands[0]) == .ignore, "Ordinary speech after Show does nothing: \(text)")
        }
        for text in ["Can you show me Codex", "Could you show Codex", "Don't show Codex", "Do not show app Codex",
                     "Never show me Codex", "I said show Codex", "We should show Codex", "The show app prefix is broken",
                     "Show app command doesn't work", "Do it again show app Codex", "Again show Codex", "Hello chat show me Codex"] {
            check(heard(text).commands.isEmpty, "Mention, negation, discussion or context is ignored: \(text)")
        }
        // Residual: an exact app name after Show is a request, as after Open.
        check(heard("Show notes").commands.first.map { plan($0) } == .open(notes), "Show plus an exact app name opens it")

        // Show voice owns its own words, whether or not that command itself was accepted.
        let voiceApp = installed("com.example.voice", ["Voice"])
        check(heard("Show voice", reserved: []).commands.first.map { plan($0, apps: catalogue + [voiceApp]) } == .open(voiceApp),
              "Without reservation, Show voice would reach an app named Voice")
        for text in ["Show voice", "Please show voice", "show voice settings", "Don't show voice"] {
            let result = heard(text)
            check(result.commands.isEmpty && result.decisions == ["rejected_reserved"], "Show voice is never an app request: \(text)")
        }
        var owner = StandaloneWake()
        owner.audio(level: 0.2, seconds: 0.1)
        owner.update("Show voice", at: 1)
        check(owner.poll(at: 1, phrase: "Show voice", similar: true, rejectNegated: true, patterns: showVoice, directOnly: true),
              "The Show voice command still accepts its phrase")
        check(heard("Show voice. Show Codex").commands.map(summary) == ["openApp codex bare=true alternate=-"],
              "A later app request after Show voice still works")
        check(heard("Show app voice").commands.map(summary) == ["openApp voice bare=false alternate=app voice"],
              "An explicit Show app request isn't the Show voice phrase")

        // Ambiguity: a strict short form stays silent; the full prefix explains.
        let otherLive = installed("com.example.live", ["Live"])
        check(heard("Show Live").commands.first.map { plan($0, apps: catalogue + [otherLive]) } == .ignore, "Ambiguous Show short form is silent")
        if case .failure(let text)? = heard("Show app Live").commands.first.map({ plan($0, apps: catalogue + [otherLive]) }) {
            check(text.contains("Ableton Live 12 Suite") && text.contains("Say the full app name"), "Ambiguous full prefix asks for the full name")
        } else { check(false, "Ambiguous full prefix must not dispatch") }
        check(heard("Show Chrome").commands.first.map { plan($0) } == .activate(chrome), "Chrome still means the browser, not its Automator wrapper")

        // Archived recognition 34C2F75B-3CEB-40CF-802F-AE8D934DFB73, in its saved pieces. The archive has
        // approximate times, not word spans, so the pauses between its pieces are supplied here.
        var archive = AppCommandDetector(usesEditableShortForms: true)
        var archiveDecisions: [String] = []
        func archivePoll(_ text: String, at time: Double) -> [String] {
            archiveDecisions = []
            archive.audio(level: 0.2, seconds: 0.1)
            archive.update(text, at: time)
            archive.audio(level: 0, seconds: 1)
            return archive.poll(switchPrefixes: switches, openPrefixes: opens, reserved: showVoice,
                                onDecision: { _, decision, _ in archiveDecisions.append(decision) }).map(summary)
        }
        let first = "for most people black peppercorns are totally safe show codex"
        check(archivePoll(first, at: 1).isEmpty && archiveDecisions == ["rejected_context"],
              "Archive 1: show codex joined to the assistant's sentence without a recorded pause is not a request")
        let second = first + " show codex"
        check(archivePoll(second, at: 2) == ["openApp codex bare=true alternate=-"] && archiveDecisions == ["accepted"],
              "Archive 2: a separate show codex is a request")
        let third = second + " again show app codex? Why isn't that working? All these commands should be default variations that need to be set for me in H chat send that to that open app codecs oh a codex needs to be a spelling of the app bro you got rid of all the spellings from before get it to look at open to have opus also find what was missed and add it all back all the useful stuff we had on the first time when when he added it and I liked it cause so much is now gone"
        check(archivePoll(third, at: 3) == ["openApp codex bare=false alternate=app codex"]
              && archiveDecisions == ["accepted", "rejected_context", "rejected_context"],
              "Archive 3: again show app codex is a request; open app codecs and open to have opus inside the explanation are not")
        let fourth = third + " open app codecs"
        check(archivePoll(fourth, at: 4) == ["openApp codecs bare=false alternate=app codecs"] && archiveDecisions == ["accepted"],
              "Archive 4: open app codecs said on its own is a request")
        let codecs = heard("Open app codecs").commands[0]
        check(plan(codecs) == .activate(codex), "Codecs names Codex after the upgrade")
        check(plan(codecs, spellings: beforeUpgrade) == .activate(codex), "His saved Codec already reached Codex by a close spelling")
        if case .failure = plan(codecs, spellings: AppNameSpellings(overrides: [codex.id: original[codex.id]!])) {
            check(true, "The original Codex built-ins alone could not resolve codecs")
        } else { check(false, "The original Codex built-ins must not resolve codecs") }
        check(plan(codecs, spellings: AppNameSpellings()) == .activate(codex), "New built-ins resolve codecs without a saved list")

        print("Passed \(checks) app spelling checks")
    }
}
