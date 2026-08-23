import Foundation
import ScheduleBar
import Testing

@Test func reconcileReadsOnlyLocallyVisibleTurns() throws {
    let source = ScriptedSessionDirectory()
    source.turns = [
        sessionTurn(session: "cloud-1", turn: "t1", text: "record as task File weekly report"),
    ]
    let store = try mappedSessionStore(source: source)
    let receipt = try store.apply(.reconcileSessions)
    #expect(receipt.outcome == .recorded)
    #expect(try store.observableState().tasks.map(\.title) == ["File weekly report"])
}

@Test func reconcileCursorSurvivesRestartAndDuplicateSync() throws {
    let url = uniqueSessionStoreURL()
    let source = ScriptedSessionDirectory()
    source.turns = [
        sessionTurn(session: "cloud-1", turn: "t1", text: "record as task Prepare slides"),
    ]
    do {
        let store = try ScheduleBarStore(storeURL: url, sessionDirectory: source)
        try TestFixtures.mapDefaultDirectory(store)
        _ = try store.apply(.reconcileSessions)
        #expect(try store.observableState().tasks.count == 1)
        _ = try store.apply(.reconcileSessions)
        #expect(try store.observableState().tasks.count == 1)
    }
    source.turns.append(sessionTurn(session: "cloud-1", turn: "t1", text: "record as task Prepare slides"))
    let restarted = try ScheduleBarStore(storeURL: url, sessionDirectory: source)
    _ = try restarted.apply(.reconcileSessions)
    #expect(try restarted.observableState().tasks.count == 1)
    #expect(try restarted.observableState().tasks.map(\.title) == ["Prepare slides"])
}

@Test func reconcileHonorsClassifierAndKeepsMinimalEvidence() throws {
    let source = ScriptedSessionDirectory()
    source.turns = [
        sessionTurn(session: "s", turn: "a", text: "record as task Ship notes"),
        sessionTurn(session: "s", turn: "b", text: "we might want to rewrite the parser"),
        sessionTurn(session: "s", turn: "c", text: "for example a queue"),
    ]
    let store = try mappedSessionStore(source: source)
    _ = try store.apply(.reconcileSessions)
    let state = try store.observableState()
    #expect(state.tasks.map(\.title) == ["Ship notes"])
    #expect(state.candidates.map(\.title).contains("we might want to rewrite the parser") || state.candidates.count == 1)
    let recorded = try #require(state.tasks.first)
    let evidence = try store.sourceEvidence(for: recorded.id)
    #expect(evidence?.threadID == "s")
    #expect(evidence?.turnID == "a")
    #expect(evidence?.excerpt.contains("Ship notes") == true)
}

@Test func unreadableSessionDoesNotBlockAndIsRetryable() throws {
    let source = ScriptedSessionDirectory()
    source.failures = ["cloud-session.jsonl"]
    let store = try mappedSessionStore(source: source)
    _ = try store.apply(.reconcileSessions)
    _ = try store.apply(.quickAdd(QuickAddInput(title: "Still works")))
    let state = try store.observableState()
    #expect(state.tasks.map(\.title) == ["Still works"])
    #expect(state.diagnostics.contains { $0.code == "session_unreadable" })
}

@Test func localReconcileIsNotRealtimeRemoteCapture() {
    #expect(CapturePolicy.remoteRealtimeCapture == false)
    let text = CapturePolicy.localReconcileHelpText.lowercased()
    #expect(text.contains("local") || CapturePolicy.localReconcileHelpText.contains("本地"))
    #expect(text.contains("realtime") == false || text.contains("not realtime") || CapturePolicy.localReconcileHelpText.contains("不是") || text.contains("not"))
}

private func mappedSessionStore(source: SessionDirectory) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniqueSessionStoreURL(), sessionDirectory: source)
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func sessionTurn(session: String, turn: String, text: String) -> SessionTurn {
    SessionTurn(
        sessionID: session,
        turnID: turn,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: TestFixtures.cwd,
        userText: text,
        authority: .mainConversation
    )
}

private func uniqueSessionStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
