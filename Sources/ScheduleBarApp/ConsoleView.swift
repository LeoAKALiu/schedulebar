import AppKit
import ScheduleBar
import SwiftUI

struct ConsoleView: View {
    @ObservedObject var session: AppSession
    @State private var selectedSection: ConsoleSection = .all
    @State private var selectedTaskID: TaskSummary.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Text("All tasks").tag(ConsoleSection.all)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } content: {
            List(session.state.consoleTasks, selection: $selectedTaskID) { task in
                Text(task.title).tag(task.id)
            }
            .navigationTitle("Tasks")
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            if let task = session.state.consoleTasks.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(task: task)
            } else {
                Text("Select a task")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            session.refresh()
            if selectedTaskID == nil {
                selectedTaskID = session.state.consoleTasks.first?.id
            }
        }
    }
}

private enum ConsoleSection: Hashable {
    case all
}

private struct TaskDetailView: View {
    let task: TaskSummary

    var body: some View {
        Form {
            LabeledContent("Title", value: task.title)
            LabeledContent("Notes", value: task.notes ?? "—")
            LabeledContent("Local path") {
                if let localPath = task.localPath {
                    Button(localPath) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: localPath),
                        ])
                    }
                    .buttonStyle(.link)
                } else {
                    Text("—")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
