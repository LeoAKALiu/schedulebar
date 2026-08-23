import Foundation
import ScheduleBar
import SQLite3
import Testing

@Test func codexHookQueuesAUserCommitment() throws {
    let url = TestFixtures.uniqueStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let payload: [String: Any] = [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "turn-42",
        "cwd": TestFixtures.cwd,
        "prompt": "I will file the weekly report tomorrow",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)

    let receipt = CodexHookProcessor.process(
        data,
        storeURL: url,
        now: TestFixtures.shanghai(2026, 9, 3, 10)
    )

    #expect(receipt.outcome == .recorded)
    #expect(store.processInbox().map(\.outcome) == [.recorded])
    #expect(try store.observableState().tasks.map(\.title) == ["I will file the weekly report tomorrow"])
    #expect(try store.observableState().tasks.first?.plannedAt != nil)
}

@Test func hookTruthfullyReportsCandidateForAnUnknownDirectory() throws {
    let url = TestFixtures.uniqueStoreURL()
    let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "unknown-directory",
        "cwd": "/tmp/schedulebar-unknown-\(UUID().uuidString)",
        "prompt": "I will file the weekly report tomorrow",
    ])

    let receipt = CodexHookProcessor.process(payload, storeURL: url)

    #expect(receipt.outcome == .candidate)
    let store = try ScheduleBarStore(storeURL: url)
    #expect(store.processInbox().map(\.outcome) == [.candidate])
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.count == 1)
}

@Test func codexHookCapturesHardDeadlineSemantics() throws {
    let url = TestFixtures.uniqueStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let now = TestFixtures.shanghai(2026, 9, 3, 10)
    let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "deadline",
        "cwd": TestFixtures.cwd,
        "prompt": "I will file the report due tomorrow",
    ])

    #expect(CodexHookProcessor.process(payload, storeURL: url, now: now).outcome == .recorded)
    #expect(store.processInbox().map(\.outcome) == [.recorded])
    let deadline = try #require(try store.observableState().tasks.first?.hardDeadline)
    #expect(Calendar(identifier: .gregorian).component(.day, from: deadline) == 4)
}

@Test func codexHookCreatesAReviewableStructuredPlan() throws {
    let url = TestFixtures.uniqueStoreURL()
    let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "plan",
        "cwd": TestFixtures.cwd,
        "prompt": """
            Plan:
            - Milestone: ship beta due 2026-09-10
              - Run acceptance tests
            """,
    ])

    #expect(CodexHookProcessor.process(payload, storeURL: url).outcome == .candidate)
    let store = try ScheduleBarStore(storeURL: url)
    #expect(store.processInbox().map(\.outcome) == [.candidate])
    let plan = try #require(try store.observableState().plans.first)
    #expect(plan.items.count == 2)
    #expect(plan.items[0].kind == .milestone)
    #expect(plan.items[0].dateKind == .hardDeadline)
    #expect(plan.items[1].parentID == plan.items[0].id)
}

@Test func codexHookDoesNotCreateARejectedPlanDraft() throws {
    let url = TestFixtures.uniqueStoreURL()
    let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "rejected-plan",
        "cwd": TestFixtures.cwd,
        "prompt": """
            不要记录这个计划：
            - Milestone: beta
            - Run acceptance
            """,
    ])

    #expect(CodexHookProcessor.process(payload, storeURL: url).outcome == .ignored)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

@Test func codexHookIgnoresSessionStartAndNoise() throws {
    let url = TestFixtures.uniqueStoreURL()
    let sessionStart = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "SessionStart",
        "session_id": "hook-session",
        "cwd": TestFixtures.cwd,
    ])
    let noise = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "turn-43",
        "cwd": TestFixtures.cwd,
        "prompt": "What is the weather?",
    ])

    #expect(CodexHookProcessor.process(sessionStart, storeURL: url).outcome == .ignored)
    #expect(CodexHookProcessor.process(noise, storeURL: url).outcome == .ignored)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

@Test func negatedCommitmentIsIgnored() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = CaptureEvent(
        idempotencyKey: "negated",
        title: "Publish the draft",
        authority: .mainConversation,
        threadID: "thread",
        turnID: "turn",
        messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "I will not publish the draft",
        excerpt: "I will not publish the draft"
    )

    #expect(try store.apply(.capture(event)).outcome == .ignored)
    #expect(try store.observableState().tasks.isEmpty)
}

