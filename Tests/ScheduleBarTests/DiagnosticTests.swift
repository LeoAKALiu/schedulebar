import Foundation
import ScheduleBar
import Testing

@Test func healthReportsEachComponent() throws {
    let store = try mappedDiagnosticStore()
    let names = try store.observableState().health.map(\.name)
    #expect(Set(names) == Set([
        "plugin", "mcp", "queue", "sqlite", "deepseek",
        "notifications", "chatwork", "reconcile", "loginitem",
    ]))
}

@Test func pendingInboxShowsUntilRetryConsumesIt() throws {
    let url = uniqueDiagnosticStoreURL()
    let event = CaptureEvent(
        idempotencyKey: "diag-1",
        title: "File weekly report",
        authority: .mainConversation,
        threadID: "t",
        turnID: "diag-1",
        messageTime: Date(timeIntervalSince1970: 1_700_000_000),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task File weekly report"
    )
    _ = CaptureQueue(storeURL: url).enqueue(event)
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    #expect(try store.observableState().pendingInboxCount == 1)
    _ = try store.apply(.retryFailures)
    #expect(try store.observableState().pendingInboxCount == 0)
    #expect(try store.observableState().tasks.map(\.title) == ["File weekly report"])
    _ = try store.apply(.retryFailures)
    #expect(try store.observableState().tasks.count == 1)
}

@Test func retryModelAndReconcileStayIdempotent() async throws {
    let gateway = ScriptedModelGateway(result: .failed(code: "model_timeout", message: "timed out"))
    let sessions = ScriptedSessionDirectory()
    sessions.turns = [
        SessionTurn(
            sessionID: "s",
            turnID: "t1",
            messageTime: Date(timeIntervalSince1970: 1_700_000_000),
            workingDirectory: TestFixtures.cwd,
            userText: "record as task Prepare slides",
            authority: .mainConversation
        ),
    ]
    let store = try mappedDiagnosticStore(gateway: gateway, sessions: sessions)
    _ = try store.apply(
        .capture(
            CaptureEvent(
                idempotencyKey: "m1",
                title: "Chat turn",
                authority: .mainConversation,
                threadID: "t",
                turnID: "m1",
                messageTime: Date(timeIntervalSince1970: 1_700_000_000),
                workingDirectory: TestFixtures.cwd,
                triggerPhrase: "record as task",
                excerpt: "record as task Chat turn"
            )
        )
    )
    await store.processModelMisses()
    _ = try store.apply(.reconcileSessions)
    #expect(try store.observableState().tasks.filter { $0.title == "Prepare slides" }.count == 1)
    gateway.result = .candidates(["Missed follow-up"])
    _ = try store.apply(.retryFailures)
    await store.processModelMisses()
    _ = try store.apply(.retryFailures)
    await store.processModelMisses()
    let state = try store.observableState()
    #expect(state.candidates.filter { $0.title == "Missed follow-up" }.count == 1)
    #expect(state.tasks.filter { $0.title == "Prepare slides" }.count == 1)
}

@Test func errorsIncludeTimeComponentRetryAndNoSecrets() throws {
    let sessions = ScriptedSessionDirectory()
    sessions.failures = ["sk-secretTESTKEY999.jsonl"]
    let store = try mappedDiagnosticStore(sessions: sessions)
    _ = try store.apply(.reconcileSessions)
    let error = try #require(store.observableState().diagnostics.first { $0.code == "session_unreadable" })
    #expect(error.component == "reconcile")
    #expect(error.retryable)
    #expect(error.createdAt != .distantPast)
    #expect(error.message.contains("sk-secretTESTKEY999") == false)
}

@Test func loginAtStartupMatchesController() throws {
    let login = MemoryLoginItemController()
    let store = try ScheduleBarStore(storeURL: uniqueDiagnosticStoreURL(), loginItems: login)
    #expect(try store.observableState().loginAtStartup == false)
    _ = try store.apply(.setLoginAtStartup(true))
    #expect(login.isEnabled)
    #expect(try store.observableState().loginAtStartup == true)
    _ = try store.apply(.setLoginAtStartup(false))
    #expect(login.isEnabled == false)
    #expect(try store.observableState().loginAtStartup == false)
}

@Test func missingNotificationShowsGuidanceAndDoesNotClaimCaptureSuccess() throws {
    let health = StaticHealthEnvironment(notificationsAuthorized: false)
    let store = try mappedDiagnosticStore(health: health)
    let receipt = try store.apply(
        .capture(
            CaptureEvent(
                idempotencyKey: "n1",
                title: "Quiet capture",
                authority: .mainConversation,
                threadID: "t",
                turnID: "n1",
                messageTime: Date(timeIntervalSince1970: 1_700_000_000),
                workingDirectory: TestFixtures.cwd,
                triggerPhrase: "record as task",
                excerpt: "record as task Quiet capture"
            )
        )
    )
    #expect(receipt.outcome == .recorded)
    let note = try #require(store.observableState().health.first { $0.name == "notifications" })
    #expect(note.ok == false)
    #expect(note.detail.lowercased().contains("system settings") || note.detail.contains("通知"))
}

@Test func diagnosticExportIsRedacted() throws {
    let secrets = MemorySecretStore()
    let sessions = ScriptedSessionDirectory()
    sessions.failures = ["sk-secretTESTKEY999.jsonl"]
    let store = try ScheduleBarStore(
        storeURL: uniqueDiagnosticStoreURL(),
        secretStore: secrets,
        sessionDirectory: sessions
    )
    try TestFixtures.mapDefaultDirectory(store)
    _ = try store.apply(.setModelAPIKey("sk-secretTESTKEY999"))
    _ = try store.apply(.reconcileSessions)
    let url = FileManager.default.temporaryDirectory.appending(path: "diag-\(UUID().uuidString).json")
    _ = try store.apply(.exportDiagnostics(url))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("sk-secretTESTKEY999") == false)
    #expect(text.contains("plugin"))
    #expect(text.contains("sqlite"))
    let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect((perms?.intValue ?? 0) & 0o077 == 0)
}

private func mappedDiagnosticStore(
    gateway: ModelGateway = SilentModelGateway(),
    sessions: SessionDirectory = EmptySessionDirectory(),
    health: HealthEnvironment = StaticHealthEnvironment(),
    loginItems: LoginItemControlling = MemoryLoginItemController()
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(
        storeURL: uniqueDiagnosticStoreURL(),
        modelGateway: gateway,
        sessionDirectory: sessions,
        healthEnvironment: health,
        loginItems: loginItems
    )
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func uniqueDiagnosticStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}
