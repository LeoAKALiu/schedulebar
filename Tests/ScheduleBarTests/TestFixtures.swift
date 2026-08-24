import Foundation
import ScheduleBar

enum TestFixtures {
    static let cwd = "/Users/leo/Projects/schedule_plugin"

    static func mapDefaultDirectory(_ store: ScheduleBarStore) throws {
        _ = try store.apply(.resolveDirectory(cwd, .create(name: "Schedule Plugin")))
    }
}
