// H Chat hands the exact newly opened call to the running Model Bar, then verifies it
// after restoring ordinary defaults. This never starts Voice or sends text. — GPT-6.1 Sol
import AppKit
import Foundation

enum ModelBarVoiceSpeed {
    struct Request: Encodable {
        let requestId: UUID
        let callToken: String
        let expiresAtMs: Int64
        let speed = "ultrafast"
        let chatTitle: String
        let verifyOnly: Bool
    }
    struct Receipt: Codable {
        let requestId: UUID
        let callToken: String
        let expiresAtMs: Int64
        let result: String
        let selectedSpeed: String?
        let displaySpeed: String?
        let model: String?
        let reasoning: String?
        let reason: String?

        func confirms(_ request: Request, at now: Date) -> Bool {
            requestId == request.requestId && VoicePeerCall(token: callToken) == VoicePeerCall(token: request.callToken)
                && expiresAtMs == request.expiresAtMs && expiresAtMs > Int64(now.timeIntervalSince1970 * 1000)
                && (request.verifyOnly ? result == "already-selected" : ["applied", "already-selected"].contains(result))
                && selectedSpeed == "ultrafast" && displaySpeed == "ultrafast"
                && model?.isEmpty == false && reasoning?.isEmpty == false
        }
    }

    @MainActor struct Environment {
        var current: () async -> VoicePeerReceipt = { await Task.detached { VoicePeerControl.localStatus() }.value }
        var title: (UUID) throws -> String = { try CodexChatSpeed.uniqueTitle(thread: $0, database: VoiceTimeline.databaseURL()) }
        var open: (VoicePeerCall) async -> Bool = { call in
            guard let url = URL(string: "codex://threads/" + call.thread.uuidString.lowercased()) else { return false }
            return await VoiceBridge.openChat(call.pid, url)
        }
        var read: (VoicePeerCall) async -> CodexChatSpeed.Result = { call in
            await Task.detached { CodexChatSpeed.perform(thread: call.thread, speed: nil, expectedCall: call) }.value
        }
        var transact: (VoicePeerCall, @escaping @Sendable () async -> CodexChatSpeed.Result) async -> CodexChatSpeed.Result = { call, apply in
            guard let executable = try? CodexVoiceSpeed.executable(pid: call.pid) else {
                return .init(status: "unavailable", thread: call.thread, speed: nil, model: nil)
            }
            return await CodexVoiceSpeed.shared.preservingSpeedDefaults(thread: call.thread, speed: .ultrafast,
                pid: call.pid, executable: executable, apply: apply)
        }
        var relay: (Request) async -> Receipt? = { request in await Task.detached { send(request) }.value }
        var now: () -> Date = Date.init
    }

