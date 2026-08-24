import Foundation
import ScheduleBar
import Testing

@Test func captureCandidateAndQuickAddAppendHistory() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.quickAdd(QuickAddInput(title: "Manual task")))
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.capture(record("k1", "Captured task")))
    _ = try store.apply(.capture(tentative("k2", "Maybe later")))
    _ = try store.reviewCandidate(
        try #require(store.observableState().candidates.first?.id),
        decision: .confirm
    )
    let history = try store.observableState().history.map(\.summary)
    #expect(history.contains { $0.contains("Manual task") })
    #expect(history.contains { $0.contains("Captured task") })
    #expect(history.contains { $0.contains("Maybe later") || $0.lowercased().contains("candidate") })
    #expect(history.contains { $0.lowercased().contains("confirm") })
}

@Test func undoAutomaticCaptureRestoresActiveTasks() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.quickAdd(QuickAddInput(title: "Keep me")))
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.capture(record("auto-1", "Automatic task")))
    #expect(try store.observableState().tasks.map(\.title).sorted() == ["Automatic task", "Keep me"])
    let receipt = try store.apply(.undoLastAutomaticChange)
    #expect(receipt.outcome == .recorded)
    #expect(try store.observableState().tasks.map(\.title) == ["Keep me"])
    #expect(try store.observableState().history.isEmpty == false)
}

@Test func cancelAndArchiveLeaveHistoryAndHideFromActiveList() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let cancelID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Cancel me"))).taskID)
    let archiveID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Archive me"))).taskID)
    _ = try store.apply(.cancel(cancelID))
    _ = try store.apply(.archive(archiveID))
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.archived.map(\.title) == ["Archive me"])
    #expect(state.history.count >= 4)
}

@Test func trashCanBeRestoredWithinThirtyDays() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Trashed"))).taskID)
    _ = try store.apply(.trash(id))
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().trash.map(\.title) == ["Trashed"])
    _ = try store.apply(.restoreFromTrash(id))
    #expect(try store.observableState().tasks.map(\.title) == ["Trashed"])
    #expect(try store.observableState().trash.isEmpty)
}

@Test func expiredTrashCannotBeRestored() throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL(), now: { clock.now })
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Old trash"))).taskID)
    _ = try store.apply(.trash(id))
    clock.now = clock.now.addingTimeInterval(31 * 24 * 60 * 60)
    #expect(throws: ScheduleBarError.trashExpired) {
        try store.apply(.restoreFromTrash(id))
    }
}

@Test func permanentDeleteRequiresHuman() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Gone"))).taskID)
    _ = try store.apply(.trash(id))
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.permanentlyDelete(id), authority: .mainConversation)
    }
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.permanentlyDelete(id), authority: .subagent)
    }
    _ = try store.apply(.permanentlyDelete(id), authority: .human)
    #expect(try store.observableState().trash.isEmpty)
    #expect(try store.observableState().tasks.isEmpty)
}

@Test func sourceEvidenceIsAvailableOnDemandNotOnMenuTasks() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let id = try #require(store.apply(.capture(record("ev-1", "Evidence task"))).taskID)
    let menu = try store.observableState().menuTasks.first
    #expect(menu?.title == "Evidence task")
    #expect(try store.sourceEvidence(for: id)?.triggerPhrase == "record as task")
    #expect(try store.sourceEvidence(for: id)?.excerpt == "Please record this as a task.")
}

@Test func lifecycleSurvivesRestart() throws {
    let url = uniqueStoreURL()
    let archivedID: UUID
    do {
        let store = try ScheduleBarStore(storeURL: url)
        archivedID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Parked"))).taskID)
        _ = try store.apply(.archive(archivedID))
        try TestFixtures.mapDefaultDirectory(store)
        _ = try store.apply(.capture(record("r1", "Later undone")))
        _ = try store.apply(.undoLastAutomaticChange)
    }
    let restarted = try ScheduleBarStore(storeURL: url)
    let state = try restarted.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.archived.map(\.id) == [archivedID])
    #expect(state.history.isEmpty == false)
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func record(_ key: String, _ title: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: "/Users/leo/Projects/schedule_plugin",
        triggerPhrase: "record as task",
        excerpt: "Please record this as a task."
    )
}

private func tentative(_ key: String, _ title: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: "/Users/leo/Projects/schedule_plugin",
        triggerPhrase: "we might",
        excerpt: "we might"
    )
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
