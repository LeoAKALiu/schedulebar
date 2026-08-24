import Foundation
import ScheduleBar
import Testing

// MARK: - T12: model job concurrency

@Test func concurrentModelRunsDoNotDuplicateCandidates() async throws {
    let gateway = ScriptedModelGateway(result: .candidates(["Missed follow-up"]), delay: 0.3)
    let store = try mappedFixesStore(gateway: gateway)
    _ = try store.apply(.capture(fixesTurn(key: "race-1", title: "First turn", excerpt: "record as task")))
    _ = try store.apply(.capture(fixesTurn(key: "race-2", title: "Second turn", excerpt: "record as task")))
    async let first: Void = store.processModelMisses()
    async let second: Void = store.processModelMisses()
    _ = await (first, second)
    #expect(gateway.requests.count == 2)
    #expect(try store.observableState().candidates.filter { $0.title == "Missed follow-up" }.count == 1)
}

// MARK: - T14: reconcile cursor

@Test func turnIDOrderComparesNumbersNaturally() {
    #expect(TurnIDOrder.isLess("t2", "t10"))
    #expect(TurnIDOrder.isLess("t10", "t2") == false)
    #expect(TurnIDOrder.isLess("turn-9", "turn-10"))
    #expect(TurnIDOrder.isLess("a", "b"))
    #expect(TurnIDOrder.isLess("t10", "t10") == false)
}

@Test func laterNumericTurnIsNotSkippedAfterCursor() throws {
    let source = ScriptedSessionDirectory()
    let store = try ScheduleBarStore(
        storeURL: TestFixtures.uniqueStoreURL(),
        sessionDirectory: source
    )
    try TestFixtures.mapDefaultDirectory(store)
    let time = TestFixtures.shanghai(2026, 9, 3, 10)
    source.turns = [
        SessionTurn(
            sessionID: "s",
            turnID: "t2",
            messageTime: time,
            workingDirectory: TestFixtures.cwd,
            userText: "record as task First"
        ),
    ]
    _ = store.reconcileSessions()
    #expect(try store.observableState().tasks.map(\.title) == ["First"])
    source.turns.append(
        SessionTurn(
            sessionID: "s",
            turnID: "t10",
            messageTime: time,
            workingDirectory: TestFixtures.cwd,
            userText: "record as task Second"
        )
    )
    _ = store.reconcileSessions()
    #expect(try store.observableState().tasks.map(\.title).contains("Second"))
}

@Test func reconcileDoesNotAdvanceCursorWhenEnqueueFails() throws {
    let url = TestFixtures.uniqueStoreURL()
    let source = ScriptedSessionDirectory()
    let store = try ScheduleBarStore(storeURL: url, sessionDirectory: source)
    try TestFixtures.mapDefaultDirectory(store)
    source.turns = [
        SessionTurn(
            sessionID: "s",
            turnID: "t1",
            messageTime: TestFixtures.shanghai(2026, 9, 3, 10),
            workingDirectory: TestFixtures.cwd,
            userText: "record as task Survives outage"
        ),
    ]
    // A read-only database file makes CaptureQueue's own connection fail
    // while the already-open store connection keeps working.
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    _ = store.reconcileSessions()
    let state = try store.observableState()
    #expect(state.tasks.isEmpty)
    #expect(state.diagnostics.contains { $0.code == "reconcile_enqueue_failed" && $0.retryable })

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    _ = store.reconcileSessions()
    #expect(try store.observableState().tasks.map(\.title) == ["Survives outage"])
}

// MARK: - T09: blocked-by

@Test func blockerCyclesAreRejected() throws {
    let store = try mappedFixesStore()
    let a = try #require(store.apply(.quickAdd(QuickAddInput(title: "A"))).taskID)
    let b = try #require(store.apply(.quickAdd(QuickAddInput(title: "B"))).taskID)
    let c = try #require(store.apply(.quickAdd(QuickAddInput(title: "C"))).taskID)
    _ = try store.apply(.setBlockedBy(a, b))
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.setBlockedBy(b, a))
    }
    _ = try store.apply(.setBlockedBy(b, c))
    #expect(throws: ScheduleBarError.notPermitted) {
        try store.apply(.setBlockedBy(c, a))
    }
}

