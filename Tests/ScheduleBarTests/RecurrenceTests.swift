import Foundation
import ScheduleBar
import Testing

@Test func dailyInstancesHaveStableIdentityAfterRestartAndReplay() throws {
    let clock = TestClock(shanghai(2026, 9, 1, 9))
    let url = uniqueRecurrenceStoreURL()
    let seriesID: UUID
    let firstIDs: [UUID]
    do {
        let store = try ScheduleBarStore(storeURL: url, now: { clock.now })
        try TestFixtures.mapDefaultDirectory(store)
        let origin = try #require(store.apply(.quickAdd(QuickAddInput(title: "Standup"))).taskID)
        _ = try store.apply(.setRecurrence(origin, .daily))
        clock.now = shanghai(2026, 9, 3, 9)
        #expect(store.processRecurrences() == 2)
        #expect(store.processRecurrences() == 0)
        let tasks = try store.observableState().tasks.filter { $0.title == "Standup" }
        #expect(Set(tasks.map(\.occurrenceDate)) == Set([
            shanghai(2026, 9, 1, 0),
            shanghai(2026, 9, 2, 0),
            shanghai(2026, 9, 3, 0),
        ]))
        seriesID = try #require(tasks.first?.seriesID)
        firstIDs = tasks.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
    let restarted = try ScheduleBarStore(storeURL: url, now: { clock.now })
    #expect(restarted.processRecurrences() == 0)
    let again = try restarted.observableState().tasks.filter { $0.title == "Standup" }
    #expect(again.map(\.id).sorted { $0.uuidString < $1.uuidString } == firstIDs)
    #expect(again.allSatisfy { $0.seriesID == seriesID })
}

@Test func weeklyAndMonthlyHonorCalendarBoundaries() throws {
    let clock = TestClock(shanghai(2026, 9, 7, 9))
    let store = try mappedRecurrenceStore(now: { clock.now })
    let weekly = try #require(store.apply(.quickAdd(QuickAddInput(title: "Monday sync"))).taskID)
    let weekday = shanghaiCalendar().component(.weekday, from: shanghai(2026, 9, 7, 0))
    _ = try store.apply(.setRecurrence(weekly, .weekly(weekday: weekday)))
    clock.now = shanghai(2026, 9, 15, 9)
    _ = store.processRecurrences()
    let weeklyDays = try store.observableState().tasks
        .filter { $0.title == "Monday sync" }
        .compactMap(\.occurrenceDate)
    #expect(Set(weeklyDays) == Set([shanghai(2026, 9, 7, 0), shanghai(2026, 9, 14, 0)]))

    clock.now = shanghai(2026, 1, 31, 9)
    let monthly = try #require(store.apply(.quickAdd(QuickAddInput(title: "Month-end close"))).taskID)
    _ = try store.apply(.setRecurrence(monthly, .monthly(day: 31)))
    clock.now = shanghai(2026, 3, 31, 9)
    _ = store.processRecurrences()
    let monthlyDays = try store.observableState().tasks
        .filter { $0.title == "Month-end close" }
        .compactMap(\.occurrenceDate)
    #expect(Set(monthlyDays) == Set([shanghai(2026, 1, 31, 0), shanghai(2026, 3, 31, 0)]))
}

@Test func instancesKeepOwnerProjectDateAndSourceIndependently() throws {
    let clock = TestClock(shanghai(2026, 9, 4, 9))
    let store = try mappedRecurrenceStore(now: { clock.now })
    let origin = try #require(
        store.apply(
            .capture(
                CaptureEvent(
                    idempotencyKey: "rec-src",
                    title: "Ship notes",
                    authority: .mainConversation,
                    threadID: "rec-thread",
                    turnID: "rec-src",
                    messageTime: shanghai(2026, 9, 4, 9),
                    workingDirectory: TestFixtures.cwd,
                    triggerPhrase: "record as task",
                    excerpt: "record as task 2026-09-04",
                    datePhrase: "2026-09-04",
                    dateKind: .hardDeadline
                )
            )
        ).taskID
    )
    _ = try store.apply(.setOwner(origin, "Leo", .person))
    _ = try store.apply(.setRecurrence(origin, .daily))
    clock.now = shanghai(2026, 9, 5, 9)
    #expect(store.processRecurrences() == 1)
    let tasks = try store.observableState().tasks.filter { $0.title == "Ship notes" }
    #expect(tasks.count == 2)
    #expect(tasks.allSatisfy { $0.ownerName == "Leo" })
    #expect(Set(tasks.map(\.projectID)) == Set(tasks.compactMap(\.projectID)))
    #expect(tasks.contains { $0.occurrenceDate == shanghai(2026, 9, 4, 0) })
    #expect(tasks.contains { $0.occurrenceDate == shanghai(2026, 9, 5, 0) })
    for task in tasks {
        #expect(try store.sourceLinks(for: task.id).map(\.threadID) == ["rec-thread"])
    }
}

