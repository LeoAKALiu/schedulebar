import Foundation
import ScheduleBar
import Testing

@Test func captureWorksWithoutModelConfigured() throws {
    let store = try mappedModelStore()
    let receipt = try store.apply(
        .capture(recordTurn(key: "plain", title: "File weekly report", excerpt: "record as task"))
    )
    #expect(receipt.outcome == .recorded)
    #expect(try store.observableState().tasks.map(\.title) == ["File weekly report"])
    #expect(try store.observableState().diagnostics.isEmpty)
}

@Test func modelResultsBecomeCandidatesAndDoNotOverwriteHumanTasks() async throws {
    let gateway = ScriptedModelGateway(result: .candidates(["Missed follow-up", "Keep me"]))
    let store = try mappedModelStore(gateway: gateway)
    let human = try #require(store.apply(.quickAdd(QuickAddInput(title: "Keep me"))).taskID)
    _ = try store.apply(
        .capture(recordTurn(key: "miss", title: "Chat noise", excerpt: "we should maybe follow up later"))
    )
    await store.processModelMisses()
    let state = try store.observableState()
    #expect(state.tasks.first { $0.id == human }?.title == "Keep me")
    #expect(state.candidates.map(\.title).contains("Missed follow-up"))
    #expect(state.tasks.map(\.title).contains("Missed follow-up") == false)
}

@Test func onlyCurrentTurnTextIsSentToTheGateway() async throws {
    let gateway = ScriptedModelGateway(result: .candidates(["Later"]))
    let store = try mappedModelStore(gateway: gateway)
    var event = recordTurn(key: "turn-only", title: "Current turn", excerpt: "only this turn matters")
    event.conversation = "FULL CHAT DUMP should not be sent"
    event.reasoning = "hidden chain of thought"
    _ = try store.apply(.capture(event))
    await store.processModelMisses()
    let request = try #require(gateway.requests.first)
    #expect(request.turnText.contains("only this turn matters"))
    #expect(request.turnText.contains("FULL CHAT DUMP") == false)
    #expect(request.turnText.contains("hidden chain of thought") == false)
    #expect(request.threadID == "thread-model")
    #expect(request.turnID == "turn-only")
}

@Test func modelFailureDoesNotBlockCaptureAndRecordsDiagnostic() async throws {
    let gateway = ScriptedModelGateway(result: .failed(code: "model_timeout", message: "timed out"))
    let store = try mappedModelStore(gateway: gateway)
    let receipt = try store.apply(
        .capture(recordTurn(key: "fail", title: "Still record", excerpt: "record as task"))
    )
    #expect(receipt.outcome == .recorded)
    await store.processModelMisses()
    let state = try store.observableState()
    #expect(state.tasks.map(\.title) == ["Still record"])
    #expect(state.diagnostics.map(\.code).contains("model_timeout"))
}

@Test func captureDoesNotWaitForTheModel() throws {
    let gateway = ScriptedModelGateway(result: .candidates(["Slow miss"]), delay: 3)
    let store = try mappedModelStore(gateway: gateway)
    let start = Date()
    _ = try store.apply(
        .capture(recordTurn(key: "fast", title: "Quick capture", excerpt: "record as task"))
    )
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(try store.observableState().candidates.isEmpty)
}

@Test func apiKeyStaysInSecretStoreNotSqliteOrBackup() throws {
    let secrets = MemorySecretStore()
    let url = uniqueModelStoreURL()
    let store = try ScheduleBarStore(storeURL: url, secretStore: secrets)
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.setModelAPIKey("sk-secretTESTKEY999"))
    #expect(secrets.loadAPIKey() == "sk-secretTESTKEY999")
    let haystack = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    #expect(haystack.contains("sk-secretTESTKEY999") == false)
    let backupURL = FileManager.default.temporaryDirectory.appending(path: "model-backup-\(UUID().uuidString).json")
    _ = try store.apply(.exportBackup(backupURL))
    let backup = try String(contentsOf: backupURL, encoding: .utf8)
    #expect(backup.contains("sk-secretTESTKEY999") == false)
}

private func mappedModelStore(
    gateway: ModelGateway = SilentModelGateway(),
    secrets: SecretStore = MemorySecretStore()
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(
        storeURL: uniqueModelStoreURL(),
        modelGateway: gateway,
        secretStore: secrets
    )
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func recordTurn(key: String, title: String, excerpt: String) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "thread-model",
        turnID: key,
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: excerpt.contains("record as task") ? "record as task" : excerpt,
        excerpt: excerpt
    )
}

private func uniqueModelStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
