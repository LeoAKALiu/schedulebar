/// Production seam: `InputEvent` in, `ObservableState` out.
/// Capture events can land in `CaptureQueue` while the app is not running;
/// `processInbox()` applies each pending idempotency key exactly once.
import Foundation
import SQLite3

public final class ScheduleBarStore: @unchecked Sendable {
    private let storeURL: URL
    private let database: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let notifier: DirectoryNotifier
    private let reminderNotifier: ReminderNotifier
    private let modelGateway: ModelGateway
    private let secretStore: SecretStore
    private let sessionDirectory: SessionDirectory
    private let healthEnvironment: HealthEnvironment
    private let loginItems: LoginItemControlling
    private let modelJobRunLock = NSLock()
    private var modelJobsRunning = false

    public init(
        storeURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        notifier: DirectoryNotifier = SilentDirectoryNotifier(),
        reminderNotifier: ReminderNotifier = SilentReminderNotifier(),
        modelGateway: ModelGateway = SilentModelGateway(),
        secretStore: SecretStore = MemorySecretStore(),
        sessionDirectory: SessionDirectory = EmptySessionDirectory(),
        healthEnvironment: HealthEnvironment = StaticHealthEnvironment(),
        loginItems: LoginItemControlling = MemoryLoginItemController()
    ) throws {
        self.storeURL = storeURL
        self.now = now
        self.notifier = notifier
        self.reminderNotifier = reminderNotifier
        self.modelGateway = modelGateway
        self.secretStore = secretStore
        self.sessionDirectory = sessionDirectory
        self.healthEnvironment = healthEnvironment
        self.loginItems = loginItems
        database = try SQLiteDatabase(url: storeURL)
    }

    public func apply(_ event: InputEvent, authority: SourceAuthority = .human) throws -> Receipt {
        switch event {
        case .quickAdd(let input):
            try requireHuman(authority)
            return try quickAdd(input)
        case .editTask(let id, let input):
            try requireHuman(authority)
            return try editTask(id, input: input)
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
        case .setOwner(let taskID, let name, let kind):
            try requireHuman(authority)
            return try setOwner(taskID, name: name, kind: kind)
        case .confirmAlias(let alias, let ownerID):
            try requireHuman(authority)
            return try confirmAlias(alias, ownerID: ownerID)
        case .setStatus(let taskID, let status):
            return try setWorkflowStatus(taskID, status, authority: authority)
        case .requireAcceptance(let taskID, let criterion):
            try requireHuman(authority)
            return try requireAcceptance(taskID, criterion)
        case .satisfyAcceptance(let taskID, let criterion):
            return try satisfyAcceptance(taskID, criterion)
        case .setFollowUp(let taskID, let date):
            try requireHuman(authority)
            return try setFollowUp(taskID, date)
        case .proposePlan(let proposal):
            return try proposePlan(proposal)
        case .acceptPlan(let planID, let itemIDs):
            try requireHuman(authority)
            return try acceptPlan(planID, itemIDs)
        case .rejectPlan(let planID):
            try requireHuman(authority)
            return try rejectPlan(planID)
        case .linkSource(let taskID, let evidence):
            try requireHuman(authority)
            return try linkSource(taskID, evidence)
        case .setBlockedBy(let taskID, let blockerID):
            try requireHumanOrMain(authority)
            return try setBlockedBy(taskID, blockerID)
        case .removeBlockedBy(let taskID, let blockerID):
            try requireHumanOrMain(authority)
            return try removeBlockedBy(taskID, blockerID)
        case .setPriority(let taskID, let priority):
            try requireHuman(authority)
            return try setPriority(taskID, priority)
        case .setRecurrence(let taskID, let rule):
            try requireHuman(authority)
            return try setRecurrence(taskID, rule)
        case .stopRecurrence(let seriesID):
            try requireHuman(authority)
            return try stopRecurrence(seriesID)
        case .exportBackup(let url):
            try requireHuman(authority)
            return try exportBackup(to: url)
        case .setModelAPIKey(let key):
            try requireHuman(authority)
            return try setModelAPIKey(key)
        case .clearModelAPIKey:
            try requireHuman(authority)
            return clearModelAPIKey()
        case .reconcileSessions:
            return reconcileSessions()
        case .retryFailures:
            return retryFailures()
        case .setLoginAtStartup(let enabled):
            try requireHuman(authority)
            return setLoginAtStartup(enabled)
        case .exportDiagnostics(let url):
            try requireHuman(authority)
            return try exportDiagnostics(to: url)
        }
    }

