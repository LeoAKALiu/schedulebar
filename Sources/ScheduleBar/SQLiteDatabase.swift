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
            CREATE TABLE IF NOT EXISTS candidates (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
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
        try? exec("ALTER TABLE tasks ADD COLUMN owner_id TEXT;")
        try? exec("ALTER TABLE tasks ADD COLUMN workflow_status TEXT NOT NULL DEFAULT 'notStarted';")
        try? exec("ALTER TABLE tasks ADD COLUMN project_id TEXT;")
        try? exec("ALTER TABLE candidates ADD COLUMN project_id TEXT;")
        try? exec("ALTER TABLE tasks ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active';")
        try? exec("ALTER TABLE tasks ADD COLUMN trashed_at TEXT;")
        try? exec("ALTER TABLE tasks ADD COLUMN origin TEXT NOT NULL DEFAULT 'human';")
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