@Test func explicitRefusalIsNotUpgradedToConsent() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = CaptureEvent(
        idempotencyKey: "explicit-refusal",
        title: "不要记录为任务：整理周报",
        authority: .mainConversation,
        threadID: "thread",
        turnID: "turn",
        messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "不要记录为任务",
        excerpt: "不要记录为任务：整理周报"
    )

    #expect(try store.apply(.capture(event)).outcome == .ignored)
    #expect(try store.observableState().tasks.isEmpty)
}

@Test func anExplicitTaskMayContainAnExampleWithoutBecomingNoise() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = try #require(
        ChatWorkHandoff.event(
            userText: "record as task Add examples, e.g. the weekly report",
            idempotencyKey: "explicit-with-example",
            workingDirectory: TestFixtures.cwd
        )
    )

    #expect(try store.apply(.capture(event)).outcome == .recorded)
}

@Test func hookExplicitTaskMayContainAnExampleWithoutBecomingPlanNoise() throws {
    let url = TestFixtures.uniqueStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let payload = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "hook-session",
        "turn_id": "explicit-with-example",
        "cwd": TestFixtures.cwd,
        "prompt": "record as task Add examples, e.g. the weekly report",
    ])

    #expect(CodexHookProcessor.process(payload, storeURL: url).outcome == .recorded)
    #expect(store.processInbox().map(\.outcome) == [.recorded])
}

@Test func explicitChatWorkRecordCarriesDateSemanticsIntoTheSharedStore() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = try #require(
        ChatWorkHandoff.event(
            userText: "record as task File the report due tomorrow",
            idempotencyKey: "chat-work-date",
            workingDirectory: TestFixtures.cwd,
            messageTime: TestFixtures.shanghai(2026, 9, 3, 10)
        )
    )

    #expect(event.datePhrase == "tomorrow")
    #expect(event.dateKind == .hardDeadline)
    #expect(try store.apply(.capture(event)).outcome == .recorded)
    #expect(try store.observableState().tasks.first?.hardDeadline != nil)
}

@Test func sharedDateDiscoveryKeepsEnglishVagueDatesAsCandidates() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = try #require(
        ChatWorkHandoff.event(
            userText: "record as task File it soon",
            idempotencyKey: "chat-work-vague-date",
            workingDirectory: TestFixtures.cwd
        )
    )

    #expect(event.datePhrase == "soon")
    #expect(try store.apply(.capture(event)).outcome == .candidate)
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.first?.datePrecision == .vague)
}

@Test func acceptingPartOfAPlanPreservesTheRemainingDraft() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let first = PlanItem(id: UUID(), title: "First")
    let second = PlanItem(id: UUID(), title: "Second")
    let proposal = PlanProposal(
        idempotencyKey: "partial-plan",
        threadID: "thread",
        turnID: "turn",
        workingDirectory: TestFixtures.cwd,
        items: [first, second]
    )
    let planID = try #require(store.apply(.proposePlan(proposal)).taskID)

    _ = try store.apply(.acceptPlan(planID, [first.id]), authority: .human)
    var state = try store.observableState()
    #expect(state.tasks.map(\.title) == ["First"])
    #expect(state.plans.first?.items == [second])

    _ = try store.apply(.acceptPlan(planID, [second.id]), authority: .human)
    state = try store.observableState()
    #expect(Set(state.tasks.map(\.title)) == Set(["First", "Second"]))
    #expect(state.plans.isEmpty)
}

@Test func acceptingAChildRequiresItsParentAndPreservesTheHierarchy() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let parent = PlanItem(id: UUID(), title: "Parent", kind: .milestone)
    let child = PlanItem(id: UUID(), title: "Child", parentID: parent.id)
    let planID = try #require(
        store.apply(
            .proposePlan(
                PlanProposal(
                    idempotencyKey: "ordered-plan",
                    threadID: "thread",
                    turnID: "turn",
                    workingDirectory: TestFixtures.cwd,
                    items: [parent, child]
                )
            )
        ).taskID
    )

    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.acceptPlan(planID, [child.id]), authority: .human)
    }
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().plans.first?.items.count == 2)

    _ = try store.apply(.acceptPlan(planID, [parent.id]), authority: .human)
    _ = try store.apply(.acceptPlan(planID, [child.id]), authority: .human)
    #expect(try store.observableState().tasks.first { $0.id == child.id }?.parentID == parent.id)
}

