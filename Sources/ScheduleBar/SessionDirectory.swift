import Foundation

public struct SessionTurn: Equatable, Sendable {
    public var sessionID: String
    public var turnID: String
    public var messageTime: Date
    public var workingDirectory: String
    public var userText: String
    public var authority: SourceAuthority

    public init(
        sessionID: String,
        turnID: String,
        messageTime: Date,
        workingDirectory: String,
        userText: String,
        authority: SourceAuthority = .mainConversation
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.messageTime = messageTime
        self.workingDirectory = workingDirectory
        self.userText = userText
        self.authority = authority
    }
}

public struct SessionDirectoryScan: Equatable, Sendable {
    public var turns: [SessionTurn]
    public var failures: [String]

    public init(turns: [SessionTurn] = [], failures: [String] = []) {
        self.turns = turns
        self.failures = failures
    }
}

public protocol SessionDirectory: Sendable {
    func scan() -> SessionDirectoryScan
}

/// Natural ordering for turn identifiers so `t10` sorts after `t2`;
/// plain lexicographic comparison would skip later turns whose ids grow
/// past nine single characters.
public enum TurnIDOrder {
    public static func isLess(_ lhs: String, _ rhs: String) -> Bool {
        var left = Substring(lhs)
        var right = Substring(rhs)
        while !left.isEmpty, !right.isEmpty {
            if left.first!.isNumber, right.first!.isNumber {
                let leftRun = left.prefix(while: \.isNumber)
                let rightRun = right.prefix(while: \.isNumber)
                let leftValue = Int(leftRun) ?? 0
                let rightValue = Int(rightRun) ?? 0
                if leftValue != rightValue { return leftValue < rightValue }
                if leftRun.count != rightRun.count { return leftRun.count < rightRun.count }
                left = left.dropFirst(leftRun.count)
                right = right.dropFirst(rightRun.count)
            } else {
                if left.first != right.first { return left.first! < right.first! }
                left = left.dropFirst()
                right = right.dropFirst()
            }
        }
        if left.isEmpty != right.isEmpty { return left.isEmpty }
        return false
    }
}

public struct EmptySessionDirectory: SessionDirectory {
    public init() {}
    public func scan() -> SessionDirectoryScan { SessionDirectoryScan() }
}

public final class ScriptedSessionDirectory: SessionDirectory, @unchecked Sendable {
    public var turns: [SessionTurn] = []
    public var failures: [String] = []

    public init() {}

    public func scan() -> SessionDirectoryScan {
        SessionDirectoryScan(turns: turns, failures: failures)
    }
}

public struct FolderSessionDirectory: SessionDirectory {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func scan() -> SessionDirectoryScan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return SessionDirectoryScan() }
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            return SessionDirectoryScan(failures: [root.path])
        }
        var turns: [SessionTurn] = []
        var failures: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "jsonl" || file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8)
            else {
                failures.append(file.lastPathComponent)
                continue
            }
            let fallbackSession = file.deletingPathExtension().lastPathComponent
            if file.pathExtension == "json",
               let turn = decodeTurn(data, decoder: decoder, fallbackSession: fallbackSession, fallbackTurnID: "1") {
                turns.append(turn)
                continue
            }
            // Native Codex session files carry the working directory on
            // turn-context lines; remember the latest one for user turns.
            var lastWorkingDirectory = ""
            var lineIndex = 0
            for line in text.split(whereSeparator: \.isNewline) {
                lineIndex += 1
                let lineText = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lineText.isEmpty else { continue }
                guard let lineData = lineText.data(using: .utf8) else {
                    failures.append(file.lastPathComponent)
                    continue
                }
                if let cwd = workingDirectoryHint(from: lineData) {
                    lastWorkingDirectory = cwd
                    continue
                }
                guard let turn = decodeTurn(
                    lineData,
                    decoder: decoder,
                    fallbackSession: fallbackSession,
                    fallbackTurnID: "line-\(lineIndex)",
                    fallbackWorkingDirectory: lastWorkingDirectory
                ) else {
                    if (try? JSONSerialization.jsonObject(with: lineData)) == nil {
                        failures.append(file.lastPathComponent)
                    }
                    continue
                }
                turns.append(turn)
            }
        }
        return SessionDirectoryScan(turns: turns, failures: failures)
    }

    private func decodeTurn(
        _ data: Data,
        decoder: JSONDecoder,
        fallbackSession: String,
        fallbackTurnID: String,
        fallbackWorkingDirectory: String = ""
    ) -> SessionTurn? {
        struct Row: Decodable {
            var session_id: String?
            var turn_id: String?
            var message_time: Date?
            var cwd: String?
            var working_directory: String?
            var text: String?
            var user_text: String?
            var authority: String?
        }
        if let row = try? decoder.decode(Row.self, from: data),
           row.user_text != nil || row.text != nil || row.turn_id != nil {
            let text = (row.user_text ?? row.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let turnID = row.turn_id ?? ""
            guard !text.isEmpty, !turnID.isEmpty else { return nil }
            return SessionTurn(
                sessionID: row.session_id ?? fallbackSession,
                turnID: turnID,
                messageTime: row.message_time ?? Date.distantPast,
                workingDirectory: row.working_directory ?? row.cwd ?? fallbackWorkingDirectory,
                userText: String(text.prefix(280)),
                authority: SourceAuthority(rawValue: row.authority ?? "") ?? .mainConversation
            )
        }
        return decodeCodexTurn(data, fallbackSession: fallbackSession, fallbackTurnID: fallbackTurnID, fallbackWorkingDirectory: fallbackWorkingDirectory)
    }

    /// Native Codex JSONL shape:
    /// `{"timestamp": "...", "payload": {"type": "message", "role": "user",
    ///   "content": [{"type": "input_text", "text": "..."}]}}`
    /// Non-user and non-message lines are skipped rather than counted as
    /// failures; only genuinely unparseable JSON is a retryable diagnostic.
    private func decodeCodexTurn(
        _ data: Data,
        fallbackSession: String,
        fallbackTurnID: String,
        fallbackWorkingDirectory: String
    ) -> SessionTurn? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "message",
              (payload["role"] as? String) == "user"
        else { return nil }
        var text = payload["text"] as? String ?? ""
        if text.isEmpty, let content = payload["content"] as? [[String: Any]] {
            text = content.compactMap { ($0["text"] as? String) }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = (object["timestamp"] as? String).flatMap(formatter.date(from:))
            ?? (object["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let turnID = (object["turn_id"] as? String)
            ?? (payload["turn_id"] as? String)
            ?? ((object["timestamp"] as? String).map { "ts-\($0)" } ?? fallbackTurnID)
        return SessionTurn(
            sessionID: (object["session_id"] as? String) ?? fallbackSession,
            turnID: turnID,
            messageTime: stamp ?? Date.distantPast,
            workingDirectory: (object["cwd"] as? String)
                ?? (payload["cwd"] as? String)
                ?? fallbackWorkingDirectory,
            userText: String(text.prefix(280)),
            authority: .mainConversation
        )
    }

    /// Extracts the working directory from `turn_context`-style lines that
    /// carry no user text of their own.
    private func workingDirectoryHint(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        guard (object["type"] as? String) == "turn_context"
            || (payload["type"] as? String) == "turn_context" else { return nil }
        return (object["cwd"] as? String) ?? (payload["cwd"] as? String)
    }
}