    // One mutation followed by one explicitly read-only bar verification. Uncertain mutation
    // results are terminal; restoring defaults must never trigger a replay. — GPT-6.1 Sol
    @MainActor static func perform(call: VoicePeerCall, environment: Environment? = nil) async -> CodexChatSpeed.Result {
        let e = environment ?? Environment()
        func failed(_ status: String = "unconfirmed") -> CodexChatSpeed.Result {
            .init(status: status, thread: call.thread, speed: nil, model: nil)
        }
        func current() async -> Bool {
            let state = await e.current()
            return !Task.isCancelled && state.status == .active && state.call == call
        }
        guard await current(), await e.open(call), await current(), let title = try? e.title(call.thread) else { return failed("changed") }
        let before = await e.read(call)
        guard before.succeeded, let originalModel = before.model, await current() else {
            return failed(before.succeeded ? "unconfirmed" : before.status)
        }
        func request(verifyOnly: Bool) -> Request {
            .init(requestId: UUID(), callToken: call.token,
                  expiresAtMs: Int64(e.now().timeIntervalSince1970 * 1000) + 30_000,
                  chatTitle: title, verifyOnly: verifyOnly)
        }
        var appliedReceipt: Receipt?
        let apply: @Sendable () async -> CodexChatSpeed.Result = { @MainActor in
            // The defaults owner can temporarily hold an empty window. Bind the bar to this
            // call again before asking it to operate; never use whichever composer is focused. — GPT-6.1 Sol
            guard await current(), await e.open(call), await current(), (try? e.title(call.thread)) == title else { return failed("changed") }
            let input = request(verifyOnly: before.speed == .ultrafast)
            guard let receipt = await e.relay(input) else { return failed("modelBarUnavailable") }
            guard receipt.confirms(input, at: e.now()), await current() else { return failed("modelBarUnconfirmed") }
            appliedReceipt = receipt
            return .init(status: "confirmed", thread: call.thread, speed: .ultrafast, model: receipt.model)
        }
        let applied: CodexChatSpeed.Result
        if before.speed == .ultrafast {
            // An already-selected native state needs bar confirmation, but no temporary
            // defaults mutation or extra draft window. — GPT-6.1 Sol
            applied = await apply()
        } else { applied = await e.transact(call, apply) }
        guard applied.succeeded, await current(), await e.open(call), await current() else {
            return applied.succeeded ? failed("changed") : applied
        }
        let after = await e.read(call)
        guard after.succeeded, after.model == originalModel, after.speed == .ultrafast,
              await current(), (try? e.title(call.thread)) == title else { return failed() }
        let verification = request(verifyOnly: true)
        guard let receipt = await e.relay(verification), receipt.confirms(verification, at: e.now()),
              receipt.model == appliedReceipt?.model, receipt.reasoning == appliedReceipt?.reasoning,
              await current() else { return failed() }
        return .init(status: "confirmed", thread: call.thread, speed: .ultrafast, model: originalModel)
    }

    // The bar's versioned CLI relays to its already running signed desktop process. A bounded
    // failure never launches another bar, selects a different chat or retries. — GPT-6.1 Sol
    private static func send(_ request: Request) -> Receipt? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ethansk.codex-model-bar")
            .filter { !$0.isTerminated }
        guard running.count == 1, let app = running.first, let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == "com.ethansk.codex-model-bar",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(version), build >= 60,
              let executable = bundle.executableURL, app.executableURL == executable,
              let data = try? JSONEncoder().encode(request), data.count <= 4096 else { return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = ["--voice-speed-v1"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run(); try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close()
        } catch { if process.isRunning { process.terminate() }; return nil }
        let remaining = Double(request.expiresAtMs) / 1000 - Date().timeIntervalSince1970
        guard remaining > 0, finished.wait(timeout: .now() + min(31, remaining + 0.5)) == .success else {
            if process.isRunning { process.terminate() }; return nil
        }
        guard !Task.isCancelled, process.terminationStatus == 0, !app.isTerminated,
              let bytes = try? output.fileHandleForReading.read(upToCount: 4097), bytes.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: bytes)
    }
}

// The existing call observer supplies the exact identity when native Voice opens before its
// saved thread exists. Only an H Chat-dispatched new call can arm this handoff. — GPT-6.1 Sol
struct ModelBarVoiceLaunch {
    private(set) var pending: (sent: Date, pid: Int32)?
    mutating func arm(sent: Date, pid: Int32) { pending = (sent, pid) }
    mutating func cancel() { pending = nil }
    mutating func take(_ state: VoicePeerReceipt, at now: Date, composerReady: Bool = true) -> VoicePeerCall? {
        guard let pending else { return nil }
        guard (0...30).contains(now.timeIntervalSince(pending.sent)) else { self.pending = nil; return nil }
        guard composerReady, state.status == .active, let call = state.call,
              call.pid == pending.pid, let started = state.startedAtMilliseconds,
              Double(started) >= pending.sent.timeIntervalSince1970 * 1000 else { return nil }
        self.pending = nil
        return call
    }
}
