import SwiftUI

@main
struct ScheduleBarApp: App {
    @StateObject private var session: AppSession

    init() {
        let session: AppSession
        do {
            session = try AppSession()
        } catch {
            fatalError("ScheduleBar could not open its local store.")
        }
        _session = StateObject(wrappedValue: session)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(session: session)
        } label: {
            if session.state.candidateCount > 0 {
                Label("\(session.state.candidateCount)", systemImage: "checklist")
            } else {
                Label("ScheduleBar", systemImage: "checklist")
            }
        }
        Window("ScheduleBar", id: "console") {
            ConsoleView(session: session)
                .frame(minWidth: 720, minHeight: 420)
        }
        Window("Quick Add", id: "quick-add") {
            QuickAddView(session: session)
        }
        .windowResizability(.contentSize)
    }
}
