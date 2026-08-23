import Foundation
import ScheduleBar

@main
struct ScheduleBarMCP {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "hook" {
            _ = FileHandle.standardInput.readDataToEndOfFile()
            return
        }
        MCPStdio().run()
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
                write(response: ok(id: id, result: ["tools": [toolSpec()]]))
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
        guard name == "capture_work_change" else {
            return ["content": [["type": "text", "text": "未记录"]], "isError": true]
        }
        let event = CaptureEvent(
            idempotencyKey: string(args["idempotency_key"] ?? args["capture_id"]),
            title: string(args["title"]),
            authority: authority(args["authority"]),
            threadID: string(args["thread_id"] ?? args["session_id"]),
            turnID: string(args["turn_id"]),
            messageTime: ISO8601DateFormatter().date(from: string(args["message_time"])) ?? Date(),
            workingDirectory: string(args["cwd"] ?? args["working_directory"]),
            triggerPhrase: string(args["trigger_phrase"] ?? args["user_text"]),
            excerpt: string(args["excerpt"])
        )
        let url = (ProcessInfo.processInfo.environment["SCHEDULEBAR_STORE"]).map { URL(fileURLWithPath: $0) }
            ?? (try? ScheduleBarPaths.defaultStoreURL())
        guard let url, !event.idempotencyKey.isEmpty, !event.title.isEmpty else {
            return receiptJSON(Receipt(outcome: .notRecorded))
        }
        let receipt = CaptureQueue(storeURL: url).enqueue(event)
        return receiptJSON(receipt)
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
                    "authority": ["type": "string"],
                ],
                "required": ["title"],
            ],
        ]
    }

    func authority(_ value: Any?) -> SourceAuthority {
        SourceAuthority(rawValue: string(value)) ?? .mainConversation
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

    func readMessage(from handle: FileHandle) -> Data? {
        var header = Data()
        let newline = Data("\n".utf8)
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            header.append(byte)
            if header.count >= 4, header.suffix(4) == Data("\r\n\r\n".utf8) { break }
            if header.count >= 2, header.suffix(2) == Data("\n\n".utf8) { break }
            if header.count > 8192 { return nil }
        }
        let headerText = String(data: header, encoding: .utf8) ?? ""
        var length = 0
        for line in headerText.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        if length > 0 {
            return handle.readData(ofLength: length)
        }
        var json = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { break }
            json.append(byte)
            if byte == newline { break }
        }
        return json.isEmpty ? nil : json
    }

    func write(response: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(data)
    }
}
