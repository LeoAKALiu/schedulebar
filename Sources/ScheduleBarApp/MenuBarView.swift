import AppKit
import ScheduleBar
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
                TaskStatusMenu(task: task, session: session)
            }
            Divider()
        }
        if !session.state.today.isEmpty {
            Text("Today (\(session.state.todayCount))")
            ForEach(session.state.today) { task in
                TaskStatusMenu(task: task, session: session)
            }
            Divider()
        }
        if !session.state.nextSevenDays.isEmpty {
            Text("Next 7 days")
            ForEach(session.state.nextSevenDays) { task in
                TaskStatusMenu(task: task, session: session)
            }
            Divider()
        }
        if !session.state.waitingOnOthers.isEmpty {
            Text("Waiting on others (\(session.state.waitingOnOthers.count))")
            ForEach(session.state.waitingOnOthers) { task in
                TaskStatusMenu(task: task, session: session)
            }
            Divider()
        }
        if session.state.menuTasks.isEmpty {
            Text("No tasks yet")
        } else if !session.state.unscheduledMenuTasks.isEmpty {
            ForEach(session.state.unscheduledMenuTasks) { task in
                TaskStatusMenu(task: task, session: session)
            }
        }
        Divider()
        Text(CapturePolicy.chatWorkHelpText)
        Divider()
        Button("Quick Add…") {
            openWindow(id: "quick-add")
        }
        Button("Open Console") {
            openWindow(id: "console")
        }
        Button("Export JSON backup") {
            session.exportBackup()
        }
        Divider()
        Button("Quit ScheduleBar") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct TaskStatusMenu: View {
    let task: TaskSummary
    @ObservedObject var session: AppSession

    var body: some View {
        Menu(task.title) {
            Button("Not started") { session.setStatus(task.id, .notStarted) }
            Button("In progress") { session.setStatus(task.id, .inProgress) }
            Button("Waiting on other") { session.setStatus(task.id, .waitingOnOther) }
            Button("Blocked") { session.setStatus(task.id, .blocked) }
            Button("Pending acceptance") { session.setStatus(task.id, .pendingAcceptance) }
            Button("Complete") { session.setStatus(task.id, .completed) }
            Button("Cancel", role: .destructive) { session.setStatus(task.id, .cancelled) }
            Divider()
            Button("Priority: low") { session.setPriority(task.id, .low) }
            Button("Priority: normal") { session.setPriority(task.id, .normal) }
            Button("Priority: high") { session.setPriority(task.id, .high) }
            Button("Priority: critical") { session.setPriority(task.id, .critical) }
            Divider()
            ForEach(session.state.owners) { owner in
                Button(owner.name) { session.setOwner(task.id, owner) }
            }
        }
    }
}
