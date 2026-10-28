import Foundation

@main struct CodexDiscoveryTests {
    static func main() {
        func allowed(_ bundle: String, _ exe: String, id: String = "com.openai.codex", reported: String? = nil) -> Bool {
            VoiceBridge.isCodexApplication(bundleIdentifier: id, bundlePath: bundle,
                                          reportedExecutable: reported ?? exe, actualExecutable: exe)
        }
        precondition(allowed("/Applications/Codex.app", "/Applications/Codex.app/Contents/MacOS/Codex"))
        precondition(allowed("/Applications/ChatGPT.app", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        precondition(allowed("/Users/example/Applications/Codex.app", "/Users/example/Applications/Codex.app/Contents/MacOS/Codex"))
        precondition(!allowed("/Applications/Codex.app", "/tmp/other", id: "com.openai.codex"))
        precondition(!allowed("/Applications/Codex.app", "/Applications/Codex.app/Contents/MacOS/Codex", id: "com.example.other"))
        precondition(!allowed("/Applications/Codex.app", "/Applications/Codex.app/Contents/MacOS/Changed", reported: "/Applications/Codex.app/Contents/MacOS/Codex"))
        print("Codex discovery: standard, legacy, relocated, and rejected identity checks passed")
    }
}
