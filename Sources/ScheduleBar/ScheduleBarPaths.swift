import Foundation

public enum ScheduleBarPaths {
    public static func defaultStoreURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "ScheduleBar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "schedulebar.sqlite")
    }

    public static func backupURL(now: Date = Date()) throws -> URL {
        let store = try defaultStoreURL()
        let directory = store.deletingLastPathComponent().appending(path: "backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "schedulebar-\(stamp).json")
    }
}
