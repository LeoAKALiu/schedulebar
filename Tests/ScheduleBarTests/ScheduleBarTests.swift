import Foundation
import ScheduleBar
import Testing

@Test func quickAddAppearsInSharedMenuAndConsoleState() throws {
    let bar = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let receipt = try bar.apply(
        .quickAdd(QuickAddInput(title: "File weekly report"))
    )
    #expect(receipt.outcome == .recorded)
    #expect(receipt.taskID != nil)

    let state = try bar.observableState()
    #expect(state.tasks.map(\.title) == ["File weekly report"])
    #expect(state.menuTasks.map(\.id) == state.tasks.map(\.id))
    #expect(state.consoleTasks.map(\.id) == state.tasks.map(\.id))
}

@Test func quickAddKeepsNotesAndLocalPath() throws {
    let bar = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try bar.apply(
        .quickAdd(
            QuickAddInput(
                title: "File weekly report",
                notes: "Send on Friday",
                localPath: "/Users/leo/Projects/schedule_plugin/report.md"
            )
        )
    )
    let task = try #require(bar.observableState().tasks.first)
    #expect(task.title == "File weekly report")
    #expect(task.notes == "Send on Friday")
    #expect(task.localPath == "/Users/leo/Projects/schedule_plugin/report.md")
}

@Test func blankTitleDoesNotCreateATask() throws {
    let bar = try ScheduleBarStore(storeURL: uniqueStoreURL())
    #expect(throws: ScheduleBarError.emptyTitle) {
        try bar.apply(.quickAdd(QuickAddInput(title: "   ")))
    }
    #expect(try bar.observableState().tasks.isEmpty)
}

@Test func restartReadsTheSameQuickAddTask() throws {
    let url = uniqueStoreURL()
    let originalID: UUID
    do {
        let bar = try ScheduleBarStore(storeURL: url)
        let receipt = try bar.apply(
            .quickAdd(
                QuickAddInput(
                    title: "File weekly report",
                    notes: "Send on Friday",
                    localPath: "/tmp/report.md"
                )
            )
        )
        originalID = try #require(receipt.taskID)
    }

    let restarted = try ScheduleBarStore(storeURL: url)
    let task = try #require(restarted.observableState().tasks.first)
    #expect(task.id == originalID)
    #expect(task.title == "File weekly report")
    #expect(task.notes == "Send on Friday")
    #expect(task.localPath == "/tmp/report.md")
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
