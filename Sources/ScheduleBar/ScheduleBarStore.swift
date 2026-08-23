/// Production seam: `InputEvent` in, `ObservableState` out.
/// Capture events can land in `CaptureQueue` while the app is not running;
/// `processInbox()` applies each pending idempotency key exactly once.
import Foundation
import SQLite3

public final class ScheduleBarStore {
    private let storeURL: URL
    private let database: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let notifier: DirectoryNotifier
    private let reminderNotifier: ReminderNotifier

    public init(
        storeURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        notifier: DirectoryNotifier = SilentDirectoryNotifier(),
        reminderNotifier: ReminderNotifier = SilentReminderNotifier()
    ) throws {
        self.storeURL = storeURL
        self.now = now
        self.notifier = notifier
        self.reminderNotifier = reminderNotifier
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
        case .resolveDirectory(let path, let decision):
            try requireHuman(authority)
            return try resolveDirectory(path, decision)
        case .addTag(let taskID, let tag):
            try requireHuman(authority)
            return try addTag(taskID, tag)
        case .setReminders(let taskID, let fires):
            try requireHuman(authority)
            return try setReminders(taskID, fires)
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
        try observableState(projectID: nil)
    }

    public func observableState(projectID: UUID?) throws -> ObservableState {
        database.lock.lock()
        defer { database.lock.unlock() }
        let tasks = try loadTasks(lifecycle: "active", projectID: projectID)
        let candidates = try loadCandidates(projectID: projectID)
        var overdue: [TaskSummary] = []
        var today: [TaskSummary] = []
        var nextSevenDays: [TaskSummary] = []
        for task in tasks {
            switch DateParser.menuBucket(for: task, now: now()) {
            case .overdue: overdue.append(task)
            case .today: today.append(task)
            case .nextSevenDays: nextSevenDays.append(task)
            case nil: break
            }
        }
        return ObservableState(
            tasks: tasks,
            candidates: candidates,
            archived: try loadTasks(lifecycle: "archived", projectID: projectID),
            trash: try loadTasks(lifecycle: "trashed", projectID: projectID),
            history: try loadHistory(),
            projects: try loadProjects(),
            pendingDirectories: try loadPendingDirectories(),
            overdue: overdue,
            today: today,
            nextSevenDays: nextSevenDays
        )
    }

    public func reminders(for taskID: UUID) throws -> [Reminder] {
        database.lock.lock()
        defer { database.lock.unlock() }
        return try loadReminders(for: taskID)
    }

