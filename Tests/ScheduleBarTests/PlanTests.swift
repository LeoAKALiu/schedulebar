import Foundation
import ScheduleBar
import Testing

@Test func proposedPlanDoesNotChangeFormalTasks() throws {
    let store = try mappedPlanStore()
    let receipt = try store.apply(.proposePlan(samplePlan()), authority: .mainConversation)
    #expect(receipt.outcome == .candidate)
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.milestones.isEmpty)
    #expect(state.plans.count == 1)
    #expect(state.plans.first?.items.map(\.title) == ["Ship v1", "Write notes", "Optional polish"])
}

@Test func partialAcceptanceCreatesOnlyChosenItems() throws {
    let store = try mappedPlanStore()
    let plan = samplePlan()
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, [plan.items[0].id]))
    let state = try store.observableState()
    #expect(state.milestones.map(\.title) == ["Ship v1"])
    #expect(state.tasks.map(\.title) == ["Ship v1"])
    #expect(state.tasks.map(\.title).contains("Write notes") == false)
}

@Test func acceptedPlanCreatesMilestoneParentAndChildren() throws {
    let store = try mappedPlanStore()
    let plan = samplePlan()
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    let state = try store.observableState()
    let milestone = try #require(state.milestones.first { $0.title == "Ship v1" })
    #expect(milestone.kind == .milestone)
    let notes = try #require(state.tasks.first { $0.title == "Write notes" })
    let polish = try #require(state.tasks.first { $0.title == "Optional polish" })
    #expect(notes.parentID == milestone.id)
    #expect(notes.necessary)
    #expect(polish.parentID == milestone.id)
    #expect(polish.necessary == false)
    #expect(milestone.hardDeadline == shanghai(2026, 9, 10, 0))
}

@Test func parentProgressUsesNecessaryCompletedChildrenAndExplainsWithoutPercent() throws {
    let store = try mappedPlanStore()
    let plan = samplePlan()
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    let notes = try #require(store.observableState().tasks.first { $0.title == "Write notes" }?.id)
    let polish = try #require(store.observableState().tasks.first { $0.title == "Optional polish" }?.id)
    _ = try store.apply(.setStatus(notes, .completed), authority: .human)
    _ = try store.apply(.setStatus(polish, .completed), authority: .human)
    let milestone = try #require(store.observableState().milestones.first { $0.title == "Ship v1" })
    #expect(milestone.progressSummary == "1 of 1 required subtasks completed")
    #expect(milestone.progressSummary?.contains("%") == false)
}

@Test func oneThreadLinksManyTasksAndATaskKeepsMultipleSources() throws {
    let store = try mappedPlanStore()
    let plan = samplePlan()
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, [plan.items[0].id, plan.items[1].id]))
    let milestone = try #require(store.observableState().tasks.first { $0.title == "Ship v1" })
    let notes = try #require(store.observableState().tasks.first { $0.title == "Write notes" })
    #expect(try store.sourceLinks(for: milestone.id).map(\.threadID) == ["plan-thread"])
    #expect(try store.sourceLinks(for: notes.id).map(\.threadID) == ["plan-thread"])
    _ = try store.apply(
        .linkSource(
            milestone.id,
            SourceEvidence(
                threadID: "other-thread",
                turnID: "t2",
                triggerPhrase: "record as task",
                excerpt: "also from the recap",
                workingDirectory: TestFixtures.cwd
            )
        )
    )
    #expect(try store.sourceLinks(for: milestone.id).map(\.threadID) == ["plan-thread", "other-thread"])
}

private func samplePlan() -> PlanProposal {
    let milestone = UUID()
    let notes = UUID()
    let polish = UUID()
    return PlanProposal(
        idempotencyKey: "plan-1",
        threadID: "plan-thread",
        turnID: "turn-plan",
        workingDirectory: TestFixtures.cwd,
        items: [
            PlanItem(
                id: milestone,
                title: "Ship v1",
                kind: .milestone,
                parentID: nil,
                necessary: true,
                datePhrase: "2026-09-10",
                dateKind: .hardDeadline
            ),
            PlanItem(id: notes, title: "Write notes", kind: .task, parentID: milestone, necessary: true),
            PlanItem(id: polish, title: "Optional polish", kind: .task, parentID: milestone, necessary: false),
        ]
    )
}

private func mappedPlanStore() throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniquePlanStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniquePlanStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
