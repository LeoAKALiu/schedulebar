import Foundation
import ScheduleBar
import UserNotifications

enum DirectoryReviewAction {
    case review
    case createProject
    case linkProject
    case ignore
}

/// Delivers the T05 review notification with the three executable actions
/// (create project, link existing project, ignore). The action button opens
/// the console's directory review; "Ignore" resolves inline.
final class AppDirectoryNotifier: NSObject, DirectoryNotifier, @unchecked Sendable {
    static let openConsoleNotification = Notification.Name("ScheduleBarOpenConsole")
    private static let categoryID = "schedulebar.directory-review"
    private static let createActionID = "schedulebar.directory.create"
    private static let linkActionID = "schedulebar.directory.link"
    private static let ignoreActionID = "schedulebar.directory.ignore"

    private let lock = NSLock()
    private var handler: ((String, DirectoryReviewAction) -> Void)?
    private var requestedAuthorization = false
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [
                    UNNotificationAction(identifier: Self.createActionID, title: "Create project…", options: [.foreground]),
                    UNNotificationAction(identifier: Self.linkActionID, title: "Link to project…", options: [.foreground]),
                    UNNotificationAction(identifier: Self.ignoreActionID, title: "Ignore", options: []),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func setReviewHandler(_ handler: @escaping (String, DirectoryReviewAction) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func notifyUnknownDirectory(_ path: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "New Codex directory"
        content.body = path
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["path": path]
        let request = UNNotificationRequest(
            identifier: "schedulebar.directory.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func requestAuthorizationIfNeeded() {
        lock.lock()
        let shouldRequest = !requestedAuthorization
        requestedAuthorization = true
        lock.unlock()
        guard shouldRequest, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func dispatch(path: String, action: DirectoryReviewAction) {
        lock.lock()
        let callback = handler
        lock.unlock()
        guard let callback else {
            NotificationCenter.default.post(name: Self.openConsoleNotification, object: nil)
            return
        }
        callback(path, action)
    }
}

extension AppDirectoryNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        switch response.actionIdentifier {
        case Self.createActionID: dispatch(path: path, action: .createProject)
        case Self.linkActionID: dispatch(path: path, action: .linkProject)
        case Self.ignoreActionID: dispatch(path: path, action: .ignore)
        case UNNotificationDefaultActionIdentifier: dispatch(path: path, action: .review)
        default: return
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
