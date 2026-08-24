import Foundation

/// The authority accepted from agent-controlled integrations. Human authority
/// is only created inside the native app and can never be requested over MCP.
public enum AgentAuthorityPolicy {
    public static func parse(_ raw: String?) -> SourceAuthority? {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased() ?? ""
        switch normalized {
        case "", "main", "mainconversation", "codex": return .mainConversation
        case "subagent", "agent": return .subagent
        default: return nil
        }
    }
}

public enum CodexHookProcessor {
    /// Converts a Codex lifecycle hook payload into a durable queue write.
    /// SessionStart is intentionally observational; UserPromptSubmit and Stop
    /// are the two turn-level capture seams.
    public static func process(
        _ data: Data,
        storeURL: URL,
        now: Date = Date()
    ) -> Receipt {
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(CodexHookPayload.self, from: data) else {
            return Receipt(outcome: .notRecorded)
        }
        guard payload.eventName == "UserPromptSubmit" || payload.eventName == "Stop" else {
            return Receipt(outcome: .ignored)
        }
        let text = (payload.eventName == "Stop" ? payload.lastAssistantMessage : payload.prompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty,
              !payload.sessionID.isEmpty,
              !payload.turnID.isEmpty
        else {
            return Receipt(outcome: .notRecorded)
        }
        guard !CaptureLanguage.rejectsCapture(text) else {
            return Receipt(outcome: .ignored)
        }

        if let items = CaptureLanguage.planItems(from: text) {
            guard !CaptureLanguage.rejectsPlanDraft(text) else {
                return Receipt(outcome: .ignored)
            }
            return PlanQueue(storeURL: storeURL).enqueue(
                PlanProposal(
                    idempotencyKey: "hook:plan:\(payload.eventName):\(payload.sessionID):\(payload.turnID)",
                    threadID: payload.sessionID,
                    turnID: payload.turnID,
                    workingDirectory: payload.workingDirectory,
                    items: items,
                    messageTime: payload.messageTime ?? now
                )
            )
        }

        let title = CaptureLanguage.title(from: text)
        guard !title.isEmpty else { return Receipt(outcome: .ignored) }
        let date = CaptureLanguage.dateReference(in: text)
        let event = CaptureEvent(
            idempotencyKey: "hook:\(payload.eventName):\(payload.sessionID):\(payload.turnID)",
            title: title,
            authority: .mainConversation,
            threadID: payload.sessionID,
            turnID: payload.turnID,
            messageTime: payload.messageTime ?? now,
            workingDirectory: payload.workingDirectory,
            triggerPhrase: String(text.prefix(200)),
            excerpt: String(text.prefix(280)),
            datePhrase: date?.phrase,
            dateKind: date?.kind
        )
        guard CaptureClassifier.outcome(for: event) != .ignored else {
            return Receipt(outcome: .ignored)
        }
        do {
            let expected = try ScheduleBarStore(storeURL: storeURL).previewCaptureOutcome(event)
            let queued = CaptureQueue(storeURL: storeURL).enqueue(event)
            guard queued.outcome != .notRecorded, queued.outcome != .duplicate else {
                return queued
            }
            return Receipt(
                outcome: expected,
                summaryLine: expected == .recorded ? "Recorded: \(title)" : expected.defaultSummaryLine
            )
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }
}

private struct CodexHookPayload: Decodable {
    var eventName: String
    var sessionID: String
    var turnID: String
    var workingDirectory: String
    var prompt: String?
    var lastAssistantMessage: String?
    var messageTime: Date?

    enum CodingKeys: String, CodingKey {
        case eventName = "hook_event_name"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case workingDirectory = "cwd"
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case messageTime = "message_time"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventName = try container.decodeIfPresent(String.self, forKey: .eventName) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        let rawTime = try container.decodeIfPresent(String.self, forKey: .messageTime)
            ?? container.decodeIfPresent(String.self, forKey: .timestamp)
        messageTime = rawTime.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
