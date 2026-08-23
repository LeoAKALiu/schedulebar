import Foundation

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

public struct DefaultHealthEnvironment: HealthEnvironment {
    public init() {}

    public var pluginPresent: Bool {
        pluginRoot()?.appending(path: ".mcp.json").path.fileExists ?? false
    }

    public var mcpPresent: Bool {
        pluginRoot()?.appending(path: "bin/schedulebar-mcp").path.fileExists ?? false
    }

    public var notificationsAuthorized: Bool { true }

    public var notificationGuidance: String {
        "Enable notifications in System Settings → ScheduleBar."
    }

    private func pluginRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["SCHEDULEBAR_PLUGIN_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Plugins/schedulebar")
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
