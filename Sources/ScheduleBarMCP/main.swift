import Foundation
import ScheduleBar

@main
struct ScheduleBarMCP {
    static func main() {
        let rest = Array(CommandLine.arguments.dropFirst())
        if rest.first == "hook" {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let receipt: Receipt
            if let url = ChatWorkHandoff.configuredStoreURL() {
                receipt = CodexHookProcessor.process(input, storeURL: url)
            } else {
                receipt = Receipt(outcome: .notRecorded)
            }
            writeHookReceipt(receipt)
            return
        }
        if rest.first == "record" {
            ChatWorkCLI.run(Array(rest.dropFirst()))
            return
        }
        MCPStdio().run()
    }

    private static func writeHookReceipt(_ receipt: Receipt) {
        guard receipt.outcome != .ignored else { return }
        let payload = ["systemMessage": "ScheduleBar: \(receipt.summaryLine)"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private struct MCPStdio {
    func run() {
        let stdin = FileHandle.standardInput
        while let message = readMessage(from: stdin) {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                continue
            }
            let method = object["method"] as? String
            if method == "notifications/initialized" || method?.hasPrefix("notifications/") == true {
                continue
            }
            let id = object["id"]
            switch method {
            case "initialize":
                write(response: ok(id: id, result: [
                    "protocolVersion": object["params"].flatMap { ($0 as? [String: Any])?["protocolVersion"] } ?? "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "schedulebar", "version": "0.1.0"],
                ]))
            case "tools/list":
                write(response: ok(id: id, result: ["tools": [
                    toolSpec(),
                    recordAsTaskSpec(),
                    setBlockedBySpec(),
                    removeBlockedBySpec(),
                    setTaskStatusSpec(),
                    proposePlanSpec(),
                ]]))
            case "tools/call":
                write(response: ok(id: id, result: callTool(object["params"] as? [String: Any] ?? [:])))
            case "ping":
                write(response: ok(id: id, result: [String: Any]()))
            default:
                if id != nil {
                    write(response: error(id: id, code: -32601, message: "Method not found"))
                }
            }
        }
    }

    func callTool(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String
        let args = params["arguments"] as? [String: Any] ?? [:]
        if name == "record_as_task" {
            return recordAsTask(args)
        }
        if name == "set_blocked_by" {
            return dependencyTool(args, event: { .setBlockedBy($0, $1) })
        }
        if name == "remove_blocked_by" {
            return dependencyTool(args, event: { .removeBlockedBy($0, $1) })
        }
        if name == "set_task_status" {
            return setTaskStatus(args)
        }
        if name == "propose_plan" {
            return proposePlan(args)
        }
        guard name == "capture_work_change" else {
            return ["content": [["type": "text", "text": "未记录"]], "isError": true]
        }
        let datePhrase = optionalString(args["date_phrase"] ?? args["datePhrase"])
        let rawMessageTime = optionalString(args["message_time"])
        let parsedMessageTime = rawMessageTime.flatMap { ISO8601DateFormatter().date(from: $0) }
        if rawMessageTime != nil, parsedMessageTime == nil, datePhrase != nil {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        guard let sourceAuthority = agentAuthority(args["authority"]) else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        let event = CaptureEvent(
            idempotencyKey: string(args["idempotency_key"] ?? args["capture_id"]),
            title: string(args["title"]),
            authority: sourceAuthority,
            threadID: string(args["thread_id"] ?? args["session_id"]),
            turnID: string(args["turn_id"]),
            messageTime: parsedMessageTime ?? Date(),
            workingDirectory: string(args["cwd"] ?? args["working_directory"]),
            triggerPhrase: string(args["trigger_phrase"] ?? args["user_text"]),
            excerpt: string(args["excerpt"]),
            datePhrase: datePhrase,
            dateKind: dateKind(args["date_kind"] ?? args["dateKind"]),
            ownerName: optionalString(args["owner_name"] ?? args["ownerName"]),
            ownerKind: ownerKind(args["owner_kind"] ?? args["ownerKind"])
        )
        guard let url = ChatWorkHandoff.configuredStoreURL(), !event.idempotencyKey.isEmpty, !event.title.isEmpty else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        do {
            let store = try ScheduleBarStore(storeURL: url)
            return receiptJSON(try store.apply(.capture(event)))
        } catch {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
    }

    func dependencyTool(
        _ args: [String: Any],
        event: (UUID, UUID) -> InputEvent
    ) -> [String: Any] {
        guard let url = ChatWorkHandoff.configuredStoreURL(),
              let taskID = optionalString(args["task_id"] ?? args["taskId"]).flatMap(UUID.init(uuidString:)),
              let blockerID = optionalString(args["blocker_task_id"] ?? args["blockerTaskId"]).flatMap(UUID.init(uuidString:))
        else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        do {
            let store = try ScheduleBarStore(storeURL: url)
            return receiptJSON(try store.apply(event(taskID, blockerID), authority: .mainConversation))
        } catch {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
    }

    func setTaskStatus(_ args: [String: Any]) -> [String: Any] {
        guard let url = ChatWorkHandoff.configuredStoreURL(),
              let taskID = optionalString(args["task_id"] ?? args["taskId"]).flatMap(UUID.init(uuidString:)),
              let status = workflowStatus(args["status"]),
              let sourceAuthority = agentAuthority(args["authority"])
        else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        do {
            let store = try ScheduleBarStore(storeURL: url)
            return receiptJSON(try store.apply(.setStatus(taskID, status), authority: sourceAuthority))
        } catch {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
    }

    func proposePlan(_ args: [String: Any]) -> [String: Any] {
        guard let url = ChatWorkHandoff.configuredStoreURL(),
              let rawItems = args["items"] as? [[String: Any]],
              let key = optionalString(args["idempotency_key"] ?? args["capture_id"])
        else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        var items: [PlanItem] = []
        var knownIDs = Set<UUID>()
        for raw in rawItems {
            let title = string(raw["title"])
            guard !title.isEmpty else { return receiptJSON(Receipt(outcome: .notRecorded)) }
            let id = optionalString(raw["id"]).flatMap(UUID.init(uuidString:)) ?? UUID()
            knownIDs.insert(id)
            items.append(
                PlanItem(
                    id: id,
                    title: title,
                    kind: workKind(raw["kind"]),
                    necessary: (raw["necessary"] as? Bool) ?? true,
                    datePhrase: optionalString(raw["date_phrase"] ?? raw["datePhrase"]),
                    dateKind: dateKind(raw["date_kind"] ?? raw["dateKind"])
                )
            )
        }
        let proposal = PlanProposal(
            idempotencyKey: key,
            threadID: string(args["thread_id"] ?? args["session_id"]),
            turnID: string(args["turn_id"]),
            workingDirectory: string(args["cwd"] ?? args["working_directory"]),
            items: items,
            messageTime: optionalString(args["message_time"]).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        )
        do {
            let store = try ScheduleBarStore(storeURL: url)
            return receiptJSON(try store.apply(.proposePlan(resolvedParents(proposal, knownIDs: knownIDs, rawItems: rawItems)), authority: .mainConversation))
        } catch {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
    }

    /// Re-attaches parent references expressed with client-side item ids.
    private func resolvedParents(_ proposal: PlanProposal, knownIDs: Set<UUID>, rawItems: [[String: Any]]) -> PlanProposal {
        var copy = proposal
        copy.items = zip(proposal.items, rawItems).map { item, raw in
            var mutated = item
            if let parentText = optionalString(raw["parent_id"] ?? raw["parentId"]),
               let parentID = UUID(uuidString: parentText), knownIDs.contains(parentID) {
                mutated = PlanItem(
                    id: item.id,
                    title: item.title,
                    kind: item.kind,
                    parentID: parentID,
                    necessary: item.necessary,
                    datePhrase: item.datePhrase,
                    dateKind: item.dateKind
                )
            }
            return mutated
        }
        return copy
    }

    func receiptJSON(_ receipt: Receipt) -> [String: Any] {
        let payload: [String: Any] = [
            "ok": receipt.outcome != .notRecorded,
            "outcome": receipt.outcome.rawValue,
            "recorded": receipt.outcome == .recorded,
            "reason": receipt.summaryLine,
            "task_id": receipt.taskID?.uuidString as Any,
        ]
        let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? receipt.summaryLine
        return [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ]
    }

    func recordAsTask(_ args: [String: Any]) -> [String: Any] {
        let request = ChatWorkHandoff.parseRecordRequest(stringValues(args))
        guard let url = ChatWorkHandoff.configuredStoreURL(), !request.idempotencyKey.isEmpty, !request.userText.isEmpty else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        return receiptJSON(ChatWorkHandoff.submit(request, storeURL: url))
    }

    private func stringValues(_ args: [String: Any]) -> [String: String] {
        args.compactMapValues { $0 as? String }
    }

    func setBlockedBySpec() -> [String: Any] {
        [
            "name": "set_blocked_by",
            "description": "Declare that one task is blocked by another. Use remove_blocked_by with the same ids to clear the edge.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string"],
                    "blocker_task_id": ["type": "string"],
                ],
                "required": ["task_id", "blocker_task_id"],
            ] as [String: Any],
        ]
    }

    func removeBlockedBySpec() -> [String: Any] {
        [
            "name": "remove_blocked_by",
            "description": "Clear a previously declared blocked-by edge between two tasks.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string"],
                    "blocker_task_id": ["type": "string"],
                ],
                "required": ["task_id", "blocker_task_id"],
            ] as [String: Any],
        ]
    }

    func setTaskStatusSpec() -> [String: Any] {
        [
            "name": "set_task_status",
            "description": "Report a workflow status for an existing task on the user's behalf. Allowed statuses: notStarted, inProgress, waitingOnOther, blocked, pendingAcceptance, completed, cancelled. Agent completion reports land as pendingAcceptance until a human accepts.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "task_id": ["type": "string"],
                    "status": ["type": "string"],
                    "authority": [
                        "type": "string",
                        "enum": ["mainConversation", "subagent"],
                    ],
                ],
                "required": ["task_id", "status"],
            ] as [String: Any],
        ]
    }

    func proposePlanSpec() -> [String: Any] {
        [
            "name": "propose_plan",
            "description": "Propose a plan draft (tasks and milestones) that a human accepts or rejects in the ScheduleBar console. Plans stay drafts until accepted; nothing is scheduled automatically.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "idempotency_key": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "session_id": ["type": "string"],
                    "turn_id": ["type": "string"],
                    "message_time": ["type": "string"],
                    "cwd": ["type": "string"],
                    "working_directory": ["type": "string"],
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "parent_id": ["type": "string"],
                                "title": ["type": "string"],
                                "kind": ["type": "string"],
                                "necessary": ["type": "boolean"],
                                "date_phrase": ["type": "string"],
                                "date_kind": ["type": "string"],
                            ] as [String: Any],
                            "required": ["title"],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
                "required": ["idempotency_key", "items"],
            ] as [String: Any],
        ]
    }

    func recordAsTaskSpec() -> [String: Any] {
        [
            "name": "record_as_task",
            "description": "Chat/Work explicit handoff. Only records when the user text contains “record as task” / “记录为任务”. Ordinary chat is not monitored. Failure reason is 未记录.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "user_text": ["type": "string"],
                    "text": ["type": "string"],
                    "idempotency_key": ["type": "string"],
                    "capture_id": ["type": "string"],
                    "cwd": ["type": "string"],
                    "working_directory": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "session_id": ["type": "string"],
                    "turn_id": ["type": "string"],
                    "message_time": ["type": "string"],
                ],
                "required": ["user_text", "idempotency_key"],
            ],
        ]
    }

    func toolSpec() -> [String: Any] {
        [
            "name": "capture_work_change",
            "description": "Record an explicit user request to save a task. Returns a short structured receipt. On failure reason is 未记录 and the conversation must continue.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "idempotency_key": ["type": "string"],
                    "capture_id": ["type": "string"],
                    "title": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "session_id": ["type": "string"],
                    "turn_id": ["type": "string"],
                    "message_time": ["type": "string"],
                    "cwd": ["type": "string"],
                    "working_directory": ["type": "string"],
                    "trigger_phrase": ["type": "string"],
                    "user_text": ["type": "string"],
                    "excerpt": ["type": "string"],
                    "authority": [
                        "type": "string",
                        "enum": ["mainConversation", "subagent"],
                    ],
                    "date_phrase": ["type": "string"],
                    "date_kind": ["type": "string"],
                    "owner_name": ["type": "string"],
                    "owner_kind": ["type": "string"],
                ],
                "required": ["idempotency_key", "title"],
            ],
        ]
    }

    func agentAuthority(_ value: Any?) -> SourceAuthority? {
        AgentAuthorityPolicy.parse(optionalString(value))
    }

    func workflowStatus(_ value: Any?) -> WorkflowStatus? {
        let raw = string(value).replacingOccurrences(of: "_", with: "").lowercased()
        switch raw {
        case "notstarted", "not-started": return .notStarted
        case "inprogress": return .inProgress
        case "waitingonother": return .waitingOnOther
        case "blocked": return .blocked
        case "pendingacceptance": return .pendingAcceptance
        case "completed", "complete": return .completed
        case "cancelled", "canceled": return .cancelled
        default: return nil
        }
    }

    func workKind(_ value: Any?) -> WorkKind {
        string(value).lowercased() == "milestone" ? .milestone : .task
    }

    func ownerKind(_ value: Any?) -> OwnerKind? {
        let raw = string(value).replacingOccurrences(of: "_", with: "").lowercased()
        switch raw {
        case "self", "selfperson", "me": return .selfPerson
        case "person", "other": return .person
        case "agent": return .agent
        default: return nil
        }
    }

    func dateKind(_ value: Any?) -> DateKind? {
        let raw = string(value).replacingOccurrences(of: "_", with: "").lowercased()
        switch raw {
        case "harddeadline": return .hardDeadline
        case "planned", "plannedat": return .planned
        case "target", "targetdate": return .target
        case "followup": return .followUp
        default: return nil
        }
    }

    func optionalString(_ value: Any?) -> String? {
        let text = string(value)
        return text.isEmpty ? nil : text
    }

    func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func ok(id: Any?, result: [String: Any]) -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { body["id"] = id }
        return body
    }

    func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { body["id"] = id }
        return body
    }

    /// Reads one JSON-RPC message. MCP's stdio transport is newline-delimited
    /// JSON (one message per line); Content-Length header framing is also
    /// accepted for compatibility with LSP-style clients.
    func readMessage(from handle: FileHandle) -> Data? {
        let newline = Data("\n".utf8)
        func readLine() -> Data? {
            var line = Data()
            while true {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { return line.isEmpty ? nil : line }
                line.append(byte)
                if byte == newline { break }
            }
            return line
        }

        while let rawLine = readLine() {
            let lineText = String(data: rawLine, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lineText.isEmpty { continue }
            if lineText.lowercased().hasPrefix("content-length:") {
                var length = Int(lineText.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                while let headerLine = readLine() {
                    let headerText = String(data: headerLine, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if headerText.isEmpty { break }
                    if headerText.lowercased().hasPrefix("content-length:") {
                        length = Int(headerText.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? length
                    }
                }
                return length > 0 ? handle.readData(ofLength: length) : nil
            }
            return rawLine
        }
        return nil
    }

    /// Writes one JSON-RPC message as newline-delimited JSON, per the MCP
    /// stdio transport.
    func write(response: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum ChatWorkCLI {
    static func run(_ args: [String]) {
        var flags: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            if token.hasPrefix("--"), index + 1 < args.count {
                flags[String(token.dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        if flags.isEmpty, let data = try? FileHandle.standardInput.readToEnd(),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String { flags[key] = text }
            }
        }
        var request = ChatWorkHandoff.parseRecordRequest(
            flags,
            now: Date()
        )
        if request.idempotencyKey.isEmpty {
            request.idempotencyKey = UUID().uuidString
        }
        if request.workingDirectory.isEmpty {
            request.workingDirectory = FileManager.default.currentDirectoryPath
        }
        let receipt: Receipt
        if let url = ChatWorkHandoff.configuredStoreURL(), !request.userText.isEmpty {
            receipt = ChatWorkHandoff.submit(request, storeURL: url)
        } else {
            receipt = Receipt(outcome: .notRecorded)
        }
        let payload: [String: Any] = [
            "ok": receipt.outcome != .notRecorded,
            "outcome": receipt.outcome.rawValue,
            "recorded": receipt.outcome == .recorded,
            "reason": receipt.summaryLine,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"reason\":\"未记录\"}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
