import Foundation

@main enum AgentFlowRecordingTests {
    @MainActor static func main() {
        precondition(!AgentFlowRecordingMonitor.shouldSuppress(appPresent: false, recording: nil))
        precondition(!AgentFlowRecordingMonitor.shouldSuppress(appPresent: true, recording: false))
        precondition(AgentFlowRecordingMonitor.shouldSuppress(appPresent: true, recording: true))
        precondition(AgentFlowRecordingMonitor.shouldSuppress(appPresent: true, recording: nil))
        print("Agent Flow presence, recording, idle and unreadable-state policy passed")
    }
}
