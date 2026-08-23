import AppKit
import Foundation
import ScheduleBar

final class AppDirectoryNotifier: DirectoryNotifier, @unchecked Sendable {
    func notifyUnknownDirectory(_ path: String) {
        let notification = NSUserNotification()
        notification.title = "New Codex directory"
        notification.informativeText = path
        notification.actionButtonTitle = "Review"
        NSUserNotificationCenter.default.deliver(notification)
    }
}
