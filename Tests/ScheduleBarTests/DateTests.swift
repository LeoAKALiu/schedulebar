import Foundation
import ScheduleBar
import Testing

@Test func tomorrowIsAllDayInShanghaiNot2359() throws {
    let clock = TestClock(shanghai(2026, 9, 3, 10))
    let store = try mappedStore(now: { clock.now })
    let id = try #require(
        store.apply(
            .capture(dated(key: "t1", title: "Ship notes", phrase: "tomorrow", at: clock.now))
        ).taskID
    )
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.datePrecision == .allDay)
    #expect(task.datePhrase == "tomorrow")
    #expect(task.hardDeadline == shanghai(2026, 9, 4, 0))
    #expect(task.hardDeadline?.timeIntervalSince1970 != shanghai(2026, 9, 4, 23, 59).timeIntervalSince1970)
}

@Test func vagueDateBecomesCandidate() throws {
    let store = try mappedStore()
    let receipt = try store.apply(
        .capture(dated(key: "v1", title: "Do it sometime", phrase: "soon", at: shanghai(2026, 9, 3, 10)))
    )
    #expect(receipt.outcome == .candidate)
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.map(\.title) == ["Do it sometime"])
}

@Test func allDayHardDeadlineGetsDefaultReminders() throws {
    let store = try mappedStore()
    let id = try #require(
        store.apply(
            .capture(dated(key: "r1", title: "Due Friday work", phrase: "2026-09-04", at: shanghai(2026, 9, 1, 9)))
        ).taskID
    )
    let fires = try store.reminders(for: id).map(\.fireAt)
    #expect(fires.contains(shanghai(2026, 9, 3, 18)))
    #expect(fires.contains(shanghai(2026, 9, 4, 9)))
    #expect(fires.contains(shanghai(2026, 9, 5, 9)))
}

@Test func overdueIsDerivedWithoutMovingDeadline() throws {
    let clock = TestClock(shanghai(2026, 9, 5, 10))
    let store = try mappedStore(now: { clock.now })
    let id = try #require(
        store.apply(
            .capture(dated(key: "o1", title: "Overdue item", phrase: "2026-09-04", at: shanghai(2026, 9, 1, 9)))
        ).taskID
    )
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.isOverdue)
    #expect(task.hardDeadline == shanghai(2026, 9, 4, 0))
    #expect(try store.observableState().overdue.map(\.id) == [id])
}

@Test func menuGroupsTodayAndNextSevenDays() throws {
    let clock = TestClock(shanghai(2026, 9, 4, 15))
    let store = try mappedStore(now: { clock.now })
    _ = try store.apply(.capture(dated(key: "today", title: "Today task", phrase: "today", at: clock.now)))
    _ = try store.apply(.capture(dated(key: "week", title: "Next week-ish", phrase: "2026-09-08", at: clock.now)))
    let state = try store.observableState()
    #expect(state.today.map(\.title) == ["Today task"])
    #expect(state.nextSevenDays.map(\.title) == ["Next week-ish"])
    #expect(state.todayCount == 1)
}

@Test func captureDoesNotSendDueNotifications() throws {
    let reminders = RecordingReminderNotifier()
    let store = try mappedStore(notifier: reminders)
    _ = try store.apply(
        .capture(dated(key: "n1", title: "Quiet capture", phrase: "2026-09-04", at: shanghai(2026, 9, 1, 9)))
    )
    #expect(reminders.titles.isEmpty)
}

@Test func dueReminderFiresOnceWithClockAndRestart() throws {
    let clock = TestClock(shanghai(2026, 9, 3, 17))
    let url = uniqueStoreURL()
    let reminders = RecordingReminderNotifier()
    do {
        let store = try ScheduleBarStore(storeURL: url, now: { clock.now }, reminderNotifier: reminders)
        try TestFixtures.mapDefaultDirectory(store)
        _ = try store.apply(
            .capture(dated(key: "fire", title: "Remind me", phrase: "2026-09-04", at: shanghai(2026, 9, 1, 9)))
        )
        #expect(store.processDueReminders() == 0)
        clock.now = shanghai(2026, 9, 3, 18, 1)
        #expect(store.processDueReminders() == 1)
        #expect(reminders.titles == ["Remind me"])
        #expect(store.processDueReminders() == 0)
    }
    let reminders2 = RecordingReminderNotifier()
    let restarted = try ScheduleBarStore(storeURL: url, now: { clock.now }, reminderNotifier: reminders2)
    #expect(restarted.processDueReminders() == 0)
    #expect(try restarted.observableState().tasks.first?.hardDeadline == shanghai(2026, 9, 4, 0))
}

@Test func userCanOverrideReminders() throws {
    let store = try mappedStore()
    let id = try #require(
        store.apply(
            .capture(dated(key: "ov", title: "Custom reminder", phrase: "2026-09-04", at: shanghai(2026, 9, 1, 9)))
        ).taskID
    )
    let custom = shanghai(2026, 9, 4, 16)
    _ = try store.apply(.setReminders(id, [custom]))
    #expect(try store.reminders(for: id).map(\.fireAt) == [custom])
}

private func mappedStore(
    now: @escaping @Sendable () -> Date = { Date() },
    notifier: ReminderNotifier = SilentReminderNotifier()
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL(), now: now, reminderNotifier: notifier)
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func dated(key: String, title: String, phrase: String, at: Date) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "t",
        turnID: key,
        messageTime: at,
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task \(phrase)",
        datePhrase: phrase,
        dateKind: .hardDeadline
    )
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class RecordingReminderNotifier: ReminderNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var titles: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    func notifyReminder(title: String, fireAt: Date) {
        lock.lock(); defer { lock.unlock() }
        values.append(title)
    }
}