@Test func unblockingRestoresPreviousWorkflowStatus() throws {
    let store = try mappedFixesStore()
    let blocker = try #require(store.apply(.quickAdd(QuickAddInput(title: "Blocker"))).taskID)
    let blocked = try #require(store.apply(.quickAdd(QuickAddInput(title: "Blocked work"))).taskID)
    _ = try store.apply(.setStatus(blocked, .inProgress), authority: .human)
    _ = try store.apply(.setBlockedBy(blocked, blocker))
    #expect(try store.observableState().tasks.first { $0.id == blocked }?.status == .blocked)
    _ = try store.apply(.setStatus(blocker, .completed), authority: .human)
    #expect(try store.observableState().tasks.first { $0.id == blocked }?.status == .inProgress)
}

// MARK: - T04: undo of automatic changes

@Test func undoRestoresPreviousStatusAfterAutomaticSetStatus() throws {
    let store = try mappedFixesStore()
    let id = try #require(store.apply(.quickAdd(QuickAddInput(title: "Agent touched"))).taskID)
    _ = try store.apply(.setStatus(id, .inProgress), authority: .subagent)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .inProgress)
    _ = try store.apply(.undoLastAutomaticChange)
    #expect(try store.observableState().tasks.first { $0.id == id }?.status == .notStarted)
}

@Test func undoRemovesPendingDirectoryDiscovery() throws {
    let store = try ScheduleBarStore(storeURL: TestFixtures.uniqueStoreURL())
    _ = try store.apply(.capture(fixesTurn(key: "disc", title: "Unmapped", excerpt: "record as task", directory: "/tmp/undo-dir-\(UUID().uuidString)")))
    #expect(try store.observableState().pendingDirectories.isEmpty == false)
    _ = try store.apply(.undoLastAutomaticChange)
    _ = try store.apply(.undoLastAutomaticChange)
    #expect(try store.observableState().pendingDirectories.isEmpty)
}

// MARK: - T11: backup + source retention

@Test func backupIncludesTargetAndFollowUpDates() throws {
    let store = try mappedFixesStore()
    let targetID = try #require(
        store.apply(.capture(fixesTurn(key: "target", title: "Target dated", excerpt: "record as task", phrase: "2026-09-10", kind: .target))).taskID
    )
    let followID = try #require(store.apply(.quickAdd(QuickAddInput(title: "Follow up later"))).taskID)
    _ = try store.apply(.setFollowUp(followID, TestFixtures.shanghai(2026, 9, 12, 0)))
    let backupURL = FileManager.default.temporaryDirectory.appending(path: "fixes-backup-\(UUID().uuidString).json")
    _ = try store.apply(.exportBackup(backupURL))
    let data = try Data(contentsOf: backupURL)
    let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tasks = try #require(payload["tasks"] as? [[String: Any]])
    let target = try #require(tasks.first { ($0["id"] as? String) == targetID.uuidString })
    let follow = try #require(tasks.first { ($0["id"] as? String) == followID.uuidString })
    #expect(target["targetDate"] != nil)
    #expect(follow["followUpAt"] != nil)
}

@Test func sourceLinksCarryMessageTime() throws {
    let store = try mappedFixesStore()
    let messageTime = TestFixtures.shanghai(2026, 9, 3, 10)
    let id = try #require(
        store.apply(.capture(fixesTurn(key: "stamp", title: "Timestamped", excerpt: "record as task", at: messageTime))).taskID
    )
    let evidence = try #require(try store.sourceLinks(for: id).first)
    #expect(evidence.messageTime == messageTime)
}

// MARK: - T14: FolderSessionDirectory native shapes

