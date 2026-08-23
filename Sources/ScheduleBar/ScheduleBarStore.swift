/// Production seam for T01: `InputEvent` in, `ObservableState` out.
/// Menu and console both read `observableState()`; tests restart by opening
/// a new store on the same SQLite URL.
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ScheduleBarStore {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(storeURL: URL) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = storeURL.path.withCString { path in
            sqlite3_open_v2(path, &db, flags, nil)
        }
        guard status == SQLITE_OK, db != nil else {
            throw ScheduleBarError.storeUnavailable
        }
        try exec(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                notes TEXT,
                local_path TEXT,
                created_at TEXT NOT NULL
            );
            """
        )
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func apply(_ event: InputEvent) throws -> Receipt {
        switch event {
        case .quickAdd(let input):
            return try quickAdd(input)
        }
    }

    public func observableState() throws -> ObservableState {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, title, notes, local_path FROM tasks ORDER BY created_at DESC, title ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ScheduleBarError.storeUnavailable
        }
        defer { sqlite3_finalize(stmt) }

        var tasks: [TaskSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0).map(String.init(cString:)),
                  let id = UUID(uuidString: idText),
                  let title = sqlite3_column_text(stmt, 1).map(String.init(cString:))
            else {
                continue
            }
            tasks.append(
                TaskSummary(
                    id: id,
                    title: title,
                    notes: sqlite3_column_text(stmt, 2).map(String.init(cString:)),
                    localPath: sqlite3_column_text(stmt, 3).map(String.init(cString:))
                )
            )
        }
        return ObservableState(tasks: tasks)
    }

    private func quickAdd(_ input: QuickAddInput) throws -> Receipt {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScheduleBarError.emptyTitle }
        let notes = trimmed(input.notes)
        let localPath = trimmed(input.localPath)
        let id = UUID()
        let createdAt = ISO8601DateFormatter().string(from: Date())

        lock.lock()
        defer { lock.unlock() }
        let sql = "INSERT INTO tasks (id, title, notes, local_path, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ScheduleBarError.storeUnavailable
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        bind(stmt, 2, title)
        bind(stmt, 3, notes)
        bind(stmt, 4, localPath)
        bind(stmt, 5, createdAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ScheduleBarError.storeUnavailable
        }
        return Receipt(outcome: .recorded, taskID: id)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw ScheduleBarError.storeUnavailable
        }
    }
}
