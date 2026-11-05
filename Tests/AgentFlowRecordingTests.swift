import Foundation

@main enum AgentFlowRecordingTests {
    @MainActor static func main() {
        precondition(!AgentFlowRecordingMonitor.hasActiveOrUnknownInput(appPresent: false, recording: nil))
        precondition(!AgentFlowRecordingMonitor.hasActiveOrUnknownInput(appPresent: true, recording: false))
        precondition(AgentFlowRecordingMonitor.hasActiveOrUnknownInput(appPresent: true, recording: true))
        precondition(AgentFlowRecordingMonitor.hasActiveOrUnknownInput(appPresent: true, recording: nil))
        print("Agent Flow diagnostic: presence, recording, idle and unreadable-state policy passed")
    }
}
