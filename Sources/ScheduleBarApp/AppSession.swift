import Foundation
import ScheduleBar
import SwiftUI

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var state: ObservableState
    @Published var errorMessage: String?
    @Published var candidateEditorID: TaskSummary.ID?
    @Published var directoryToReview: String?

    private let store: ScheduleBarStore
    private var captureRefreshRunning = false

    init(store: ScheduleBarStore) throws {
        self.store = store
        _ = store.processInbox()
        _ = store.reconcileSessions()
        _ = store.processDueReminders()
        _ = store.processRecurrences()
        self.state = try store.observableState()
        startReminderPolling()
    }

    convenience init() throws {
        let notifier = AppDirectoryNotifier()
        try self.init(
            store: ScheduleBarStore(
                storeURL: StoreLocation.fileURL(),
                notifier: notifier,
                reminderNotifier: AppReminderNotifier(),
                modelGateway: HTTPModelGateway.userConfigured(),
                secretStore: KeychainSecretStore(),
                sessionDirectory: FolderSessionDirectory(
                    root: (try? StoreLocation.sessionDirectoryURL())
                        ?? FileManager.default.temporaryDirectory.appending(path: "schedulebar-sessions")
                ),
                healthEnvironment: DefaultHealthEnvironment(),
                loginItems: SMAppServiceLoginItem()
            )
        )
        notifier.setReviewHandler { [weak self] path, action in
            guard let self else { return }
            Task { @MainActor in
                switch action {
                case .ignore:
                    self.perform(.resolveDirectory(path, .ignore), failure: "Could not ignore the directory.")
                case .review, .createProject, .linkProject:
                    self.beginDirectoryReview(path)
                }
            }
        }
    }

    func quickAdd(title: String, notes: String, localPath: String) {
        errorMessage = nil
        do {
            _ = try store.apply(
                .quickAdd(
                    QuickAddInput(
                        title: title,
                        notes: notes,
                        localPath: localPath
                    )
                )
            )
            state = try store.observableState()
        } catch ScheduleBarError.emptyTitle {
            errorMessage = "Title is required."
        } catch {
            errorMessage = "Could not save the task."
        }
    }

    func editTask(_ id: TaskSummary.ID, title: String, notes: String, localPath: String) {
        perform(
            .editTask(id, QuickAddInput(title: title, notes: notes, localPath: localPath)),
            failure: "Could not save the task."
        )
    }

    func confirmCandidate(_ id: TaskSummary.ID) {
        perform(.reviewCandidate(id, .confirm), failure: "Could not confirm the candidate.")
    }

    func beginEditingCandidate(_ id: TaskSummary.ID) {
        candidateEditorID = id
    }

    func editCandidate(_ id: TaskSummary.ID, title: String, notes: String, localPath: String) {
        perform(
            .reviewCandidate(id, .edit(QuickAddInput(title: title, notes: notes, localPath: localPath))),
            failure: "Could not save the candidate."
        )
    }

    func rejectCandidate(_ id: TaskSummary.ID) {
        perform(.reviewCandidate(id, .reject), failure: "Could not reject the candidate.")
    }

    func archive(_ id: TaskSummary.ID) {
        perform(.archive(id), failure: "Could not archive the task.")
    }

    func trash(_ id: TaskSummary.ID) {
        perform(.trash(id), failure: "Could not move the task to trash.")
    }

    func restore(_ id: TaskSummary.ID) {
        perform(.restoreFromTrash(id), failure: "Could not restore the task.")
    }

    func permanentlyDelete(_ id: TaskSummary.ID) {
        perform(.permanentlyDelete(id), failure: "Could not delete the task.")
    }

    func undoAutomatic() {
        perform(.undoLastAutomaticChange, failure: "Could not undo the last automatic change.")
    }

    func createProject(for path: String, name: String) {
        perform(.resolveDirectory(path, .create(name: name)), failure: "Could not create the project.")
    }

    func linkDirectory(_ path: String, to projectID: UUID) {
        perform(.resolveDirectory(path, .link(projectID: projectID)), failure: "Could not link the directory.")
    }

    func ignoreDirectory(_ path: String) {
        perform(.resolveDirectory(path, .ignore), failure: "Could not ignore the directory.")
    }

    func beginDirectoryReview(_ path: String) {
        directoryToReview = path
        NotificationCenter.default.post(name: AppDirectoryNotifier.openConsoleNotification, object: nil)
    }

    func evidence(for id: TaskSummary.ID) -> SourceEvidence? {
        try? store.sourceEvidence(for: id)
    }

    func evidenceLinks(for id: TaskSummary.ID) -> [SourceEvidence] {
        (try? store.sourceLinks(for: id)) ?? []
    }

    func setStatus(_ id: TaskSummary.ID, _ status: WorkflowStatus) {
        perform(.setStatus(id, status), failure: "Could not change status.")
    }

    func setOwner(_ id: TaskSummary.ID, _ owner: OwnerSummary) {
        perform(.setOwner(id, owner.name, owner.kind), failure: "Could not assign the owner.")
    }

    func acceptPlan(_ id: UUID, _ itemIDs: [UUID]) {
        perform(.acceptPlan(id, itemIDs), failure: "Could not accept the plan.")
    }

    func setPriority(_ id: TaskSummary.ID, _ priority: BusinessPriority) {
        perform(.setPriority(id, priority), failure: "Could not change priority.")
    }

    func setBlockedBy(_ id: TaskSummary.ID, _ blockerID: UUID) {
        perform(.setBlockedBy(id, blockerID), failure: "Could not set the blocker.")
    }

    func removeBlockedBy(_ id: TaskSummary.ID, _ blockerID: UUID) {
        perform(.removeBlockedBy(id, blockerID), failure: "Could not remove the blocker.")
    }

    func addTag(_ id: TaskSummary.ID, _ tag: String) {
        perform(.addTag(id, tag), failure: "Could not add the tag.")
    }

    func confirmAlias(_ alias: String, for owner: OwnerSummary) {
        perform(.confirmAlias(alias, owner.id), failure: "Could not confirm the alias.")
    }

    func setReminders(_ id: TaskSummary.ID, _ fires: [Date]) {
        perform(.setReminders(id, fires), failure: "Could not update reminders.")
    }

    func addReminder(_ id: TaskSummary.ID, at date: Date) {
        var fires = reminders(for: id).map(\.fireAt)
        fires.append(date)
        setReminders(id, fires)
    }

    func removeReminder(_ id: TaskSummary.ID, reminderID: UUID) {
        let current = reminders(for: id)
        let fires = current.filter { $0.id != reminderID }.map(\.fireAt)
        setReminders(id, fires)
    }

    func reminders(for id: TaskSummary.ID) -> [Reminder] {
        (try? store.reminders(for: id)) ?? []
    }

    var candidateBeingEdited: TaskSummary? {
        guard let candidateEditorID else { return nil }
        return state.candidates.first { $0.id == candidateEditorID }
    }

    func setModelAPIKey(_ key: String) {
        perform(.setModelAPIKey(key), failure: "Could not save the model key.")
    }

    func clearModelAPIKey() {
        perform(.clearModelAPIKey, failure: "Could not clear the model key.")
    }

    func stopRecurrence(_ id: UUID) {
        perform(.stopRecurrence(id), failure: "Could not stop recurrence.")
    }

    func retryFailures() {
        perform(.retryFailures, failure: "Could not retry failed operations.")
        Task {
            await store.processModelMisses()
            refresh()
        }
    }

    func setLoginAtStartup(_ enabled: Bool) {
        perform(.setLoginAtStartup(enabled), failure: "Could not update the login item.")
    }

    func exportDiagnostics() {
        errorMessage = nil
        do {
            let url = try ScheduleBarPaths.diagnosticsURL()
            _ = try store.apply(.exportDiagnostics(url))
            refresh()
        } catch {
            errorMessage = "Could not export diagnostics."
        }
    }

    func exportBackup() {
        errorMessage = nil
        do {
            let url = try ScheduleBarPaths.backupURL()
            _ = try store.apply(.exportBackup(url), authority: .human)
            refresh()
        } catch {
            errorMessage = "Could not export backup."
        }
    }

    func refresh() {
        do {
            _ = store.processInbox()
            _ = store.reconcileSessions()
            _ = store.processDueReminders()
            _ = store.processRecurrences()
            state = try store.observableState()
        } catch {
            errorMessage = "Could not read tasks."
        }
    }

    private func perform(_ event: InputEvent, failure: String) {
        errorMessage = nil
        do {
            _ = try store.apply(event, authority: .human)
            state = try store.observableState()
        } catch ScheduleBarError.emptyTitle {
            errorMessage = "Title is required."
        } catch ScheduleBarError.notPermitted {
            errorMessage = failure
        } catch ScheduleBarError.notFound {
            errorMessage = failure
        } catch {
            errorMessage = failure
        }
    }

    private func startReminderPolling() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.captureRefreshRunning else { return }
                self.captureRefreshRunning = true
                let store = self.store
                Task.detached(priority: .utility) {
                    _ = store.processInbox()
                    let latest = try? store.observableState()
                    await MainActor.run {
                        if let latest { self.state = latest }
                        self.captureRefreshRunning = false
                    }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.processModelMisses()
                self?.refresh()
            }
        }
    }
}
