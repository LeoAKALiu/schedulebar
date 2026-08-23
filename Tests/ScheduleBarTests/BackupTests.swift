import Foundation
import ScheduleBar
import Testing

@Test func exportContainsDomainObjectsWithoutRawDatabaseShape() throws {
    let store = try mappedBackupStore()
    let blocker = try #require(store.apply(.quickAdd(QuickAddInput(title: "Schema"))).taskID)
    let task = try #require(store.apply(.quickAdd(QuickAddInput(title: "Feature"))).taskID)
    _ = try store.apply(.setOwner(task, "Leo", .person))
    _ = try store.apply(.setPriority(task, .high))
    _ = try store.apply(.setBlockedBy(task, blocker))
    _ = try store.apply(.setReminders(task, [shanghai(2026, 9, 4, 9)]))
    _ = try store.apply(.setRecurrence(blocker, .daily))
    let plan = PlanProposal(
        idempotencyKey: "backup-plan",
        threadID: "thread-b",
        turnID: "turn-b",
        workingDirectory: TestFixtures.cwd,
        items: [
            PlanItem(id: UUID(), title: "Ship milestone", kind: .milestone, necessary: true),
        ]
    )
    _ = try store.apply(.proposePlan(plan), authority: .mainConversation)
    let draftID = try #require(store.observableState().plans.first?.id)
    _ = try store.apply(.acceptPlan(draftID, plan.items.map(\.id)))

    let backupURL = uniqueBackupURL()
    let receipt = try store.apply(.exportBackup(backupURL))
    #expect(receipt.outcome == .recorded)
    let json = try backupJSON(backupURL)
    #expect(json["projects"] is [[String: Any]])
    #expect(json["tasks"] is [[String: Any]])
    #expect(json["milestones"] is [[String: Any]])
    #expect(json["owners"] is [[String: Any]])
    #expect(json["reminders"] is [[String: Any]])
    #expect(json["dependencies"] is [[String: Any]])
    #expect(json["recurrences"] is [[String: Any]])
    #expect(json["history"] is [[String: Any]])
    #expect(json["sources"] is [[String: Any]])
    #expect(json["tables"] == nil)
    #expect(json["sqlite"] == nil)
    let tasks = try #require(json["tasks"] as? [[String: Any]])
    #expect(tasks.contains { ($0["title"] as? String) == "Feature" })
    let milestones = try #require(json["milestones"] as? [[String: Any]])
    #expect(milestones.contains { ($0["title"] as? String) == "Ship milestone" })
}

@Test func decoyCaptureFieldsNeverReachStoreOrBackup() throws {
    let url = uniqueBackupStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    try TestFixtures.mapDefaultDirectory(store)
    let event = CaptureEvent(
        idempotencyKey: "decoy-1",
        title: "Ship notes",
        authority: .mainConversation,
        threadID: "thread-secret",
        turnID: "turn-secret",
        messageTime: shanghai(2026, 9, 4, 9),
        workingDirectory: TestFixtures.cwd,
        triggerPhrase: "record as task",
        excerpt: "record as task ship notes"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var payload = try #require(try JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any])
    payload["conversation"] = "FULL CHAT DUMP with every prior turn"
    payload["attachments"] = "private.pdf binary blob"
    payload["toolOutput"] = "tool stdout from apply_patch"
    payload["reasoning"] = "hidden chain of thought"
    payload["apiKey"] = "sk-secretTESTKEY999"
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
        CaptureEvent.self,
        from: JSONSerialization.data(withJSONObject: payload)
    )
    let retainedPayload = String(decoding: try encoder.encode(decoded), as: UTF8.self)
    #expect(retainedPayload.contains("FULL CHAT DUMP") == false)
    #expect(retainedPayload.contains("sk-secretTESTKEY999") == false)
    _ = try store.apply(.capture(decoded))

    let sqliteText = sqliteHaystack(url)
    #expect(sqliteText.contains("FULL CHAT DUMP") == false)
    #expect(sqliteText.contains("private.pdf") == false)
    #expect(sqliteText.contains("tool stdout from apply_patch") == false)
    #expect(sqliteText.contains("hidden chain of thought") == false)
    #expect(sqliteText.contains("sk-secretTESTKEY999") == false)

    let backupURL = uniqueBackupURL()
    _ = try store.apply(.exportBackup(backupURL))
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    #expect(backupText.contains("FULL CHAT DUMP") == false)
    #expect(backupText.contains("private.pdf") == false)
    #expect(backupText.contains("tool stdout from apply_patch") == false)
    #expect(backupText.contains("hidden chain of thought") == false)
    #expect(backupText.contains("sk-secretTESTKEY999") == false)
    #expect(backupText.contains("conversation") == false)
    #expect(backupText.contains("apiKey") == false)

    let taskID = try #require(store.observableState().tasks.first?.id)
    let evidence = try store.sourceEvidence(for: taskID)
    #expect(evidence?.threadID == "thread-secret")
    #expect(evidence?.turnID == "turn-secret")
    #expect(evidence?.triggerPhrase == "record as task")
    #expect(evidence?.workingDirectory == TestFixtures.cwd)
}

@Test func secretLikeValuesAreRedactedFromTitleHistoryAndBackup() throws {
    let url = uniqueBackupStoreURL()
    let store = try ScheduleBarStore(storeURL: url)
    let id = try #require(
        store.apply(.quickAdd(QuickAddInput(title: "Rotate sk-secretTESTKEY999", notes: "key=sk-secretTESTKEY999"))).taskID
    )
    let task = try #require(store.observableState().tasks.first { $0.id == id })
    #expect(task.title.contains("sk-secretTESTKEY999") == false)
    #expect(task.title.contains("[redacted]"))
    #expect(task.notes?.contains("sk-secretTESTKEY999") == false)
    let backupURL = uniqueBackupURL()
    _ = try store.apply(.exportBackup(backupURL))
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    #expect(backupText.contains("sk-secretTESTKEY999") == false)
    #expect(sqliteHaystack(url).contains("sk-secretTESTKEY999") == false)
}

@Test func backupFileUsesOwnerOnlyPermissions() throws {
    let store = try mappedBackupStore()
    _ = try store.apply(.quickAdd(QuickAddInput(title: "Keep")))
    let backupURL = uniqueBackupURL()
    _ = try store.apply(.exportBackup(backupURL))
    let perms = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
    #expect((perms?.intValue ?? 0) & 0o077 == 0)
}

private func mappedBackupStore() throws -> ScheduleBarStore {
    let store = try ScheduleBarStore(storeURL: uniqueBackupStoreURL())
    try TestFixtures.mapDefaultDirectory(store)
    return store
}

private func backupJSON(_ url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
}

private func sqliteHaystack(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func shanghai(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func uniqueBackupStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "schedulebar.sqlite")
}

private func uniqueBackupURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ScheduleBarBackup-\(UUID().uuidString).json")
}
