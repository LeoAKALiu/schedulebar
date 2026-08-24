import Foundation
import ScheduleBar
import Testing

@Test func explicitRecordCommandStaysConfirmed() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    let receipt = try store.apply(.capture(event(key: "e1", title: "Ship v1", phrase: "record as task")))
    #expect(receipt.outcome == .recorded)
    #expect(try store.observableState().tasks.map(\.title) == ["Ship v1"])
    #expect(try store.observableState().candidates.isEmpty)
}

@Test func tentativeIntentBecomesCandidate() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let receipt = try store.apply(
        .capture(event(key: "c1", title: "Maybe rewrite the parser", phrase: "we might want to"))
    )
    #expect(receipt.outcome == .candidate)
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.candidates.map(\.title) == ["Maybe rewrite the parser"])
    #expect(state.candidateCount == 1)
}

@Test func discussionAndAgentMechanicsAreIgnored() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    let discussion = try store.apply(
        .capture(event(key: "d1", title: "For example a queue", phrase: "for example"))
    )
    let rejected = try store.apply(
        .capture(event(key: "d2", title: "Drop the rewrite", phrase: "never mind, forget it"))
    )
    let mechanics = try store.apply(
        .capture(event(key: "d3", title: "Read Package.swift", phrase: "read the file and run tests"))
    )
    #expect(discussion.outcome == .ignored)
    #expect(rejected.outcome == .ignored)
    #expect(mechanics.outcome == .ignored)
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.candidates.isEmpty)
}

@Test func subagentCannotConfirmNewWork() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    var capture = event(key: "s1", title: "Add a cache layer", phrase: "I will add a cache layer")
    capture.authority = .subagent
    let receipt = try store.apply(.capture(capture))
    #expect(receipt.outcome == .candidate)
    #expect(try store.observableState().tasks.isEmpty)
    #expect(try store.observableState().candidates.count == 1)
}

@Test func confirmingACandidateCreatesATask() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.capture(event(key: "c2", title: "Draft the outline", phrase: "we might")))
    let id = try #require(store.observableState().candidates.first?.id)
    let receipt = try store.reviewCandidate(id, decision: .confirm)
    #expect(receipt.outcome == .recorded)
    let state = try store.observableState()
    #expect(state.candidates.isEmpty)
    #expect(state.tasks.map(\.title) == ["Draft the outline"])
}

@Test func humanTitleIsNotOverwrittenByCapture() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.quickAdd(QuickAddInput(title: "File weekly report")))
    _ = try store.apply(.capture(event(key: "h1", title: "File weekly report NOW", phrase: "record as task")))
    let titles = try store.observableState().tasks.map(\.title).sorted()
    #expect(titles.contains("File weekly report"))
    #expect(titles.contains("File weekly report NOW"))
    #expect(try store.observableState().tasks.first { $0.title == "File weekly report" } != nil)
}

@Test func similarCandidatesAreNotMerged() throws {
    let store = try ScheduleBarStore(storeURL: uniqueStoreURL())
    _ = try store.apply(.capture(event(key: "x", title: "Rewrite parser", phrase: "we might")))
    _ = try store.apply(.capture(event(key: "y", title: "Rewrite parser", phrase: "we might")))
    #expect(try store.observableState().candidates.count == 2)
}

private func event(key: String, title: String, phrase: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: "/Users/leo/Projects/schedule_plugin",
        triggerPhrase: phrase,
        excerpt: phrase
    )
}

private func uniqueStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