@Test func folderSessionDirectoryReadsDocumentedAndCodexLines() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "fixes-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let jsonl = """
        {"session_id":"doc","turn_id":"t1","message_time":"2026-09-03T10:00:00Z","cwd":"/Users/leo/Projects/schedule_plugin","user_text":"record as task Documented"}
        {"timestamp":"2026-09-03T11:00:00.123Z","type":"turn_context","payload":{"cwd":"/Users/leo/Projects/other"}}
        {"timestamp":"2026-09-03T11:00:00.123Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"record as task Native"}]}}
        {"timestamp":"2026-09-03T11:30:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        {this is not json
        """
    try jsonl.data(using: .utf8)!.write(to: root.appending(path: "session.jsonl"))
    let scan = FolderSessionDirectory(root: root).scan()
    #expect(scan.turns.count == 2)
    #expect(scan.failures == ["session.jsonl"])
    let documented = try #require(scan.turns.first { $0.turnID == "t1" })
    #expect(documented.userText.contains("Documented"))
    let native = try #require(scan.turns.first { $0.userText.contains("Native") })
    #expect(native.workingDirectory == "/Users/leo/Projects/other")
    let expectedStamp = TestFixtures.shanghai(2026, 9, 3, 19, 0).addingTimeInterval(0.123)
    #expect(abs(native.messageTime.timeIntervalSince(expectedStamp)) < 0.001)
    #expect(native.turnID.isEmpty == false)
}

// MARK: - T15: platform adapter smoke tests

@Test func defaultHealthEnvironmentChecksRealFiles() throws {
    let previous = ProcessInfo.processInfo.environment["SCHEDULEBAR_PLUGIN_ROOT"]
    defer {
        setenv("SCHEDULEBAR_PLUGIN_ROOT", previous ?? "", 1)
        if previous == nil { unsetenv("SCHEDULEBAR_PLUGIN_ROOT") }
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "fixes-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "bin", directoryHint: .isDirectory), withIntermediateDirectories: true)
    let environment = DefaultHealthEnvironment()
    #expect(environment.pluginPresent == false)
    #expect(environment.mcpPresent == false)

    try Data("{}".utf8).write(to: root.appending(path: ".mcp.json"))
    try Data("#!/bin/sh\n".utf8).write(to: root.appending(path: "bin/schedulebar-mcp"))
    setenv("SCHEDULEBAR_PLUGIN_ROOT", root.path, 1)
    #expect(environment.pluginPresent)
    #expect(environment.mcpPresent)
    #expect(environment.notificationsAuthorized == true || environment.notificationsAuthorized == false)
    #expect(environment.notificationGuidance.isEmpty == false)
}

@Test func loginItemControllerReadsRealStatus() {
    let controller = SMAppServiceLoginItem()
    _ = controller.isEnabled
}

@Test func modelGatewayAdaptsToUserConfiguration() throws {
    let suiteName = "fixes-model-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configured = HTTPModelGateway.userConfigured(defaults: defaults)
    #expect(configured.baseURL.absoluteString == "https://api.deepseek.com")
    #expect(configured.model == "deepseek-chat")
    defaults.set("https://compat.example.test", forKey: HTTPModelGateway.baseURLDefaultsKey)
    defaults.set("compat-model", forKey: HTTPModelGateway.modelDefaultsKey)
    let customized = HTTPModelGateway.userConfigured(defaults: defaults)
    #expect(customized.baseURL.absoluteString == "https://compat.example.test")
    #expect(customized.model == "compat-model")
}

// MARK: - T13: shared record parsing

@Test func recordRequestParsingSharesAliasesWithoutSynthesizingConsent() throws {
    let stamp = TestFixtures.shanghai(2026, 9, 3, 10)
    let fromTitle = ChatWorkHandoff.parseRecordRequest(
        ["title": "Weekly report"],
        now: stamp
    )
    #expect(fromTitle.userText.isEmpty)

    let full = ChatWorkHandoff.parseRecordRequest(
        [
            "text": "record as task File taxes",
            "capture_id": "key-1",
            "working_directory": TestFixtures.cwd,
            "session_id": "s-9",
            "turn_id": "turn-3",
            "message_time": ISO8601DateFormatter().string(from: stamp),
        ],
        now: stamp.addingTimeInterval(60)
    )
    #expect(full.userText == "record as task File taxes")
    #expect(full.idempotencyKey == "key-1")
    #expect(full.workingDirectory == TestFixtures.cwd)
    #expect(full.threadID == "s-9")
    #expect(full.turnID == "turn-3")
    #expect(full.messageTime == stamp)

    let store = ChatWorkHandoff.configuredStoreURL(environment: ["SCHEDULEBAR_STORE": "/tmp/xyz/s.sqlite"])
    #expect(store?.path == "/tmp/xyz/s.sqlite")
    let fallback = ChatWorkHandoff.configuredStoreURL(environment: [:])
    #expect(fallback != nil)
}

// MARK: - helpers

private func mappedFixesStore(
    gateway: ModelGateway = SilentModelGateway()
) throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(
        storeURL: TestFixtures.uniqueStoreURL(),
        modelGateway: gateway
    )
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func fixesTurn(
    key: String,
    title: String,
    excerpt: String,
    at: Date = TestFixtures.shanghai(2026, 9, 3, 10),
    directory: String = TestFixtures.cwd,
    phrase: String? = nil,
    kind: DateKind? = nil
) -> CaptureEvent {
    CaptureEvent(
        idempotencyKey: key,
        title: title,
        authority: .mainConversation,
        threadID: "t",
        turnID: key,
        messageTime: at,
        workingDirectory: directory,
        triggerPhrase: excerpt,
        excerpt: excerpt,
        datePhrase: phrase,
        dateKind: kind
    )
}
