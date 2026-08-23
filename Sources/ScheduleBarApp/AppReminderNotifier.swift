import AppKit
import Foundation
import ScheduleBar

final class AppReminderNotifier: ReminderNotifier, @unchecked Sendable {
    func notifyReminder(title: String, fireAt: Date) {
        let notification = NSUserNotification()
        notification.title = "Due reminder"
        notification.informativeText = title
        notification.subtitle = fireAt.formatted(date: .abbreviated, time: .shortened)
        NSUserNotificationCenter.default.deliver(notification)
    }
}