import Foundation
import ScheduleBar

enum StoreLocation {
    static func fileURL() throws -> URL {
        guard let url = ChatWorkHandoff.configuredStoreURL() else {
            throw ScheduleBarError.storeUnavailable
        }
        return url
    }

    static func sessionDirectoryURL() throws -> URL {
        if ProcessInfo.processInfo.environment["SCHEDULEBAR_STORE"] != nil {
            let directory = try fileURL().deletingLastPathComponent()
                .appending(path: "sessions", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        return try ScheduleBarPaths.sessionDirectory()
    }
}
