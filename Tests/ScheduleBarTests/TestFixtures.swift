import Foundation
import ScheduleBar

enum TestFixtures {
    static let cwd = "/Users/leo/Projects/schedule_plugin"

    static func uniqueStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "schedulebar.sqlite")
    }

    static func mapDefaultDirectory(_ store: ScheduleBarStore) throws {
        _ = try store.apply(.resolveDirectory(cwd, .create(name: "Schedule Plugin")))
    }

    static func shanghai(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