@Test func acceptingAPlanRollsBackAllItemsWhenOneWriteFails() throws {
    let url = TestFixtures.uniqueStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let first = PlanItem(id: UUID(), title: "First")
    let second = PlanItem(id: UUID(), title: "Second")
    let planID = try #require(
        store.apply(
            .proposePlan(
                PlanProposal(
                    idempotencyKey: "atomic-plan",
                    threadID: "thread",
                    turnID: "turn",
                    workingDirectory: TestFixtures.cwd,
                    items: [first, second]
                )
            )
        ).taskID
    )
    var rawDatabase: OpaquePointer?
    #expect(sqlite3_open(url.path, &rawDatabase) == SQLITE_OK)
    defer { sqlite3_close(rawDatabase) }
    let trigger = """
        CREATE TRIGGER fail_second_plan_source
        BEFORE INSERT ON source_links
        WHEN NEW.excerpt = 'Second'
        BEGIN SELECT RAISE(ABORT, 'forced failure'); END;
        """
    #expect(sqlite3_exec(rawDatabase, trigger, nil, nil, nil) == SQLITE_OK)

    #expect(throws: ScheduleBarError.storeUnavailable) {
        try store.apply(.acceptPlan(planID, [first.id, second.id]), authority: .human)
    }
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.plans.first?.items == [first, second])
}

@Test func agentAuthorityPolicyNeverGrantsHumanAuthority() {
    #expect(AgentAuthorityPolicy.parse(nil) == .mainConversation)
    #expect(AgentAuthorityPolicy.parse("mainConversation") == .mainConversation)
    #expect(AgentAuthorityPolicy.parse("subagent") == .subagent)
    #expect(AgentAuthorityPolicy.parse("human") == nil)
}

@Test func editingCandidateDoesNotConfirmIt() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let event = CaptureEvent(
        idempotencyKey: "candidate-edit",
        title: "Maybe prepare slides",
        authority: .mainConversation,
        threadID: "thread",
        turnID: "turn",
        messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "maybe",
        excerpt: "Maybe prepare slides"
    )
    _ = try store.apply(.capture(event))
    let candidate = try #require(try store.observableState().candidates.first)

    _ = try store.reviewCandidate(
        candidate.id,
        decision: .edit(QuickAddInput(title: "Prepare final slides", notes: "Use v3", localPath: "/tmp/slides"))
    )
    var state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.candidates.first?.title == "Prepare final slides")
    #expect(state.candidates.first?.notes == "Use v3")
    #expect(state.candidates.first?.localPath == "/tmp/slides")

    _ = try store.reviewCandidate(candidate.id, decision: .confirm)
    state = try store.observableState()
    #expect(state.candidates.isEmpty)
    #expect(state.tasks.first?.title == "Prepare final slides")
    #expect(state.tasks.first?.notes == "Use v3")
    #expect(state.tasks.first?.localPath == "/tmp/slides")
    let formalTaskID = try #require(state.tasks.first?.id)
    #expect(try store.sourceEvidence(for: formalTaskID)?.turnID == "turn")
}

@Test func humanCanEditAFormalTaskWithoutChangingItsIdentity() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    let id = try #require(
        store.apply(.quickAdd(QuickAddInput(title: "Draft title"))).taskID
    )

    _ = try store.apply(
        .editTask(id, QuickAddInput(title: "Final title", notes: "Reviewed", localPath: "/tmp/final")),
        authority: .human
    )

    let task = try #require(try store.observableState().tasks.first)
    #expect(task.id == id)
    #expect(task.title == "Final title")
    #expect(task.notes == "Reviewed")
    #expect(task.localPath == "/tmp/final")
}

@Test func modelCandidateCanBeUndone() async throws {
    let gateway = ScriptedModelGateway(result: .candidates(["Model-only candidate"]))
    let secrets = MemorySecretStore()
    secrets.saveAPIKey("test-key")
    let store = try ScheduleBarStore(
        storeURL: TestFixtures.uniqueStoreURL(),
        modelGateway: gateway,
        secretStore: secrets
    )
    try TestFixtures.mapDefaultDirectory(store)
    let event = CaptureEvent(
        idempotencyKey: "model-source",
        title: "Recorded source",
        authority: .mainConversation,
        threadID: "thread",
        turnID: "turn",
        messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task Recorded source"
    )
    _ = try store.apply(.capture(event))
    await store.processModelMisses()
    #expect(try store.observableState().candidates.map(\.title).contains("Model-only candidate"))

    _ = try store.apply(.undoLastAutomaticChange)
    #expect(try store.observableState().candidates.map(\.title).contains("Model-only candidate") == false)
}

@Test func unreadableSessionRootIsReportedForRetry() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "session-root-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let scan = FolderSessionDirectory(root: file).scan()
    #expect(scan.turns.isEmpty)
    #expect(scan.failures.isEmpty == false)
}
