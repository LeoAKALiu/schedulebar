import Foundation

public protocol SecretStore: Sendable {
    func saveAPIKey(_ key: String)
    func loadAPIKey() -> String?
    func deleteAPIKey()
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init() {}

    public func saveAPIKey(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        self.key = key
    }

    public func loadAPIKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    public func deleteAPIKey() {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }
}
