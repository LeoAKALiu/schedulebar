/// Production seam: `InputEvent` in, `ObservableState` out.
/// Capture events can land in `CaptureQueue` while the app is not running;
/// `processInbox()` applies each pending idempotency key exactly once.
import Foundation
import SQLite3

public final class ScheduleBarStore {
    private let storeURL: URL
    private let database: SQLiteDatabase

    public init(storeURL: URL) throws {
        self.storeURL = storeURL
        database = try SQLiteDatabase(url: storeURL)
    }

    public func apply(_ event: InputEvent) throws -> Receipt {
        switch event {
        case .quickAdd(let input):
            return try quickAdd(input)
        case .capture(let capture):
            let queued = CaptureQueue(storeURL: storeURL).enqueue(capture)
            guard queued.outcome == .recorded else { return queued }
            return processInbox().last ?? queued
        }
    }

    public func processInbox() -> [Receipt] {
        let pending: [(key: String, payload: String)]
        database.lock.lock()
        do {
            defer { database.lock.unlock() }
            let stmt = try database.prepare(
                "SELECT idempotency_key, payload FROM capture_inbox WHERE status = 'pending' ORDER BY rowid ASC;"
            )
            defer { sqlite3_finalize(stmt) }
            var rows: [(String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let key = database.column(stmt, 0), let payload = database.column(stmt, 1) {
                    rows.append((key, payload))
                }
            }
            pending = rows
        } catch {
            return []
        }
        return pending.map { applyPending(key: $0.key, payload: $0.payload) }
    }

    public func observableState() throws -> ObservableState {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare(
            "SELECT id, title, notes, local_path FROM tasks ORDER BY created_at DESC, title ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        var tasks: [TaskSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let title = database.column(stmt, 1)
            else { continue }
            tasks.append(
                TaskSummary(
                    id: id,
                    title: title,
                    notes: database.column(stmt, 2),
                    localPath: database.column(stmt, 3)
                )
            )
        }
        return ObservableState(tasks: tasks, candidates: try loadCandidates())
    }

    public func reviewCandidate(_ id: UUID, decision: CandidateDecision) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        switch decision {
        case .reject:
            try markCandidate(id, status: "rejected")
            return Receipt(outcome: .ignored, summaryLine: "Candidate rejected")
        case .confirm:
            guard let title = try candidateTitle(id) else {
                throw ScheduleBarError.storeUnavailable
            }
            let receipt = try insertTask(title: title, notes: nil, localPath: nil)
            try markCandidate(id, status: "confirmed")
            return receipt
        case .edit(let input):
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
            let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath))
            try markCandidate(id, status: "confirmed")
            return receipt
        }
    }

    private func applyPending(key: String, payload: String) -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        do {
            let event = try decode(payload)
            let classified = CaptureClassifier.outcome(for: event)
            var taskID: UUID?
            switch classified {
            case .recorded:
                let created = try insertTask(title: event.title, notes: nil, localPath: nil)
                taskID = created.taskID
            case .candidate:
                taskID = try insertCandidate(title: event.title, inboxKey: key)
            case .ignored, .duplicate, .notRecorded:
                break
            }
            let stmt = try database.prepare(
                "UPDATE capture_inbox SET status = 'processed', task_id = ? WHERE idempotency_key = ?;"
            )
            defer { sqlite3_finalize(stmt) }
            database.bind(stmt, 1, taskID?.uuidString)
            database.bind(stmt, 2, key)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                return Receipt(outcome: .notRecorded)
            }
            return Receipt(
                outcome: classified,
                taskID: taskID,
                summaryLine: summary(classified, title: event.title)
            )
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }

    private func quickAdd(_ input: QuickAddInput) throws -> Receipt {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
        database.lock.lock()
        defer { database.lock.unlock() }
        return try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath))
    }

    private func insertTask(title: String, notes: String?, localPath: String?) throws -> Receipt {
        let id = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let stmt = try database.prepare(
            "INSERT INTO tasks (id, title, notes, local_path, created_at) VALUES (?, ?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, title)
        database.bind(stmt, 3, notes)
        database.bind(stmt, 4, localPath)
        database.bind(stmt, 5, createdAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Recorded: \(title)")
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadCandidates() throws -> [TaskSummary] {
        let stmt = try database.prepare(
            "SELECT id, title, notes FROM candidates WHERE status = 'open' ORDER BY created_at DESC;"
        )
        defer { sqlite3_finalize(stmt) }
        var items: [TaskSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let title = database.column(stmt, 1)
            else { continue }
            items.append(TaskSummary(id: id, title: title, notes: database.column(stmt, 2)))
        }
        return items
    }

    private func insertCandidate(title: String, inboxKey: String) throws -> UUID {
        let id = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let stmt = try database.prepare(
            "INSERT INTO candidates (id, title, notes, inbox_key, status, created_at) VALUES (?, ?, NULL, ?, 'open', ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, title)
        database.bind(stmt, 3, inboxKey)
        database.bind(stmt, 4, createdAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        return id
    }

    private func markCandidate(_ id: UUID, status: String) throws {
        let stmt = try database.prepare("UPDATE candidates SET status = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, status)
        database.bind(stmt, 2, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    private func candidateTitle(_ id: UUID) throws -> String? {
        let stmt = try database.prepare("SELECT title FROM candidates WHERE id = ? AND status = 'open';")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return database.column(stmt, 0)
    }

    private func summary(_ outcome: Outcome, title: String) -> String {
        switch outcome {
        case .recorded: return "Recorded: \(title)"
        case .candidate: return "Saved as candidate"
        case .ignored: return "Ignored"
        case .duplicate: return "Already recorded"
        case .notRecorded: return "未记录"
        }
    }

    private func decode(_ payload: String) throws -> CaptureEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = payload.data(using: .utf8) else {
            throw ScheduleBarError.storeUnavailable
        }
        return try decoder.decode(CaptureEvent.self, from: data)
    }
}
