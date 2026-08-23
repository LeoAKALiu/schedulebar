import Foundation
import ScheduleBar
import Testing

@Test func humanAndMainConversationCanDeclareBlockedBy() throws {
    let store = try mappedPriorityStore()
    let blocker = try #require(store.apply(.quickAdd(QuickAddInput(title: "Design API"))).taskID)
    let blocked = try #require(store.apply(.quickAdd(QuickAddInput(title: "Implement API"))).taskID)
    _ = try store.apply(.setBlockedBy(blocked, blocker), authority: .human)
    let other = try #require(store.apply(.quickAdd(QuickAddInput(title: "Write clients"))).taskID)
    _ = try store.apply(.setBlockedBy(other, blocker), authority: .mainConversation)
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.setBlockedBy(blocked, other), authority: .subagent)
    }
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == blocked }?.blockedByIDs == [blocker])
    #expect(state.tasks.first { $0.id == other }?.blockedByIDs == [blocker])
}

@Test func unsatisfiedBlockerIsVisibleAndMatchesBlockedStatus() throws {
    let store = try mappedPriorityStore()
    let blocker = try #require(store.apply(.quickAdd(QuickAddInput(title: "Land schema"))).taskID)
    let blocked = try #require(store.apply(.quickAdd(QuickAddInput(title: "Ship feature"))).taskID)
    _ = try store.apply(.setBlockedBy(blocked, blocker))
    let task = try #require(store.observableState().tasks.first { $0.id == blocked })
    #expect(task.status == .blocked)
    #expect(task.hasUnsatisfiedBlockers)
    #expect(task.blockedByIDs == [blocker])
}

@Test func completingOrRemovingBlockerDoesNotMoveDates() throws {
    let store = try mappedPriorityStore()
    let blocker = try #require(
        store.apply(
            .capture(datedCapture(key: "blk", title: "Schema work", phrase: "2026-09-04"))
        ).taskID
    )
    let blocked = try #require(
        store.apply(
            .capture(datedCapture(key: "dep", title: "Feature work", phrase: "2026-09-10"))
        ).taskID
    )
    _ = try store.apply(.setBlockedBy(blocked, blocker))
    #expect(try store.observableState().tasks.first { $0.id == blocked }?.hardDeadline == shanghai(2026, 9, 10, 0))
    _ = try store.apply(.setStatus(blocker, .completed), authority: .human)
    let afterComplete = try #require(store.observableState().tasks.first { $0.id == blocked })
    #expect(afterComplete.status != .blocked)
    #expect(afterComplete.hasUnsatisfiedBlockers == false)
    #expect(afterComplete.hardDeadline == shanghai(2026, 9, 10, 0))
    #expect(try store.observableState().tasks.first { $0.id == blocker }?.hardDeadline == shanghai(2026, 9, 4, 0))

    let extra = try #require(store.apply(.quickAdd(QuickAddInput(title: "Docs"))).taskID)
    _ = try store.apply(.setBlockedBy(blocked, extra))
    #expect(try store.observableState().tasks.first { $0.id == blocked }?.hardDeadline == shanghai(2026, 9, 10, 0))
    _ = try store.apply(.removeBlockedBy(blocked, extra))
    let afterRemove = try #require(store.observableState().tasks.first { $0.id == blocked })
    #expect(afterRemove.hardDeadline == shanghai(2026, 9, 10, 0))
    #expect(afterRemove.hasUnsatisfiedBlockers == false)
}

@Test func captureSetsPriorityOnlyFromExplicitLanguage() throws {
    let store = try mappedPriorityStore()
    let plain = try #require(
        store.apply(.capture(datedCapture(key: "p1", title: "File report", phrase: "2026-09-04"))).taskID
    )
    let high = try #require(
        store.apply(
            .capture(priorityCapture(key: "p2", title: "Pager work", phrase: "high priority"))
        ).taskID
    )
    let critical = try #require(
        store.apply(
            .capture(priorityCapture(key: "p3", title: "Outage", phrase: "this is critical"))
        ).taskID
    )
    let low = try #require(
        store.apply(
            .capture(priorityCapture(key: "p4", title: "Nice to have", phrase: "low priority"))
        ).taskID
    )
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == plain }?.priority == .normal)
    #expect(state.tasks.first { $0.id == high }?.priority == .high)
    #expect(state.tasks.first { $0.id == critical }?.priority == .critical)
    #expect(state.tasks.first { $0.id == low }?.priority == .low)
}

@Test func dateUrgencyDoesNotRewriteBusinessPriority() throws {
    let clock = TestClock(shanghai(2026, 9, 5, 10))
    let store = try mappedPriorityStore(now: { clock.now })
    let id = try #require(
        store.apply(
            .capture(priorityCapture(key: "u1", title: "Overdue but low", phrase: "low priority", date: "2026-09-04"))
        ).taskID
    )
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.priority == .low)
    #expect(task.dateUrgency == .overdue)
    #expect(task.isOverdue)
}

@Test func dependencyAndPriorityChangesAreInHistoryAndSurviveRestart() throws {
    let url = uniquePriorityStoreURL()
    let blockedID: UUID
    let blockerID: UUID
    do {
        let store = try ScheduleBarStore(storeURL: url)
        try TestFixtures.mapDefaultDirectory(store)
        blockerID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Blocker"))).taskID)
        blockedID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Blocked"))).taskID)
        _ = try store.apply(.setBlockedBy(blockedID, blockerID))
        _ = try store.apply(.setPriority(blockedID, .high))
        let history = try store.observableState().history.map(\.summary)
        #expect(history.contains { $0.lowercased().contains("blocked") })
        #expect(history.contains { $0.lowercased().contains("high") })
    }
    let restarted = try ScheduleBarStore(storeURL: url)
    let task = try #require(restarted.observableState().tasks.first { $0.id == blockedID })
    #expect(task.blockedByIDs == [blockerID])
    #expect(task.priority == .high)
    #expect(task.status == .blocked)
}

private func mappedPriorityStore(
    now: @escaping @Sendable () -> Date = { Date() }
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniquePriorityStoreURL(), now: now)
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func datedCapture(key: String, title: String, phrase: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "t",
        turnID: key,
        messageTime: shanghai(2026, 9, 1, 9),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task \(phrase)",
        datePhrase: phrase,
        dateKind: .hardDeadline
    )
}

private func priorityCapture(key: String, title: String, phrase: String, date: String? = nil) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "t",
        turnID: key,
        messageTime: shanghai(2026, 9, 1, 9),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task \(phrase)",
        datePhrase: date,
        dateKind: date == nil ? nil : .hardDeadline
    )
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniquePriorityStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
