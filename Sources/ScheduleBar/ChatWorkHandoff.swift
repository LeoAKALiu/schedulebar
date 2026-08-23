import Foundation

public enum CapturePolicy {
    public static let chatWorkAutomaticCapture = false
    public static let remoteRealtimeCapture = false
    public static let chatWorkHelpText =
        "Chat/Work does not capture automatically. Say “record as task” or use Quick Add."
    public static let localReconcileHelpText =
        "Remote/cloud Codex is reconciled only after it is visible locally. This is not realtime capture."
}

/// Normalized arguments shared by the `schedulebar-mcp record` CLI and the
/// MCP `record_as_task` tool so both entrances agree on alias names and
/// explicit-consent handling. A bare title is never upgraded into consent.
public struct ChatWorkRecordRequest: Equatable, Sendable {
    public var userText: String
    public var idempotencyKey: String
    public var workingDirectory: String
    public var threadID: String
    public var turnID: String?
    public var messageTime: Date

    public init(
        userText: String,
        idempotencyKey: String,
        workingDirectory: String,
        threadID: String,
        turnID: String?,
        messageTime: Date
    ) {
        self.userText = userText
        self.idempotencyKey = idempotencyKey
        self.workingDirectory = workingDirectory
        self.threadID = threadID
        self.turnID = turnID
        self.messageTime = messageTime
    }
}

public enum ChatWorkHandoff {
    /// Resolves the store location: `SCHEDULEBAR_STORE` wins, then the
    /// default Application Support location.
    public static func configuredStoreURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        environment["SCHEDULEBAR_STORE"].map { URL(fileURLWithPath: $0) }
            ?? (try? ScheduleBarPaths.defaultStoreURL())
    }

    public static func parseRecordRequest(
        _ values: [String: String],
        now: Date = Date()
    ) -> ChatWorkRecordRequest {
        func first(_ keys: String...) -> String? {
            for key in keys {
                if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        let userText = first("text", "user_text", "user-text") ?? ""
        return ChatWorkRecordRequest(
            userText: userText,
            idempotencyKey: first("key", "idempotency_key", "idempotency-key", "capture_id") ?? "",
            workingDirectory: first("cwd", "working_directory", "working-directory") ?? "",
            threadID: first("thread", "thread_id", "session_id") ?? "chat-work",
            turnID: first("turn", "turn_id"),
            messageTime: first("message_time", "message-time").flatMap { ISO8601DateFormatter().date(from: $0) } ?? now
        )
    }

    public static func event(
        userText: String,
        idempotencyKey: String,
        workingDirectory: String,
        threadID: String = "chat-work",
        turnID: String? = nil,
        messageTime: Date = Date()
    ) -> CaptureEvent? {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trigger = explicitTrigger(in: text) else { return nil }
        let title = titleAfterTrigger(text, trigger: trigger)
        guard !title.isEmpty, !idempotencyKey.isEmpty else { return nil }
        let date = CaptureLanguage.dateReference(in: text)
        return CaptureEvent(
            idempotencyKey: idempotencyKey,
            title: title,
            authority: .mainConversation,
            threadID: threadID,
            turnID: turnID ?? idempotencyKey,
            messageTime: messageTime,
            workingDirectory: workingDirectory,
            triggerPhrase: trigger,
            excerpt: String(text.prefix(280)),
            datePhrase: date?.phrase,
            dateKind: date?.kind
        )
    }

    public static func submit(
        _ userText: String,
        storeURL: URL,
        idempotencyKey: String,
        workingDirectory: String,
        threadID: String = "chat-work",
        turnID: String? = nil,
        messageTime: Date = Date()
    ) -> Receipt {
        guard let event = event(
            userText: userText,
            idempotencyKey: idempotencyKey,
            workingDirectory: workingDirectory,
            threadID: threadID,
            turnID: turnID,
            messageTime: messageTime
        ) else {
            return Receipt(outcome: .notRecorded)
        }
        do {
            let store = try ScheduleBarStore(storeURL: storeURL)
            return try store.apply(.capture(event))
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }

    public static func submit(_ request: ChatWorkRecordRequest, storeURL: URL) -> Receipt {
        submit(
            request.userText,
            storeURL: storeURL,
            idempotencyKey: request.idempotencyKey,
            workingDirectory: request.workingDirectory,
            threadID: request.threadID,
            turnID: request.turnID,
            messageTime: request.messageTime
        )
    }

    private static func explicitTrigger(in text: String) -> String? {
        CaptureLanguage.explicitRecordTrigger(in: text)
    }

    private static func titleAfterTrigger(_ text: String, trigger: String) -> String {
        CaptureLanguage.title(from: text)
    }
}
