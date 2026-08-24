import Foundation
import ScheduleBar
import Testing

@Test func explicitRecordAppearsInMenuAndConsole() throws {
    let url = uniqueStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let receipt = try store.apply(.capture(explicitRecord(key: "turn-1", title: "File weekly report")))
    #expect(receipt.outcome == .recorded)
    #expect(receipt.summaryLine.contains("File weekly report"))
    let state = try store.observableState()
    #expect(state.menuTasks.map(\.title) == ["File weekly report"])
    #expect(state.consoleTasks.map(\.title) == ["File weekly report"])
}

@Test func inboxWriteSurvivesWithoutTheAppThenProcessesOnce() throws {
    let url = uniqueStoreURL()
    let event = explicitRecord(key: "turn-2", title: "Prepare slides")
    let first = CaptureQueue(storeURL: url).enqueue(event)
    #expect(first.outcome == .recorded)

    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    #expect(try store.observableState().tasks.isEmpty)

    let processed = store.processInbox()
    #expect(processed.map(\.outcome) == [.recorded])
    #expect(try store.observableState().tasks.map(\.title) == ["Prepare slides"])

    let again = store.processInbox()
    #expect(again.isEmpty)
    #expect(try store.observableState().tasks.count == 1)
}

@Test func identicalIdempotencyKeyDoesNotCreateASecondTask() throws {
    let url = uniqueStoreURL()
    let event = explicitRecord(key: "same-key", title: "File weekly report")
    let queue = CaptureQueue(storeURL: url)
    let first = queue.enqueue(event)
    let second = queue.enqueue(event)
    #expect(first.outcome == .recorded)
    #expect(second.outcome == .duplicate)
    #expect(second.summaryLine.isEmpty == false)

    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    _ = store.processInbox()
    #expect(try store.observableState().tasks.count == 1)
}

@Test func similarTitlesWithDifferentKeysStaySeparate() throws {
    let url = uniqueStoreURL()
    let queue = CaptureQueue(storeURL: url)
    _ = queue.enqueue(explicitRecord(key: "a", title: "File weekly report"))
    _ = queue.enqueue(explicitRecord(key: "b", title: "File weekly report"))
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    _ = store.processInbox()
    #expect(try store.observableState().tasks.count == 2)
}

@Test func unwritableQueueReturnsNotRecordedWithoutThrowing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarNotAFile-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let receipt = CaptureQueue(storeURL: directory).enqueue(
        explicitRecord(key: "fail", title: "Should not persist")
    )
    #expect(receipt.outcome == .notRecorded)
    #expect(receipt.summaryLine == "未记录")
}

@Test func concurrentSameKeyYieldsOneInboxRow() throws {
    let url = uniqueStoreURL()
    let event = explicitRecord(key: "race", title: "Race task")
    let group = DispatchGroup()
    let box = ReceiptBox()
    for _ in 0..<2 {
        group.enter()
        DispatchQueue.global().async {
            box.append(CaptureQueue(storeURL: url).enqueue(event))
            group.leave()
        }
    }
    group.wait()
    let receipts = box.receipts
    #expect(receipts.filter { $0.outcome == .recorded }.count == 1)
    #expect(receipts.filter { $0.outcome == .duplicate }.count == 1)
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    _ = store.processInbox()
    #expect(try store.observableState().tasks.count == 1)
}

@Test func pluginManifestShipsHooksAndMCP() throws {
    let pluginRoot = repoRoot().appending(path: "Plugins/schedulebar")
    let manifest = try json(pluginRoot.appending(path: ".codex-plugin/plugin.json"))
    #expect(manifest["hooks"] as? String == "./hooks/hooks.json")
    #expect(manifest["mcpServers"] as? String == "./.mcp.json")
    let hooks = try json(pluginRoot.appending(path: "hooks/hooks.json"))
    #expect(hooks["hooks"] is [String: Any])
    let mcp = try json(pluginRoot.appending(path: ".mcp.json"))
    let servers = try #require(mcp["mcpServers"] as? [String: Any])
    #expect(servers["schedulebar"] != nil)
}

private func explicitRecord(key: String, title: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread-1",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: "/Users/leo/Projects/schedule_plugin",
        triggerPhrase: "record as task",
        excerpt: "Please record this as a task."
    )
}

private final class ReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Receipt] = []
    var receipts: [Receipt] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    func append(_ receipt: Receipt) {
        lock.lock(); defer { lock.unlock() }
        values.append(receipt)
    }
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func json(_ url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}
