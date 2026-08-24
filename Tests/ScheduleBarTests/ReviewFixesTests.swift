import Foundation
import ScheduleBar
import Testing

@Test func confirmingCandidateKeepsMappedProject() throws {
    let store = try mappedReviewStore()
    let projectID = try #require(store.observableState().projects.first { $0.name == "Schedule Plugin" }?.id)
    let receipt = try store.apply(
        .capture(datedReview(key: "keep-project", title: "Vague mapped work", phrase: "soon", at: TestFixtures.shanghai(2026, 9, 3, 10)))
    )
    #expect(receipt.outcome == .candidate)
    let candidate = try #require(store.observableState().candidates.first { $0.title == "Vague mapped work" })
    #expect(candidate.projectID == projectID)
    let confirmed = try store.reviewCandidate(candidate.id, decision: .confirm)
    #expect(confirmed.outcome == .recorded)
    let state = try store.observableState()
    let task = try #require(state.tasks.first { $0.title == "Vague mapped work" })
    #expect(task.projectID == projectID)
    #expect(state.projects.map(\.name).contains("Inbox") == false)
}

@Test func classifiedCaptureReceiptIsNotAlwaysRecorded() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    let recordedStyle = try store.apply(
        .capture(
            CaptureEvent(
                idempotencyKey: "honest-1",
                title: "Unmapped explicit",
                authority: .mainConversation,
                threadID: "t",
                turnID: "honest-1",
                messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
                workingDirectory: TestFixtures.cwd,
                triggerPhrase: "record as task",
                excerpt: "record as task"
            )
        )
    )
    #expect(recordedStyle.outcome == .candidate)
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.map(\.title) == ["Unmapped explicit"])
}

@Test func acceptedPlanIsRemovedFromOpenDrafts() throws {
    let store = try mappedReviewStore()
    let plan = relativePlan(messageTime: TestFixtures.shanghai(2026, 9, 3, 10))
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    #expect(try store.observableState().plans.isEmpty)
    #expect(throws: ScheduleBarError.notFound) {
        try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    }
}

@Test func completedTaskDoesNotFireDueReminder() throws {
    let clock = ReviewClock(TestFixtures.shanghai(2026, 9, 3, 17))
    let reminders = RecordingReviewReminders()
    let store = try ScheduleBarStore(
        storeURL: TestFixtures.uniqueStoreURL(),
        now: { clock.now },
        reminderNotifier: reminders
    )
    try TestFixtures.mapDefaultDirectory(store)
    let id = try #require(
        store.apply(
            .capture(datedReview(key: "done-fire", title: "Already done", phrase: "2026-09-04", at: TestFixtures.shanghai(2026, 9, 1, 9)))
        ).taskID
    )
    _ = try store.apply(.setStatus(id, .completed), authority: .human)
    clock.now = TestFixtures.shanghai(2026, 9, 3, 18, 1)
    #expect(store.processDueReminders() == 0)
    #expect(reminders.titles.isEmpty)
}

@Test func nonHumanCannotOverwriteHumanBlockedStatus() throws {
    let store = try mappedReviewStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Hold"))).taskID)
    _ = try store.apply(.setStatus(id, .blocked), authority: .human)
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.setStatus(id, .inProgress), authority: .subagent)
    }
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .blocked)
    let completion = try store.apply(.setStatus(id, .completed), authority: .subagent)
    #expect(completion.outcome == .recorded)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .pendingAcceptance)
}

@Test func vagueDatePhraseSurvivesConfirm() throws {
    let store = try mappedReviewStore()
    _ = try store.apply(
        .capture(datedReview(key: "keep-vague", title: "Do it sometime", phrase: "soon", at: TestFixtures.shanghai(2026, 9, 3, 10)))
    )
    let candidate = try #require(store.observableState().candidates.first { $0.title == "Do it sometime" })
    #expect(candidate.datePhrase == "soon")
    _ = try store.reviewCandidate(candidate.id, decision: .confirm)
    let task = try #require(store.observableState().tasks.first { $0.title == "Do it sometime" })
    #expect(task.datePhrase == "soon")
    #expect(task.datePrecision == .vague)
    #expect(task.hardDeadline == nil)
    #expect(try store.reminders(for: task.id).isEmpty)
}

@Test func planRelativeDateUsesProposalMessageTime() throws {
    let clock = ReviewClock(TestFixtures.shanghai(2026, 9, 10, 16))
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL(), now: { clock.now })
    try TestFixtures.mapDefaultDirectory(store)
    let plan = relativePlan(messageTime: TestFixtures.shanghai(2026, 9, 3, 10))
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    let task = try #require(store.observableState().tasks.first { $0.title == "Ship tomorrow" })
    #expect(task.hardDeadline == TestFixtures.shanghai(2026, 9, 4, 0))
}

