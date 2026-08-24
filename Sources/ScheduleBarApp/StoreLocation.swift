import Foundation
import ScheduleBar

enum StoreLocation {
    static func fileURL() throws -> URL {
        try ScheduleBarPaths.defaultStoreURL()
    }
}
