import Darwin
import Foundation
import SQLite3

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private(set) var db: OpaquePointer?
    let lock = NSLock()

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = url.path.withCString { path in
            sqlite3_open_v2(path, &db, flags, nil)
        }
        guard status == SQLITE_OK, db != nil else {
            if let db { sqlite3_close(db) }
            self.db = nil
            throw ScheduleBarError.storeUnavailable
        }
        try exec("PRAGMA journal_mode=DELETE;")
        try exec("PRAGMA busy_timeout=5000;")
        try migrate()
        chmod(url.path, 0o600)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func migrate() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
                local_path TEXT,
                created_at TEXT NOT NULL,
                lifecycle TEXT NOT NULL DEFAULT 'active',
                trashed_at TEXT,
                origin TEXT NOT NULL DEFAULT 'human'
            );
            CREATE TABLE IF NOT EXISTS capture_inbox (
                idempotency_key TEXT PRIMARY KEY NOT NULL,
                payload TEXT NOT NULL,
                status TEXT NOT NULL,
                task_id TEXT
            );
            CREATE TABLE IF NOT EXISTS plan_inbox (
                idempotency_key TEXT PRIMARY KEY NOT NULL,
                payload TEXT NOT NULL,
                status TEXT NOT NULL,
                plan_id TEXT
            );
            CREATE TABLE IF NOT EXISTS candidates (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
                local_path TEXT,
                inbox_key TEXT,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                project_id TEXT
            );
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY NOT NULL,
                created_at TEXT NOT NULL,
                automatic INTEGER NOT NULL,
                summary TEXT NOT NULL,
                action TEXT NOT NULL,
                target_id TEXT,
                target_table TEXT,
                undone INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS source_evidence (
                task_id TEXT PRIMARY KEY NOT NULL,
                thread_id TEXT,
                turn_id TEXT,
                trigger_phrase TEXT,
                excerpt TEXT,
                working_directory TEXT
            );
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS directories (
                path TEXT PRIMARY KEY NOT NULL,
                decision TEXT NOT NULL,
                project_id TEXT,
                notified INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS tags (
                name TEXT PRIMARY KEY NOT NULL
            );
            CREATE TABLE IF NOT EXISTS task_tags (
                task_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (task_id, tag)
            );
            CREATE TABLE IF NOT EXISTS task_dates (
                task_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                phrase TEXT,
                anchor_at TEXT,
                instant TEXT,
                precision TEXT NOT NULL,
                status TEXT NOT NULL,
                PRIMARY KEY (task_id, kind)
            );
            CREATE TABLE IF NOT EXISTS reminders (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                fire_at TEXT NOT NULL,
                fired INTEGER NOT NULL DEFAULT 0,
                fired_at TEXT
            );
            CREATE TABLE IF NOT EXISTS owners (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS owner_aliases (
                alias TEXT PRIMARY KEY NOT NULL,
                owner_id TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS acceptance_evidence (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                criterion TEXT NOT NULL,
                satisfied INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try addColumnIfMissing(table: "tasks", column: "owner_id", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "workflow_status", definition: "TEXT NOT NULL DEFAULT 'notStarted'")
        try addColumnIfMissing(table: "tasks", column: "kind", definition: "TEXT NOT NULL DEFAULT 'task'")
        try addColumnIfMissing(table: "tasks", column: "parent_id", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "necessary", definition: "INTEGER NOT NULL DEFAULT 1")
        try addColumnIfMissing(table: "tasks", column: "priority", definition: "TEXT NOT NULL DEFAULT 'normal'")
        try addColumnIfMissing(table: "tasks", column: "series_id", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "occurrence", definition: "TEXT")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS recurrences (
                id TEXT PRIMARY KEY NOT NULL,
                origin_task_id TEXT NOT NULL,
                title TEXT NOT NULL,
                rule TEXT NOT NULL,
                weekday INTEGER,
                month_day INTEGER,
                owner_id TEXT,
                project_id TEXT,
                anchor_at TEXT NOT NULL,
                stopped INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS recurrence_instances (
                series_id TEXT NOT NULL,
                occurrence TEXT NOT NULL,
                task_id TEXT NOT NULL,
                PRIMARY KEY (series_id, occurrence)
            );
            CREATE TABLE IF NOT EXISTS model_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                turn_text TEXT NOT NULL,
                thread_id TEXT,
                turn_id TEXT,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS diagnostics (
                id TEXT PRIMARY KEY NOT NULL,
                created_at TEXT NOT NULL,
                code TEXT NOT NULL,
                message TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS session_cursors (
                session_id TEXT PRIMARY KEY NOT NULL,
                last_turn_id TEXT NOT NULL,
                last_time TEXT NOT NULL
            );
            """
        )
        try addColumnIfMissing(table: "diagnostics", column: "component", definition: "TEXT")
        try addColumnIfMissing(table: "diagnostics", column: "retryable", definition: "INTEGER NOT NULL DEFAULT 1")
        try exec(
            """
            CREATE TABLE IF NOT EXISTS task_blockers (
                task_id TEXT NOT NULL,
                blocker_id TEXT NOT NULL,
                PRIMARY KEY (task_id, blocker_id)
            );
            """
        )
        try exec(
            """
            CREATE TABLE IF NOT EXISTS plans (
                id TEXT PRIMARY KEY NOT NULL,
                idempotency_key TEXT UNIQUE NOT NULL,
                thread_id TEXT,
                turn_id TEXT,
                working_directory TEXT,
                payload TEXT NOT NULL,
                status TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS source_links (
                id TEXT PRIMARY KEY NOT NULL,
                task_id TEXT NOT NULL,
                thread_id TEXT,
                turn_id TEXT,
                trigger_phrase TEXT,
                excerpt TEXT,
                working_directory TEXT
            );
            """
        )
        try addColumnIfMissing(table: "tasks", column: "project_id", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "project_id", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "local_path", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "lifecycle", definition: "TEXT NOT NULL DEFAULT 'active'")
        try addColumnIfMissing(table: "tasks", column: "trashed_at", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "origin", definition: "TEXT NOT NULL DEFAULT 'human'")
        try addColumnIfMissing(table: "tasks", column: "status_authority", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_phrase", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_kind", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_anchor", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_precision", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_status", definition: "TEXT")
        try addColumnIfMissing(table: "candidates", column: "date_instant", definition: "TEXT")
        try addColumnIfMissing(table: "plans", column: "message_time", definition: "TEXT")
        try addColumnIfMissing(table: "tasks", column: "pre_block_status", definition: "TEXT")
        try addColumnIfMissing(table: "history", column: "detail", definition: "TEXT")
        try addColumnIfMissing(table: "source_links", column: "message_time", definition: "TEXT")
        try addColumnIfMissing(table: "source_evidence", column: "message_time", definition: "TEXT")
        try exec(
            """
            UPDATE candidates
            SET project_id = (
                SELECT directories.project_id
                FROM source_evidence
                JOIN directories ON directories.path = source_evidence.working_directory
                WHERE source_evidence.task_id = candidates.id
                  AND directories.decision = 'mapped'
                  AND directories.project_id IS NOT NULL
                LIMIT 1
            )
            WHERE status = 'open'
              AND project_id IS NULL
              AND EXISTS (
                  SELECT 1
                  FROM source_evidence
                  JOIN directories ON directories.path = source_evidence.working_directory
                  WHERE source_evidence.task_id = candidates.id
                    AND directories.decision = 'mapped'
                    AND directories.project_id IS NOT NULL
              );
            """
        )
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if self.column(stmt, 1) == column { return }
        }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw ScheduleBarError.storeUnavailable
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ScheduleBarError.storeUnavailable
        }
        return stmt
    }

    func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map(String.init(cString:))
    }

    var changes: Int32 {
        sqlite3_changes(db)
    }
}
