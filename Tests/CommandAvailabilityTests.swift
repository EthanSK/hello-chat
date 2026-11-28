// Catalogue and persisted choices only; no microphone, app input or audio routes. — GPT-6.1 Sol
import Foundation

@main enum CommandAvailabilityTests {
    static func main() {
        let commands = HomeCommand.all
        precondition(commands.count == 24)
        precondition(Set(commands.map(\.id)).count == commands.count)
        precondition(Set(commands.flatMap(\.slots)) == Set(PhraseSlot.allCases), "Every current phrase slot inherits a command switch")
        precondition(commands.last == .speakerOutput)
        precondition(HomeCommand.containing(.openAppPhrase) == HomeCommand.containing(.switchAppPhrase))
        precondition(HomeCommand.containing(.rewindFivePhrase) == HomeCommand.containing(.rewindVideoPhrase))
        precondition(HomeCommand.containing(.rewindTenPhrase) == HomeCommand.containing(.rewindVideoPhrase))
        precondition(HomeCommand.containing(.zoomInPhrase) != HomeCommand.containing(.zoomOutPhrase))
        precondition(HomeCommand.containing(.pauseMusicPhrase) != HomeCommand.containing(.playMusicPhrase))
        for slot in PhraseSlot.allCases { precondition(HomeCommand.forAction(slot.rawValue) == HomeCommand.containing(slot)) }
        for action in VoiceAudioAction.allCases { precondition(HomeCommand.forAction(action.rawValue) == HomeCommand.containing(action.slots[0])) }
        precondition(HomeCommand.forAction("app") == HomeCommand.containing(.openAppPhrase))
        precondition(HomeCommand.forAction("speakerOutput") == .speakerOutput)
        let suite = "HChatAvailabilityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = CommandAvailability.load(from: defaults)
        precondition(commands.allSatisfy(saved.isEnabled), "An existing or future command is on without a disabled identity")
        let future = HomeCommand(id: "futureCommand", slots: [])
        precondition(saved.isEnabled(future))
        for command in commands {
            saved.setEnabled(false, for: command); saved.save(to: defaults)
            precondition(!CommandAvailability.load(from: defaults).isEnabled(command))
            for slot in command.slots { precondition(!saved.isEnabled(slot)) }
        }
        precondition(saved.isEnabled(future))
        saved.setEnabled(false, for: future)
        saved.save(to: defaults)
        for command in commands { saved.setEnabled(true, for: command) }
        saved.save(to: defaults)
        precondition(CommandAvailability.load(from: defaults).disabledIDs == [future.id], "Keep unknown identities across app-version changes")
        saved.setEnabled(true, for: future); saved.save(to: defaults)
        precondition(defaults.object(forKey: CommandAvailability.preferenceKey) == nil)
        precondition(commands.allSatisfy(CommandAvailability.load(from: defaults).isEnabled))
        print("Command availability: 20 groups, all phrase slots, directional choices and persistence passed")
    }
}
