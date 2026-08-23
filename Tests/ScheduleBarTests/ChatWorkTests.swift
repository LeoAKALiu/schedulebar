import Foundation
import ScheduleBar
import Testing

@Test func explicitChatWorkRecordEntersTheSameQueueAndReadModel() throws {
    let url = uniqueChatWorkStoreURL()
    let receipt = ChatWorkHandoff.submit(
        "record as task File weekly report",
        storeURL: url,
        idempotencyKey: "chat-1",
        workingDirectory: TestFixtures.cwd
    )
    #expect(receipt.outcome == .recorded)
    #expect(receipt.summaryLine.contains("File weekly report") || receipt.outcome == .recorded)

    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    _ = store.processInbox()
    let state = try store.observableState()
    #expect(state.menuTasks.map(\.title) == ["File weekly report"])
    #expect(state.consoleTasks.map(\.title) == ["File weekly report"])
}

@Test func ordinaryChatWorkTextIsNotMonitored() throws {
    let url = uniqueChatWorkStoreURL()
    let receipt = ChatWorkHandoff.submit(
        "How does the parser work? Just thinking out loud.",
        storeURL: url,
        idempotencyKey: "chat-idle",
        workingDirectory: TestFixtures.cwd
    )
    #expect(receipt.outcome == .notRecorded)
    #expect(receipt.summaryLine == "未记录")
    let store = try ScheduleBarStore(storeURL: url)
    _ = store.processInbox()
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.isEmpty)
}

@Test func explicitChatWorkDuplicateAndFailureAreVisible() throws {
    let url = uniqueChatWorkStoreURL()
    let first = ChatWorkHandoff.submit(
        "记录为任务 准备幻灯片",
        storeURL: url,
        idempotencyKey: "same-chat",
        workingDirectory: TestFixtures.cwd
    )
    let second = ChatWorkHandoff.submit(
        "记录为任务 准备幻灯片",
        storeURL: url,
        idempotencyKey: "same-chat",
        workingDirectory: TestFixtures.cwd
    )
    #expect(first.outcome == .recorded)
    #expect(second.outcome == .duplicate)
    #expect(second.summaryLine.isEmpty == false)

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarNotAFile-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let failed = ChatWorkHandoff.submit(
        "record as task Should not persist",
        storeURL: directory,
        idempotencyKey: "fail-chat",
        workingDirectory: TestFixtures.cwd
    )
    #expect(failed.outcome == .notRecorded)
    #expect(failed.summaryLine == "未记录")
}

@Test func chatWorkPolicyIsExplicitOnly() {
    #expect(CapturePolicy.chatWorkAutomaticCapture == false)
    #expect(CapturePolicy.chatWorkHelpText.lowercased().contains("automatic") || CapturePolicy.chatWorkHelpText.contains("自动"))
    #expect(CapturePolicy.chatWorkHelpText.lowercased().contains("record") || CapturePolicy.chatWorkHelpText.contains("记录"))
}

private func uniqueChatWorkStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
