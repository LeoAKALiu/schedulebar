import Foundation
import UserNotifications

public struct ComponentStatus: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var ok: Bool
    public var detail: String

    public init(name: String, ok: Bool, detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }
}

public protocol HealthEnvironment: Sendable {
    var pluginPresent: Bool { get }
    var mcpPresent: Bool { get }
    var notificationsAuthorized: Bool { get }
    var notificationGuidance: String { get }
}

public struct StaticHealthEnvironment: HealthEnvironment {
    public var pluginPresent: Bool
    public var mcpPresent: Bool
    public var notificationsAuthorized: Bool
    public var notificationGuidance: String

    public init(
        pluginPresent: Bool = true,
        mcpPresent: Bool = true,
        notificationsAuthorized: Bool = true,
        notificationGuidance: String = "Enable notifications in System Settings → ScheduleBar."
    ) {
        self.pluginPresent = pluginPresent
        self.mcpPresent = mcpPresent
        self.notificationsAuthorized = notificationsAuthorized
        self.notificationGuidance = notificationGuidance
    }
}

public final class DefaultHealthEnvironment: HealthEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedNotificationsAuthorized: Bool?

    public init() {
        refreshNotificationAuthorization()
    }

    public var pluginPresent: Bool {
        pluginRoot()?.appending(path: ".mcp.json").path.fileExists ?? false
    }

    public var mcpPresent: Bool {
        pluginRoot()?.appending(path: "bin/schedulebar-mcp").path.fileExists ?? false
    }

    /// Real UNUserNotificationCenter state; until the async read lands the
    /// answer is "not authorized" so a missing permission is never reported
    /// as healthy (issue #16).
    public var notificationsAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedNotificationsAuthorized == true
    }

    public var notificationGuidance: String {
        "Enable notifications in System Settings → ScheduleBar, then retry."
    }

    private func refreshNotificationAuthorization() {
        // UNUserNotificationCenter throws an ObjC exception in processes whose
        // main bundle is not an app (test runners, CLI helpers); only a real
        // app bundle has a meaningful authorization state.
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.storeNotificationAuthorization(settings.authorizationStatus == .authorized)
        }
    }

    private func storeNotificationAuthorization(_ authorized: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cachedNotificationsAuthorized = authorized
    }

    private func pluginRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["SCHEDULEBAR_PLUGIN_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        // GUI apps launched from Finder run with cwd "/", so anchor the
        // fallback on the app bundle instead of the working directory.
        let bundle = Bundle.main.bundleURL
        let candidates = [
            bundle.appending(path: "Contents/Plugins/schedulebar"),
            bundle.appending(path: "Plugins/schedulebar"),
            bundle.deletingLastPathComponent().appending(path: "Plugins/schedulebar"),
        ]
        return candidates.first { $0.path.fileExists } ?? candidates[0]
    }
}

public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

public final class MemoryLoginItemController: LoginItemControlling, @unchecked Sendable {
    public var isEnabled = false

    public init() {}

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}

private extension String {
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: self)
    }
}
