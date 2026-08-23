import Foundation

public enum CapturePolicy {
    public static let chatWorkAutomaticCapture = false
    public static let remoteRealtimeCapture = false
    public static let chatWorkHelpText =
        "Chat/Work does not capture automatically. Say “record as task” or use Quick Add."
    public static let localReconcileHelpText =
        "Remote/cloud Codex is reconciled only after it is visible locally. This is not realtime capture."
}

public enum ChatWorkHandoff {
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
        return CaptureEvent(
            idempotencyKey: idempotencyKey,
            title: title,
            authority: .mainConversation,
            threadID: threadID,
            turnID: turnID ?? idempotencyKey,
            messageTime: messageTime,
            workingDirectory: workingDirectory,
            triggerPhrase: trigger,
            excerpt: String(text.prefix(280))
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

    private static func explicitTrigger(in text: String) -> String? {
        let lowered = text.lowercased()
        let triggers = ["record as task", "记录为任务", "记为任务"]
        return triggers.first { lowered.contains($0) }
    }

    private static func titleAfterTrigger(_ text: String, trigger: String) -> String {
        let lowered = text.lowercased()
        guard let range = lowered.range(of: trigger) else { return "" }
        var rest = String(text[range.upperBound...])
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.hasPrefix(":") || rest.hasPrefix("：") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }
}
