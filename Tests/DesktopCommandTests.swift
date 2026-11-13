// Switch app, Open app and Zoom: detection, resolution, catalog and the zoom key contract.
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
        func failureText(_ decision: AppCommandDecision) -> String? { if case .failure(let text) = decision { return text }; return nil }

        // Slots: four new canonical preferences after the unchanged Voice and Browser fields.
        check(PhraseSlot.voiceSlots.count == 7 && PhraseSlot.videoSlots == [.pauseVideoPhrase, .playVideoPhrase], "Existing fields are intact")
        check(PhraseSlot.desktopSlots == [.switchAppPhrase, .openAppPhrase, .zoomInPhrase, .zoomOutPhrase], "Desktop fields follow them")
        check(PhraseSlot.desktopSlots.map(\.rawValue) == ["switchAppPhrase", "openAppPhrase", "zoomInPhrase", "zoomOutPhrase"], "Canonical preference names")
        check(PhraseSlot.desktopSlots.map(\.defaultText) == ["Switch app", "Open app", "Zoom in", "Zoom out"], "Defaults")
        check(PhraseSlot.switchAppPhrase.example != nil && PhraseSlot.openAppPhrase.example != nil && PhraseSlot.zoomInPhrase.example == nil,
              "Only the app prefixes carry an example")
        check(PhraseSlot.switchAppPhrase.label.hasSuffix("prefix") && PhraseSlot.openAppPhrase.label.hasSuffix("prefix"), "App commands are labelled as prefixes")

        // App command detection.
        let switchPrefix = PhrasePattern(slot: .switchAppPhrase, text: "Switch app", similar: true, dictionaries: .init())
        let openPrefix = PhrasePattern(slot: .openAppPhrase, text: "Open app", similar: true, dictionaries: .init())
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

        // Resolution: running apps for Switch, installed apps for Open.
        let chrome = AppCandidate(id: "com.google.Chrome", names: ["Google Chrome"], pid: 11)
        let chatGPT = AppCandidate(id: "com.openai.chat", names: ["ChatGPT"], pid: 12)
        let codex = AppCandidate(id: "com.openai.codex", names: ["Codex"], pid: 13)
        let code = AppCandidate(id: "com.microsoft.VSCode", names: ["Code", "Visual Studio Code"], pid: 14)
        let running = [chrome, chatGPT, codex, code]
        check(AppCommandPlanner.decideSwitch("chrome", running: running) == .activate(chrome), "Chrome alias")
        let chromeWrapper = AppCandidate(id: "example.workflow", names: ["Chrome"], pid: 20)
        check(AppCommandPlanner.decideSwitch("chrome", running: [chromeWrapper, chrome]) == .activate(chrome), "Chrome alias selects the browser over a named wrapper")
        check(AppCommandPlanner.decideSwitch("chorme", running: running) == .activate(chrome), "Close spelling of a known alias")
        check(AppCommandPlanner.decideSwitch("chat gpt", running: running) == .activate(chatGPT), "Chat GPT is ChatGPT when it is open")
        check(AppCommandPlanner.decideSwitch("chat gpt", running: [chrome, codex]) == .activate(codex), "Chat GPT falls back to Codex")
        check(AppCommandPlanner.decideSwitch("bs code", running: running) == .activate(code), "BS Code is VS Code")
        check(AppCommandPlanner.decideSwitch("visual studio code", running: running) == .activate(code), "Exact bundle name")
        check(AppCommandPlanner.decideSwitch("googel chrome", running: running) == .activate(chrome), "Conservative fuzzy match")
        check(failureText(AppCommandPlanner.decideSwitch("safari", running: running))?.contains("already open") == true,
              "Switch never reaches for an app that isn't running")
        let impostor = AppCandidate(id: "com.example.chat", names: ["ChatGPT"], pid: 20)
        check(failureText(AppCommandPlanner.decideSwitch("chat gpt", running: [chatGPT, impostor]))?.contains("Say the full app name") == true,
              "An ambiguous exact name is never masked by the alias")
        let notes = [AppCandidate(id: "a.notes", names: ["Notes"], pid: 21), AppCandidate(id: "b.notes", names: ["Notes"], pid: 22)]
        check(failureText(AppCommandPlanner.decideSwitch("notes", running: notes)) != nil, "Two apps with one name are ambiguous")
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
        check(AppCommandPlanner.decideOpen(command(.openApp, "safari", bare: true), installed: installed) == .open(safari), "Open Safari")
        check(AppCommandPlanner.decideOpen(command(.openApp, "chrome", bare: true), installed: installed) == .open(installedChrome), "Open Chrome")
        check(AppCommandPlanner.decideOpen(command(.openApp, "app store", bare: true), installed: installed) == .open(appStore), "Open the App Store")
        check(AppCommandPlanner.decideOpen(command(.openApp, "store", alternate: "app store"), installed: installed) == .open(appStore), "Open app store")
        check(AppCommandPlanner.decideOpen(command(.openApp, "store", alternate: "app store"),
              installed: installed + [installedApp("x.score", "Score")]) == .open(appStore), "Exact App Store beats fuzzy Score")
        check(AppCommandPlanner.decideOpen(command(.openApp, "safar"), installed: installed) == .open(safari), "Open app prefix may fuzzy-match")
        for name in ["safar", "door", "chrome settings", "codex"] {
            check(AppCommandPlanner.decideOpen(command(.openApp, name, bare: true), installed: installed) == .ignore, "Bare open stays ordinary speech: \(name)")
        }
        check(failureText(AppCommandPlanner.decideOpen(command(.openApp, "chrome settings"), installed: installed)) != nil, "Open app reports no match")
        check(AppCommandPlanner.decideOpen(command(.openApp, "codex", bare: true), installed: installed) == .ignore, "Open never uses running apps")

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

        var result = await commands.perform(command(.switchApp, "chrome"))
        check(result == DesktopCommandResult(message: "Switched to Google Chrome", diagnostic: "frontmost"), "Switch confirms the front app")
        check(probe.activated == [chrome.id] && probe.opened.isEmpty && probe.scans == 0, "Switch only activates a running app")
        probe.bringsForward = false
        result = await commands.perform(command(.switchApp, "codex"))
        check(result.diagnostic == "dispatched" && result.message == "Asked Codex to come forward, but it isn't in front yet." && probe.sleeps == 10,
              "Dispatch is not reported as success")
        result = await commands.perform(command(.switchApp, "safari"))
        check(result.message?.hasPrefix("No open app matches") == true && probe.opened.isEmpty && probe.scans == 0, "Switch never launches")
        probe.bringsForward = true
        result = await commands.perform(command(.openApp, "safari", bare: true))
        check(result == DesktopCommandResult(message: "Opened Safari", diagnostic: "frontmost") && probe.opened == [safari.id], "Open Safari")
        result = await commands.perform(command(.openApp, "codex", bare: true))
        check(result == DesktopCommandResult(message: nil, diagnostic: "ignored") && probe.opened == [safari.id], "Bare open never uses running apps")
        check(probe.scans == 1, "The installed catalog is cached, not rescanned per command")
        probe.verifies = false
        result = await commands.perform(command(.openApp, "app store", bare: true))
        check(result.message == "App Store is no longer installed there." && probe.opened == [safari.id], "A vanished bundle is not opened")
        probe.verifies = true
        _ = await commands.perform(command(.openApp, "safari", bare: true))
        check(probe.scans == 2, "A vanished bundle refreshes the catalog")
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

        print("Passed \(checks) desktop command checks")
    }
}
