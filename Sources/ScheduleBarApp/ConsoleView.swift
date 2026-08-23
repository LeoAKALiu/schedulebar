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
                Text("Candidates (\(session.state.candidateCount))").tag(ConsoleSection.candidates)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } content: {
            List(listedItems, selection: $selectedTaskID) { task in
                Text(task.title).tag(task.id)
            }
            .navigationTitle("Tasks")
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            if let task = listedItems.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(task: task, isCandidate: selectedSection == .candidates) {
                    session.confirmCandidate(task.id)
                } reject: {
                    session.rejectCandidate(task.id)
                }
            } else {
                Text("Select a task")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            session.refresh()
            if selectedTaskID == nil {
                selectedTaskID = listedItems.first?.id
            }
        }
    }

    private var listedItems: [TaskSummary] {
        selectedSection == .candidates ? session.state.candidates : session.state.consoleTasks
    }
}

private enum ConsoleSection: Hashable {
    case all
    case candidates
}

private struct TaskDetailView: View {
    let task: TaskSummary
    var isCandidate = false
    var confirm: () -> Void = {}
    var reject: () -> Void = {}

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
            if isCandidate {
                Button("Confirm", action: confirm)
                Button("Reject", role: .destructive, action: reject)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
