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
                Text("Archive").tag(ConsoleSection.archive)
                Text("Trash").tag(ConsoleSection.trash)
                Text("History").tag(ConsoleSection.history)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } content: {
            if selectedSection == .history {
                List(session.state.history) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.summary)
                        Text(entry.isAutomatic ? "Automatic" : "Human")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("History")
            } else {
                List(listedItems, selection: $selectedTaskID) { task in
                    Text(task.title).tag(task.id)
                }
                .navigationTitle("Tasks")
            }
        } detail: {
            if selectedSection == .history {
                Button("Undo last automatic change") {
                    session.undoAutomatic()
                }
                .padding()
            } else if let task = listedItems.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(
                    task: task,
                    isCandidate: selectedSection == .candidates,
                    evidence: selectedSection == .all ? session.evidence(for: task.id) : nil
                ) {
                    session.confirmCandidate(task.id)
                } reject: {
                    session.rejectCandidate(task.id)
                } archive: {
                    session.archive(task.id)
                } trash: {
                    session.trash(task.id)
                } restore: {
                    session.restore(task.id)
                } delete: {
                    session.permanentlyDelete(task.id)
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
        switch selectedSection {
        case .candidates: return session.state.candidates
        case .archive: return session.state.archived
        case .trash: return session.state.trash
        case .all, .history: return session.state.consoleTasks
        }
    }

}

private enum ConsoleSection: Hashable {
    case all
    case candidates
    case archive
    case trash
    case history
}

private struct TaskDetailView: View {
    let task: TaskSummary
    var isCandidate = false
    var evidence: SourceEvidence?
    var confirm: () -> Void = {}
    var reject: () -> Void = {}
    var archive: () -> Void = {}
    var trash: () -> Void = {}
    var restore: () -> Void = {}
    var delete: () -> Void = {}

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
            } else {
                Button("Archive", action: archive)
                Button("Move to Trash", action: trash)
                Button("Restore", action: restore)
                Button("Delete permanently", role: .destructive, action: delete)
            }
            if let evidence {
                DisclosureGroup("Source evidence") {
                    LabeledContent("Trigger", value: evidence.triggerPhrase)
                    LabeledContent("Excerpt", value: evidence.excerpt)
                    LabeledContent("Directory", value: evidence.workingDirectory)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
