/// Production seam: `InputEvent` in, `ObservableState` out.
/// Capture events can land in `CaptureQueue` while the app is not running;
/// `processInbox()` applies each pending idempotency key exactly once.
import Foundation
import SQLite3

public final class ScheduleBarStore {
    private let storeURL: URL
    private let database: SQLiteDatabase
    private let now: @Sendable () -> Date

    public init(storeURL: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.storeURL = storeURL
        self.now = now
        database = try SQLiteDatabase(url: storeURL)
    }

    public func apply(_ event: InputEvent, authority: SourceAuthority = .human) throws -> Receipt {
        switch event {
        case .quickAdd(let input):
            try requireHuman(authority)
            return try quickAdd(input)
        case .capture(let capture):
            let queued = CaptureQueue(storeURL: storeURL).enqueue(capture)
            guard queued.outcome == .recorded else { return queued }
            return processInbox().last ?? queued
        case .reviewCandidate(let id, let decision):
            try requireHuman(authority)
            return try reviewCandidate(id, decision: decision)
        case .cancel(let id):
            try requireHuman(authority)
            return try setLifecycle(id, "cancelled", summary: "Cancelled")
        case .archive(let id):
            try requireHuman(authority)
            return try setLifecycle(id, "archived", summary: "Archived")
        case .trash(let id):
            try requireHuman(authority)
            return try moveToTrash(id)
        case .restoreFromTrash(let id):
            try requireHuman(authority)
            return try restoreFromTrash(id)
        case .permanentlyDelete(let id):
            try requireHuman(authority)
            return try permanentlyDelete(id)
        case .undoLastAutomaticChange:
            try requireHuman(authority)
            return try undoLastAutomaticChange()
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
        return ObservableState(
            tasks: try loadTasks(lifecycle: "active"),
            candidates: try loadCandidates(),
            archived: try loadTasks(lifecycle: "archived"),
            trash: try loadTasks(lifecycle: "trashed"),
            history: try loadHistory()
        )
    }

    public func sourceEvidence(for taskID: UUID) throws -> SourceEvidence? {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare(
            "SELECT thread_id, turn_id, trigger_phrase, excerpt, working_directory FROM source_evidence WHERE task_id = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return SourceEvidence(
            threadID: database.column(stmt, 0) ?? "",
            turnID: database.column(stmt, 1) ?? "",
            triggerPhrase: database.column(stmt, 2) ?? "",
            excerpt: database.column(stmt, 3) ?? "",
            workingDirectory: database.column(stmt, 4) ?? ""
        )
    }

    public func reviewCandidate(_ id: UUID, decision: CandidateDecision) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        switch decision {
        case .reject:
            try markCandidate(id, status: "rejected")
            try appendHistory(summary: "Rejected candidate", automatic: false, action: "reject_candidate", targetID: id, table: "candidates")
            return Receipt(outcome: .ignored, summaryLine: "Candidate rejected")
        case .confirm:
            guard let title = try candidateTitle(id) else {
                throw ScheduleBarError.storeUnavailable
            }
            let receipt = try insertTask(title: title, notes: nil, localPath: nil, origin: "human")
            try markCandidate(id, status: "confirmed")
            try appendHistory(summary: "Confirmed candidate: \(title)", automatic: false, action: "confirm_candidate", targetID: receipt.taskID, table: "tasks")
            return receipt
        case .edit(let input):
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
            let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath), origin: "human")
            try markCandidate(id, status: "confirmed")
            try appendHistory(summary: "Confirmed candidate: \(title)", automatic: false, action: "confirm_candidate", targetID: receipt.taskID, table: "tasks")
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
                let created = try insertTask(title: event.title, notes: nil, localPath: nil, origin: "capture")
                taskID = created.taskID
                try insertEvidence(taskID: created.taskID, event: event)
                try appendHistory(
                    summary: "Captured: \(event.title)",
                    automatic: true,
                    action: "create_task",
                    targetID: created.taskID,
                    table: "tasks"
                )
            case .candidate:
                taskID = try insertCandidate(title: event.title, inboxKey: key)
                try appendHistory(
                    summary: "Candidate: \(event.title)",
                    automatic: true,
                    action: "create_candidate",
                    targetID: taskID,
                    table: "candidates"
                )
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
        let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath), origin: "human")
        try appendHistory(summary: "Added: \(title)", automatic: false, action: "create_task", targetID: receipt.taskID, table: "tasks")
        return receipt
    }

    private func insertTask(title: String, notes: String?, localPath: String?, origin: String) throws -> Receipt {
        let id = UUID()
        let createdAt = iso(now())
        let stmt = try database.prepare(
            """
            INSERT INTO tasks (id, title, notes, local_path, created_at, lifecycle, origin)
            VALUES (?, ?, ?, ?, ?, 'active', ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, title)
        database.bind(stmt, 3, notes)
        database.bind(stmt, 4, localPath)
        database.bind(stmt, 5, createdAt)
        database.bind(stmt, 6, origin)
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

    private func loadTasks(lifecycle: String) throws -> [TaskSummary] {
        let stmt = try database.prepare(
            "SELECT id, title, notes, local_path FROM tasks WHERE lifecycle = ? ORDER BY created_at DESC, title ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, lifecycle)
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
        return tasks
    }

    private func loadHistory() throws -> [HistoryEntry] {
        let stmt = try database.prepare(
            "SELECT id, summary, automatic, created_at FROM history ORDER BY rowid DESC;"
        )
        defer { sqlite3_finalize(stmt) }
        var items: [HistoryEntry] = []
        let formatter = ISO8601DateFormatter()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let summary = database.column(stmt, 1)
            else { continue }
            let created = database.column(stmt, 3).flatMap(formatter.date(from:)) ?? Date.distantPast
            items.append(
                HistoryEntry(
                    id: id,
                    summary: summary,
                    isAutomatic: sqlite3_column_int(stmt, 2) == 1,
                    createdAt: created
                )
            )
        }
        return items
    }

    private func setLifecycle(_ id: UUID, _ lifecycle: String, summary: String) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try updateLifecycle(id, lifecycle, trashedAt: nil)
        try appendHistory(summary: "\(summary): \(id.uuidString)", automatic: false, action: lifecycle, targetID: id, table: "tasks")
        return Receipt(outcome: .recorded, taskID: id, summaryLine: summary)
    }

    private func moveToTrash(_ id: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try updateLifecycle(id, "trashed", trashedAt: iso(now()))
        try appendHistory(summary: "Moved to trash", automatic: false, action: "trash", targetID: id, table: "tasks")
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Moved to trash")
    }

    private func restoreFromTrash(_ id: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare("SELECT trashed_at FROM tasks WHERE id = ? AND lifecycle = 'trashed';")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScheduleBarError.notFound }
        if let stamped = database.column(stmt, 0).flatMap({ ISO8601DateFormatter().date(from: $0) }),
           now().timeIntervalSince(stamped) > 30 * 24 * 60 * 60 {
            throw ScheduleBarError.trashExpired
        }
        try updateLifecycle(id, "active", trashedAt: nil)
        try appendHistory(summary: "Restored from trash", automatic: false, action: "restore", targetID: id, table: "tasks")
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Restored")
    }

    private func permanentlyDelete(_ id: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let check = try database.prepare("SELECT id FROM tasks WHERE id = ? AND lifecycle = 'trashed';")
        defer { sqlite3_finalize(check) }
        database.bind(check, 1, id.uuidString)
        guard sqlite3_step(check) == SQLITE_ROW else { throw ScheduleBarError.notFound }
        try database.exec("DELETE FROM source_evidence WHERE task_id = '\(id.uuidString)';")
        try database.exec("DELETE FROM tasks WHERE id = '\(id.uuidString)';")
        try appendHistory(summary: "Permanently deleted", automatic: false, action: "delete", targetID: id, table: "tasks")
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Permanently deleted")
    }

    private func undoLastAutomaticChange() throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare(
            """
            SELECT id, action, target_id, target_table FROM history
            WHERE automatic = 1 AND undone = 0
            ORDER BY rowid DESC LIMIT 1;
            """
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let historyID = database.column(stmt, 0),
              let action = database.column(stmt, 1),
              let target = database.column(stmt, 2),
              let table = database.column(stmt, 3)
        else { throw ScheduleBarError.notFound }
        if action == "create_task", table == "tasks" {
            try database.exec("UPDATE tasks SET lifecycle = 'undone' WHERE id = '\(target)';")
        } else if action == "create_candidate", table == "candidates" {
            try database.exec("UPDATE candidates SET status = 'undone' WHERE id = '\(target)';")
        }
        try database.exec("UPDATE history SET undone = 1 WHERE id = '\(historyID)';")
        try appendHistory(summary: "Undo automatic change", automatic: false, action: "undo", targetID: UUID(uuidString: target), table: table)
        return Receipt(outcome: .recorded, summaryLine: "Undo automatic change")
    }

    private func updateLifecycle(_ id: UUID, _ lifecycle: String, trashedAt: String?) throws {
        let stmt = try database.prepare("UPDATE tasks SET lifecycle = ?, trashed_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, lifecycle)
        database.bind(stmt, 2, trashedAt)
        database.bind(stmt, 3, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else {
            throw ScheduleBarError.notFound
        }
    }

    private func appendHistory(
        summary: String,
        automatic: Bool,
        action: String,
        targetID: UUID?,
        table: String
    ) throws {
        let stmt = try database.prepare(
            """
            INSERT INTO history (id, created_at, automatic, summary, action, target_id, target_table, undone)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, iso(now()))
        sqlite3_bind_int(stmt, 3, automatic ? 1 : 0)
        database.bind(stmt, 4, summary)
        database.bind(stmt, 5, action)
        database.bind(stmt, 6, targetID?.uuidString)
        database.bind(stmt, 7, table)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    private func insertEvidence(taskID: UUID?, event: CaptureEvent) throws {
        guard let taskID else { return }
        let stmt = try database.prepare(
            """
            INSERT OR REPLACE INTO source_evidence
            (task_id, thread_id, turn_id, trigger_phrase, excerpt, working_directory)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, event.threadID)
        database.bind(stmt, 3, event.turnID)
        database.bind(stmt, 4, event.triggerPhrase)
        database.bind(stmt, 5, event.excerpt)
        database.bind(stmt, 6, event.workingDirectory)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    private func requireHuman(_ authority: SourceAuthority) throws {
        guard authority == .human else { throw ScheduleBarError.notPermitted }
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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
