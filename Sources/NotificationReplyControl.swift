// Notification callbacks reuse the signed app's existing correlated control mailbox, never a second IPC listener. — GPT-6.1 Sol
import Foundation

extension HAgentControl {
    func addNotificationReplies(to operations: inout [String: Operation]) {
        let replies = model.notificationReplies
        let event: Fields = ["eventID": .uuid, "instance": .uuid]
        func add(_ name: String, fields: Fields, optional: Fields = [:], _ body: @escaping (HControlRequest) async throws -> [String: Any]) {
            // These bounded lifecycle callbacks must remain usable while an unrelated native action awaits its own completion. — GPT-6.1 Sol
            operations["notificationReply." + name] = Operation(kind: name == "status" ? "read" : "session", fields: fields, optionalFields: optional, run: { request in
                do { return .init(.confirmed, try await body(request)) }
                catch let failure as NotificationReplyCoordinator.Failure {
                    switch failure {
                    case .invalidEvent: return .init(.invalid, message: failure.rawValue)
                    case .differentInstance: return .init(.conflict, message: failure.rawValue)
                    case .busy, .unavailable: return .init(.unavailable, message: failure.rawValue)
                    }
                }
            })
        }
        add("prepare", fields: ["eventID": .uuid, "threadID": .uuid, "turnID": .text, "questionID": .text, "spokenText": .text], optional: ["manualFinish": .bool, "stopSpeaking": .bool]) { request in
            let rawTurn = request.string("turnID")
            let turn = UUID(uuidString: rawTurn)
            guard rawTurn.isEmpty || turn != nil,
                  let event = UUID(uuidString: request.string("eventID")), let thread = UUID(uuidString: request.string("threadID")) else {
                throw NotificationReplyCoordinator.Failure.invalidEvent
            }
            return try await replies.prepare(event: event, thread: thread, turn: turn, question: request.string("questionID"), spokenText: request.string("spokenText"),
                                             manualFinish: request.arguments["manualFinish"] as? Bool ?? false,
                                             stopSpeaking: request.arguments["stopSpeaking"] as? Bool ?? false)
        }
        add("audioStarted", fields: event.merging(["startedUptime": .number(0...1e12), "startedWall": .number(0...1e12)]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            return try replies.audioStarted(event: ids.event, instance: ids.instance, uptime: request.number("startedUptime"), wall: request.number("startedWall"))
        }
        add("audioEnded", fields: event.merging(["endedUptime": .number(0...1e12), "endedWall": .number(0...1e12), "completed": .bool]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            return try replies.audioEnded(event: ids.event, instance: ids.instance, uptime: request.number("endedUptime"), wall: request.number("endedWall"), completed: request.flag("completed"))
        }
        add("fallbackReady", fields: event.merging(["deliveredUptime": .number(0...1e12), "deliveredWall": .number(0...1e12), "skipReason": .text]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            return try await replies.fallbackReady(event: ids.event, instance: ids.instance,
                deliveredUptime: request.number("deliveredUptime"), deliveredWall: request.number("deliveredWall"),
                skipReason: request.string("skipReason"), expiresAt: request.expires)
        }
        add("cancel", fields: event.merging(["reason": .text]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            return try replies.cancel(event: ids.event, instance: ids.instance, reason: request.string("reason"))
        }
        add("mediaReleased", fields: event.merging(["released": .bool]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            return try replies.mediaReleased(event: ids.event, instance: ids.instance, released: request.flag("released"), expiresAt: request.expires)
        }
        add("status", fields: event) { request in
            let ids = try request.notificationReplyIDs()
            return try replies.status(event: ids.event, instance: ids.instance)
        }
        add("claimRelaySend", fields: event.merging(["relayThreadID": .uuid]) { $1 }) { request in
            let ids = try request.notificationReplyIDs()
            guard let relay = UUID(uuidString: request.string("relayThreadID")) else { throw NotificationReplyCoordinator.Failure.invalidEvent }
            return try await replies.claimRelaySend(event: ids.event, instance: ids.instance, relayThread: relay, expiresAt: request.expires)
        }
    }
}

private extension HControlRequest {
    func number(_ key: String) throws -> Double {
        guard let value = arguments[key] as? NSNumber else { throw NotificationReplyCoordinator.Failure.invalidEvent }
        return value.doubleValue
    }
    func flag(_ key: String) throws -> Bool {
        guard let value = arguments[key] as? Bool else { throw NotificationReplyCoordinator.Failure.invalidEvent }
        return value
    }
    func notificationReplyIDs() throws -> (event: UUID, instance: UUID) {
        guard let event = UUID(uuidString: string("eventID")), let instance = UUID(uuidString: string("instance")) else {
            throw NotificationReplyCoordinator.Failure.invalidEvent
        }
        return (event, instance)
    }
}
