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
                ForEach(session.state.projects) { project in
                    Text(project.name).tag(ConsoleSection.project(project.id))
                }
                ForEach(session.state.pendingDirectories) { discovery in
                    Text("New: \(discovery.normalizedPath)").tag(ConsoleSection.pending(discovery.normalizedPath))
                }
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
            } else if case .pending(let path) = selectedSection {
                DirectoryReviewView(path: path, session: session)
            } else if let task = listedItems.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(
                    task: task,
                    session: session,
                    isCandidate: selectedSection == .candidates,
                    evidence: showsEvidence ? session.evidence(for: task.id) : nil
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
        case .project(let id):
            return session.state.consoleTasks.filter { $0.projectID == id }
        case .all, .history, .pending:
            return session.state.consoleTasks
        }
    }

    private var showsEvidence: Bool {
        switch selectedSection {
        case .all, .project: return true
        default: return false
        }
    }

}

private enum ConsoleSection: Hashable {
    case all
    case candidates
    case archive
    case trash
    case history
    case project(UUID)
    case pending(String)
}

private struct DirectoryReviewView: View {
    let path: String
    @ObservedObject var session: AppSession
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Codex directory")
                .font(.headline)
            Text(path)
                .textSelection(.enabled)
            TextField("Project name", text: $name)
            Button("Create project") {
                let title = name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name
                session.createProject(for: path, name: title)
            }
            ForEach(session.state.projects) { project in
                Button("Link to \(project.name)") {
                    session.linkDirectory(path, to: project.id)
                }
            }
            Button("Ignore") {
                session.ignoreDirectory(path)
            }
        }
        .padding()
        .onAppear {
            if name.isEmpty { name = URL(fileURLWithPath: path).lastPathComponent }
        }
    }
}

private struct TaskDetailView: View {
    let task: TaskSummary
    @ObservedObject var session: AppSession
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
            LabeledContent("Owner", value: task.ownerName ?? "—")
            LabeledContent("Status", value: task.status.rawValue)
            LabeledContent("Notes", value: task.notes ?? "—")
            if let phrase = task.datePhrase {
                LabeledContent("Date", value: phrase)
            }
            if task.isOverdue {
                Text("Overdue")
                    .foregroundStyle(.red)
            }
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
                Button("In progress") { session.setStatus(task.id, .inProgress) }
                Button("Waiting on other") { session.setStatus(task.id, .waitingOnOther) }
                Button("Blocked") { session.setStatus(task.id, .blocked) }
                Button("Pending acceptance") { session.setStatus(task.id, .pendingAcceptance) }
                Button("Complete") { session.setStatus(task.id, .completed) }
                ForEach(session.state.owners) { owner in
                    Button("Assign \(owner.name)") { session.setOwner(task.id, owner) }
                }
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
