import Foundation

@main enum SpeechModelTests {
    static func main() {
        let domain = "HelloChat.SpeechModelTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }

        precondition(SpeechModel.saved(in: preferences) == .nemotron560)
        precondition(SpeechModel.allCases.first == .nemotron560)
        precondition(Set(SpeechModel.allCases.map(\.rawValue)).count == 4)
        for model in SpeechModel.allCases {
            preferences.set(model.rawValue, forKey: "speechModel")
            let reopened = UserDefaults(suiteName: domain)!
            precondition(SpeechModel.saved(in: reopened) == model, "Preserve an existing saved choice")
        }
        preferences.set("unknown-model", forKey: "speechModel")
        precondition(SpeechModel.saved(in: preferences) == .nemotron560)
        precondition(preferences.string(forKey: "speechModel") == "unknown-model", "Reading must not overwrite preferences")
        print("Speech model defaults, list order, saved choices and fallback passed")
    }
}
