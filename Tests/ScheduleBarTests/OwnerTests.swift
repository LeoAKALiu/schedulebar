import Foundation
import ScheduleBar
import Testing

@Test func quickAddDefaultsToSelfOwnerAndNotStarted() throws {
    let store = try mappedOwnerStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Mine"))).taskID)
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.ownerName == "Me")
    #expect(task.ownerKind == .selfPerson)
    #expect(task.status == .notStarted)
}

@Test func assigningSomeoneElseShowsInWaitingOnOthers() throws {
    let store = try mappedOwnerStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Ask Leo"))).taskID)
    _ = try store.apply(.setOwner(id, "Leo", .person))
    let state = try store.observableState()
    #expect(state.waitingOnOthers.map(\.title) == ["Ask Leo"])
    #expect(state.tasks.first { $0.id == id }?.status == .waitingOnOther)
    #expect(state.tasks.first { $0.id == id }?.ownerName == "Leo")
    #expect(state.tasks.first { $0.id == id }?.ownerKind == .person)
}

@Test func ownerAliasUnifiesTwoNames() throws {
    let store = try mappedOwnerStore()
    let first = try #require(store.apply(.quickAdd(QuickAddInput(title: "A"))).taskID)
    _ = try store.apply(.setOwner(first, "Leo", .person))
    let ownerID = try #require(store.observableState().tasks.first { $0.id == first }?.ownerID)
    _ = try store.apply(.confirmAlias("刘", ownerID))
    let second = try #require(store.apply(.quickAdd(QuickAddInput(title: "B"))).taskID)
    _ = try store.apply(.setOwner(second, "刘", .person))
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == first }?.ownerID == ownerID)
    #expect(state.tasks.first { $0.id == second }?.ownerID == ownerID)
    #expect(Set(state.owners.map(\.name)) == Set(["Me", "Leo"]))
}

@Test func subagentCompletionStaysPendingAcceptance() throws {
    let store = try mappedOwnerStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Ship"))).taskID)
    _ = try store.apply(.setOwner(id, "Codex", .agent))
    let receipt = try store.apply(.setStatus(id, .completed), authority: .subagent)
    #expect(receipt.outcome == .recorded)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .pendingAcceptance)
}

@Test func humanAcceptanceMarksCompleted() throws {
    let store = try mappedOwnerStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Ship"))).taskID)
    _ = try store.apply(.setStatus(id, .pendingAcceptance))
    _ = try store.apply(.setStatus(id, .completed), authority: .human)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .completed)
}

@Test func satisfiedEvidenceAllowsNonHumanCompletion() throws {
    let store = try mappedOwnerStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "CI gate"))).taskID)
    _ = try store.apply(.requireAcceptance(id, "ci-green"))
    _ = try store.apply(.setStatus(id, .completed), authority: .mainConversation)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .pendingAcceptance)
    _ = try store.apply(.satisfyAcceptance(id, "ci-green"), authority: .subagent)
    _ = try store.apply(.setStatus(id, .completed), authority: .mainConversation)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .completed)
}

@Test func delegatedFollowUpIsIndependentOfHardDeadline() throws {
    let store = try mappedOwnerStore()
    let id = try #require(
        store.apply(
            .capture(
                CaptureEvent(
                    idempotencyKey: "delegate-1",
                    title: "Leo writes the recap",
                    authority: .mainConversation,
                    threadID: "t",
                    turnID: "delegate-1",
                    messageTime: shanghai(2026, 9, 4, 10),
                    workingDirectory: TestFixtures.cwd,
                    triggerPhrase: "record as task",
                    excerpt: "record as task 2026-09-10",
                    datePhrase: "2026-09-10",
                    dateKind: .hardDeadline
                )
            )
        ).taskID
    )
    _ = try store.apply(.setOwner(id, "Leo", .person))
    _ = try store.apply(.setFollowUp(id, shanghai(2026, 9, 6, 0)))
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.hardDeadline == shanghai(2026, 9, 10, 0))
    #expect(task.followUpAt == shanghai(2026, 9, 6, 0))
    #expect(try store.observableState().waitingOnOthers.map(\.id) == [id])
}

@Test func ownerAndStatusChangesAreInHistoryAndSurviveRestart() throws {
    let url = uniqueOwnerStoreURL()
    let taskID: UUID
    let ownerID: UUID
    do {
        let store = try ScheduleBarStore(storeURL: url)
        try TestFixtures.mapDefaultDirectory(store)
        taskID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Keep owner"))).taskID)
        _ = try store.apply(.setOwner(taskID, "Leo", .person))
        _ = try store.apply(.setStatus(taskID, .blocked))
        ownerID = try #require(store.observableState().tasks.first { $0.id == taskID }?.ownerID)
        let history = try store.observableState().history.map(\.summary)
        #expect(history.contains { $0.contains("Leo") })
        #expect(history.contains { $0.lowercased().contains("blocked") })
    }
    let restarted = try ScheduleBarStore(storeURL: url)
    let task = try #require(restarted.observableState().tasks.first { $0.id == taskID })
    #expect(task.ownerID == ownerID)
    #expect(task.ownerName == "Leo")
    #expect(task.status == .blocked)
}

private func mappedOwnerStore() throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniqueOwnerStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniqueOwnerStoreURL() -> URL { TestFixtures.uniqueStoreURL() }
