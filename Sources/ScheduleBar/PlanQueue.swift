import Darwin
import Foundation
import SQLite3

public final class PlanQueue: @unchecked Sendable {
    private let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public func enqueue(_ proposal: PlanProposal) -> Receipt {
        let parent = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fd = open(storeURL.path + ".lock", O_CREAT | O_RDWR, 0o644)
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
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(proposal)
            guard let payload = String(data: data, encoding: .utf8) else {
                return Receipt(outcome: .notRecorded)
            }
            let stmt = try database.prepare(
                "INSERT OR IGNORE INTO plan_inbox (idempotency_key, payload, status) VALUES (?, ?, 'pending');"
            )
            defer { sqlite3_finalize(stmt) }
            database.bind(stmt, 1, proposal.idempotencyKey)
            database.bind(stmt, 2, payload)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                return Receipt(outcome: .notRecorded)
            }
            if database.changes == 0 { return Receipt(outcome: .duplicate) }
            return Receipt(outcome: .candidate, summaryLine: "Saved plan draft")
        } catch {
            return Receipt(outcome: .notRecorded)
        }
    }
}