@Test func missingDateKindDoesNotCreateHardDeadlineReminders() throws {
    let store = try mappedReviewStore()
    let id = try #require(
        store.apply(
            .capture(
                CaptureEvent(
                    idempotencyKey: "no-kind",
                    title: "Tomorrow without kind",
                    authority: .mainConversation,
                    threadID: "t",
                    turnID: "no-kind",
                    messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
                    workingDirectory: TestFixtures.cwd,
                    triggerPhrase: "record as task",
                    excerpt: "record as task tomorrow",
                    datePhrase: "tomorrow"
                )
            )
        ).taskID
    )
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.hardDeadline == nil)
    #expect(task.plannedAt == TestFixtures.shanghai(2026, 9, 4, 0))
    #expect(try store.reminders(for: id).isEmpty)
}

@Test func projectProgressCountsNecessaryChildrenOnly() throws {
    let store = try mappedReviewStore()
    let plan = sampleHierarchyPlan()
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))
    let project = try #require(store.observableState().projects.first { $0.name == "Schedule Plugin" })
    #expect(project.progressSummary == "0 of 1 required subtasks completed")
    let notes = try #require(store.observableState().tasks.first { $0.title == "Write notes" }?.id)
    _ = try store.apply(.setStatus(notes, .completed), authority: .human)
    #expect(try store.observableState().projects.first { $0.name == "Schedule Plugin" }?.progressSummary == "1 of 1 required subtasks completed")
}

@Test func fridayAndNextFridayParseInShanghai() throws {
    let store = try mappedReviewStore()
    let thursday = TestFixtures.shanghai(2026, 9, 3, 10)
    let fridayID = try #require(
        store.apply(.capture(datedReview(key: "fri", title: "Friday work", phrase: "Friday", at: thursday))).taskID
    )
    let nextFridayID = try #require(
        store.apply(.capture(datedReview(key: "next-fri", title: "Next Friday work", phrase: "next Friday", at: thursday))).taskID
    )
    let chineseID = try #require(
        store.apply(.capture(datedReview(key: "xia-fri", title: "下周五工作", phrase: "下周五", at: thursday))).taskID
    )
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == fridayID }?.hardDeadline == TestFixtures.shanghai(2026, 9, 4, 0))
    #expect(state.tasks.first { $0.id == nextFridayID }?.hardDeadline == TestFixtures.shanghai(2026, 9, 11, 0))
    #expect(state.tasks.first { $0.id == chineseID }?.hardDeadline == TestFixtures.shanghai(2026, 9, 11, 0))
}

@Test func observableStateIncludesProjectCandidates() throws {
    let store = try mappedReviewStore()
    let projectID = try #require(store.observableState().projects.first { $0.name == "Schedule Plugin" }?.id)
    _ = try store.apply(
        .capture(datedReview(key: "proj-cand", title: "Project candidate", phrase: "soon", at: TestFixtures.shanghai(2026, 9, 3, 10)))
    )
    let filtered = try store.observableState(projectID: projectID)
    #expect(filtered.candidates.map(\.title) == ["Project candidate"])
}

@Test func nextSevenDaysCountIsExposedOnState() throws {
    let clock = ReviewClock(TestFixtures.shanghai(2026, 9, 4, 15))
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL(), now: { clock.now })
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.capture(datedReview(key: "week", title: "Next week-ish", phrase: "2026-09-08", at: clock.now)))
    let state = try store.observableState()
    #expect(state.nextSevenDays.map(\.title) == ["Next week-ish"])
    #expect(state.nextSevenDaysCount == 1)
}

@Test func candidateEvidenceIsStored() throws {
    let store = try mappedReviewStore()
    _ = try store.apply(
        .capture(datedReview(key: "ev-cand", title: "Maybe later", phrase: "soon", at: TestFixtures.shanghai(2026, 9, 3, 10)))
    )
    let id = try #require(store.observableState().candidates.first?.id)
    #expect(try store.sourceEvidence(for: id)?.triggerPhrase == "record as task")
}

private func mappedReviewStore() throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func datedReview(key: String, title: String, phrase: String, at: Date) -> CaptureEvent {
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

private func relativePlan(messageTime: Date) -> PlanProposal {
    PlanProposal(
        idempotencyKey: "relative-plan",
        threadID: "plan-thread",
        turnID: "turn-plan",
        workingDirectory: TestFixtures.cwd,
        items: [
            PlanItem(
                id: UUID(),
                title: "Ship tomorrow",
                kind: .task,
                datePhrase: "tomorrow",
                dateKind: .hardDeadline
            ),
        ],
        messageTime: messageTime
    )
}

private func sampleHierarchyPlan() -> PlanProposal {
    let milestone = UUID()
    let notes = UUID()
    let polish = UUID()
    return PlanProposal(
        idempotencyKey: "progress-plan",
        threadID: "plan-thread",
        turnID: "turn-progress",
        workingDirectory: TestFixtures.cwd,
        items: [
            PlanItem(id: milestone, title: "Ship v1", kind: .milestone, necessary: true),
            PlanItem(id: notes, title: "Write notes", kind: .task, parentID: milestone, necessary: true),
            PlanItem(id: polish, title: "Optional polish", kind: .task, parentID: milestone, necessary: false),
        ]
    )
}

private final class ReviewClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class RecordingReviewReminders: ReminderNotifier, @unchecked Sendable {
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
