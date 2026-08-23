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
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
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
            if file.pathExtension == "json", let turn = decodeTurn(data, decoder: decoder, fallbackSession: file.deletingPathExtension().lastPathComponent) {
                turns.append(turn)
                continue
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let lineText = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !lineText.isEmpty else { continue }
                guard let lineData = lineText.data(using: .utf8),
                      let turn = decodeTurn(lineData, decoder: decoder, fallbackSession: file.deletingPathExtension().lastPathComponent)
                else {
                    failures.append(file.lastPathComponent)
                    continue
                }
                turns.append(turn)
            }
        }
        return SessionDirectoryScan(turns: turns, failures: failures)
    }

    private func decodeTurn(_ data: Data, decoder: JSONDecoder, fallbackSession: String) -> SessionTurn? {
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
        guard let row = try? decoder.decode(Row.self, from: data) else { return nil }
        let text = (row.user_text ?? row.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let turnID = row.turn_id ?? ""
        guard !text.isEmpty, !turnID.isEmpty else { return nil }
        return SessionTurn(
            sessionID: row.session_id ?? fallbackSession,
            turnID: turnID,
            messageTime: row.message_time ?? Date.distantPast,
            workingDirectory: row.working_directory ?? row.cwd ?? "",
            userText: String(text.prefix(280)),
            authority: SourceAuthority(rawValue: row.authority ?? "") ?? .mainConversation
        )
    }
}
