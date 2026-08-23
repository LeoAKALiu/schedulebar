import Foundation
import ScheduleBar
import UserNotifications

final class AppReminderNotifier: ReminderNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var requestedAuthorization = false
    private let center = UNUserNotificationCenter.current()

    func notifyReminder(title: String, fireAt: Date) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Due reminder"
        content.body = title
        content.subtitle = fireAt.formatted(date: .abbreviated, time: .shortened)
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: "schedulebar.reminder.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    /// Reminders are opt-in: ask once through the real permission flow instead
    /// of silently delivering into a suppressed notification center.
    private func requestAuthorizationIfNeeded() {
        lock.lock()
        let shouldRequest = !requestedAuthorization
        requestedAuthorization = true
        lock.unlock()
        guard shouldRequest, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