    public func processDueReminders() -> Int {
        database.lock.lock()
        defer { database.lock.unlock() }
        do {
            let stmt = try database.prepare(
                """
                SELECT r.id, r.fire_at, t.title
                FROM reminders r
                JOIN tasks t ON t.id = r.task_id
                WHERE r.fired = 0 AND t.lifecycle = 'active'
                ORDER BY r.fire_at ASC;
                """
            )
            defer { sqlite3_finalize(stmt) }
            let formatter = ISO8601DateFormatter()
            let current = now()
            var due: [(id: String, fireAt: Date, title: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = database.column(stmt, 0),
                      let fireText = database.column(stmt, 1),
                      let fireAt = formatter.date(from: fireText),
                      let title = database.column(stmt, 2),
                      fireAt <= current
                else { continue }
                due.append((id, fireAt, title))
            }
            for item in due {
                reminderNotifier.notifyReminder(title: item.title, fireAt: item.fireAt)
                let mark = try database.prepare("UPDATE reminders SET fired = 1, fired_at = ? WHERE id = ?;")
                defer { sqlite3_finalize(mark) }
                database.bind(mark, 1, iso(current))
                database.bind(mark, 2, item.id)
                guard sqlite3_step(mark) == SQLITE_DONE else { continue }
            }
            return due.count
        } catch {
            return 0
        }
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
            let receipt = try insertTask(title: title, notes: nil, localPath: nil, origin: "human", projectID: try inboxProjectID())
            try markCandidate(id, status: "confirmed")
            try appendHistory(summary: "Confirmed candidate: \(title)", automatic: false, action: "confirm_candidate", targetID: receipt.taskID, table: "tasks")
            return receipt
        case .edit(let input):
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
            let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath), origin: "human", projectID: try inboxProjectID())
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
            try discoverDirectory(event.workingDirectory)
            let mappedProject = try projectID(forDirectory: event.workingDirectory)
            let parsedDate = DateParser.parse(phrase: event.datePhrase, kind: event.dateKind, at: event.messageTime)
            var classified = CaptureClassifier.outcome(for: event)
            if classified == .recorded, mappedProject == nil {
                classified = .candidate
            }
            if classified == .recorded, parsedDate?.isVague == true {
                classified = .candidate
            }
            var taskID: UUID?
            switch classified {
            case .recorded:
                let created = try insertTask(
                    title: event.title,
                    notes: nil,
                    localPath: nil,
                    origin: "capture",
                    projectID: mappedProject
                )
                taskID = created.taskID
                if let parsedDate, !parsedDate.isVague, let createdID = created.taskID {
                    try attachDate(parsedDate, to: createdID)
                }
                try insertEvidence(taskID: created.taskID, event: event)
                try appendHistory(
                    summary: "Captured: \(event.title)",
                    automatic: true,
                    action: "create_task",
                    targetID: created.taskID,
                    table: "tasks"
                )
            case .candidate:
                taskID = try insertCandidate(title: event.title, inboxKey: key, projectID: mappedProject)
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
        let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath), origin: "human", projectID: try inboxProjectID())
        try appendHistory(summary: "Added: \(title)", automatic: false, action: "create_task", targetID: receipt.taskID, table: "tasks")
        return receipt
    }

    private func insertTask(title: String, notes: String?, localPath: String?, origin: String, projectID: UUID?) throws -> Receipt {
        let id = UUID()
        let createdAt = iso(now())
        let stmt = try database.prepare(
            """
            INSERT INTO tasks (id, title, notes, local_path, created_at, lifecycle, origin, project_id)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, title)
        database.bind(stmt, 3, notes)
        database.bind(stmt, 4, localPath)
        database.bind(stmt, 5, createdAt)
        database.bind(stmt, 6, origin)
        database.bind(stmt, 7, projectID?.uuidString)
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

    private func loadCandidates(projectID: UUID?) throws -> [TaskSummary] {
        let sql: String
        if projectID == nil {
            sql = "SELECT id, title, notes, project_id FROM candidates WHERE status = 'open' ORDER BY created_at DESC;"
        } else {
            sql = "SELECT id, title, notes, project_id FROM candidates WHERE status = 'open' AND project_id = ? ORDER BY created_at DESC;"
        }
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let projectID {
            database.bind(stmt, 1, projectID.uuidString)
        }
        var items: [TaskSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let title = database.column(stmt, 1)
            else { continue }
            items.append(
                TaskSummary(
                    id: id,
                    title: title,
                    notes: database.column(stmt, 2),
                    projectID: database.column(stmt, 3).flatMap(UUID.init(uuidString:))
                )
            )
        }
        return items
    }

    private func insertCandidate(title: String, inboxKey: String, projectID: UUID?) throws -> UUID {
        let id = UUID()
        let createdAt = iso(now())
        let stmt = try database.prepare(
            "INSERT INTO candidates (id, title, notes, inbox_key, status, created_at, project_id) VALUES (?, ?, NULL, ?, 'open', ?, ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, title)
        database.bind(stmt, 3, inboxKey)
        database.bind(stmt, 4, createdAt)
        database.bind(stmt, 5, projectID?.uuidString)
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

    private func loadTasks(lifecycle: String, projectID: UUID?) throws -> [TaskSummary] {
        let sql: String
        if projectID == nil {
            sql = "SELECT id, title, notes, local_path, project_id FROM tasks WHERE lifecycle = ? ORDER BY created_at DESC, title ASC;"
        } else {
            sql = "SELECT id, title, notes, local_path, project_id FROM tasks WHERE lifecycle = ? AND project_id = ? ORDER BY created_at DESC, title ASC;"
        }
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, lifecycle)
        if let projectID {
            database.bind(stmt, 2, projectID.uuidString)
        }
        var tasks: [TaskSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let title = database.column(stmt, 1)
            else { continue }
            let dates = try loadDates(for: id)
            tasks.append(
                TaskSummary(
                    id: id,
                    title: title,
                    notes: database.column(stmt, 2),
                    localPath: database.column(stmt, 3),
                    projectID: database.column(stmt, 4).flatMap(UUID.init(uuidString:)),
                    tags: try loadTags(for: id),
                    datePhrase: dates.phrase,
                    datePrecision: dates.precision,
                    hardDeadline: dates.hardDeadline,
                    plannedAt: dates.plannedAt,
                    targetDate: dates.targetDate,
                    followUpAt: dates.followUpAt,
                    isOverdue: dates.isOverdue
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
        try database.exec("DELETE FROM task_dates WHERE task_id = '\(id.uuidString)';")
        try database.exec("DELETE FROM reminders WHERE task_id = '\(id.uuidString)';")
        try database.exec("DELETE FROM task_tags WHERE task_id = '\(id.uuidString)';")
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

    private func discoverDirectory(_ raw: String) throws {
        let path = PathNormalization.normalize(raw)
        guard !path.isEmpty else { return }
        let existing = try database.prepare("SELECT notified FROM directories WHERE path = ?;")
        defer { sqlite3_finalize(existing) }
        database.bind(existing, 1, path)
        if sqlite3_step(existing) == SQLITE_ROW {
            return
        }
        let insert = try database.prepare(
            "INSERT INTO directories (path, decision, project_id, notified) VALUES (?, 'pending', NULL, 1);"
        )
        defer { sqlite3_finalize(insert) }
        database.bind(insert, 1, path)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        notifier.notifyUnknownDirectory(path)
        try appendHistory(summary: "Discovered directory: \(path)", automatic: true, action: "discover_directory", targetID: nil, table: "directories")
    }

    private func projectID(forDirectory raw: String) throws -> UUID? {
        let path = PathNormalization.normalize(raw)
        let stmt = try database.prepare("SELECT decision, project_id FROM directories WHERE path = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, path)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard database.column(stmt, 0) == "mapped" else { return nil }
        return database.column(stmt, 1).flatMap(UUID.init(uuidString:))
    }

    private func resolveDirectory(_ raw: String, _ decision: DirectoryDecision) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let path = PathNormalization.normalize(raw)
        switch decision {
        case .create(let name):
            let id = try insertProject(name)
            try upsertDirectory(path, decision: "mapped", projectID: id)
            try appendHistory(summary: "Created project \(name)", automatic: false, action: "map_directory", targetID: id, table: "projects")
            return Receipt(outcome: .recorded, taskID: id, projectID: id, summaryLine: "Created project \(name)")
        case .link(let projectID):
            try upsertDirectory(path, decision: "mapped", projectID: projectID)
            try appendHistory(summary: "Linked directory to project", automatic: false, action: "map_directory", targetID: projectID, table: "projects")
            return Receipt(outcome: .recorded, taskID: projectID, projectID: projectID, summaryLine: "Linked directory")
        case .ignore:
            try upsertDirectory(path, decision: "ignored", projectID: nil)
            try appendHistory(summary: "Ignored directory: \(path)", automatic: false, action: "ignore_directory", targetID: nil, table: "directories")
            return Receipt(outcome: .recorded, summaryLine: "Ignored directory")
        }
    }

    private func upsertDirectory(_ path: String, decision: String, projectID: UUID?) throws {
        let stmt = try database.prepare(
            """
            INSERT INTO directories (path, decision, project_id, notified)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(path) DO UPDATE SET decision = excluded.decision, project_id = excluded.project_id;
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, path)
        database.bind(stmt, 2, decision)
        database.bind(stmt, 3, projectID?.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func insertProject(_ name: String) throws -> UUID {
        let id = UUID()
        let stmt = try database.prepare("INSERT INTO projects (id, name, created_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, name)
        database.bind(stmt, 3, iso(now()))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        return id
    }

    private func inboxProjectID() throws -> UUID {
        let stmt = try database.prepare("SELECT id FROM projects WHERE name = 'Inbox' LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let id = database.column(stmt, 0).flatMap(UUID.init(uuidString:)) {
            return id
        }
        return try insertProject("Inbox")
    }

    private func addTag(_ taskID: UUID, _ raw: String) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw ScheduleBarError.emptyTitle }
        let insertTag = try database.prepare("INSERT OR IGNORE INTO tags (name) VALUES (?);")
        defer { sqlite3_finalize(insertTag) }
        database.bind(insertTag, 1, tag)
        guard sqlite3_step(insertTag) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        let link = try database.prepare("INSERT OR IGNORE INTO task_tags (task_id, tag) VALUES (?, ?);")
        defer { sqlite3_finalize(link) }
        database.bind(link, 1, taskID.uuidString)
        database.bind(link, 2, tag)
        guard sqlite3_step(link) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try appendHistory(summary: "Tagged \(tag)", automatic: false, action: "add_tag", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Tagged \(tag)")
    }

    private func loadTags(for taskID: UUID) throws -> [String] {
        let stmt = try database.prepare("SELECT tag FROM task_tags WHERE task_id = ? ORDER BY tag ASC;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        var tags: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let tag = database.column(stmt, 0) { tags.append(tag) }
        }
        return tags
    }

    private func loadProjects() throws -> [ProjectSummary] {
        let stmt = try database.prepare("SELECT id, name FROM projects ORDER BY name ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [ProjectSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let name = database.column(stmt, 1)
            else { continue }
            items.append(ProjectSummary(id: id, name: name))
        }
        return items
    }

    private func loadPendingDirectories() throws -> [DirectoryDiscovery] {
        let stmt = try database.prepare("SELECT path FROM directories WHERE decision = 'pending' ORDER BY path ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [DirectoryDiscovery] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let path = database.column(stmt, 0) {
                items.append(DirectoryDiscovery(normalizedPath: path))
            }
        }
        return items
    }

    private func attachDate(_ parsed: ParsedDate, to taskID: UUID) throws {
        let stmt = try database.prepare(
            """
            INSERT INTO task_dates (task_id, kind, phrase, anchor_at, instant, precision, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(task_id, kind) DO UPDATE SET
                phrase = excluded.phrase,
                anchor_at = excluded.anchor_at,
                instant = excluded.instant,
                precision = excluded.precision,
                status = excluded.status;
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, parsed.kind.rawValue)
        database.bind(stmt, 3, parsed.phrase)
        database.bind(stmt, 4, iso(parsed.anchor))
        database.bind(stmt, 5, parsed.instant.map(iso))
        database.bind(stmt, 6, parsed.precision.rawValue)
        database.bind(stmt, 7, parsed.status.rawValue)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        if parsed.kind == .hardDeadline, parsed.precision == .allDay, let instant = parsed.instant {
            try replaceReminders(taskID, DateParser.defaultAllDayHardDeadlineReminders(deadline: instant))
        }
    }

    private func setReminders(_ taskID: UUID, _ fires: [Date]) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let check = try database.prepare("SELECT id FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(check) }
        database.bind(check, 1, taskID.uuidString)
        guard sqlite3_step(check) == SQLITE_ROW else { throw ScheduleBarError.notFound }
        try replaceReminders(taskID, fires)
        try appendHistory(summary: "Updated reminders", automatic: false, action: "set_reminders", targetID: taskID, table: "reminders")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Updated reminders")
    }

    private func replaceReminders(_ taskID: UUID, _ fires: [Date]) throws {
        let clear = try database.prepare("DELETE FROM reminders WHERE task_id = ?;")
        defer { sqlite3_finalize(clear) }
        database.bind(clear, 1, taskID.uuidString)
        guard sqlite3_step(clear) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        for fireAt in fires {
            let stmt = try database.prepare(
                "INSERT INTO reminders (id, task_id, fire_at, fired, fired_at) VALUES (?, ?, ?, 0, NULL);"
            )
            defer { sqlite3_finalize(stmt) }
            database.bind(stmt, 1, UUID().uuidString)
            database.bind(stmt, 2, taskID.uuidString)
            database.bind(stmt, 3, iso(fireAt))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        }
    }

    private func loadReminders(for taskID: UUID) throws -> [Reminder] {
        let stmt = try database.prepare(
            "SELECT id, fire_at FROM reminders WHERE task_id = ? ORDER BY fire_at ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        let formatter = ISO8601DateFormatter()
        var items: [Reminder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let fireText = database.column(stmt, 1),
                  let fireAt = formatter.date(from: fireText)
            else { continue }
            items.append(Reminder(id: id, fireAt: fireAt))
        }
        return items
    }

    private func loadDates(for taskID: UUID) throws -> (
        phrase: String?,
        precision: DatePrecision?,
        hardDeadline: Date?,
        plannedAt: Date?,
        targetDate: Date?,
        followUpAt: Date?,
        isOverdue: Bool
    ) {
        let stmt = try database.prepare(
            "SELECT kind, phrase, instant, precision FROM task_dates WHERE task_id = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        let formatter = ISO8601DateFormatter()
        var phrase: String?
        var precision: DatePrecision?
        var hardDeadline: Date?
        var plannedAt: Date?
        var targetDate: Date?
        var followUpAt: Date?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = database.column(stmt, 0).flatMap(DateKind.init(rawValue:))
            let rowPhrase = database.column(stmt, 1)
            let instant = database.column(stmt, 2).flatMap(formatter.date(from:))
            let rowPrecision = database.column(stmt, 3).flatMap(DatePrecision.init(rawValue:))
            switch kind {
            case .hardDeadline:
                hardDeadline = instant
                phrase = rowPhrase ?? phrase
                precision = rowPrecision ?? precision
            case .target:
                targetDate = instant
                if phrase == nil { phrase = rowPhrase }
                if precision == nil { precision = rowPrecision }
            case .planned:
                plannedAt = instant
                if phrase == nil { phrase = rowPhrase }
                if precision == nil { precision = rowPrecision }
            case .followUp:
                followUpAt = instant
                if phrase == nil { phrase = rowPhrase }
                if precision == nil { precision = rowPrecision }
            case nil:
                continue
            }
        }
        let overdue: Bool
        if let hardDeadline, let precision {
            overdue = DateParser.isOverdue(hardDeadline: hardDeadline, precision: precision, now: now())
        } else {
            overdue = false
        }
        return (phrase, precision, hardDeadline, plannedAt, targetDate, followUpAt, overdue)
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
