import Darwin
import Foundation
import SQLite3

public final class CaptureQueue: @unchecked Sendable {
    private let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public func enqueue(_ event: CaptureEvent) -> Receipt {
        let parent = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockPath = storeURL.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return Receipt(outcome: .notRecorded) }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        guard let database = try? SQLiteDatabase(url: storeURL) else {
            return Receipt(outcome: .notRecorded)
        }
        database.lock.lock()
        defer { database.lock.unlock() }
        do {
            try database.exec("BEGIN IMMEDIATE;")
            let payload = try encode(event)
            let inserted: Bool
            do {
                let stmt = try database.prepare(
                    "INSERT OR IGNORE INTO capture_inbox (idempotency_key, payload, status) VALUES (?, ?, 'pending');"
                )
                defer { sqlite3_finalize(stmt) }
                database.bind(stmt, 1, event.idempotencyKey)
                database.bind(stmt, 2, payload)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    try? database.exec("ROLLBACK;")
                    return Receipt(outcome: .notRecorded)
                }
                inserted = database.changes > 0
            }
            try database.exec("COMMIT;")
            if inserted {
                return Receipt(outcome: .recorded, summaryLine: "Recorded: \(event.title)")
            }
            return Receipt(outcome: .duplicate)
        } catch {
            try? database.exec("ROLLBACK;")
            return Receipt(outcome: .notRecorded)
        }
    }

    private func encode(_ event: CaptureEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScheduleBarError.storeUnavailable
        }
        return text
    }
}
