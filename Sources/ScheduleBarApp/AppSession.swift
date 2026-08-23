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
        self.state = try store.observableState()
    }

    convenience init() throws {
        try self.init(store: ScheduleBarStore(storeURL: StoreLocation.fileURL()))
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

    func refresh() {
        do {
            state = try store.observableState()
            errorMessage = nil
        } catch {
            errorMessage = "Could not read tasks."
        }
    }
}
