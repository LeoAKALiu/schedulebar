import ScheduleBar
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
            if let badge = menuBadge(session.state) {
                Label(badge, systemImage: "checklist")
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

private func menuBadge(_ state: ObservableState) -> String? {
    var parts: [String] = []
    if state.overdueCount > 0 { parts.append("!\(state.overdueCount)") }
    if state.todayCount > 0 { parts.append("\(state.todayCount)") }
    if state.candidateCount > 0 { parts.append("\(state.candidateCount)") }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
