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
                Text(CapturePolicy.chatWorkHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CapturePolicy.localReconcileHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("All tasks").tag(ConsoleSection.all)
                Text("Candidates (\(session.state.candidateCount))").tag(ConsoleSection.candidates)
                Text("Archive").tag(ConsoleSection.archive)
                Text("Trash").tag(ConsoleSection.trash)
                Text("History").tag(ConsoleSection.history)
                Text("Plans (\(session.state.plans.count))").tag(ConsoleSection.plans)
                Text("Milestones (\(session.state.milestones.count))").tag(ConsoleSection.milestones)
                Text("Recurrence (\(session.state.recurrences.count))").tag(ConsoleSection.recurrence)
                Text("Diagnostics").tag(ConsoleSection.diagnostics)
                ForEach(session.state.projects) { project in
                    Text(project.progressSummary.map { "\(project.name) — \($0)" } ?? project.name)
                        .tag(ConsoleSection.project(project.id))
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
            } else if selectedSection == .diagnostics {
                List {
                    Section("Components") {
                        ForEach(session.state.health) { item in
                            VStack(alignment: .leading) {
                                Text("\(item.name): \(item.ok ? "ok" : "attention")")
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Queue") {
                        Text("Pending inbox: \(session.state.pendingInboxCount)")
                    }
                    Section("Recent errors") {
                        ForEach(session.state.diagnostics) { item in
                            VStack(alignment: .leading) {
                                Text("\(item.component) \(item.code)")
                                Text(item.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(item.createdAt.formatted(date: .abbreviated, time: .standard)) · \(item.retryable ? "retryable" : "logged")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Model miss detection") {
                        ModelKeySection(session: session)
                    }
                    Section("Actions") {
                        Button("Retry failed operations") { session.retryFailures() }
                        Toggle("Open at login", isOn: loginBinding)
                        Button("Export diagnostics") { session.exportDiagnostics() }
                    }
                }
                .navigationTitle("Diagnostics")
            } else if selectedSection == .recurrence {
                List(session.state.recurrences) { series in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(series.title)
                        Text("\(series.rule.displayDescription) · \(series.isStopped ? "Stopped" : "Active")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !series.isStopped {
                            Button("Stop") { session.stopRecurrence(series.id) }
                        }
                    }
                }
                .navigationTitle("Recurrence")
            } else if selectedSection == .plans {
                List(session.state.plans) { plan in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.items) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Button("Accept") {
                                    session.acceptPlan(plan.id, [item.id])
                                }
                                .disabled(
                                    item.parentID.map { parentID in
                                        !session.state.tasks.contains { $0.id == parentID }
                                    } ?? false
                                )
                                .help(item.parentID == nil ? "Accept this item" : "Accept its parent first, or accept all")
                            }
                        }
                        Button("Accept all") {
                            session.acceptPlan(plan.id, plan.items.map(\.id))
                        }
                    }
                }
                .navigationTitle("Plans")
            } else {
                List(listedItems, selection: $selectedTaskID) { task in
                    Text(task.hasUnsatisfiedBlockers ? "⛔ \(task.title)" : task.title)
                        .tag(task.id)
                }
                .navigationTitle("Tasks")
            }
        } detail: {
            if selectedSection == .history {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Undo last automatic change") {
                        session.undoAutomatic()
                    }
                    Button("Export JSON backup") {
                        session.exportBackup()
                    }
                }
                .padding()
            } else if case .pending(let path) = selectedSection {
                DirectoryReviewView(path: path, session: session)
            } else if let task = listedItems.first(where: { $0.id == selectedTaskID }) {
                TaskDetailView(
                    task: task,
                    session: session,
                    isCandidate: isCandidate(task),
                    isTrash: selectedSection == .trash,
                    evidenceLinks: showsEvidence(for: task) ? session.evidenceLinks(for: task.id) : []
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
        .onChange(of: session.directoryToReview) { _, path in
            if let path {
                selectedSection = .pending(path)
            }
        }
        .overlay(alignment: .top) {
            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.background)
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
                + session.state.candidates.filter { $0.projectID == id }
        case .milestones: return session.state.milestones
        case .all, .history, .pending, .plans, .recurrence, .diagnostics:
            return session.state.consoleTasks
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { session.state.loginAtStartup },
            set: { session.setLoginAtStartup($0) }
        )
    }

    private func isCandidate(_ task: TaskSummary) -> Bool {
        session.state.candidates.contains { $0.id == task.id }
    }

    private func showsEvidence(for task: TaskSummary) -> Bool {
        switch selectedSection {
        case .all, .project, .candidates: return true
        default: return isCandidate(task)
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
    case plans
    case milestones
    case recurrence
    case diagnostics
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
    var isTrash = false
    var evidenceLinks: [SourceEvidence] = []
    var confirm: () -> Void = {}
    var reject: () -> Void = {}
    var archive: () -> Void = {}
    var trash: () -> Void = {}
    var restore: () -> Void = {}
    var delete: () -> Void = {}
    @State private var editTitle = ""
    @State private var editNotes = ""
    @State private var editPath = ""
    @State private var tagDraft = ""
    @State private var aliasDraft = ""

    var body: some View {
        Form {
            if isCandidate || !isTrash {
                TextField("Title", text: $editTitle)
                TextField("Notes", text: $editNotes)
                TextField("Local path", text: $editPath)
            } else {
                LabeledContent("Title", value: task.title)
            }
            LabeledContent("Owner", value: task.ownerName ?? "—")
            LabeledContent("Status", value: task.status.rawValue)
            LabeledContent("Kind", value: task.kind.rawValue)
            LabeledContent("Priority", value: task.priority.rawValue)
            LabeledContent("Date urgency", value: task.dateUrgency.rawValue)
            if !task.blockedByIDs.isEmpty {
                LabeledContent("Blocked by") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(task.blockedByIDs, id: \.self) { blockerID in
                            HStack {
                                Text(blockerTitle(blockerID))
                                Button("Remove") { session.removeBlockedBy(task.id, blockerID) }
                                    .font(.caption)
                            }
                        }
                    }
                }
                if task.hasUnsatisfiedBlockers {
                    Text("Unsatisfied blockers keep this task in the blocked workflow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !isCandidate {
                blockerPicker
            }
            if let progress = task.progressSummary {
                LabeledContent("Progress", value: progress)
            }
            if task.seriesID != nil {
                LabeledContent("Occurrence", value: task.occurrenceDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
            if !task.tags.isEmpty {
                LabeledContent("Tags", value: task.tags.joined(separator: ", "))
            }
            if let phrase = task.datePhrase {
                LabeledContent("Date", value: phrase)
            }
            if task.isOverdue {
                Text("Overdue")
                    .foregroundStyle(.red)
            }
            if !isCandidate {
                reminderControls
                tagControls
                if let owner = session.state.owners.first(where: { $0.id == task.ownerID }) {
                    aliasControls(for: owner)
                }
            }
            if let error = session.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
            if isCandidate {
                Button("Save changes") {
                    session.editCandidate(task.id, title: editTitle, notes: editNotes, localPath: editPath)
                }
                Button("Confirm", action: confirm)
                Button("Reject", role: .destructive, action: reject)
            } else {
                if !isTrash {
                    Button("Save task changes") {
                        session.editTask(task.id, title: editTitle, notes: editNotes, localPath: editPath)
                    }
                }
                Button("Not started") { session.setStatus(task.id, .notStarted) }
                Button("In progress") { session.setStatus(task.id, .inProgress) }
                Button("Waiting on other") { session.setStatus(task.id, .waitingOnOther) }
                Button("Blocked") { session.setStatus(task.id, .blocked) }
                Button("Pending acceptance") { session.setStatus(task.id, .pendingAcceptance) }
                Button("Complete") { session.setStatus(task.id, .completed) }
                Button("Cancel", role: .destructive) { session.setStatus(task.id, .cancelled) }
                Button("Priority: low") { session.setPriority(task.id, .low) }
                Button("Priority: normal") { session.setPriority(task.id, .normal) }
                Button("Priority: high") { session.setPriority(task.id, .high) }
                Button("Priority: critical") { session.setPriority(task.id, .critical) }
                ForEach(session.state.owners) { owner in
                    Button("Assign \(owner.name)") { session.setOwner(task.id, owner) }
                }
                Button("Archive", action: archive)
                Button("Move to Trash", action: trash)
                if isTrash {
                    Button("Restore", action: restore)
                    Button("Delete permanently", role: .destructive, action: delete)
                }
            }
            if !evidenceLinks.isEmpty {
                DisclosureGroup("Source evidence") {
                    ForEach(Array(evidenceLinks.enumerated()), id: \.offset) { _, evidence in
                        LabeledContent("Trigger", value: evidence.triggerPhrase)
                        LabeledContent("Excerpt", value: evidence.excerpt)
                        LabeledContent("Directory", value: evidence.workingDirectory)
                        if let time = evidence.messageTime {
                            LabeledContent("Message time", value: time.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            editTitle = task.title
            editNotes = task.notes ?? ""
            editPath = task.localPath ?? ""
        }
        .onChange(of: task.id) { _, _ in
            editTitle = task.title
            editNotes = task.notes ?? ""
            editPath = task.localPath ?? ""
        }
    }

    private var blockerPicker: some View {
        let candidates = session.state.tasks.filter {
            $0.id != task.id && !task.blockedByIDs.contains($0.id)
        }
        return Group {
            if !candidates.isEmpty {
                Menu("Add blocker") {
                    ForEach(candidates) { other in
                        Button(other.title) { session.setBlockedBy(task.id, other.id) }
                    }
                }
            }
        }
    }

    private var reminderControls: some View {
        Group {
            let current = session.reminders(for: task.id)
            if !current.isEmpty {
                ForEach(current) { reminder in
                    LabeledContent("Reminder", value: reminder.fireAt.formatted(date: .abbreviated, time: .standard))
                }
            } else {
                Text("No reminders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Remind in 1 hour") {
                session.addReminder(task.id, at: Date().addingTimeInterval(3600))
            }
            Button("Remind tomorrow 9:00") {
                session.addReminder(task.id, at: nextNine())
            }
            if !current.isEmpty {
                Button("Clear reminders", role: .destructive) {
                    session.setReminders(task.id, [])
                }
            }
        }
    }

    private var tagControls: some View {
        HStack {
            TextField("Add tag", text: $tagDraft)
            Button("Add tag") {
                let tag = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty else { return }
                session.addTag(task.id, tag)
                tagDraft = ""
            }
        }
    }

    @ViewBuilder
    private func aliasControls(for owner: OwnerSummary) -> some View {
        HStack {
            TextField("Confirm alias for \(owner.name)", text: $aliasDraft)
            Button("Confirm alias") {
                let alias = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty else { return }
                session.confirmAlias(alias, for: owner)
                aliasDraft = ""
            }
        }
    }

    private func blockerTitle(_ id: UUID) -> String {
        let known = session.state.tasks.first { $0.id == id }?.title
            ?? session.state.trash.first { $0.id == id }?.title
            ?? session.state.archived.first { $0.id == id }?.title
        if let known { return known }
        return "Removed task \(id.uuidString.prefix(8))…"
    }

    private func nextNine() -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 9
        components.minute = 0
        return calendar.date(from: components) ?? tomorrow
    }
}

private struct ModelKeySection: View {
    @ObservedObject var session: AppSession
    @State private var key = ""

    var body: some View {
        Group {
            SecureField("DeepSeek-compatible API key", text: $key)
            HStack {
                Button("Save key") {
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    session.setModelAPIKey(trimmed)
                    key = ""
                }
                Button("Clear key", role: .destructive) { session.clearModelAPIKey() }
            }
            Text("The key is stored only in the macOS Keychain and never exported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
