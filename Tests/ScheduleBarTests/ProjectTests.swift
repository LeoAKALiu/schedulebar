import Foundation
import ScheduleBar
import Testing

@Test func firstUnknownDirectoryNotifiesOnce() throws {
    let notifier = RecordingNotifier()
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL(), notifier: notifier)
    _ = try store.apply(.capture(record(key: "a", title: "First look")))
    #expect(notifier.paths == ["/Users/leo/Projects/schedule_plugin"])
    #expect(try store.observableState().pendingDirectories.map(\.normalizedPath) == ["/Users/leo/Projects/schedule_plugin"])
    _ = try store.apply(.capture(record(key: "b", title: "Second look")))
    #expect(notifier.paths.count == 1)
}

@Test func resumeDoesNotRenotifyMappedOrPendingDirectory() throws {
    let url = uniqueStoreURL()
    let notifier = RecordingNotifier()
    do {
        let store = try ScheduleBarStore(storeURL: url, notifier: notifier)
        _ = try store.apply(.capture(record(key: "r1", title: "See dir")))
        #expect(notifier.paths.count == 1)
    }
    let notifier2 = RecordingNotifier()
    let restarted = try ScheduleBarStore(storeURL: url, notifier: notifier2)
    _ = try restarted.apply(.capture(record(key: "r2", title: "See dir again")))
    #expect(notifier2.paths.isEmpty)
}

@Test func createLinkAndIgnoreDirectoryDecisionsPersist() throws {
    let url = uniqueStoreURL()
    let projectID: UUID
    do {
        let store = try ScheduleBarStore(storeURL: url)
        _ = try store.apply(.capture(record(key: "d1", title: "Unfiled first")))
        #expect(try store.observableState().candidates.count == 1)
        #expect(try store.observableState().tasks.isEmpty)
        let created = try store.apply(
            .resolveDirectory("/Users/leo/Projects/schedule_plugin", .create(name: "Schedule Plugin"))
        )
        projectID = try #require(created.taskID)
        _ = try store.apply(.capture(record(key: "d2", title: "Mapped task")))
        #expect(try store.observableState().tasks.map(\.title) == ["Mapped task"])
        #expect(try store.observableState().tasks.first?.projectID == projectID)
    }
    let restarted = try ScheduleBarStore(storeURL: url)
    #expect(try restarted.observableState().projects.map(\.name) == ["Schedule Plugin"])
    _ = try restarted.apply(.resolveDirectory("/tmp/other-project", .ignore))
    _ = try restarted.apply(
        .capture(
            CaptureEvent(
                idempotencyKey: "ignored-dir",
                title: "From ignored dir",
                authority: .mainConversation,
                threadID: "t",
                turnID: "t",
                messageTime: Date(timeIntervalSince1970: 1_700_000_000),
                workingDirectory: "/tmp/other-project",
                triggerPhrase: "record as task",
                excerpt: "record as task"
            )
        )
    )
    #expect(try restarted.observableState().tasks.map(\.title) == ["Mapped task"])
    #expect(try restarted.observableState().candidates.map(\.title).contains("From ignored dir"))
}

@Test func linkingUsesExistingProjectAndTagsCrossProjects() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.resolveDirectory("/Users/leo/Projects/schedule_plugin", .create(name: "Alpha")))
    _ = try store.apply(.capture(record(key: "alpha-task", title: "Alpha task")))
    _ = try store.apply(.resolveDirectory("/Users/leo/Projects/other", .create(name: "Beta")))
    let betaProject = try #require(store.observableState().projects.first { $0.name == "Beta" }?.id)
    _ = try store.apply(.resolveDirectory("/Users/leo/Work/linked", .link(projectID: betaProject)))
    _ = try store.apply(
        .capture(
            CaptureEvent(
                idempotencyKey: "link-1",
                title: "Linked work",
                authority: .mainConversation,
                threadID: "t",
                turnID: "t",
                messageTime: Date(timeIntervalSince1970: 1_700_000_000),
                workingDirectory: "/Users/leo/Work/linked",
                triggerPhrase: "record as task",
                excerpt: "record as task"
            )
        )
    )
    let linked = try #require(store.observableState().tasks.first { $0.title == "Linked work" })
    let alphaTask = try #require(store.observableState().tasks.first { $0.title == "Alpha task" })
    #expect(linked.projectID == betaProject)
    _ = try store.apply(.addTag(linked.id, "shared"))
    _ = try store.apply(.addTag(alphaTask.id, "shared"))
    #expect(try store.observableState().tasks.first { $0.title == "Linked work" }?.tags == ["shared"])
    #expect(try store.observableState().tasks.first { $0.title == "Alpha task" }?.tags == ["shared"])
}

@Test func consoleFiltersTasksByProject() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.resolveDirectory("/Users/leo/Projects/schedule_plugin", .create(name: "Alpha")))
    _ = try store.apply(.capture(record(key: "p1", title: "Alpha task")))
    let alpha = try #require(store.observableState().projects.first { $0.name == "Alpha" }?.id)
    let filtered = try store.observableState(projectID: alpha)
    #expect(filtered.tasks.map(\.title) == ["Alpha task"])
}

@Test func directoryDecisionIsInUndoableHistory() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.resolveDirectory("/Users/leo/Projects/schedule_plugin", .create(name: "Alpha")))
    #expect(try store.observableState().history.contains { $0.summary.contains("Alpha") })
}

private func record(key: String, title: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: "/Users/leo/Projects/schedule_plugin",
        triggerPhrase: "record as task",
        excerpt: "record as task"
    )
}

private func uniqueStoreURL() -> URL { TestFixtures.uniqueStoreURL() }

private final class RecordingNotifier: DirectoryNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
    func notifyUnknownDirectory(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        values.append(path)
    }
}
