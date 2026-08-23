import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if session.state.candidateCount > 0 {
            Text("Candidates (\(session.state.candidateCount))")
            ForEach(session.state.candidates) { candidate in
                Menu(candidate.title) {
                    Button("Confirm") { session.confirmCandidate(candidate.id) }
                    Button("Reject", role: .destructive) { session.rejectCandidate(candidate.id) }
                }
            }
            Divider()
        }
        if !session.state.overdue.isEmpty {
            Text("Overdue (\(session.state.overdueCount))")
            ForEach(session.state.overdue) { task in
                Text(task.title)
            }
            Divider()
        }
        if !session.state.today.isEmpty {
            Text("Today (\(session.state.todayCount))")
            ForEach(session.state.today) { task in
                Text(task.title)
            }
            Divider()
        }
        if !session.state.nextSevenDays.isEmpty {
            Text("Next 7 days")
            ForEach(session.state.nextSevenDays) { task in
                Text(task.title)
            }
            Divider()
        }
        if session.state.menuTasks.isEmpty {
            Text("No tasks yet")
        } else if !session.state.unscheduledMenuTasks.isEmpty {
            ForEach(session.state.unscheduledMenuTasks) { task in
                Text(task.title)
            }
        }
        Divider()
        Button("Quick Add…") {
            openWindow(id: "quick-add")
        }
        Button("Open Console") {
            openWindow(id: "console")
        }
        Divider()
        Button("Quit ScheduleBar") {
            NSApplication.shared.terminate(nil)
        }
    }
}
