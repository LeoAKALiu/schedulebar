import AppKit
import ScheduleBar
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if session.state.candidateCount > 0 {
            Section("Candidates (\(session.state.candidateCount))") {
                ForEach(session.state.candidates) { candidate in
                    Menu {
                        Button {
                            session.confirmCandidate(candidate.id)
                        } label: {
                            Label("Confirm", systemImage: "checkmark.circle")
                        }
                        Button {
                            session.beginEditingCandidate(candidate.id)
                            openWindow(id: "candidate-edit")
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            session.rejectCandidate(candidate.id)
                        } label: {
                            Label("Reject", systemImage: "xmark.circle")
                        }
                    } label: {
                        Label(candidate.title, systemImage: "sparkles")
                    }
                }
            }
            Divider()
        }

        if !session.state.overdue.isEmpty {
            Section("Overdue (\(session.state.overdueCount))") {
                ForEach(session.state.overdue) { task in
                    TaskStatusMenu(task: task, session: session)
                }
            }
            Divider()
        }

        if !session.state.today.isEmpty {
            Section("Today (\(session.state.todayCount))") {
                ForEach(session.state.today) { task in
                    TaskStatusMenu(task: task, session: session)
                }
            }
            Divider()
        }

        if !session.state.nextSevenDays.isEmpty {
            Section("Next 7 Days (\(session.state.nextSevenDaysCount))") {
                ForEach(session.state.nextSevenDays) { task in
                    TaskStatusMenu(task: task, session: session)
                }
            }
            Divider()
        }

        if !session.state.waitingOnOthers.isEmpty {
            Section("Waiting on Others (\(session.state.waitingOnOthers.count))") {
                ForEach(session.state.waitingOnOthers) { task in
                    TaskStatusMenu(task: task, session: session)
                }
            }
            Divider()
        }

        if session.state.menuTasks.isEmpty && session.state.candidateCount == 0 {
            Text("No active tasks")
                .foregroundStyle(.secondary)
            Divider()
        } else if !session.state.unscheduledMenuTasks.isEmpty {
            Section("Other Tasks") {
                ForEach(session.state.unscheduledMenuTasks) { task in
                    TaskStatusMenu(task: task, session: session)
                }
            }
            Divider()
        }

        Section {
            Button {
                openWindow(id: "quick-add")
            } label: {
                Label("Quick Add…", systemImage: "plus.circle")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                openWindow(id: "console")
            } label: {
                Label("Open Console", systemImage: "macwindow")
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                session.exportBackup()
            } label: {
                Label("Export JSON Backup…", systemImage: "square.and.arrow.up")
            }

            Menu {
                Text(CapturePolicy.chatWorkHelpText)
                Divider()
                Text(CapturePolicy.localReconcileHelpText)
            } label: {
                Label("Capture Policy & Info", systemImage: "info.circle")
            }
        }

        Divider()

        Button(role: .destructive) {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit ScheduleBar", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

private struct TaskStatusMenu: View {
    let task: TaskSummary
    @ObservedObject var session: AppSession

    var body: some View {
        Menu {
            Menu {
                Button {
                    session.setStatus(task.id, .notStarted)
                } label: {
                    statusRow("Not started", isCurrent: task.status == .notStarted, icon: "circle")
                }
                Button {
                    session.setStatus(task.id, .inProgress)
                } label: {
                    statusRow("In progress", isCurrent: task.status == .inProgress, icon: "arrow.triangle.2.circlepath.circle")
                }
                Button {
                    session.setStatus(task.id, .waitingOnOther)
                } label: {
                    statusRow("Waiting on other", isCurrent: task.status == .waitingOnOther, icon: "person.crop.circle.badge.clock")
                }
                Button {
                    session.setStatus(task.id, .blocked)
                } label: {
                    statusRow("Blocked", isCurrent: task.status == .blocked, icon: "exclamationmark.octagon")
                }
                Button {
                    session.setStatus(task.id, .pendingAcceptance)
                } label: {
                    statusRow("Pending acceptance", isCurrent: task.status == .pendingAcceptance, icon: "hourglass.circle")
                }
                Button {
                    session.setStatus(task.id, .completed)
                } label: {
                    statusRow("Complete", isCurrent: task.status == .completed, icon: "checkmark.circle")
                }
                Button(role: .destructive) {
                    session.setStatus(task.id, .cancelled)
                } label: {
                    statusRow("Cancel", isCurrent: task.status == .cancelled, icon: "xmark.circle")
                }
            } label: {
                Label("Status: \(task.status.displayName)", systemImage: task.status.iconName)
            }

            Menu {
                Button {
                    session.setPriority(task.id, .low)
                } label: {
                    priorityRow("Priority: low", isCurrent: task.priority == .low, icon: "arrow.down")
                }
                Button {
                    session.setPriority(task.id, .normal)
                } label: {
                    priorityRow("Priority: normal", isCurrent: task.priority == .normal, icon: "minus")
                }
                Button {
                    session.setPriority(task.id, .high)
                } label: {
                    priorityRow("Priority: high", isCurrent: task.priority == .high, icon: "arrow.up")
                }
                Button {
                    session.setPriority(task.id, .critical)
                } label: {
                    priorityRow("Priority: critical", isCurrent: task.priority == .critical, icon: "exclamationmark.3")
                }
            } label: {
                Label("Priority: \(task.priority.shortName)", systemImage: task.priority.iconName)
            }

            if !session.state.owners.isEmpty {
                Menu {
                    ForEach(session.state.owners) { owner in
                        Button {
                            session.setOwner(task.id, owner)
                        } label: {
                            Label(
                                task.ownerID == owner.id ? "✓ \(owner.name)" : owner.name,
                                systemImage: owner.kind.iconName
                            )
                        }
                    }
                } label: {
                    Label("Owner: \(task.ownerName ?? "Unassigned")", systemImage: "person")
                }
            }

            Menu {
                Button {
                    session.addReminder(task.id, at: Date().addingTimeInterval(3600))
                } label: {
                    Label("Remind in 1 hour", systemImage: "clock")
                }
                Button {
                    session.addReminder(task.id, at: tomorrowAtNine())
                } label: {
                    Label("Remind tomorrow at 9:00", systemImage: "sun.max")
                }
                if !session.reminders(for: task.id).isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        session.setReminders(task.id, [])
                    } label: {
                        Label("Clear reminders", systemImage: "bell.slash")
                    }
                }
            } label: {
                Label("Reminders", systemImage: "bell")
            }

            Divider()

            if task.status != .completed {
                Button {
                    session.setStatus(task.id, .completed)
                } label: {
                    Label("Mark as Complete", systemImage: "checkmark.circle.fill")
                }
            } else {
                Button {
                    session.setStatus(task.id, .notStarted)
                } label: {
                    Label("Mark as Not Started", systemImage: "circle")
                }
            }
        } label: {
            Label(
                task.hasUnsatisfiedBlockers ? "⛔ \(task.title)" : task.title,
                systemImage: task.status.iconName
            )
        }
    }

    private func statusRow(_ title: String, isCurrent: Bool, icon: String) -> some View {
        Label(isCurrent ? "✓ \(title)" : title, systemImage: icon)
    }

    private func priorityRow(_ title: String, isCurrent: Bool, icon: String) -> some View {
        Label(isCurrent ? "✓ \(title)" : title, systemImage: icon)
    }

    private func tomorrowAtNine() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        return calendar.date(from: components) ?? tomorrow
    }
}