@Test func completingOneInstanceDoesNotCompleteOthers() throws {
    let clock = TestClock(shanghai(2026, 9, 1, 9))
    let store = try mappedRecurrenceStore(now: { clock.now })
    let origin = try #require(store.apply(.quickAdd(QuickAddInput(title: "Backup"))).taskID)
    _ = try store.apply(.setRecurrence(origin, .daily))
    clock.now = shanghai(2026, 9, 2, 9)
    _ = store.processRecurrences()
    let first = try #require(store.observableState().tasks.first { $0.occurrenceDate == shanghai(2026, 9, 1, 0) })
    _ = try store.apply(.setStatus(first.id, .completed), authority: .human)
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == first.id }?.status == .completed)
    #expect(state.tasks.first { $0.occurrenceDate == shanghai(2026, 9, 2, 0) }?.status == .notStarted)
}

@Test func vagueOrComplexRecurrenceBecomesCandidate() throws {
    let store = try mappedRecurrenceStore()
    let vague = try store.apply(
        .capture(recordPhrase(key: "vaguerec", title: "Check inbox", phrase: "every so often"))
    )
    let complex = try store.apply(
        .capture(recordPhrase(key: "complexrec", title: "Review board", phrase: "every other Tuesday except holidays"))
    )
    #expect(vague.outcome == .candidate)
    #expect(complex.outcome == .candidate)
    #expect(try store.observableState().tasks.isEmpty)
}

@Test func stoppingRecurrenceKeepsInstancesAndHistory() throws {
    let clock = TestClock(shanghai(2026, 9, 1, 9))
    let store = try mappedRecurrenceStore(now: { clock.now })
    let origin = try #require(store.apply(.quickAdd(QuickAddInput(title: "Logs"))).taskID)
    _ = try store.apply(.setRecurrence(origin, .daily))
    clock.now = shanghai(2026, 9, 2, 9)
    _ = store.processRecurrences()
    let seriesID = try #require(store.observableState().tasks.first { $0.id == origin }?.seriesID)
    _ = try store.apply(.stopRecurrence(seriesID))
    clock.now = shanghai(2026, 9, 5, 9)
    #expect(store.processRecurrences() == 0)
    let state = try store.observableState()
    #expect(state.tasks.filter { $0.title == "Logs" }.count == 2)
    #expect(state.recurrences.first { $0.id == seriesID }?.isStopped == true)
    #expect(state.history.contains { $0.summary.lowercased().contains("stop") || $0.summary.lowercased().contains("recurrence") })
}

@Test func explicitDailyCaptureMaterializesToday() throws {
    let clock = TestClock(shanghai(2026, 9, 4, 10))
    let store = try mappedRecurrenceStore(now: { clock.now })
    let receipt = try store.apply(
        .capture(recordPhrase(key: "daily-cap", title: "Daily standup", phrase: "every day"))
    )
    #expect(receipt.outcome == .recorded)
    _ = store.processRecurrences()
    let task = try #require(store.observableState().tasks.first { $0.title == "Daily standup" })
    #expect(task.seriesID != nil)
    #expect(task.occurrenceDate == shanghai(2026, 9, 4, 0))
}

private func mappedRecurrenceStore(
    now: @escaping @Sendable () -> Date = { Date() }
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniqueRecurrenceStoreURL(), now: now)
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func recordPhrase(key: String, title: String, phrase: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "t",
        turnID: key,
        messageTime: shanghai(2026, 9, 4, 9),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task \(phrase)"
    )
}

private func shanghaiCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    shanghaiCalendar().date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniqueRecurrenceStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