    public func processInbox() -> [Receipt] {
        let pending: [(key: String, payload: String)]
        let pendingPlans: [(key: String, payload: String)]
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
            let planStmt = try database.prepare(
                "SELECT idempotency_key, payload FROM plan_inbox WHERE status = 'pending' ORDER BY rowid ASC;"
            )
            defer { sqlite3_finalize(planStmt) }
            var planRows: [(String, String)] = []
            while sqlite3_step(planStmt) == SQLITE_ROW {
                if let key = database.column(planStmt, 0), let payload = database.column(planStmt, 1) {
                    planRows.append((key, payload))
                }
            }
            pendingPlans = planRows
        } catch {
            return []
        }
        var receipts = pending.map { applyPending(key: $0.key, payload: $0.payload) }
        receipts.append(contentsOf: pendingPlans.map { applyPendingPlan(key: $0.key, payload: $0.payload) })
        return receipts
    }

    public func previewCaptureOutcome(_ event: CaptureEvent) throws -> Outcome {
        database.lock.lock()
        defer { database.lock.unlock() }
        let mappedProject = try projectID(forDirectory: event.workingDirectory)
        return captureClassification(event, mappedProject: mappedProject).outcome
    }

    public func observableState() throws -> ObservableState {
        try observableState(projectID: nil)
    }

    public func observableState(projectID: UUID?) throws -> ObservableState {
        database.lock.lock()
        defer { database.lock.unlock() }
        let tasks = withProgress(try loadTasks(lifecycle: "active", projectID: projectID))
        let candidates = try loadCandidates(projectID: projectID)
        var overdue: [TaskSummary] = []
        var today: [TaskSummary] = []
        var nextSevenDays: [TaskSummary] = []
        for task in tasks where task.status != .completed && task.status != .cancelled {
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
            projects: try loadProjects(progressFrom: tasks),
            pendingDirectories: try loadPendingDirectories(),
            overdue: overdue,
            today: today,
            nextSevenDays: nextSevenDays,
            waitingOnOthers: tasks.filter(isWaitingOnOther),
            owners: try loadOwners(),
            plans: try loadPlans(),
            milestones: tasks.filter { $0.kind == .milestone },
            recurrences: try loadRecurrences(),
            diagnostics: try loadDiagnostics(),
            health: try loadHealth(),
            pendingInboxCount: pendingInboxCount(),
            loginAtStartup: loginItems.isEnabled
        )
    }

    public func processModelMisses() async {
        guard beginModelJobRun() else { return }
        defer { endModelJobRun() }
        let jobs = pendingModelJobs()
        let apiKey = secretStore.loadAPIKey()
        for job in jobs {
            let result = await modelGateway.detectMissedCandidates(job.request, apiKey: apiKey)
            recordModelResult(jobID: job.id, result)
        }
    }

    /// Timer-driven runs and manual retries can overlap because each HTTP call
    /// is allowed to take seconds; a second run while one is in flight would
    /// re-read the same pending jobs and insert duplicate candidates.
    private func beginModelJobRun() -> Bool {
        modelJobRunLock.lock()
        defer { modelJobRunLock.unlock() }
        if modelJobsRunning { return false }
        modelJobsRunning = true
        return true
    }

    private func endModelJobRun() {
        modelJobRunLock.lock()
        defer { modelJobRunLock.unlock() }
        modelJobsRunning = false
    }

    private func pendingModelJobs() -> [(id: String, request: MissedCandidateRequest)] {
        database.lock.lock()
        defer { database.lock.unlock() }
        return (try? loadPendingModelJobs()) ?? []
    }

    private func recordModelResult(jobID: String, _ result: ModelMissResult) {
        database.lock.lock()
        defer { database.lock.unlock() }
        do {
            switch result {
            case .candidates(let titles):
                for title in titles {
                    let cleaned = Retention.sanitize(title.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !cleaned.isEmpty else { continue }
                    if try taskTitleExists(cleaned) || candidateTitleExists(cleaned) { continue }
                    let candidateID = try insertCandidate(title: cleaned, inboxKey: "model:\(jobID):\(cleaned)", projectID: nil)
                    try appendHistory(
                        summary: "Model candidate: \(cleaned)",
                        automatic: true,
                        action: "model_candidate",
                        targetID: candidateID,
                        table: "candidates"
                    )
                }
                try markModelJob(jobID, status: "done")
            case .failed(let code, let message):
                try insertDiagnostic(code: code, message: Retention.sanitize(message), component: "deepseek")
                try markModelJob(jobID, status: "failed")
            }
        } catch {
            return
        }
    }

    public func reconcileSessions() -> Receipt {
        let scan = sessionDirectory.scan()
        for failure in scan.failures {
            recordDiagnostic(code: "session_unreadable", message: "retryable: \(failure)")
        }
        let turns = scan.turns.sorted {
            if $0.messageTime != $1.messageTime { return $0.messageTime < $1.messageTime }
            return TurnIDOrder.isLess($0.turnID, $1.turnID)
        }
        var queued = false
        for turn in turns {
            if !isAfterCursor(turn) { continue }
            guard let event = captureEvent(from: turn) else {
                if !saveCursor(turn) { break }
                continue
            }
            let result = CaptureQueue(storeURL: storeURL).enqueue(event)
            if result.outcome == .notRecorded {
                // Keep the cursor on this turn so the next reconcile retries it
                // instead of silently dropping it forever.
                recordDiagnostic(
                    code: "reconcile_enqueue_failed",
                    message: "retryable: enqueue failed for turn \(turn.turnID)"
                )
                break
            }
            if result.outcome == .recorded { queued = true }
            if !saveCursor(turn) {
                recordDiagnostic(
                    code: "reconcile_cursor_failed",
                    message: "retryable: could not persist cursor after turn \(turn.turnID)"
                )
                break
            }
        }
        if queued {
            _ = processInbox()
        }
        return Receipt(outcome: .recorded, summaryLine: "Reconciled local sessions")
    }

    public func processRecurrences() -> Int {
        database.lock.lock()
        defer { database.lock.unlock() }
        return (try? generateRecurrenceInstances()) ?? 0
    }

    public func sourceLinks(for taskID: UUID) throws -> [SourceEvidence] {
        database.lock.lock()
        defer { database.lock.unlock() }
        return try loadSourceLinks(for: taskID)
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
                WHERE r.fired = 0
                  AND t.lifecycle = 'active'
                  AND t.workflow_status NOT IN ('completed', 'cancelled')
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
        try sourceLinks(for: taskID).first
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
            guard let row = try candidateRecord(id) else {
                throw ScheduleBarError.storeUnavailable
            }
            return try confirmCandidate(row, title: row.title, notes: row.notes, localPath: row.localPath)
        case .edit(let input):
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
            guard try candidateRecord(id) != nil else { throw ScheduleBarError.notFound }
            let stmt = try database.prepare(
                "UPDATE candidates SET title = ?, notes = ?, local_path = ? WHERE id = ? AND status = 'open';"
            )
            defer { sqlite3_finalize(stmt) }
            database.bind(stmt, 1, Retention.sanitize(title))
            database.bind(stmt, 2, trimmed(input.notes).map(Retention.sanitize))
            database.bind(stmt, 3, trimmed(input.localPath))
            database.bind(stmt, 4, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else {
                throw ScheduleBarError.storeUnavailable
            }
            try appendHistory(
                summary: "Edited candidate: \(title)",
                automatic: false,
                action: "edit_candidate",
                targetID: id,
                table: "candidates"
            )
            return Receipt(outcome: .candidate, taskID: id, summaryLine: "Candidate updated")
        }
    }

    private func confirmCandidate(
        _ row: CandidateRecord,
        title: String,
        notes: String?,
        localPath: String?
    ) throws -> Receipt {
        let projectID = try row.projectID ?? inboxProjectID()
        let receipt = try insertTask(
            title: title,
            notes: notes,
            localPath: localPath,
            origin: "human",
            projectID: projectID
        )
        if let parsed = row.date, let taskID = receipt.taskID {
            try attachDate(parsed, to: taskID)
        }
        if let taskID = receipt.taskID {
            try execChange(
                "UPDATE source_evidence SET task_id = ? WHERE task_id = ?;",
                taskID.uuidString,
                row.id.uuidString
            )
            try execChange(
                "UPDATE source_links SET task_id = ? WHERE task_id = ?;",
                taskID.uuidString,
                row.id.uuidString
            )
        }
        try markCandidate(row.id, status: "confirmed")
        try appendHistory(
            summary: "Confirmed candidate: \(title)",
            automatic: false,
            action: "confirm_candidate",
            targetID: receipt.taskID,
            table: "tasks"
        )
        return receipt
    }

    private func applyPending(key: String, payload: String) -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        do {
            let event = try decode(payload)
            try database.exec("BEGIN IMMEDIATE;")
            do {
                let receipt = try classifyAndApply(event, inboxKey: key)
                try database.exec("COMMIT;")
                return receipt
            } catch {
                try? database.exec("ROLLBACK;")
                return Receipt(outcome: .notRecorded)
            }
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }

    private func applyPendingPlan(key: String, payload: String) -> Receipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = payload.data(using: .utf8),
              let proposal = try? decoder.decode(PlanProposal.self, from: data)
        else { return Receipt(outcome: .notRecorded) }
        do {
            let receipt = try apply(.proposePlan(proposal), authority: .mainConversation)
            database.lock.lock()
            defer { database.lock.unlock() }
            let stmt = try database.prepare(
                "UPDATE plan_inbox SET status = 'processed', plan_id = ? WHERE idempotency_key = ?;"
            )
            defer { sqlite3_finalize(stmt) }
            database.bind(stmt, 1, receipt.taskID?.uuidString)
            database.bind(stmt, 2, key)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return Receipt(outcome: .notRecorded) }
            return receipt
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }

    private func classifyAndApply(_ event: CaptureEvent, inboxKey: String) throws -> Receipt {
        try discoverDirectory(event.workingDirectory)
        let mappedProject = try projectID(forDirectory: event.workingDirectory)
        let classification = captureClassification(event, mappedProject: mappedProject)
        let parsedDate = classification.date
        let recurrence = classification.recurrence
        let classified = classification.outcome
        var taskID: UUID?
        switch classified {
        case .recorded:
            let created = try insertTask(
                title: event.title,
                notes: nil,
                localPath: nil,
                origin: "capture",
                projectID: mappedProject,
                ownerName: event.ownerName,
                ownerKind: event.ownerKind,
                priority: PriorityParser.parse(event) ?? .normal
            )
            taskID = created.taskID
            if let parsedDate, !parsedDate.isVague, let createdID = created.taskID {
                try attachDate(parsedDate, to: createdID)
            }
            if case .rule(let rule) = recurrence, let createdID = created.taskID {
                _ = try attachRecurrence(to: createdID, rule: rule)
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
            taskID = try insertCandidate(title: event.title, inboxKey: inboxKey, projectID: mappedProject, date: parsedDate)
            try insertEvidence(taskID: taskID, event: event)
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
        try enqueueModelJob(event)
        let stmt = try database.prepare(
            "UPDATE capture_inbox SET status = 'processed', task_id = ? WHERE idempotency_key = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID?.uuidString)
        database.bind(stmt, 2, inboxKey)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        return Receipt(
            outcome: classified,
            taskID: taskID,
            summaryLine: summary(classified, title: event.title)
        )
    }

    private func captureClassification(
        _ event: CaptureEvent,
        mappedProject: UUID?
    ) -> (outcome: Outcome, date: ParsedDate?, recurrence: RecurrenceParse) {
        let parsedDate = DateParser.parse(phrase: event.datePhrase, kind: event.dateKind, at: event.messageTime)
        let recurrence = RecurrenceParser.parse(event)
        var outcome = CaptureClassifier.outcome(for: event)
        if outcome == .recorded, mappedProject == nil { outcome = .candidate }
        if outcome == .recorded, parsedDate?.isVague == true { outcome = .candidate }
        if outcome == .recorded, recurrence == .vague || recurrence == .complex { outcome = .candidate }
        return (outcome, parsedDate, recurrence)
    }

    private func quickAdd(_ input: QuickAddInput) throws -> Receipt {
        let title = Retention.sanitize(input.title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
        database.lock.lock()
        defer { database.lock.unlock() }
        let receipt = try insertTask(title: title, notes: trimmed(input.notes), localPath: trimmed(input.localPath), origin: "human", projectID: try inboxProjectID())
        try appendHistory(summary: "Added: \(title)", automatic: false, action: "create_task", targetID: receipt.taskID, table: "tasks")
        return receipt
    }

    private func editTask(_ id: UUID, input: QuickAddInput) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
        let stmt = try database.prepare(
            "UPDATE tasks SET title = ?, notes = ?, local_path = ? WHERE id = ? AND lifecycle != 'undone';"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, Retention.sanitize(title))
        database.bind(stmt, 2, trimmed(input.notes).map(Retention.sanitize))
        database.bind(stmt, 3, trimmed(input.localPath))
        database.bind(stmt, 4, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else {
            throw ScheduleBarError.notFound
        }
        try appendHistory(
            summary: "Edited task: \(title)",
            automatic: false,
            action: "edit_task",
            targetID: id,
            table: "tasks"
        )
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Task updated")
    }

    private func insertTask(
        title: String,
        notes: String?,
        localPath: String?,
        origin: String,
        projectID: UUID?,
        ownerName: String? = nil,
        ownerKind: OwnerKind? = nil,
        id: UUID? = nil,
        kind: WorkKind = .task,
        parentID: UUID? = nil,
        necessary: Bool = true,
        priority: BusinessPriority = .normal,
        seriesID: UUID? = nil,
        occurrence: String? = nil
    ) throws -> Receipt {
        let id = id ?? UUID()
        let createdAt = iso(now())
        let title = Retention.sanitize(title)
        let notes = Retention.sanitize(notes)
        let resolvedName = ownerName ?? "Me"
        let resolvedKind = ownerKind ?? (resolvedName == "Me" ? .selfPerson : .person)
        let ownerID = try upsertOwner(name: resolvedName, kind: resolvedKind)
        let stmt = try database.prepare(
            """
            INSERT INTO tasks (id, title, notes, local_path, created_at, lifecycle, origin, project_id, owner_id, workflow_status, kind, parent_id, necessary, priority, series_id, occurrence)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, 'notStarted', ?, ?, ?, ?, ?, ?);
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
        database.bind(stmt, 8, ownerID.uuidString)
        database.bind(stmt, 9, kind.rawValue)
        database.bind(stmt, 10, parentID?.uuidString)
        sqlite3_bind_int(stmt, 11, necessary ? 1 : 0)
        database.bind(stmt, 12, priority.rawValue)
        database.bind(stmt, 13, seriesID?.uuidString)
        database.bind(stmt, 14, occurrence)
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
            sql = """
                SELECT id, title, notes, local_path, project_id, date_phrase, date_kind, date_anchor, date_precision, date_status, date_instant
                FROM candidates WHERE status = 'open' ORDER BY created_at DESC;
                """
        } else {
            sql = """
                SELECT id, title, notes, local_path, project_id, date_phrase, date_kind, date_anchor, date_precision, date_status, date_instant
                FROM candidates WHERE status = 'open' AND project_id = ? ORDER BY created_at DESC;
                """
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
            let parsed = parsedDate(
                phrase: database.column(stmt, 5),
                kind: database.column(stmt, 6),
                anchor: database.column(stmt, 7),
                precision: database.column(stmt, 8),
                status: database.column(stmt, 9),
                instant: database.column(stmt, 10)
            )
            items.append(
                TaskSummary(
                    id: id,
                    title: title,
                    notes: database.column(stmt, 2),
                    localPath: database.column(stmt, 3),
                    projectID: database.column(stmt, 4).flatMap(UUID.init(uuidString:)),
                    datePhrase: parsed?.phrase,
                    datePrecision: parsed?.precision
                )
            )
        }
        return items
    }

    private func insertCandidate(title: String, inboxKey: String, projectID: UUID?, date: ParsedDate? = nil) throws -> UUID {
        if let existing = try candidateID(forInboxKey: inboxKey) {
            return existing
        }
        let id = UUID()
        let createdAt = iso(now())
        let stmt = try database.prepare(
            """
            INSERT INTO candidates (
                id, title, notes, local_path, inbox_key, status, created_at, project_id,
                date_phrase, date_kind, date_anchor, date_precision, date_status, date_instant
            ) VALUES (?, ?, NULL, NULL, ?, 'open', ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, Retention.sanitize(title))
        database.bind(stmt, 3, inboxKey)
        database.bind(stmt, 4, createdAt)
        database.bind(stmt, 5, projectID?.uuidString)
        database.bind(stmt, 6, date?.phrase)
        database.bind(stmt, 7, date?.kind.rawValue)
        database.bind(stmt, 8, date.map { iso($0.anchor) })
        database.bind(stmt, 9, date?.precision.rawValue)
        database.bind(stmt, 10, date?.status.rawValue)
        database.bind(stmt, 11, date?.instant.map(iso))
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

    private func candidateID(forInboxKey inboxKey: String) throws -> UUID? {
        let stmt = try database.prepare(
            "SELECT id FROM candidates WHERE inbox_key = ? AND status = 'open' LIMIT 1;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, inboxKey)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = database.column(stmt, 0)
        else { return nil }
        return UUID(uuidString: text)
    }

    private func candidateRecord(_ id: UUID) throws -> CandidateRecord? {
        let stmt = try database.prepare(
            """
            SELECT title, notes, local_path, project_id, date_phrase, date_kind, date_anchor, date_precision, date_status, date_instant
            FROM candidates WHERE id = ? AND status = 'open';
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW, let title = database.column(stmt, 0) else { return nil }
        return CandidateRecord(
            id: id,
            title: title,
            notes: database.column(stmt, 1),
            localPath: database.column(stmt, 2),
            projectID: database.column(stmt, 3).flatMap(UUID.init(uuidString:)),
            date: parsedDate(
                phrase: database.column(stmt, 4),
                kind: database.column(stmt, 5),
                anchor: database.column(stmt, 6),
                precision: database.column(stmt, 7),
                status: database.column(stmt, 8),
                instant: database.column(stmt, 9)
            )
        )
    }

    private func parsedDate(
        phrase: String?,
        kind: String?,
        anchor: String?,
        precision: String?,
        status: String?,
        instant: String?
    ) -> ParsedDate? {
        guard let phrase, !phrase.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        return ParsedDate(
            kind: kind.flatMap(DateKind.init(rawValue:)) ?? .planned,
            phrase: phrase,
            anchor: anchor.flatMap(formatter.date(from:)) ?? now(),
            instant: instant.flatMap(formatter.date(from:)),
            precision: precision.flatMap(DatePrecision.init(rawValue:)) ?? .vague,
            status: status.flatMap(DateParseStatus.init(rawValue:)) ?? .vague
        )
    }

    private func summary(_ outcome: Outcome, title: String) -> String {
        if outcome == .recorded {
            return "Recorded: \(title)"
        }
        return outcome.defaultSummaryLine
    }

    private func loadTasks(lifecycle: String, projectID: UUID?) throws -> [TaskSummary] {
        let sql: String
        if projectID == nil {
            sql = """
                SELECT t.id, t.title, t.notes, t.local_path, t.project_id, t.owner_id, t.workflow_status, o.name, o.kind, t.kind, t.parent_id, t.necessary, t.priority, t.series_id, t.occurrence
                FROM tasks t
                LEFT JOIN owners o ON o.id = t.owner_id
                WHERE t.lifecycle = ? ORDER BY t.created_at DESC, t.title ASC;
                """
        } else {
            sql = """
                SELECT t.id, t.title, t.notes, t.local_path, t.project_id, t.owner_id, t.workflow_status, o.name, o.kind, t.kind, t.parent_id, t.necessary, t.priority, t.series_id, t.occurrence
                FROM tasks t
                LEFT JOIN owners o ON o.id = t.owner_id
                WHERE t.lifecycle = ? AND t.project_id = ? ORDER BY t.created_at DESC, t.title ASC;
                """
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
            let blockers = try loadBlockerIDs(for: id)
            var summary = TaskSummary(
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
                isOverdue: dates.isOverdue,
                ownerID: database.column(stmt, 5).flatMap(UUID.init(uuidString:)),
                ownerName: database.column(stmt, 7),
                ownerKind: database.column(stmt, 8).flatMap(OwnerKind.init(rawValue:)),
                status: database.column(stmt, 6).flatMap(WorkflowStatus.init(rawValue:)) ?? .notStarted,
                kind: database.column(stmt, 9).flatMap(WorkKind.init(rawValue:)) ?? .task,
                parentID: database.column(stmt, 10).flatMap(UUID.init(uuidString:)),
                necessary: sqlite3_column_int(stmt, 11) == 1,
                priority: database.column(stmt, 12).flatMap(BusinessPriority.init(rawValue:)) ?? .normal,
                blockedByIDs: blockers,
                hasUnsatisfiedBlockers: try hasUnsatisfiedBlockers(blockers),
                seriesID: database.column(stmt, 13).flatMap(UUID.init(uuidString:)),
                occurrenceDate: database.column(stmt, 14).flatMap(RecurrenceParser.date(fromOccurrence:))
            )
            summary.dateUrgency = DateParser.dateUrgency(for: summary, now: now())
            tasks.append(summary)
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
        try execChange("DELETE FROM source_evidence WHERE task_id = ?;", id.uuidString)
        try execChange("DELETE FROM source_links WHERE task_id = ?;", id.uuidString)
        try execChange("DELETE FROM task_dates WHERE task_id = ?;", id.uuidString)
        try execChange("DELETE FROM reminders WHERE task_id = ?;", id.uuidString)
        try execChange("DELETE FROM task_tags WHERE task_id = ?;", id.uuidString)
        try execChange("DELETE FROM tasks WHERE id = ?;", id.uuidString)
        try appendHistory(summary: "Permanently deleted", automatic: false, action: "delete", targetID: id, table: "tasks")
        return Receipt(outcome: .recorded, taskID: id, summaryLine: "Permanently deleted")
    }

    private func undoLastAutomaticChange() throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare(
            """
            SELECT id, action, target_id, target_table, detail FROM history
            WHERE automatic = 1 AND undone = 0
            ORDER BY rowid DESC LIMIT 1;
            """
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let historyID = database.column(stmt, 0),
              let action = database.column(stmt, 1),
              let table = database.column(stmt, 3)
        else { throw ScheduleBarError.notFound }
        let target = database.column(stmt, 2)
        let detail = database.column(stmt, 4)
        if let target, action == "create_task", table == "tasks" {
            try execChange("UPDATE tasks SET lifecycle = 'undone' WHERE id = ?;", target)
        } else if let target, (action == "create_candidate" || action == "model_candidate"), table == "candidates" {
            try execChange("UPDATE candidates SET status = 'undone' WHERE id = ?;", target)
        } else if let target, action == "propose_plan", table == "plans" {
            try execChange("UPDATE plans SET status = 'undone' WHERE id = ?;", target)
        } else if let target, action == "satisfy_acceptance", table == "tasks" {
            try execChange("UPDATE acceptance_evidence SET satisfied = 0 WHERE task_id = ?;", target)
        } else if let target, action == "set_status", table == "tasks", let detail,
                  let restored = WorkflowStatus(rawValue: detail) {
            try execChange("UPDATE tasks SET workflow_status = ?, status_authority = NULL WHERE id = ?;", restored.rawValue, target)
        } else if action == "discover_directory", table == "directories", let detail {
            // Remove the pending row so the directory can be re-discovered;
            // a decision the human already made stands and is not reverted.
            try execChange("DELETE FROM directories WHERE path = ? AND decision = 'pending';", detail)
        }
        try execChange("UPDATE history SET undone = 1 WHERE id = ?;", historyID)
        try appendHistory(summary: "Undo automatic change", automatic: false, action: "undo", targetID: target.flatMap(UUID.init(uuidString:)), table: table)
        return Receipt(outcome: .recorded, summaryLine: "Undo automatic change")
    }

    private func execChange(_ sql: String, _ value: String) throws {
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, value)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    private func execChange(_ sql: String, _ value1: String, _ value2: String) throws {
        let stmt = try database.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, value1)
        database.bind(stmt, 2, value2)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
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
        table: String,
        detail: String? = nil
    ) throws {
        let stmt = try database.prepare(
            """
            INSERT INTO history (id, created_at, automatic, summary, action, target_id, target_table, undone, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, iso(now()))
        sqlite3_bind_int(stmt, 3, automatic ? 1 : 0)
        database.bind(stmt, 4, Retention.sanitize(summary))
        database.bind(stmt, 5, action)
        database.bind(stmt, 6, targetID?.uuidString)
        database.bind(stmt, 7, table)
        database.bind(stmt, 8, detail)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    private func insertEvidence(taskID: UUID?, event: CaptureEvent) throws {
        guard let taskID else { return }
        let evidence = SourceEvidence(
            threadID: event.threadID,
            turnID: event.turnID,
            triggerPhrase: event.triggerPhrase,
            excerpt: event.excerpt,
            workingDirectory: event.workingDirectory,
            messageTime: event.messageTime
        )
        let stmt = try database.prepare(
            """
            INSERT OR REPLACE INTO source_evidence
            (task_id, thread_id, turn_id, trigger_phrase, excerpt, working_directory, message_time)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, evidence.threadID)
        database.bind(stmt, 3, evidence.turnID)
        database.bind(stmt, 4, evidence.triggerPhrase)
        database.bind(stmt, 5, evidence.excerpt)
        database.bind(stmt, 6, evidence.workingDirectory)
        database.bind(stmt, 7, evidence.messageTime.map(iso))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        try insertSourceLink(taskID: taskID, evidence: evidence)
    }

    private func requireHuman(_ authority: SourceAuthority) throws {
        guard authority == .human else { throw ScheduleBarError.notPermitted }
    }

    private func requireHumanOrMain(_ authority: SourceAuthority) throws {
        guard authority == .human || authority == .mainConversation else {
            throw ScheduleBarError.notPermitted
        }
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
        try appendHistory(summary: "Discovered directory: \(path)", automatic: true, action: "discover_directory", targetID: nil, table: "directories", detail: path)
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
            try assignOpenCandidates(from: path, to: id)
            try appendHistory(summary: "Created project \(name)", automatic: false, action: "map_directory", targetID: id, table: "projects")
            return Receipt(outcome: .recorded, taskID: id, projectID: id, summaryLine: "Created project \(name)")
        case .link(let projectID):
            try upsertDirectory(path, decision: "mapped", projectID: projectID)
            try assignOpenCandidates(from: path, to: projectID)
            try appendHistory(summary: "Linked directory to project", automatic: false, action: "map_directory", targetID: projectID, table: "projects")
            return Receipt(outcome: .recorded, taskID: projectID, projectID: projectID, summaryLine: "Linked directory")
        case .ignore:
            try upsertDirectory(path, decision: "ignored", projectID: nil)
            try appendHistory(summary: "Ignored directory: \(path)", automatic: false, action: "ignore_directory", targetID: nil, table: "directories")
            return Receipt(outcome: .recorded, summaryLine: "Ignored directory")
        }
    }

    private func assignOpenCandidates(from path: String, to projectID: UUID) throws {
        let stmt = try database.prepare(
            """
            UPDATE candidates
            SET project_id = ?
            WHERE status = 'open' AND project_id IS NULL AND id IN (
                SELECT task_id FROM source_evidence WHERE working_directory = ?
            );
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, projectID.uuidString)
        database.bind(stmt, 2, path)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
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

    private func isWaitingOnOther(_ task: TaskSummary) -> Bool {
        guard task.status != .completed, task.status != .cancelled else { return false }
        if task.status == .waitingOnOther { return true }
        if let kind = task.ownerKind, kind != .selfPerson { return true }
        return false
    }

    private func setOwner(_ taskID: UUID, name: String, kind: OwnerKind) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        let ownerID = try upsertOwner(name: name, kind: kind)
        let stmt = try database.prepare("UPDATE tasks SET owner_id = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, ownerID.uuidString)
        database.bind(stmt, 2, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        if kind != .selfPerson {
            try updateWorkflowIfNeeded(taskID, to: .waitingOnOther, unless: [.blocked, .pendingAcceptance, .completed, .cancelled], authority: .human)
        } else {
            try updateWorkflowIfNeeded(taskID, to: .notStarted, onlyIf: [.waitingOnOther], authority: .human)
        }
        try appendHistory(summary: "Assigned owner \(name)", automatic: false, action: "set_owner", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Assigned owner \(name)")
    }

    private func confirmAlias(_ alias: String, ownerID: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduleBarError.emptyTitle }
        try requireOwner(ownerID)
        let stmt = try database.prepare(
            """
            INSERT INTO owner_aliases (alias, owner_id) VALUES (?, ?)
            ON CONFLICT(alias) DO UPDATE SET owner_id = excluded.owner_id;
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, name)
        database.bind(stmt, 2, ownerID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try appendHistory(summary: "Confirmed alias \(name)", automatic: false, action: "confirm_alias", targetID: ownerID, table: "owners")
        return Receipt(outcome: .recorded, taskID: ownerID, summaryLine: "Confirmed alias \(name)")
    }

    private func setWorkflowStatus(_ taskID: UUID, _ status: WorkflowStatus, authority: SourceAuthority) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        var resolved = status
        if status == .completed, authority != .human, try !acceptanceMet(taskID) {
            resolved = .pendingAcceptance
        }
        if authority != .human {
            try rejectNonHumanStatusOverwrite(taskID, resolved: resolved, requested: status)
        }
        let recordedAuthority: SourceAuthority?
        if authority == .human {
            recordedAuthority = .human
        } else if try statusAuthority(taskID) == .human {
            recordedAuthority = nil
        } else {
            recordedAuthority = authority
        }
        let previous = try currentStatus(taskID)
        try writeWorkflowStatus(taskID, resolved, authority: recordedAuthority)
        if resolved == .blocked, previous != .blocked {
            try savePreBlockStatus(previous, for: taskID)
        } else if resolved != .blocked, previous == .blocked {
            try clearPreBlockStatus(for: taskID)
        }
        if resolved == .cancelled {
            try updateLifecycle(taskID, "cancelled", trashedAt: nil)
        }
        try appendHistory(
            summary: "Status: \(resolved.rawValue)",
            automatic: authority != .human,
            action: "set_status",
            targetID: taskID,
            table: "tasks",
            detail: previous.rawValue
        )
        if resolved == .completed || resolved == .cancelled {
            try refreshDependents(of: taskID)
        }
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Status: \(resolved.rawValue)")
    }

    private func rejectNonHumanStatusOverwrite(
        _ taskID: UUID,
        resolved: WorkflowStatus,
        requested: WorkflowStatus
    ) throws {
        let current = try currentStatus(taskID)
        if resolved == current { return }
        if try statusAuthority(taskID) == .human {
            let completionReport = requested == .completed && resolved == .pendingAcceptance
            if !completionReport {
                throw ScheduleBarError.notPermitted
            }
            return
        }
        let allowed: Set<WorkflowStatus> = [.inProgress, .blocked, .waitingOnOther, .pendingAcceptance]
        if allowed.contains(resolved) { return }
        if resolved == .completed, try acceptanceMet(taskID) { return }
        throw ScheduleBarError.notPermitted
    }

    private func requireAcceptance(_ taskID: UUID, _ criterion: String) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        let key = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ScheduleBarError.emptyTitle }
        let stmt = try database.prepare(
            "INSERT INTO acceptance_evidence (id, task_id, criterion, satisfied) VALUES (?, ?, ?, 0);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, taskID.uuidString)
        database.bind(stmt, 3, key)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try appendHistory(summary: "Required acceptance \(key)", automatic: false, action: "require_acceptance", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Required acceptance \(key)")
    }

    private func satisfyAcceptance(_ taskID: UUID, _ criterion: String) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare(
            "UPDATE acceptance_evidence SET satisfied = 1 WHERE task_id = ? AND criterion = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, criterion)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else {
            throw ScheduleBarError.notFound
        }
        try appendHistory(summary: "Satisfied acceptance \(criterion)", automatic: true, action: "satisfy_acceptance", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Satisfied acceptance \(criterion)")
    }

    private func setFollowUp(_ taskID: UUID, _ date: Date) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        let instant = DateParser.calendar().startOfDay(for: date)
        try attachDate(
            ParsedDate(
                kind: .followUp,
                phrase: "follow-up",
                anchor: now(),
                instant: instant,
                precision: .allDay,
                status: .resolved
            ),
            to: taskID
        )
        try appendHistory(summary: "Set follow-up", automatic: false, action: "set_follow_up", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Set follow-up")
    }

    private func upsertOwner(name raw: String, kind: OwnerKind) throws -> UUID {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduleBarError.emptyTitle }
        if let aliased = try ownerID(forAlias: name) {
            return aliased
        }
        let existing = try database.prepare("SELECT id FROM owners WHERE name = ?;")
        defer { sqlite3_finalize(existing) }
        database.bind(existing, 1, name)
        if sqlite3_step(existing) == SQLITE_ROW, let id = database.column(existing, 0).flatMap(UUID.init(uuidString:)) {
            return id
        }
        let id = UUID()
        let insert = try database.prepare("INSERT INTO owners (id, name, kind) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(insert) }
        database.bind(insert, 1, id.uuidString)
        database.bind(insert, 2, name)
        database.bind(insert, 3, kind.rawValue)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        return id
    }

    private func ownerID(forAlias alias: String) throws -> UUID? {
        let stmt = try database.prepare("SELECT owner_id FROM owner_aliases WHERE alias = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, alias)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return database.column(stmt, 0).flatMap(UUID.init(uuidString:))
    }

    private func loadOwners() throws -> [OwnerSummary] {
        let stmt = try database.prepare("SELECT id, name, kind FROM owners ORDER BY name ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [OwnerSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let name = database.column(stmt, 1),
                  let kind = database.column(stmt, 2).flatMap(OwnerKind.init(rawValue:))
            else { continue }
            items.append(OwnerSummary(id: id, name: name, kind: kind))
        }
        return items
    }

    private func requireTask(_ id: UUID) throws {
        let stmt = try database.prepare("SELECT id FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScheduleBarError.notFound }
    }

    private func requireOwner(_ id: UUID) throws {
        let stmt = try database.prepare("SELECT id FROM owners WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScheduleBarError.notFound }
    }

    private func writeWorkflowStatus(_ taskID: UUID, _ status: WorkflowStatus, authority: SourceAuthority? = nil) throws {
        let stmt = try database.prepare("UPDATE tasks SET workflow_status = ?, status_authority = COALESCE(?, status_authority) WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, status.rawValue)
        database.bind(stmt, 2, authority?.rawValue)
        database.bind(stmt, 3, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else {
            throw ScheduleBarError.notFound
        }
    }

    private func statusAuthority(_ taskID: UUID) throws -> SourceAuthority? {
        let stmt = try database.prepare("SELECT status_authority FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScheduleBarError.notFound }
        return database.column(stmt, 0).flatMap(SourceAuthority.init(rawValue:))
    }

    private func currentStatus(_ taskID: UUID) throws -> WorkflowStatus {
        let stmt = try database.prepare("SELECT workflow_status FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ScheduleBarError.notFound }
        return database.column(stmt, 0).flatMap(WorkflowStatus.init(rawValue:)) ?? .notStarted
    }

    private func updateWorkflowIfNeeded(
        _ taskID: UUID,
        to status: WorkflowStatus,
        unless excluded: [WorkflowStatus] = [],
        onlyIf allowed: [WorkflowStatus]? = nil,
        authority: SourceAuthority? = nil
    ) throws {
        let current = try currentStatus(taskID)
        if let allowed, !allowed.contains(current) { return }
        if excluded.contains(current) { return }
        if current != status {
            try writeWorkflowStatus(taskID, status, authority: authority)
        }
    }

    private func acceptanceMet(_ taskID: UUID) throws -> Bool {
        let stmt = try database.prepare(
            "SELECT criterion, satisfied FROM acceptance_evidence WHERE task_id = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        var any = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            any = true
            if sqlite3_column_int(stmt, 1) == 0 { return false }
        }
        return any
    }

    private func proposePlan(_ proposal: PlanProposal) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try discoverDirectory(proposal.workingDirectory)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(proposal.items),
              let payload = String(data: data, encoding: .utf8)
        else { throw ScheduleBarError.storeUnavailable }
        let id = UUID()
        let stmt = try database.prepare(
            """
            INSERT OR IGNORE INTO plans (id, idempotency_key, thread_id, turn_id, working_directory, payload, status, message_time)
            VALUES (?, ?, ?, ?, ?, ?, 'open', ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        database.bind(stmt, 2, proposal.idempotencyKey)
        database.bind(stmt, 3, proposal.threadID)
        database.bind(stmt, 4, proposal.turnID)
        database.bind(stmt, 5, proposal.workingDirectory)
        database.bind(stmt, 6, payload)
        database.bind(stmt, 7, iso(proposal.messageTime))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        if database.changes == 0 {
            return Receipt(outcome: .duplicate, summaryLine: "Already recorded")
        }
        try appendHistory(summary: "Proposed plan", automatic: true, action: "propose_plan", targetID: id, table: "plans")
        return Receipt(outcome: .candidate, taskID: id, summaryLine: "Saved as candidate")
    }

    private func acceptPlan(_ planID: UUID, _ itemIDs: [UUID]) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try database.exec("BEGIN IMMEDIATE;")
        do {
            let receipt = try acceptPlanInTransaction(planID, itemIDs)
            try database.exec("COMMIT;")
            return receipt
        } catch {
            try? database.exec("ROLLBACK;")
            throw error
        }
    }

    private func acceptPlanInTransaction(_ planID: UUID, _ itemIDs: [UUID]) throws -> Receipt {
        let stmt = try database.prepare(
            "SELECT payload, thread_id, turn_id, working_directory, message_time FROM plans WHERE id = ? AND status = 'open';"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, planID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let payload = database.column(stmt, 0),
              let data = payload.data(using: .utf8),
              let items = try? JSONDecoder().decode([PlanItem].self, from: data)
        else { throw ScheduleBarError.notFound }
        let threadID = database.column(stmt, 1) ?? ""
        let turnID = database.column(stmt, 2) ?? ""
        let workingDirectory = database.column(stmt, 3) ?? ""
        let messageTime = database.column(stmt, 4).flatMap { ISO8601DateFormatter().date(from: $0) } ?? now()
        let accepted = Set(itemIDs)
        let chosen = items.filter { accepted.contains($0.id) }
        guard !chosen.isEmpty else { throw ScheduleBarError.notFound }
        for item in chosen {
            if let parentID = item.parentID,
               !accepted.contains(parentID),
               try !taskExists(parentID) {
                throw ScheduleBarError.notPermitted
            }
        }
        let projectID = try projectID(forDirectory: workingDirectory) ?? inboxProjectID()
        var created = Set<UUID>()
        var remaining = chosen
        while !remaining.isEmpty {
            let ready = remaining.filter { item in
                guard let parent = item.parentID else { return true }
                return created.contains(parent) || (try? taskExists(parent)) == true || !accepted.contains(parent)
            }
            guard !ready.isEmpty else { break }
            for item in ready {
                if try taskExists(item.id) {
                    created.insert(item.id)
                    remaining.removeAll { $0.id == item.id }
                    continue
                }
                let parent: UUID?
                if let parentID = item.parentID,
                   created.contains(parentID) || (try? taskExists(parentID)) == true {
                    parent = parentID
                } else {
                    parent = nil
                }
                _ = try insertTask(
                    title: item.title,
                    notes: nil,
                    localPath: nil,
                    origin: "plan",
                    projectID: projectID,
                    id: item.id,
                    kind: item.kind,
                    parentID: parent,
                    necessary: item.necessary
                )
                if let phrase = item.datePhrase,
                   let parsed = DateParser.parse(phrase: phrase, kind: item.dateKind, at: messageTime),
                   !parsed.isVague {
                    try attachDate(parsed, to: item.id)
                }
                try insertSourceLink(
                    taskID: item.id,
                    evidence: SourceEvidence(
                        threadID: threadID,
                        turnID: turnID,
                        triggerPhrase: "accepted plan",
                        excerpt: item.title,
                        workingDirectory: workingDirectory,
                        messageTime: messageTime
                    )
                )
                created.insert(item.id)
                remaining.removeAll { $0.id == item.id }
            }
        }
        let pendingItems = items.filter { !accepted.contains($0.id) }
        if pendingItems.isEmpty {
            try execChange("UPDATE plans SET status = 'accepted' WHERE id = ? AND status = 'open';", planID.uuidString)
        } else {
            let encoder = JSONEncoder()
            guard let pendingData = try? encoder.encode(pendingItems),
                  let pendingPayload = String(data: pendingData, encoding: .utf8)
            else { throw ScheduleBarError.storeUnavailable }
            let update = try database.prepare("UPDATE plans SET payload = ? WHERE id = ? AND status = 'open';")
            defer { sqlite3_finalize(update) }
            database.bind(update, 1, pendingPayload)
            database.bind(update, 2, planID.uuidString)
            guard sqlite3_step(update) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        }
        try appendHistory(summary: "Accepted plan items", automatic: false, action: "accept_plan", targetID: planID, table: "plans")
        return Receipt(outcome: .recorded, taskID: planID, summaryLine: "Accepted plan items")
    }

    private func rejectPlan(_ planID: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare("UPDATE plans SET status = 'rejected' WHERE id = ? AND status = 'open';")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, planID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else { throw ScheduleBarError.notFound }
        try appendHistory(summary: "Rejected plan", automatic: false, action: "reject_plan", targetID: planID, table: "plans")
        return Receipt(outcome: .ignored, taskID: planID, summaryLine: "Rejected plan")
    }

    private func linkSource(_ taskID: UUID, _ evidence: SourceEvidence) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        try insertSourceLink(taskID: taskID, evidence: evidence)
        try appendHistory(summary: "Linked source", automatic: false, action: "link_source", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Linked source")
    }

    private func insertSourceLink(taskID: UUID, evidence: SourceEvidence) throws {
        let stmt = try database.prepare(
            """
            INSERT INTO source_links (id, task_id, thread_id, turn_id, trigger_phrase, excerpt, working_directory, message_time)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, taskID.uuidString)
        database.bind(stmt, 3, evidence.threadID)
        database.bind(stmt, 4, evidence.turnID)
        database.bind(stmt, 5, Retention.sanitize(evidence.triggerPhrase))
        database.bind(stmt, 6, Retention.sanitize(evidence.excerpt))
        database.bind(stmt, 7, evidence.workingDirectory)
        database.bind(stmt, 8, evidence.messageTime.map(iso))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func loadSourceLinks(for taskID: UUID) throws -> [SourceEvidence] {
        let stmt = try database.prepare(
            """
            SELECT thread_id, turn_id, trigger_phrase, excerpt, working_directory, message_time
            FROM source_links WHERE task_id = ? ORDER BY rowid ASC;
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        let formatter = ISO8601DateFormatter()
        var items: [SourceEvidence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                SourceEvidence(
                    threadID: database.column(stmt, 0) ?? "",
                    turnID: database.column(stmt, 1) ?? "",
                    triggerPhrase: database.column(stmt, 2) ?? "",
                    excerpt: database.column(stmt, 3) ?? "",
                    workingDirectory: database.column(stmt, 4) ?? "",
                    messageTime: database.column(stmt, 5).flatMap(formatter.date(from:))
                )
            )
        }
        if !items.isEmpty { return items }
        let legacy = try database.prepare(
            "SELECT thread_id, turn_id, trigger_phrase, excerpt, working_directory, message_time FROM source_evidence WHERE task_id = ?;"
        )
        defer { sqlite3_finalize(legacy) }
        database.bind(legacy, 1, taskID.uuidString)
        guard sqlite3_step(legacy) == SQLITE_ROW else { return [] }
        return [
            SourceEvidence(
                threadID: database.column(legacy, 0) ?? "",
                turnID: database.column(legacy, 1) ?? "",
                triggerPhrase: database.column(legacy, 2) ?? "",
                excerpt: database.column(legacy, 3) ?? "",
                workingDirectory: database.column(legacy, 4) ?? "",
                messageTime: database.column(legacy, 5).flatMap(formatter.date(from:))
            ),
        ]
    }

    private func loadPlans() throws -> [PlanDraft] {
        let stmt = try database.prepare("SELECT id, payload FROM plans WHERE status = 'open' ORDER BY rowid ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [PlanDraft] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let payload = database.column(stmt, 1),
                  let data = payload.data(using: .utf8),
                  let planItems = try? decoder.decode([PlanItem].self, from: data)
            else { continue }
            items.append(PlanDraft(id: id, items: planItems))
        }
        return items
    }

    private func withProgress(_ tasks: [TaskSummary]) -> [TaskSummary] {
        tasks.map { task in
            var copy = task
            copy.progressSummary = requiredProgress(parent: task.id, in: tasks)
            return copy
        }
    }

    private func requiredProgress(parent: UUID, in tasks: [TaskSummary]) -> String? {
        requiredProgress(in: tasks.filter { $0.parentID == parent })
    }

    private func requiredProgress(in tasks: [TaskSummary]) -> String? {
        let required = tasks.filter { $0.necessary && $0.parentID != nil }
        guard !required.isEmpty else { return nil }
        let done = required.filter { $0.status == .completed }.count
        return "\(done) of \(required.count) required subtasks completed"
    }

    private func loadProjects(progressFrom tasks: [TaskSummary]) throws -> [ProjectSummary] {
        try loadProjects().map { project in
            var copy = project
            copy.progressSummary = requiredProgress(in: tasks.filter { $0.projectID == project.id })
            return copy
        }
    }

    private func taskExists(_ id: UUID) throws -> Bool {
        let stmt = try database.prepare("SELECT id FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, id.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func setBlockedBy(_ taskID: UUID, _ blockerID: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        guard taskID != blockerID else { throw ScheduleBarError.notPermitted }
        try requireTask(taskID)
        try requireTask(blockerID)
        if try reaches(from: blockerID, to: taskID) {
            throw ScheduleBarError.notPermitted
        }
        let stmt = try database.prepare(
            "INSERT OR IGNORE INTO task_blockers (task_id, blocker_id) VALUES (?, ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, blockerID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try syncBlockedStatus(taskID)
        try appendHistory(summary: "Blocked by \(blockerID.uuidString)", automatic: false, action: "set_blocked_by", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Blocked by dependency")
    }

    /// True when `target` is reachable from `start` by following existing
    /// blocked-by edges; adding `start` as a blocker of `target` would then
    /// create a cycle in which both tasks stay blocked forever.
    private func reaches(from start: UUID, to target: UUID) throws -> Bool {
        var stack = [start]
        var seen = Set<UUID>()
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            if current == target { return true }
            stack.append(contentsOf: try loadBlockerIDs(for: current))
        }
        return false
    }

    private func removeBlockedBy(_ taskID: UUID, _ blockerID: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare("DELETE FROM task_blockers WHERE task_id = ? AND blocker_id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        database.bind(stmt, 2, blockerID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try syncBlockedStatus(taskID)
        try appendHistory(summary: "Removed blocker", automatic: false, action: "remove_blocked_by", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Removed blocker")
    }

    private func setPriority(_ taskID: UUID, _ priority: BusinessPriority) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        try requireTask(taskID)
        let stmt = try database.prepare("UPDATE tasks SET priority = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, priority.rawValue)
        database.bind(stmt, 2, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else { throw ScheduleBarError.notFound }
        try appendHistory(summary: "Priority: \(priority.rawValue)", automatic: false, action: "set_priority", targetID: taskID, table: "tasks")
        return Receipt(outcome: .recorded, taskID: taskID, summaryLine: "Priority: \(priority.rawValue)")
    }

    private func loadBlockerIDs(for taskID: UUID) throws -> [UUID] {
        let stmt = try database.prepare(
            "SELECT blocker_id FROM task_blockers WHERE task_id = ? ORDER BY rowid ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = database.column(stmt, 0), let id = UUID(uuidString: text) {
                ids.append(id)
            }
        }
        return ids
    }

    private func hasUnsatisfiedBlockers(_ blockerIDs: [UUID]) throws -> Bool {
        for id in blockerIDs {
            if try blockerIsUnsatisfied(id) { return true }
        }
        return false
    }

    private func blockerIsUnsatisfied(_ blockerID: UUID) throws -> Bool {
        let stmt = try database.prepare("SELECT workflow_status, lifecycle FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, blockerID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let status = database.column(stmt, 0).flatMap(WorkflowStatus.init(rawValue:)) ?? .notStarted
        let lifecycle = database.column(stmt, 1) ?? "active"
        if status == .completed || status == .cancelled { return false }
        if lifecycle == "cancelled" || lifecycle == "undone" { return false }
        return true
    }

    private func syncBlockedStatus(_ taskID: UUID) throws {
        let unsatisfied = try hasUnsatisfiedBlockers(try loadBlockerIDs(for: taskID))
        let current = try currentStatus(taskID)
        if unsatisfied, current != .completed, current != .cancelled {
            if current != .blocked {
                try savePreBlockStatus(current, for: taskID)
                try writeWorkflowStatus(taskID, .blocked)
            }
        } else if !unsatisfied, current == .blocked {
            let restored = try preBlockStatus(for: taskID) ?? .notStarted
            try clearPreBlockStatus(for: taskID)
            try writeWorkflowStatus(taskID, restored)
        }
    }

    /// The status a task had before dependency edges marked it blocked, so the
    /// workflow can be restored (instead of reset) when the last blocker clears.
    private func savePreBlockStatus(_ status: WorkflowStatus, for taskID: UUID) throws {
        try execChange("UPDATE tasks SET pre_block_status = ? WHERE id = ?;", status.rawValue, taskID.uuidString)
    }

    private func preBlockStatus(for taskID: UUID) throws -> WorkflowStatus? {
        let stmt = try database.prepare("SELECT pre_block_status FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = database.column(stmt, 0)
        else { return nil }
        return WorkflowStatus(rawValue: raw)
    }

    private func clearPreBlockStatus(for taskID: UUID) throws {
        let stmt = try database.prepare("UPDATE tasks SET pre_block_status = NULL WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func refreshDependents(of blockerID: UUID) throws {
        let stmt = try database.prepare("SELECT task_id FROM task_blockers WHERE blocker_id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, blockerID.uuidString)
        var dependents: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = database.column(stmt, 0), let id = UUID(uuidString: text) {
                dependents.append(id)
            }
        }
        for id in dependents {
            try syncBlockedStatus(id)
        }
    }

    private func setRecurrence(_ taskID: UUID, _ rule: RecurrenceRule) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let seriesID = try attachRecurrence(to: taskID, rule: rule)
        try appendHistory(summary: "Set recurrence", automatic: false, action: "set_recurrence", targetID: seriesID, table: "recurrences")
        return Receipt(outcome: .recorded, taskID: seriesID, summaryLine: "Set recurrence")
    }

    private func stopRecurrence(_ seriesID: UUID) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let stmt = try database.prepare("UPDATE recurrences SET stopped = 1 WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, seriesID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE, database.changes > 0 else { throw ScheduleBarError.notFound }
        try appendHistory(summary: "Stopped recurrence", automatic: false, action: "stop_recurrence", targetID: seriesID, table: "recurrences")
        return Receipt(outcome: .recorded, taskID: seriesID, summaryLine: "Stopped recurrence")
    }

    private func attachRecurrence(to taskID: UUID, rule: RecurrenceRule) throws -> UUID {
        try requireTask(taskID)
        let existing = try database.prepare("SELECT series_id FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(existing) }
        database.bind(existing, 1, taskID.uuidString)
        if sqlite3_step(existing) == SQLITE_ROW, let seriesText = database.column(existing, 0), let seriesID = UUID(uuidString: seriesText) {
            _ = try generateRecurrenceInstances()
            return seriesID
        }
        let calendar = DateParser.calendar()
        let dates = try loadDates(for: taskID)
        let anchor = dates.hardDeadline ?? dates.plannedAt ?? dates.targetDate ?? now()
        guard let first = RecurrenceParser.firstOccurrence(rule: rule, from: calendar.startOfDay(for: anchor), calendar: calendar) else {
            throw ScheduleBarError.storeUnavailable
        }
        let meta = try loadTaskMeta(taskID)
        let encoded = RecurrenceParser.encode(rule)
        let seriesID = UUID()
        let stmt = try database.prepare(
            """
            INSERT INTO recurrences (id, origin_task_id, title, rule, weekday, month_day, owner_id, project_id, anchor_at, stopped)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, seriesID.uuidString)
        database.bind(stmt, 2, taskID.uuidString)
        database.bind(stmt, 3, meta.title)
        database.bind(stmt, 4, encoded.kind)
        if let weekday = encoded.weekday {
            sqlite3_bind_int(stmt, 5, Int32(weekday))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let day = encoded.day {
            sqlite3_bind_int(stmt, 6, Int32(day))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        database.bind(stmt, 7, meta.ownerID?.uuidString)
        database.bind(stmt, 8, meta.projectID?.uuidString)
        database.bind(stmt, 9, iso(first))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try registerInstance(seriesID: seriesID, occurrence: RecurrenceParser.occurrenceKey(first, calendar: calendar), taskID: taskID)
        try stampInstance(taskID: taskID, seriesID: seriesID, occurrence: first)
        _ = try generateRecurrenceInstances()
        return seriesID
    }

    private func generateRecurrenceInstances() throws -> Int {
        let calendar = DateParser.calendar()
        let end = calendar.startOfDay(for: now())
        let stmt = try database.prepare(
            """
            SELECT id, origin_task_id, title, rule, weekday, month_day, owner_id, project_id, anchor_at
            FROM recurrences WHERE stopped = 0;
            """
        )
        defer { sqlite3_finalize(stmt) }
        var created = 0
        var series: [(
            id: UUID,
            origin: UUID,
            title: String,
            rule: RecurrenceRule,
            ownerID: UUID?,
            projectID: UUID?,
            anchor: Date
        )] = []
        let formatter = ISO8601DateFormatter()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let originText = database.column(stmt, 1),
                  let origin = UUID(uuidString: originText),
                  let title = database.column(stmt, 2),
                  let kind = database.column(stmt, 3)
            else { continue }
            let weekday = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
            let monthDay = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
            guard let rule = RecurrenceParser.decode(kind: kind, weekday: weekday, day: monthDay) else { continue }
            let ownerID = database.column(stmt, 6).flatMap(UUID.init(uuidString:))
            let projectID = database.column(stmt, 7).flatMap(UUID.init(uuidString:))
            let anchor = database.column(stmt, 8).flatMap(formatter.date(from:)) ?? end
            series.append((id, origin, title, rule, ownerID, projectID, calendar.startOfDay(for: anchor)))
        }
        for item in series {
            var cursor = item.anchor
            var steps = 0
            while cursor <= end, steps < 400 {
                if RecurrenceParser.matches(item.rule, day: cursor, calendar: calendar) {
                    let key = RecurrenceParser.occurrenceKey(cursor, calendar: calendar)
                    if try !instanceExists(seriesID: item.id, occurrence: key) {
                        let owner = try ownerNameKind(item.ownerID)
                        let receipt = try insertTask(
                            title: item.title,
                            notes: nil,
                            localPath: nil,
                            origin: "recurrence",
                            projectID: item.projectID,
                            ownerName: owner?.name,
                            ownerKind: owner?.kind,
                            seriesID: item.id,
                            occurrence: key
                        )
                        if let taskID = receipt.taskID {
                            try registerInstance(seriesID: item.id, occurrence: key, taskID: taskID)
                            try stampInstance(taskID: taskID, seriesID: item.id, occurrence: cursor)
                            try copySourceLinks(from: item.origin, to: taskID)
                            created += 1
                        }
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                steps += 1
            }
        }
        return created
    }

    private func stampInstance(taskID: UUID, seriesID: UUID, occurrence: Date) throws {
        let calendar = DateParser.calendar()
        let key = RecurrenceParser.occurrenceKey(occurrence, calendar: calendar)
        let stmt = try database.prepare("UPDATE tasks SET series_id = ?, occurrence = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, seriesID.uuidString)
        database.bind(stmt, 2, key)
        database.bind(stmt, 3, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
        try attachDate(
            ParsedDate(
                kind: .planned,
                phrase: key,
                anchor: now(),
                instant: occurrence,
                precision: .allDay,
                status: .resolved
            ),
            to: taskID
        )
    }

    private func registerInstance(seriesID: UUID, occurrence: String, taskID: UUID) throws {
        let stmt = try database.prepare(
            "INSERT OR IGNORE INTO recurrence_instances (series_id, occurrence, task_id) VALUES (?, ?, ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, seriesID.uuidString)
        database.bind(stmt, 2, occurrence)
        database.bind(stmt, 3, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func instanceExists(seriesID: UUID, occurrence: String) throws -> Bool {
        let stmt = try database.prepare(
            "SELECT task_id FROM recurrence_instances WHERE series_id = ? AND occurrence = ?;"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, seriesID.uuidString)
        database.bind(stmt, 2, occurrence)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func loadTaskMeta(_ taskID: UUID) throws -> (title: String, ownerID: UUID?, projectID: UUID?) {
        let stmt = try database.prepare("SELECT title, owner_id, project_id FROM tasks WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, taskID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW, let title = database.column(stmt, 0) else {
            throw ScheduleBarError.notFound
        }
        return (
            title,
            database.column(stmt, 1).flatMap(UUID.init(uuidString:)),
            database.column(stmt, 2).flatMap(UUID.init(uuidString:))
        )
    }

    private func ownerNameKind(_ ownerID: UUID?) throws -> (name: String, kind: OwnerKind)? {
        guard let ownerID else { return nil }
        let stmt = try database.prepare("SELECT name, kind FROM owners WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, ownerID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let name = database.column(stmt, 0),
              let kind = database.column(stmt, 1).flatMap(OwnerKind.init(rawValue:))
        else { return nil }
        return (name, kind)
    }

    private func copySourceLinks(from origin: UUID, to taskID: UUID) throws {
        for evidence in try loadSourceLinks(for: origin) {
            try insertSourceLink(taskID: taskID, evidence: evidence)
        }
    }

    private func loadRecurrences() throws -> [RecurrenceSeries] {
        let stmt = try database.prepare(
            "SELECT id, title, rule, weekday, month_day, stopped FROM recurrences ORDER BY rowid ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        var items: [RecurrenceSeries] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let title = database.column(stmt, 1),
                  let kind = database.column(stmt, 2)
            else { continue }
            let weekday = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
            let monthDay = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
            guard let rule = RecurrenceParser.decode(kind: kind, weekday: weekday, day: monthDay) else { continue }
            items.append(
                RecurrenceSeries(
                    id: id,
                    title: title,
                    rule: rule,
                    isStopped: sqlite3_column_int(stmt, 5) == 1
                )
            )
        }
        return items
    }

    private func exportBackup(to url: URL) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let tasks = withProgress(try loadTasks(lifecycle: "active", projectID: nil))
        let archived = try loadTasks(lifecycle: "archived", projectID: nil)
        let trash = try loadTasks(lifecycle: "trashed", projectID: nil)
        let payload: [String: Any] = [
            "version": 1,
            "exportedAt": iso(now()),
            "projects": try loadProjects().map { ["id": $0.id.uuidString, "name": $0.name] },
            "owners": try loadOwners().map { ["id": $0.id.uuidString, "name": $0.name, "kind": $0.kind.rawValue] },
            "tasks": jsonTasks(tasks),
            "milestones": jsonTasks(tasks.filter { $0.kind == .milestone }),
            "archived": jsonTasks(archived),
            "trash": jsonTasks(trash),
            "reminders": try loadAllReminders(),
            "dependencies": try loadAllDependencies(),
            "recurrences": try loadRecurrences().map {
                [
                    "id": $0.id.uuidString,
                    "title": $0.title,
                    "rule": jsonRule($0.rule),
                    "stopped": $0.isStopped,
                ] as [String: Any]
            },
            "history": try loadHistory().map {
                [
                    "id": $0.id.uuidString,
                    "summary": $0.summary,
                    "automatic": $0.isAutomatic,
                    "createdAt": iso($0.createdAt),
                ] as [String: Any]
            },
            "sources": try loadAllSources(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try appendHistory(summary: "Exported backup", automatic: false, action: "export_backup", targetID: nil, table: "backup")
        return Receipt(outcome: .recorded, summaryLine: "Exported backup")
    }

    private func jsonTasks(_ tasks: [TaskSummary]) -> [[String: Any]] {
        tasks.map { task in
            var row: [String: Any] = [
                "id": task.id.uuidString,
                "title": task.title,
                "kind": task.kind.rawValue,
                "status": task.status.rawValue,
                "priority": task.priority.rawValue,
                "necessary": task.necessary,
            ]
            if let notes = task.notes { row["notes"] = notes }
            if let owner = task.ownerName { row["owner"] = owner }
            if let projectID = task.projectID { row["projectID"] = projectID.uuidString }
            if let parentID = task.parentID { row["parentID"] = parentID.uuidString }
            if let deadline = task.hardDeadline { row["hardDeadline"] = iso(deadline) }
            if let planned = task.plannedAt { row["plannedAt"] = iso(planned) }
            if let target = task.targetDate { row["targetDate"] = iso(target) }
            if let followUp = task.followUpAt { row["followUpAt"] = iso(followUp) }
            if let phrase = task.datePhrase { row["datePhrase"] = phrase }
            if let seriesID = task.seriesID { row["seriesID"] = seriesID.uuidString }
            if let occurrence = task.occurrenceDate { row["occurrence"] = iso(occurrence) }
            if !task.tags.isEmpty { row["tags"] = task.tags }
            if !task.blockedByIDs.isEmpty { row["blockedBy"] = task.blockedByIDs.map(\.uuidString) }
            return row
        }
    }

    private func jsonRule(_ rule: RecurrenceRule) -> String {
        switch rule {
        case .daily: return "daily"
        case .weekly(let weekday): return "weekly:\(weekday)"
        case .monthly(let day): return "monthly:\(day)"
        }
    }

    private func loadAllReminders() throws -> [[String: Any]] {
        let stmt = try database.prepare("SELECT task_id, fire_at FROM reminders ORDER BY fire_at ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let taskID = database.column(stmt, 0), let fireAt = database.column(stmt, 1) else { continue }
            items.append(["taskID": taskID, "fireAt": fireAt])
        }
        return items
    }

    private func loadAllDependencies() throws -> [[String: Any]] {
        let stmt = try database.prepare("SELECT task_id, blocker_id FROM task_blockers ORDER BY rowid ASC;")
        defer { sqlite3_finalize(stmt) }
        var items: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let taskID = database.column(stmt, 0), let blockerID = database.column(stmt, 1) else { continue }
            items.append(["taskID": taskID, "blockedBy": blockerID])
        }
        return items
    }

    private func loadAllSources() throws -> [[String: Any]] {
        let stmt = try database.prepare(
            """
            SELECT task_id, thread_id, turn_id, trigger_phrase, excerpt, working_directory, message_time
            FROM source_links ORDER BY rowid ASC;
            """
        )
        defer { sqlite3_finalize(stmt) }
        var items: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append([
                "taskID": database.column(stmt, 0) ?? "",
                "threadID": database.column(stmt, 1) ?? "",
                "turnID": database.column(stmt, 2) ?? "",
                "triggerPhrase": database.column(stmt, 3) ?? "",
                "excerpt": database.column(stmt, 4) ?? "",
                "workingDirectory": database.column(stmt, 5) ?? "",
                "messageTime": database.column(stmt, 6) ?? "",
            ])
        }
        return items
    }

    private func setModelAPIKey(_ key: String) throws -> Receipt {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScheduleBarError.emptyTitle }
        secretStore.saveAPIKey(trimmed)
        database.lock.lock()
        defer { database.lock.unlock() }
        try appendHistory(summary: "Configured model key", automatic: false, action: "set_model_key", targetID: nil, table: "settings")
        return Receipt(outcome: .recorded, summaryLine: "Configured model key")
    }

    private func clearModelAPIKey() -> Receipt {
        secretStore.deleteAPIKey()
        return Receipt(outcome: .recorded, summaryLine: "Cleared model key")
    }

    private func enqueueModelJob(_ event: CaptureEvent) throws {
        let turnText = Retention.sanitize(
            String("\(event.title)\n\(event.excerpt)".prefix(500))
        )
        guard !turnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stmt = try database.prepare(
            "INSERT INTO model_jobs (id, turn_text, thread_id, turn_id, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?);"
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, turnText)
        database.bind(stmt, 3, event.threadID)
        database.bind(stmt, 4, event.turnID)
        database.bind(stmt, 5, iso(now()))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func loadPendingModelJobs() throws -> [(id: String, request: MissedCandidateRequest)] {
        let stmt = try database.prepare(
            "SELECT id, turn_text, thread_id, turn_id FROM model_jobs WHERE status = 'pending' ORDER BY rowid ASC;"
        )
        defer { sqlite3_finalize(stmt) }
        var jobs: [(String, MissedCandidateRequest)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = database.column(stmt, 0), let text = database.column(stmt, 1) else { continue }
            jobs.append(
                (
                    id,
                    MissedCandidateRequest(
                        turnText: text,
                        threadID: database.column(stmt, 2) ?? "",
                        turnID: database.column(stmt, 3) ?? ""
                    )
                )
            )
        }
        return jobs
    }

    private func markModelJob(_ id: String, status: String) throws {
        let stmt = try database.prepare("UPDATE model_jobs SET status = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, status)
        database.bind(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func insertDiagnostic(code: String, message: String, component: String = "") throws {
        let stmt = try database.prepare(
            """
            INSERT INTO diagnostics (id, created_at, code, message, component, retryable)
            VALUES (?, ?, ?, ?, ?, 1);
            """
        )
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, UUID().uuidString)
        database.bind(stmt, 2, iso(now()))
        database.bind(stmt, 3, code)
        database.bind(stmt, 4, Retention.sanitize(message))
        database.bind(stmt, 5, component)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ScheduleBarError.storeUnavailable }
    }

    private func loadDiagnostics() throws -> [DiagnosticEntry] {
        let stmt = try database.prepare(
            "SELECT id, code, message, created_at, component, retryable FROM diagnostics ORDER BY rowid DESC;"
        )
        defer { sqlite3_finalize(stmt) }
        let formatter = ISO8601DateFormatter()
        var items: [DiagnosticEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = database.column(stmt, 0),
                  let id = UUID(uuidString: idText),
                  let code = database.column(stmt, 1)
            else { continue }
            items.append(
                DiagnosticEntry(
                    id: id,
                    code: code,
                    message: database.column(stmt, 2) ?? "",
                    component: database.column(stmt, 4) ?? "",
                    retryable: sqlite3_column_int(stmt, 5) == 1,
                    createdAt: database.column(stmt, 3).flatMap(formatter.date(from:)) ?? now()
                )
            )
        }
        return items
    }

    private func taskTitleExists(_ title: String) throws -> Bool {
        let stmt = try database.prepare("SELECT id FROM tasks WHERE title = ? AND lifecycle = 'active' LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, title)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func candidateTitleExists(_ title: String) throws -> Bool {
        let stmt = try database.prepare("SELECT id FROM candidates WHERE title = ? AND status = 'open' LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, title)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func captureEvent(from turn: SessionTurn) -> CaptureEvent? {
        let key = "session:\(turn.sessionID):\(turn.turnID)"
        if let explicit = ChatWorkHandoff.event(
            userText: turn.userText,
            idempotencyKey: key,
            workingDirectory: turn.workingDirectory,
            threadID: turn.sessionID,
            turnID: turn.turnID,
            messageTime: turn.messageTime
        ) {
            var event = explicit
            event.authority = turn.authority
            return event
        }
        let line = turn.userText.split(whereSeparator: \.isNewline).first.map(String.init) ?? turn.userText
        let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return CaptureEvent(
            idempotencyKey: key,
            title: String(title.prefix(80)),
            authority: turn.authority,
            threadID: turn.sessionID,
            turnID: turn.turnID,
            messageTime: turn.messageTime,
            workingDirectory: turn.workingDirectory,
            triggerPhrase: String(turn.userText.prefix(200)),
            excerpt: String(turn.userText.prefix(280))
        )
    }

    private func isAfterCursor(_ turn: SessionTurn) -> Bool {
        database.lock.lock()
        defer { database.lock.unlock() }
        guard let cursor = try? loadCursor(sessionID: turn.sessionID) else { return true }
        if turn.messageTime > cursor.time { return true }
        if turn.messageTime < cursor.time { return false }
        return TurnIDOrder.isLess(cursor.turnID, turn.turnID)
    }

    @discardableResult
    private func saveCursor(_ turn: SessionTurn) -> Bool {
        database.lock.lock()
        defer { database.lock.unlock() }
        let sql = """
            INSERT INTO session_cursors (session_id, last_turn_id, last_time)
            VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET last_turn_id = excluded.last_turn_id, last_time = excluded.last_time;
            """
        guard let stmt = try? database.prepare(sql) else { return false }
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, turn.sessionID)
        database.bind(stmt, 2, turn.turnID)
        database.bind(stmt, 3, iso(turn.messageTime))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func loadCursor(sessionID: String) throws -> (turnID: String, time: Date)? {
        let stmt = try database.prepare("SELECT last_turn_id, last_time FROM session_cursors WHERE session_id = ?;")
        defer { sqlite3_finalize(stmt) }
        database.bind(stmt, 1, sessionID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let turnID = database.column(stmt, 0),
              let time = database.column(stmt, 1).flatMap({ ISO8601DateFormatter().date(from: $0) })
        else { return nil }
        return (turnID, time)
    }

    private func recordDiagnostic(code: String, message: String) {
        database.lock.lock()
        defer { database.lock.unlock() }
        try? insertDiagnostic(code: code, message: message, component: "reconcile")
    }

    private func retryFailures() -> Receipt {
        resetFailedModelJobs()
        _ = processInbox()
        _ = reconcileSessions()
        return Receipt(outcome: .recorded, summaryLine: "Retried failed operations")
    }

    private func setLoginAtStartup(_ enabled: Bool) -> Receipt {
        loginItems.setEnabled(enabled)
        return Receipt(outcome: .recorded, summaryLine: enabled ? "Login item enabled" : "Login item disabled")
    }

    private func exportDiagnostics(to url: URL) throws -> Receipt {
        database.lock.lock()
        defer { database.lock.unlock() }
        let payload: [String: Any] = [
            "version": 1,
            "exportedAt": iso(now()),
            "components": try loadHealth().map {
                ["name": $0.name, "ok": $0.ok, "detail": $0.detail] as [String: Any]
            },
            "errors": try loadDiagnostics().map {
                [
                    "code": $0.code,
                    "component": $0.component,
                    "retryable": $0.retryable,
                    "createdAt": iso($0.createdAt),
                    "message": $0.message,
                ] as [String: Any]
            },
            "pendingInbox": pendingInboxCount(),
            "pendingModelJobs": try failedOrPendingModelJobCount(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Receipt(outcome: .recorded, summaryLine: "Exported diagnostics")
    }

    private func loadHealth() throws -> [ComponentStatus] {
        let pending = pendingInboxCount()
        let reconcileError = try loadDiagnostics().contains { $0.code == "session_unreadable" && $0.retryable }
        let deepseek = secretStore.loadAPIKey() == nil ? "not configured (optional)" : "configured"
        return [
            ComponentStatus(name: "plugin", ok: healthEnvironment.pluginPresent, detail: healthEnvironment.pluginPresent ? "installed" : "plugin bundle missing"),
            ComponentStatus(name: "mcp", ok: healthEnvironment.mcpPresent, detail: healthEnvironment.mcpPresent ? "present" : "schedulebar-mcp missing"),
            ComponentStatus(name: "queue", ok: true, detail: "\(pending) pending"),
            ComponentStatus(name: "sqlite", ok: true, detail: "local"),
            ComponentStatus(name: "deepseek", ok: true, detail: deepseek),
            ComponentStatus(
                name: "notifications",
                ok: healthEnvironment.notificationsAuthorized,
                detail: healthEnvironment.notificationsAuthorized ? "authorized" : healthEnvironment.notificationGuidance
            ),
            ComponentStatus(name: "chatwork", ok: true, detail: "explicit only"),
            ComponentStatus(name: "reconcile", ok: !reconcileError, detail: reconcileError ? "retryable read error" : "local sync"),
            ComponentStatus(name: "loginitem", ok: true, detail: loginItems.isEnabled ? "enabled" : "disabled"),
        ]
    }

    private func pendingInboxCount() -> Int {
        let stmt: OpaquePointer?
        do {
            stmt = try database.prepare(
                "SELECT (SELECT COUNT(*) FROM capture_inbox WHERE status = 'pending') + (SELECT COUNT(*) FROM plan_inbox WHERE status = 'pending');"
            )
        } catch {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func failedOrPendingModelJobCount() throws -> Int {
        let stmt = try database.prepare("SELECT COUNT(*) FROM model_jobs WHERE status IN ('pending', 'failed');")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func resetFailedModelJobs() {
        database.lock.lock()
        defer { database.lock.unlock() }
        try? database.exec("UPDATE model_jobs SET status = 'pending' WHERE status = 'failed';")
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

private struct CandidateRecord {
    var id: UUID
    var title: String
    var notes: String?
    var localPath: String?
    var projectID: UUID?
    var date: ParsedDate?
}
