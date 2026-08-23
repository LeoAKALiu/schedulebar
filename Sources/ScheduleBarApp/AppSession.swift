import Foundation
import ScheduleBar
import SwiftUI

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var state: ObservableState
    @Published var errorMessage: String?

    private let store: ScheduleBarStore

    init(store: ScheduleBarStore) throws {
        self.store = store
        _ = store.processInbox()
        _ = store.processDueReminders()
        self.state = try store.observableState()
        startReminderPolling()
    }

    convenience init() throws {
        try self.init(
            store: ScheduleBarStore(
                storeURL: StoreLocation.fileURL(),
                notifier: AppDirectoryNotifier(),
                reminderNotifier: AppReminderNotifier()
            )
        )
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

    func confirmCandidate(_ id: TaskSummary.ID) {
        errorMessage = nil
        do {
            _ = try store.reviewCandidate(id, decision: .confirm)
            state = try store.observableState()
        } catch {
            errorMessage = "Could not confirm the candidate."
        }
    }

    func rejectCandidate(_ id: TaskSummary.ID) {
        errorMessage = nil
        do {
            _ = try store.reviewCandidate(id, decision: .reject)
            state = try store.observableState()
        } catch {
            errorMessage = "Could not reject the candidate."
        }
    }

    func archive(_ id: TaskSummary.ID) {
        _ = try? store.apply(.archive(id))
        refresh()
    }

    func trash(_ id: TaskSummary.ID) {
        _ = try? store.apply(.trash(id))
        refresh()
    }

    func restore(_ id: TaskSummary.ID) {
        _ = try? store.apply(.restoreFromTrash(id))
        refresh()
    }

    func permanentlyDelete(_ id: TaskSummary.ID) {
        _ = try? store.apply(.permanentlyDelete(id), authority: .human)
        refresh()
    }

    func undoAutomatic() {
        _ = try? store.apply(.undoLastAutomaticChange)
        refresh()
    }

    func createProject(for path: String, name: String) {
        _ = try? store.apply(.resolveDirectory(path, .create(name: name)))
        refresh()
    }

    func linkDirectory(_ path: String, to projectID: UUID) {
        _ = try? store.apply(.resolveDirectory(path, .link(projectID: projectID)))
        refresh()
    }

    func ignoreDirectory(_ path: String) {
        _ = try? store.apply(.resolveDirectory(path, .ignore))
        refresh()
    }

    func evidence(for id: TaskSummary.ID) -> SourceEvidence? {
        try? store.sourceEvidence(for: id)
    }

    func refresh() {
        do {
            _ = store.processDueReminders()
            state = try store.observableState()
            errorMessage = nil
        } catch {
            errorMessage = "Could not read tasks."
        }
    }

    private func startReminderPolling() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
